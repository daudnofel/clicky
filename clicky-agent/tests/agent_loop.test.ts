import { describe, it, expect, vi } from "vitest";
import { runWorkflowOnUrl } from "../src/agent_loop";
import type {
  AgentAction,
  OutboundAgentMessage,
  WorkflowProfile,
} from "../src/types";

/**
 * Minimum-viable WorkflowProfile factory. Every required field of § A.1
 * is present so the agent loop can pass it through unchanged.
 */
function makeProfile(): WorkflowProfile {
  return {
    id: "p",
    procedure: [],
    parameters: [],
    decision_rules: [],
    reference_keys: [],
    stop_condition: "submit-ready",
    output_format: "review-queue-card",
  };
}

/**
 * Test-only ReplayStepResponse type alias that mirrors what WorkerClient
 * returns. We don't import ReplayStepResponse directly because the worker
 * is stubbed in every case here.
 */
interface FakeReplayResponse {
  action: AgentAction;
  next_state_hint: "filling" | "navigating" | "drafting" | "submit_ready";
}

describe("agent loop", () => {
  it("halts immediately when worker says halt", async () => {
    const fakeWorker = {
      replayStep: vi.fn(async () => ({
        action: {
          type: "halt" as const,
          confidence: 1,
          reasoning: "stub",
        },
        next_state_hint: "submit_ready" as const,
      })),
    };
    const events: OutboundAgentMessage[] = [];

    await runWorkflowOnUrl({
      sessionId: "test",
      queueId: "q1",
      workflowProfile: makeProfile(),
      referenceData: {},
      parameters: { job_url: "about:blank" },
      worker: fakeWorker as any,
      emit: (event) => events.push(event),
      playwright: undefined, // real Playwright skipped for this unit test
    });

    expect(fakeWorker.replayStep).toHaveBeenCalledTimes(1);
    expect(events.some((e) => e.type === "queue_item_started")).toBe(true);
    expect(events.some((e) => e.type === "queue_item_ready")).toBe(true);
  });

  it("emits error and never emits queue_item_ready when MAX_STEPS is exhausted", async () => {
    // A worker that NEVER returns halt — the loop must self-terminate.
    // We don't know MAX_STEPS from outside the module; just ensure it
    // doesn't run forever and that it surfaces the right error.
    const fillForever: FakeReplayResponse = {
      action: {
        type: "fill",
        selector: "input#name",
        value: "x",
        confidence: 0.5,
        reasoning: "fill",
      },
      next_state_hint: "filling",
    };
    const fakeWorker = {
      replayStep: vi.fn(async () => fillForever),
    };
    const events: OutboundAgentMessage[] = [];

    await runWorkflowOnUrl({
      sessionId: "test",
      queueId: "q-max",
      workflowProfile: makeProfile(),
      referenceData: {},
      parameters: { job_url: "about:blank" },
      worker: fakeWorker as any,
      emit: (event) => events.push(event),
      playwright: undefined,
    });

    // queue_item_ready must NOT have been emitted — that's the whole point
    // of the MAX_STEPS guard (we never reached a halt).
    expect(events.some((e) => e.type === "queue_item_ready")).toBe(false);

    // Exactly one error event, and it must mention MAX_STEPS so an operator
    // reading logs knows what happened. Tightening on the text guards
    // against future refactors that lose the message.
    const errorEvents = events.filter((e) => e.type === "error");
    expect(errorEvents).toHaveLength(1);
    expect(errorEvents[0]).toMatchObject({
      type: "error",
      queue_id: "q-max",
      error: "MAX_STEPS exceeded",
    });

    // The worker should have been called many times — confirming we did
    // iterate, not bail at step 0.
    expect(fakeWorker.replayStep.mock.calls.length).toBeGreaterThan(5);
  });

  it("terminates without crashing when the worker throws", async () => {
    const fakeWorker = {
      replayStep: vi.fn(async () => {
        throw new Error("boom");
      }),
    };
    const events: OutboundAgentMessage[] = [];

    // Crucially: the loop must NOT propagate this rejection out — that
    // would crash the orchestrator and kill the websocket. It can either
    // emit an `error` event and return, or it can re-throw a wrapped
    // error that the orchestrator catches. The current implementation
    // lets the throw propagate, which the orchestrator's try/catch in
    // runStartJob handles. So we accept either: a thrown error OR a
    // graceful `error` event.
    let thrown: Error | null = null;
    try {
      await runWorkflowOnUrl({
        sessionId: "test",
        queueId: "q-throw",
        workflowProfile: makeProfile(),
        referenceData: {},
        parameters: { job_url: "about:blank" },
        worker: fakeWorker as any,
        emit: (event) => events.push(event),
        playwright: undefined,
      });
    } catch (err) {
      thrown = err as Error;
    }

    // The loop made it as far as queue_item_started before the worker blew.
    expect(events.some((e) => e.type === "queue_item_started")).toBe(true);

    // No queue_item_ready — we never reached a halt.
    expect(events.some((e) => e.type === "queue_item_ready")).toBe(false);

    // Either the loop emitted an error event before returning, OR it
    // surfaced the worker error to the caller. Both are acceptable
    // failure modes — the contract is "don't crash silently."
    const surfacedError =
      events.some((e) => e.type === "error") ||
      (thrown !== null && thrown.message.includes("boom"));
    expect(surfacedError).toBe(true);
  });

  it("walks a multi-step happy path: fill, click, halt — emits started, progress, ready in order", async () => {
    const fillAction: AgentAction = {
      type: "fill",
      selector: "input#email",
      value: "daud@example.com",
      confidence: 0.9,
      reasoning: "fill email",
    };
    const clickAction: AgentAction = {
      type: "click",
      selector: "button#next",
      confidence: 0.8,
      reasoning: "advance to next page",
    };
    const haltAction: AgentAction = {
      type: "halt",
      confidence: 1.0,
      reasoning: "form ready",
    };

    const responses: FakeReplayResponse[] = [
      { action: fillAction, next_state_hint: "filling" },
      { action: clickAction, next_state_hint: "navigating" },
      { action: haltAction, next_state_hint: "submit_ready" },
    ];
    let callIndex = 0;
    const fakeWorker = {
      replayStep: vi.fn(async () => responses[callIndex++]),
    };
    const events: OutboundAgentMessage[] = [];

    await runWorkflowOnUrl({
      sessionId: "test",
      queueId: "q-multi",
      workflowProfile: makeProfile(),
      referenceData: {},
      parameters: { job_url: "about:blank" },
      worker: fakeWorker as any,
      emit: (event) => events.push(event),
      playwright: undefined,
    });

    expect(fakeWorker.replayStep).toHaveBeenCalledTimes(3);

    // queue_item_started must come first.
    expect(events[0].type).toBe("queue_item_started");

    // queue_item_ready must come last (and only once).
    const readyEvents = events.filter((e) => e.type === "queue_item_ready");
    expect(readyEvents).toHaveLength(1);
    expect(events[events.length - 1].type).toBe("queue_item_ready");

    // We must have seen at least one queue_item_progress event between
    // them (one per non-halt step in this case → 2 progress events
    // before the halt step's own progress event = 3 total).
    const progressEvents = events.filter(
      (e) => e.type === "queue_item_progress"
    );
    expect(progressEvents.length).toBeGreaterThanOrEqual(1);

    // Ordering: every progress event must come after started and before
    // ready. Use indices to verify.
    const startedIdx = events.findIndex((e) => e.type === "queue_item_started");
    const readyIdx = events.findIndex((e) => e.type === "queue_item_ready");
    for (const p of progressEvents) {
      const i = events.indexOf(p);
      expect(i).toBeGreaterThan(startedIdx);
      expect(i).toBeLessThan(readyIdx);
    }
  });

  it("preserves submit_selector as a TOP-LEVEL queue_item_ready field (§ A.4 amendment)", async () => {
    const haltWithSubmit: FakeReplayResponse = {
      action: {
        type: "halt",
        submit_selector: "button#submit",
        confidence: 1.0,
        reasoning: "ready to submit",
      },
      next_state_hint: "submit_ready",
    };
    const fakeWorker = {
      replayStep: vi.fn(async () => haltWithSubmit),
    };
    const events: OutboundAgentMessage[] = [];

    await runWorkflowOnUrl({
      sessionId: "test",
      queueId: "q-submit",
      workflowProfile: makeProfile(),
      referenceData: {},
      parameters: { job_url: "about:blank" },
      worker: fakeWorker as any,
      emit: (event) => events.push(event),
      playwright: undefined,
    });

    const readyEvent = events.find((e) => e.type === "queue_item_ready");
    expect(readyEvent).toBeDefined();
    // Narrow with the discriminant so the next assertions are typed.
    if (readyEvent?.type !== "queue_item_ready") throw new Error("unreachable");

    // The amendment: submit_selector lives at the TOP of queue_item_ready,
    // NOT inside filled_fields. If a future refactor moves it back into
    // filled_fields, this test fails.
    expect(readyEvent.submit_selector).toBe("button#submit");
    expect(readyEvent.filled_fields).not.toHaveProperty("submit_selector");
    // filled_fields should still exist as an object (just empty here).
    expect(readyEvent.filled_fields).toEqual({});
  });
});
