// Unit tests for the Azure OpenAI backend behind the `ModelClient`
// abstraction. These tests do NOT require any Azure credentials — they
// inject a fake fetch via __setAzureFetchOverrideForTests and verify
// that:
//
//   1. The dispatcher routes to the Azure client when
//      WORKFLOW_MODEL_BACKEND === "azure_openai".
//   2. The request URL has the right shape
//      (`{endpoint}/openai/deployments/{deployment}/chat/completions?api-version=...`).
//   3. The `api-key` auth header is set (NOT bearer / x-api-key).
//   4. The request body uses the OpenAI Chat Completions message shape
//      (system as the first message; user multimodal content with
//      `image_url` data-URLs for vision).
//   5. `response_format: {type: "json_object"}` is set when JSON mode
//      is requested.
//   6. Happy paths for /workflow/learn and /workflow/replay-step return
//      the parsed profile / action correctly.
//   7. The Anthropic-default path is NOT affected (no env var set ->
//      AnthropicClient is used).

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { handleWorkflowLearn } from "../src/workflow_learn";
import { handleWorkflowReplayStep } from "../src/workflow_replay_step";
import { __setAzureFetchOverrideForTests } from "../src/azure_openai_client";
import { __setFetchOverrideForTests as __setAnthropicFetchOverrideForTests } from "../src/anthropic_client";
import type { Env } from "../src/types";

// Env with all four Azure fields set. WORKFLOW_MODEL_BACKEND is the
// trigger that routes through AzureOpenAIClient instead of AnthropicClient.
const azureEnv: Env = {
  ANTHROPIC_API_KEY: "test-anthropic-key", // present but unused on Azure path
  ELEVENLABS_API_KEY: "test-key",
  ELEVENLABS_VOICE_ID: "test-voice",
  ASSEMBLYAI_API_KEY: "test-key",
  WORKFLOW_MODEL_BACKEND: "azure_openai",
  AZURE_OPENAI_ENDPOINT: "https://my-resource.openai.azure.com",
  AZURE_OPENAI_API_KEY: "test-azure-key",
  AZURE_OPENAI_DEPLOYMENT: "gpt-4o-prod",
  AZURE_OPENAI_API_VERSION: "2024-10-21",
};

/**
 * Build an OpenAI Chat Completions success response. The handler reads
 * `choices[0].message.content` as the model's text output, then
 * JSON.parses it.
 */
function fakeOpenAISuccess(jsonContent: string): Response {
  return new Response(
    JSON.stringify({
      id: "chatcmpl-test",
      object: "chat.completion",
      choices: [
        {
          index: 0,
          message: { role: "assistant", content: jsonContent },
          finish_reason: "stop",
        },
      ],
      usage: {
        prompt_tokens: 42,
        completion_tokens: 17,
        total_tokens: 59,
      },
    }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
}

/**
 * Same shape as the learn-test fixture but factored out so the assertions
 * focus on the Azure-specific request body shape, not on how the form
 * was assembled.
 */
function buildLearnRequest(opts: {
  manifest: Record<string, unknown>;
  events: string;
  frameCount?: number;
}): Request {
  const formData = new FormData();
  formData.append("manifest", JSON.stringify(opts.manifest));
  formData.append("events", opts.events);
  formData.append("transcript", JSON.stringify({ utterances: [] }));
  const frameCount = opts.frameCount ?? 2;
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

function buildReplayRequest(body: Record<string, unknown>): Request {
  return new Request("http://localhost/workflow/replay-step", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("AzureOpenAIClient (mocked) via /workflow/learn", () => {
  beforeEach(() => {
    __setAzureFetchOverrideForTests(null);
    // Also clear the Anthropic override so a stray earlier test can't
    // leak into ours.
    __setAnthropicFetchOverrideForTests(null);
  });

  afterEach(() => {
    __setAzureFetchOverrideForTests(null);
    __setAnthropicFetchOverrideForTests(null);
  });

  it("routes to Azure when WORKFLOW_MODEL_BACKEND=azure_openai and returns a parsed profile", async () => {
    let observedUrl: string | null = null;
    let observedInit: RequestInit | null = null;
    __setAzureFetchOverrideForTests(async (url, init) => {
      observedUrl = url;
      observedInit = init;
      return fakeOpenAISuccess(
        JSON.stringify({
          name: "Apply to jobs",
          procedure: [{ step_index: 0, intent: "open URL" }],
          parameters: [{ name: "job_url", type: "url" }],
          decision_rules: [],
          reference_keys: ["identity.name"],
          stop_condition: "submit-ready",
          output_format: "review-queue-card",
        }),
      );
    });
    // Sanity guard: if the dispatcher ever wrongly routes to Anthropic,
    // its fetch override would fire — and we'd notice because the test
    // observation variables stay null.
    __setAnthropicFetchOverrideForTests(async () => {
      throw new Error(
        "Anthropic fetch was called but WORKFLOW_MODEL_BACKEND=azure_openai — routing bug",
      );
    });

    const req = buildLearnRequest({
      manifest: { uuid: "demo-azure-1" },
      events: "",
    });
    const res = await handleWorkflowLearn(req, azureEnv);

    expect(res.status).toBe(200);
    const body = (await res.json()) as { profile: Record<string, unknown> };
    expect(body.profile.procedure).toBeInstanceOf(Array);
    expect(body.profile.source_demo_uuid).toBe("demo-azure-1");
    expect(body.profile.id).toMatch(/^wf-/);

    // URL shape: `${endpoint}/openai/deployments/${deployment}/chat/completions?api-version=...`
    expect(observedUrl).not.toBeNull();
    expect(observedUrl).toContain(
      "https://my-resource.openai.azure.com/openai/deployments/gpt-4o-prod/chat/completions",
    );
    expect(observedUrl).toContain("api-version=2024-10-21");

    // api-key header is set (NOT bearer).
    expect(observedInit).not.toBeNull();
    const headers = (observedInit as RequestInit).headers as Record<
      string,
      string
    >;
    expect(headers["api-key"]).toBe("test-azure-key");
    expect(headers["x-api-key"]).toBeUndefined();
    expect(headers["authorization"]).toBeUndefined();
  });

  it("uses OpenAI message shape: system message first, user content with image_url data-URLs", async () => {
    let observedBody: Record<string, unknown> | null = null;
    __setAzureFetchOverrideForTests(async (_url, init) => {
      observedBody = JSON.parse(init.body as string);
      return fakeOpenAISuccess(
        JSON.stringify({ procedure: [{ step_index: 0, intent: "ok" }] }),
      );
    });

    const req = buildLearnRequest({
      manifest: { uuid: "demo-azure-shape" },
      events: "",
      frameCount: 3,
    });
    await handleWorkflowLearn(req, azureEnv);

    expect(observedBody).not.toBeNull();
    const body = observedBody as {
      messages: Array<{ role: string; content: unknown }>;
      response_format?: { type: string };
    };

    // First message is the system role with the concatenated system
    // prompt (no `cache_control` markers — Azure caching is implicit).
    expect(body.messages[0].role).toBe("system");
    expect(typeof body.messages[0].content).toBe("string");
    // The static LEARN_SYSTEM_PROMPT mentions "WorkflowProfile" — sanity
    // check that it landed in the system message.
    expect(body.messages[0].content as string).toMatch(/WorkflowProfile/i);

    // Second message is the user role with multimodal content.
    expect(body.messages[1].role).toBe("user");
    const userContent = body.messages[1].content as Array<
      Record<string, unknown>
    >;
    expect(Array.isArray(userContent)).toBe(true);
    // Image parts use `image_url` with a data URL — NOT the Anthropic
    // `source.type=base64` shape.
    const imageParts = userContent.filter(
      (part) => part.type === "image_url",
    );
    expect(imageParts.length).toBe(3);
    for (const part of imageParts) {
      const imageUrl = part.image_url as { url: string };
      expect(imageUrl.url).toMatch(/^data:image\/jpeg;base64,/);
    }
    // Text part exists alongside the images.
    const textParts = userContent.filter((part) => part.type === "text");
    expect(textParts.length).toBeGreaterThan(0);
  });

  it("sets response_format: {type: 'json_object'} when JSON mode is requested", async () => {
    let observedBody: Record<string, unknown> | null = null;
    __setAzureFetchOverrideForTests(async (_url, init) => {
      observedBody = JSON.parse(init.body as string);
      return fakeOpenAISuccess(
        JSON.stringify({ procedure: [{ step_index: 0, intent: "ok" }] }),
      );
    });

    const req = buildLearnRequest({
      manifest: { uuid: "demo-azure-json-mode" },
      events: "",
    });
    await handleWorkflowLearn(req, azureEnv);

    const body = observedBody as { response_format?: { type: string } };
    expect(body.response_format).toEqual({ type: "json_object" });
  });

  it("uses max_tokens by default and max_completion_tokens when AZURE_OPENAI_MAX_TOKENS_PARAM is set", async () => {
    let observedBody: Record<string, unknown> | null = null;
    __setAzureFetchOverrideForTests(async (_url, init) => {
      observedBody = JSON.parse(init.body as string);
      return fakeOpenAISuccess(
        JSON.stringify({ procedure: [{ step_index: 0, intent: "ok" }] }),
      );
    });

    // Default path uses max_tokens.
    await handleWorkflowLearn(
      buildLearnRequest({ manifest: { uuid: "max-tokens-default" }, events: "" }),
      azureEnv,
    );
    expect(observedBody).not.toBeNull();
    expect((observedBody as Record<string, unknown>).max_tokens).toBe(4096);
    expect(
      (observedBody as Record<string, unknown>).max_completion_tokens,
    ).toBeUndefined();

    // Override path uses max_completion_tokens.
    const envWithCompletionTokens: Env = {
      ...azureEnv,
      AZURE_OPENAI_MAX_TOKENS_PARAM: "max_completion_tokens",
    };
    await handleWorkflowLearn(
      buildLearnRequest({
        manifest: { uuid: "max-completion-tokens" },
        events: "",
      }),
      envWithCompletionTokens,
    );
    expect((observedBody as Record<string, unknown>).max_completion_tokens).toBe(
      4096,
    );
    expect((observedBody as Record<string, unknown>).max_tokens).toBeUndefined();
  });
});

describe("AzureOpenAIClient (mocked) via /workflow/replay-step", () => {
  beforeEach(() => {
    __setAzureFetchOverrideForTests(null);
    __setAnthropicFetchOverrideForTests(null);
  });

  afterEach(() => {
    __setAzureFetchOverrideForTests(null);
    __setAnthropicFetchOverrideForTests(null);
  });

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

  it("returns a valid `fill` AgentAction from a clean OpenAI response", async () => {
    __setAzureFetchOverrideForTests(async () =>
      fakeOpenAISuccess(
        JSON.stringify({
          action: {
            type: "fill",
            selector: "aria-ref=e7",
            value: "daud@example.com",
            confidence: 0.9,
            reasoning: "filling email",
          },
          next_state_hint: "filling",
        }),
      ),
    );

    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, azureEnv);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { action: Record<string, unknown> };
    expect(body.action.type).toBe("fill");
    expect(body.action.selector).toBe("aria-ref=e7");
    expect(body.action.value).toBe("daud@example.com");
  });

  it("includes the workflow_profile as part of the system message (Azure has no per-block cache markers)", async () => {
    let observedBody: Record<string, unknown> | null = null;
    __setAzureFetchOverrideForTests(async (_url, init) => {
      observedBody = JSON.parse(init.body as string);
      return fakeOpenAISuccess(
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
    await handleWorkflowReplayStep(req, azureEnv);

    const body = observedBody as {
      messages: Array<{ role: string; content: unknown }>;
    };
    // System content has both the static REPLAY_SYSTEM_PROMPT and the
    // serialized workflow_profile concatenated. Azure relies on implicit
    // prefix caching, so we don't expect any `cache_control` markers in
    // the request — we just expect the workflow profile text to be
    // present in the system message.
    const systemContent = body.messages[0].content as string;
    expect(systemContent).toMatch(/WORKFLOW_PROFILE_FOR_REPLAY/);
    expect(systemContent).toMatch(/wf-test/);
    // Spot-check that there's no Anthropic-style cache_control marker
    // anywhere in the request body.
    expect(JSON.stringify(observedBody)).not.toMatch(/cache_control/);
  });

  it("includes the screenshot as an image_url block when provided", async () => {
    let imageBlockCount = 0;
    __setAzureFetchOverrideForTests(async (_url, init) => {
      const parsedBody = JSON.parse(init.body as string) as {
        messages: Array<{ role: string; content: Array<{ type: string }> }>;
      };
      // The user message is the second message.
      const userContent = parsedBody.messages[1].content;
      imageBlockCount = userContent.filter(
        (part) => part.type === "image_url",
      ).length;
      return fakeOpenAISuccess(
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
      screenshot_b64: "/9j/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODw==",
    });
    await handleWorkflowReplayStep(req, azureEnv);
    expect(imageBlockCount).toBe(1);
  });

  it("falls back to safe halt on Azure parse failure", async () => {
    __setAzureFetchOverrideForTests(async () =>
      fakeOpenAISuccess("not valid JSON at all"),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, azureEnv);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { action: Record<string, unknown> };
    expect(body.action.type).toBe("halt");
    expect(body.action.submit_selector).toBeNull();
  });

  it("falls back to safe halt on Azure upstream non-2xx", async () => {
    __setAzureFetchOverrideForTests(async () =>
      new Response("rate limited", {
        status: 429,
        headers: { "content-type": "text/plain" },
      }),
    );
    const req = buildReplayRequest(defaultRequestBody);
    const res = await handleWorkflowReplayStep(req, azureEnv);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { action: Record<string, unknown> };
    expect(body.action.type).toBe("halt");
    expect(body.action.reasoning).toMatch(/429/);
  });
});

describe("Dispatcher: Anthropic remains the default", () => {
  beforeEach(() => {
    __setAzureFetchOverrideForTests(null);
    __setAnthropicFetchOverrideForTests(null);
  });

  afterEach(() => {
    __setAzureFetchOverrideForTests(null);
    __setAnthropicFetchOverrideForTests(null);
  });

  it("falls back to Anthropic when WORKFLOW_MODEL_BACKEND is unset", async () => {
    let anthropicCalled = false;
    __setAnthropicFetchOverrideForTests(async () => {
      anthropicCalled = true;
      return new Response(
        JSON.stringify({
          id: "msg_test",
          content: [
            {
              type: "text",
              text: JSON.stringify({
                procedure: [{ step_index: 0, intent: "ok" }],
              }),
            },
          ],
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    });
    __setAzureFetchOverrideForTests(async () => {
      throw new Error(
        "Azure fetch was called but WORKFLOW_MODEL_BACKEND is unset — routing bug",
      );
    });

    const envWithoutBackend: Env = {
      ANTHROPIC_API_KEY: "test-key",
      ELEVENLABS_API_KEY: "test-key",
      ELEVENLABS_VOICE_ID: "test-voice",
      ASSEMBLYAI_API_KEY: "test-key",
    };
    const req = buildLearnRequest({
      manifest: { uuid: "demo-default-anthropic" },
      events: "",
    });
    const res = await handleWorkflowLearn(req, envWithoutBackend);
    expect(res.status).toBe(200);
    expect(anthropicCalled).toBe(true);
  });

  it("also falls back to Anthropic when WORKFLOW_MODEL_BACKEND has any non-azure_openai value (typo guard)", async () => {
    let anthropicCalled = false;
    __setAnthropicFetchOverrideForTests(async () => {
      anthropicCalled = true;
      return new Response(
        JSON.stringify({
          id: "msg_test",
          content: [
            {
              type: "text",
              text: JSON.stringify({
                procedure: [{ step_index: 0, intent: "ok" }],
              }),
            },
          ],
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    });
    __setAzureFetchOverrideForTests(async () => {
      throw new Error(
        "Azure fetch was called but WORKFLOW_MODEL_BACKEND value is a typo — should fall back to Anthropic",
      );
    });

    // Hyphen instead of underscore — a common typo. Must NOT route to Azure.
    const envWithTypo: Env = {
      ANTHROPIC_API_KEY: "test-key",
      ELEVENLABS_API_KEY: "test-key",
      ELEVENLABS_VOICE_ID: "test-voice",
      ASSEMBLYAI_API_KEY: "test-key",
      WORKFLOW_MODEL_BACKEND: "azure-openai",
    };
    const req = buildLearnRequest({
      manifest: { uuid: "demo-typo-guard" },
      events: "",
    });
    const res = await handleWorkflowLearn(req, envWithTypo);
    expect(res.status).toBe(200);
    expect(anthropicCalled).toBe(true);
  });
});
