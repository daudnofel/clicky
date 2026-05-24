// Unit tests for `/workflow/replay-step`. These tests do NOT require an
// Anthropic API key or a running wrangler dev server. They inject a
// fake fetch via __setFetchOverrideForTests and verify the handler's
// validation, caching, and halt-on-error behavior.

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { handleWorkflowReplayStep } from "../src/workflow_replay_step";
import { __setFetchOverrideForTests } from "../src/anthropic_client";
import type { Env } from "../src/types";

const fakeEnv: Env = {
  ANTHROPIC_API_KEY: "test-key",
  ELEVENLABS_API_KEY: "test-key",
  ELEVENLABS_VOICE_ID: "test-voice",
  ASSEMBLYAI_API_KEY: "test-key",
};

function buildReplayRequest(
  body: Record<string, unknown>,
): Request {
  return new Request("http://localhost/workflow/replay-step", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function fakeClaudeSuccess(actionJsonString: string): Response {
  return new Response(
    JSON.stringify({
      id: "msg_test",
      role: "assistant",
      content: [{ type: "text", text: actionJsonString }],
    }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
}

const defaultRequestBody = {
  session_id: "session-test",
  workflow_profile: {
    id: "wf-test",
    procedure: [{ step_index: 0, intent: "open URL" }],
  },
  reference_data: { identity: { name: "Daud" } },
  parameters: { job_url: "https://example.com/job/1" },
  current_url: "https://example.com/job/1",
  screenshot_b64: "",
  accessibility_tree: "page:\n  - button [ref=e3]: Apply",
  step_history: [],
};

describe("handleWorkflowReplayStep (mocked Claude)", () => {
  beforeEach(() => {
    __setFetchOverrideForTests(null);
  });

  afterEach(() => {
    __setFetchOverrideForTests(null);
  });

  it("returns a valid `fill` action from a clean Claude response", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "fill",
            selector: "aria-ref=e7",
            value: "daud@example.com",
            confidence: 0.9,
            reasoning: "filling email field",
          },
          next_state_hint: "filling",
        }),
      ),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { action: Record<string, unknown> };
    expect(body.action.type).toBe("fill");
    expect(body.action.selector).toBe("aria-ref=e7");
    expect(body.action.value).toBe("daud@example.com");
  });

  it("preserves Claude's submit_selector on halt actions (§ A.3 amendment)", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "halt",
            confidence: 1,
            reasoning: "form is complete; ready to submit",
            submit_selector: "aria-ref=e42",
          },
          next_state_hint: "submit_ready",
        }),
      ),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    const body = (await res.json()) as { action: Record<string, unknown> };
    expect(body.action.type).toBe("halt");
    expect(body.action.submit_selector).toBe("aria-ref=e42");
  });

  it("stamps submit_selector=null on halt when Claude forgot to emit it", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "halt",
            confidence: 0.5,
            reasoning: "cannot find submit button",
          },
          next_state_hint: "submit_ready",
        }),
      ),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    const body = (await res.json()) as { action: Record<string, unknown> };
    expect(body.action.type).toBe("halt");
    expect(body.action).toHaveProperty("submit_selector");
    expect(body.action.submit_selector).toBeNull();
  });

  it("falls back to safe halt when Claude produces invalid JSON", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess("I'm sorry, I cannot do that."),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { action: Record<string, unknown> };
    expect(body.action.type).toBe("halt");
    expect(body.action.confidence).toBe(0);
    expect(body.action.reasoning).toMatch(/invalid JSON/i);
    expect(body.action.submit_selector).toBeNull();
  });

  it("strips markdown code fences from Claude's JSON output", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        '```json\n{"action":{"type":"click","selector":"aria-ref=e4","confidence":0.8,"reasoning":"next"},"next_state_hint":"filling"}\n```',
      ),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    const body = (await res.json()) as { action: Record<string, unknown> };
    expect(body.action.type).toBe("click");
    expect(body.action.selector).toBe("aria-ref=e4");
  });

  it("falls back to safe halt when Claude returns a schema-invalid action type", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        JSON.stringify({
          action: { type: "DROP_TABLES", selector: "anything" },
          next_state_hint: "filling",
        }),
      ),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    const body = (await res.json()) as { action: Record<string, unknown> };
    expect(body.action.type).toBe("halt");
    expect(body.action.reasoning).toMatch(/schema/i);
  });

  it("sends the workflow_profile as a cached system block (the per-job cache win)", async () => {
    let observedClaudeBody: Record<string, unknown> | null = null;
    __setFetchOverrideForTests(async (_url, init) => {
      observedClaudeBody = JSON.parse(init.body as string);
      return fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "halt",
            confidence: 1,
            reasoning: "done",
            submit_selector: null,
          },
          next_state_hint: "submit_ready",
        }),
      );
    });
    const req = buildReplayRequest(defaultRequestBody);
    await handleWorkflowReplayStep(req, fakeEnv);

    expect(observedClaudeBody).not.toBeNull();
    const sys = (observedClaudeBody as { system: unknown }).system as Array<
      Record<string, unknown>
    >;
    expect(sys.length).toBe(2);
    expect(sys[0].cache_control).toEqual({ type: "ephemeral" });
    expect(sys[1].cache_control).toEqual({ type: "ephemeral" });
    // Second block contains the serialized workflow_profile.
    expect(sys[1].text).toMatch(/WORKFLOW_PROFILE_FOR_REPLAY/);
    expect(sys[1].text).toMatch(/wf-test/);
  });

  it("falls back to safe halt on upstream non-2xx response", async () => {
    __setFetchOverrideForTests(async () =>
      new Response("overloaded", {
        status: 529,
        headers: { "content-type": "text/plain" },
      }),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { action: Record<string, unknown> };
    expect(body.action.type).toBe("halt");
    expect(body.action.reasoning).toMatch(/529/);
  });

  it("falls back to safe halt on a malformed request body", async () => {
    const req = new Request("http://localhost/workflow/replay-step", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{not-json",
    });
    __setFetchOverrideForTests(async () => {
      throw new Error("should not call Claude with malformed body");
    });
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    // 400 is fine here — the body is genuinely malformed input from the
    // caller, so signalling that loudly is appropriate.
    expect(res.status).toBe(400);
    const body = (await res.json()) as { action: Record<string, unknown> };
    expect(body.action.type).toBe("halt");
  });

  it("includes the screenshot as an image block when provided", async () => {
    let imageBlockCount = 0;
    __setFetchOverrideForTests(async (_url, init) => {
      const parsedBody = JSON.parse(init.body as string) as {
        messages: Array<{ content: Array<{ type: string }> }>;
      };
      imageBlockCount = parsedBody.messages[0].content.filter(
        (block) => block.type === "image",
      ).length;
      return fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "halt",
            confidence: 1,
            reasoning: "ok",
            submit_selector: null,
          },
          next_state_hint: "submit_ready",
        }),
      );
    });
    const req = buildReplayRequest({
      ...defaultRequestBody,
      screenshot_b64: "/9j/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODw==", // dummy
    });
    await handleWorkflowReplayStep(req, fakeEnv);
    expect(imageBlockCount).toBe(1);
  });

  // ---------------------------------------------------------------------
  // § A.3 amendment 2026-05-23 — results-list halt payload validation.
  // The model emits a peer `results` array on halt when the workflow's
  // output_format is "results-list". The handler must pass clean payloads
  // through unchanged and sanitize malformed entries without dropping the
  // whole halt.
  // ---------------------------------------------------------------------

  it("passes a clean `results` array through unchanged on halt", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "halt",
            confidence: 0.9,
            reasoning: "scanned the results list",
            results: [
              {
                title: "Senior Data Scientist — Acme",
                fields: { salary: "$220K", location: "Remote", company: "Acme" },
                url: "https://remoteok.com/job/12345",
              },
              {
                title: "ML Engineer — Globex",
                fields: { salary: "$200K", location: "NYC" },
              },
            ],
          },
          next_state_hint: "submit_ready",
        }),
      ),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    const body = (await res.json()) as {
      action: {
        type: string;
        results?: Array<{ title: string; fields: Record<string, string>; url?: string }>;
      };
    };
    expect(body.action.type).toBe("halt");
    expect(body.action.results).toBeDefined();
    expect(body.action.results).toHaveLength(2);
    expect(body.action.results?.[0].title).toBe("Senior Data Scientist — Acme");
    expect(body.action.results?.[0].fields.salary).toBe("$220K");
    expect(body.action.results?.[0].url).toBe("https://remoteok.com/job/12345");
    // Second item has no url — the field should be absent (not null) so
    // the Swift Codable decode sees an "no url" item correctly.
    expect(body.action.results?.[1].url).toBeUndefined();
  });

  it("drops items missing a title from the `results` array but keeps the rest", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "halt",
            confidence: 0.7,
            reasoning: "two of three rows had titles",
            results: [
              { title: "Good item", fields: { price: "$10" } },
              { fields: { price: "$20" } }, // missing title → dropped
              { title: "", fields: {} }, // empty title → dropped
              { title: "Another good item", fields: {} },
            ],
          },
          next_state_hint: "submit_ready",
        }),
      ),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    const body = (await res.json()) as {
      action: { results?: Array<{ title: string }> };
    };
    expect(body.action.results).toHaveLength(2);
    expect(body.action.results?.[0].title).toBe("Good item");
    expect(body.action.results?.[1].title).toBe("Another good item");
  });

  it("coerces non-string `fields` values to strings and replaces non-object fields with {}", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "halt",
            confidence: 0.5,
            reasoning: "mixed types in fields",
            results: [
              {
                title: "Numeric salary",
                fields: { salary: 220000, remote: true, junk: null },
              },
              {
                title: "Not an object",
                fields: "salary=200K",
              },
            ],
          },
          next_state_hint: "submit_ready",
        }),
      ),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    const body = (await res.json()) as {
      action: { results?: Array<{ title: string; fields: Record<string, string> }> };
    };
    expect(body.action.results).toHaveLength(2);
    expect(body.action.results?.[0].fields.salary).toBe("220000");
    expect(body.action.results?.[0].fields.remote).toBe("true");
    // null values are dropped from `fields`, not stringified.
    expect(body.action.results?.[0].fields.junk).toBeUndefined();
    expect(body.action.results?.[1].fields).toEqual({});
  });

  it("strips a non-string `url` from a results item but keeps the item", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "halt",
            confidence: 0.5,
            reasoning: "bad url type",
            results: [
              { title: "Has bad url", fields: {}, url: 12345 },
            ],
          },
          next_state_hint: "submit_ready",
        }),
      ),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    const body = (await res.json()) as {
      action: { results?: Array<{ title: string; url?: string }> };
    };
    expect(body.action.results).toHaveLength(1);
    expect(body.action.results?.[0].title).toBe("Has bad url");
    expect(body.action.results?.[0].url).toBeUndefined();
  });

  it("caps the `results` array at 15 items", async () => {
    // Build a 25-item results list to test the cap.
    const oversizedResultsArray = Array.from({ length: 25 }, (_, idx) => ({
      title: `Item ${idx}`,
      fields: { idx: String(idx) },
    }));
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "halt",
            confidence: 0.8,
            reasoning: "oversize list",
            results: oversizedResultsArray,
          },
          next_state_hint: "submit_ready",
        }),
      ),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    const body = (await res.json()) as {
      action: { results?: unknown[] };
    };
    expect(body.action.results).toHaveLength(15);
  });

  it("strips a non-array `results` field entirely (rather than dropping the halt)", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "halt",
            confidence: 0.5,
            reasoning: "model emitted results as an object instead of an array",
            results: { not: "an array" },
          },
          next_state_hint: "submit_ready",
        }),
      ),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, fakeEnv);
    const body = (await res.json()) as {
      action: { type: string; results?: unknown };
    };
    expect(body.action.type).toBe("halt");
    expect(body.action.results).toBeUndefined();
  });

  it("omits the image block when screenshot_b64 is empty", async () => {
    let imageBlockCount = 0;
    __setFetchOverrideForTests(async (_url, init) => {
      const parsedBody = JSON.parse(init.body as string) as {
        messages: Array<{ content: Array<{ type: string }> }>;
      };
      imageBlockCount = parsedBody.messages[0].content.filter(
        (block) => block.type === "image",
      ).length;
      return fakeClaudeSuccess(
        JSON.stringify({
          action: {
            type: "halt",
            confidence: 1,
            reasoning: "ok",
            submit_selector: null,
          },
          next_state_hint: "submit_ready",
        }),
      );
    });
    const req = buildReplayRequest(defaultRequestBody);
    await handleWorkflowReplayStep(req, fakeEnv);
    expect(imageBlockCount).toBe(0);
  });
});
