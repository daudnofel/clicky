// Unit tests for `/workflow/learn`. These tests do NOT require an
// Anthropic API key or a running wrangler dev server — they inject a
// fake fetch via __setFetchOverrideForTests and verify the handler's
// parsing, stamping, and error-handling behavior.

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { handleWorkflowLearn } from "../src/workflow_learn";
import { __setFetchOverrideForTests } from "../src/anthropic_client";
import type { Env } from "../src/types";

const fakeEnv: Env = {
  ANTHROPIC_API_KEY: "test-key",
  ELEVENLABS_API_KEY: "test-key",
  ELEVENLABS_VOICE_ID: "test-voice",
  ASSEMBLYAI_API_KEY: "test-key",
};

/**
 * Build a multipart/form-data Request the same way the Swift recorder
 * would. The frame data is a tiny 1x1 JPEG so the encoding path runs
 * through without ballooning the test.
 */
function buildLearnRequest(opts: {
  manifest: Record<string, unknown>;
  events: string;
  transcript?: Record<string, unknown>;
  frameCount?: number;
}): Request {
  const formData = new FormData();
  formData.append("manifest", JSON.stringify(opts.manifest));
  formData.append("events", opts.events);
  formData.append(
    "transcript",
    JSON.stringify(opts.transcript ?? { utterances: [] }),
  );
  const frameCount = opts.frameCount ?? 3;
  // 1x1 JPEG: minimum valid JPEG header + EOI. Bytes don't have to
  // decode; the handler only base64-encodes them.
  const tinyJpegBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
  for (let i = 0; i < frameCount; i++) {
    const name = `frame_${String(i).padStart(4, "0")}`;
    formData.append(name, new File([tinyJpegBytes], `${name}.jpg`));
  }
  return new Request("http://localhost/workflow/learn", {
    method: "POST",
    body: formData,
  });
}

/**
 * Helper to build a fake Anthropic Messages API success response. The
 * `content[0].text` is what the handler parses as the WorkflowProfile.
 */
function fakeClaudeSuccess(profileJsonString: string): Response {
  return new Response(
    JSON.stringify({
      id: "msg_test",
      role: "assistant",
      content: [{ type: "text", text: profileJsonString }],
    }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
}

describe("handleWorkflowLearn (mocked Claude)", () => {
  beforeEach(() => {
    __setFetchOverrideForTests(null);
  });

  afterEach(() => {
    __setFetchOverrideForTests(null);
  });

  it("parses a well-formed WorkflowProfile and stamps id/timestamps/source_demo_uuid", async () => {
    let observedClaudeBody: Record<string, unknown> | null = null;
    __setFetchOverrideForTests(async (_url, init) => {
      observedClaudeBody = JSON.parse(init.body as string);
      return fakeClaudeSuccess(
        JSON.stringify({
          name: "Apply to engineering jobs",
          procedure: [
            { step_index: 0, intent: "open application URL" },
            { step_index: 1, intent: "fill personal info from reference data" },
          ],
          parameters: [
            { name: "job_url", type: "url", example_from_demo: "https://x.com" },
          ],
          decision_rules: ["use full name not initials"],
          reference_keys: ["identity.name", "identity.email"],
          style_profile: { applicable: false },
          stop_condition: "submit-ready",
          output_format: "review-queue-card",
        }),
      );
    });

    const req = buildLearnRequest({
      manifest: { uuid: "demo-uuid-123", startedAt: "2026-05-22T12:00:00Z" },
      events:
        '{"t":0.1,"type":"click","x":100,"y":200}\n{"t":1.5,"type":"url_change","url":"https://example.com"}',
    });
    const res = await handleWorkflowLearn(req, fakeEnv);

    expect(res.status).toBe(200);
    const body = (await res.json()) as { profile: Record<string, unknown> };
    expect(body.profile).toBeDefined();
    expect(body.profile.id).toMatch(/^wf-/);
    expect(body.profile.created_from_demo_at).toBeTypeOf("string");
    expect(body.profile.source_demo_uuid).toBe("demo-uuid-123");
    expect(body.profile.procedure).toBeInstanceOf(Array);
    expect((body.profile.procedure as unknown[]).length).toBe(2);

    // Verify the Claude request used cache_control on the system prompt.
    expect(observedClaudeBody).not.toBeNull();
    const sys = (observedClaudeBody as { system: unknown }).system as Array<
      Record<string, unknown>
    >;
    expect(sys[0].cache_control).toEqual({ type: "ephemeral" });
  });

  it("strips markdown code fences from Claude's JSON output", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(
        '```json\n{"procedure":[{"step_index":0,"intent":"fenced output"}]}\n```',
      ),
    );
    const req = buildLearnRequest({
      manifest: { uuid: "demo-uuid-fenced" },
      events: "",
    });
    const res = await handleWorkflowLearn(req, fakeEnv);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { profile: Record<string, unknown> };
    expect((body.profile.procedure as Array<{ intent: string }>)[0].intent).toBe(
      "fenced output",
    );
  });

  it("returns 502 when Claude produces non-JSON output", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess("Sure! Here is your profile: it has 4 steps."),
    );
    const req = buildLearnRequest({
      manifest: { uuid: "demo-uuid-nonjson" },
      events: "",
    });
    const res = await handleWorkflowLearn(req, fakeEnv);
    expect(res.status).toBe(502);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/not valid JSON/i);
  });

  it("returns 502 when Claude's output is missing the required `procedure` array", async () => {
    __setFetchOverrideForTests(async () =>
      fakeClaudeSuccess(JSON.stringify({ name: "no procedure here" })),
    );
    const req = buildLearnRequest({
      manifest: { uuid: "demo-uuid-noprocedure" },
      events: "",
    });
    const res = await handleWorkflowLearn(req, fakeEnv);
    expect(res.status).toBe(502);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/procedure/);
  });

  it("forwards non-2xx upstream errors with the upstream status code", async () => {
    __setFetchOverrideForTests(async () =>
      new Response("rate limited", {
        status: 429,
        headers: { "content-type": "text/plain" },
      }),
    );
    const req = buildLearnRequest({
      manifest: { uuid: "demo-uuid-429" },
      events: "",
    });
    const res = await handleWorkflowLearn(req, fakeEnv);
    expect(res.status).toBe(429);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/Anthropic API error/);
  });

  it("returns 400 when required form fields are missing", async () => {
    // No manifest at all.
    const formData = new FormData();
    formData.append("events", "");
    const req = new Request("http://localhost/workflow/learn", {
      method: "POST",
      body: formData,
    });
    __setFetchOverrideForTests(async () => {
      throw new Error(
        "should not call Claude when required fields are missing",
      );
    });
    const res = await handleWorkflowLearn(req, fakeEnv);
    expect(res.status).toBe(400);
  });

  it("downsamples frames to at most 12 even when many are uploaded", async () => {
    // Capture the Claude request body so we can count `type: "image"` blocks.
    let imageCount = 0;
    __setFetchOverrideForTests(async (_url, init) => {
      const parsedBody = JSON.parse(init.body as string) as {
        messages: Array<{ content: Array<{ type: string }> }>;
      };
      imageCount = parsedBody.messages[0].content.filter(
        (block) => block.type === "image",
      ).length;
      return fakeClaudeSuccess(
        JSON.stringify({ procedure: [{ step_index: 0, intent: "ok" }] }),
      );
    });
    const req = buildLearnRequest({
      manifest: { uuid: "demo-uuid-many-frames" },
      events: "",
      frameCount: 50,
    });
    const res = await handleWorkflowLearn(req, fakeEnv);
    expect(res.status).toBe(200);
    expect(imageCount).toBeLessThanOrEqual(12);
    expect(imageCount).toBeGreaterThan(0);
  });
});
