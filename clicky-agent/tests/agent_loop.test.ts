import { describe, it, expect, vi } from "vitest";
import { runWorkflowOnUrl } from "../src/agent_loop";
import type { WorkflowProfile } from "../src/types";

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
    const events: any[] = [];

    const profile: WorkflowProfile = {
      id: "p",
      procedure: [],
      parameters: [],
      decision_rules: [],
      reference_keys: [],
      stop_condition: "submit-ready",
      output_format: "review-queue-card",
    };

    await runWorkflowOnUrl({
      sessionId: "test",
      queueId: "q1",
      workflowProfile: profile,
      referenceData: {},
      parameters: { job_url: "about:blank" },
      worker: fakeWorker as any,
      emit: (e) => events.push(e),
      playwright: undefined, // real Playwright skipped for this unit test
    });

    expect(fakeWorker.replayStep).toHaveBeenCalledTimes(1);
    expect(events.some((e) => e.type === "queue_item_started")).toBe(true);
    expect(events.some((e) => e.type === "queue_item_ready")).toBe(true);
  });
});
