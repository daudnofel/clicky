import type { Env } from "./types";
import {
  callClaude,
  extractTextFromClaudeResponse,
  stripCodeFences,
} from "./anthropic_client";
import { REPLAY_SYSTEM_PROMPT } from "./prompts/replay_system";

/**
 * Cap on Claude's response length. A single AgentAction is small — a few
 * hundred tokens at most even when `drafted_text` is long. 1024 leaves
 * plenty of headroom for verbose drafts without inviting runaway output.
 */
const MAX_OUTPUT_TOKENS = 1024;

/**
 * Default action returned when ANYTHING goes wrong (Claude unreachable,
 * invalid JSON, malformed shape). The Node agent halts cleanly on this so
 * we never execute random Playwright clicks against a half-understood DOM.
 */
function safeHaltAction(reasoning: string): Record<string, unknown> {
  return {
    action: {
      type: "halt",
      confidence: 0,
      reasoning,
      submit_selector: null,
    },
    next_state_hint: "submit_ready",
  };
}

type ReplayRequestBody = {
  session_id?: unknown;
  workflow_profile?: unknown;
  reference_data?: unknown;
  parameters?: unknown;
  current_url?: unknown;
  screenshot_b64?: unknown;
  accessibility_tree?: unknown;
  step_history?: unknown;
};

/**
 * `POST /workflow/replay-step` — return the next AgentAction for one step
 * of a workflow replay.
 *
 * Request and response shape: see § A.3 of the implementation plan. The
 * caller (Node agent) loops this once per step, executing each returned
 * action against a Playwright `page` and feeding the new screenshot +
 * accessibility tree back in.
 *
 * Caching strategy: the WorkflowProfile is the largest static input
 * across every step of a single replay job (often 1-2KB; sometimes
 * larger when style_profile.verbatim_examples is rich). We send it as a
 * SECOND cached system block — the cache-key changes per workflow but
 * stays constant across all steps of one job, which is the win.
 */
export async function handleWorkflowReplayStep(
  request: Request,
  env: Env,
): Promise<Response> {
  let body: ReplayRequestBody;
  try {
    body = (await request.json()) as ReplayRequestBody;
  } catch (parseErr) {
    return new Response(
      JSON.stringify(
        safeHaltAction(`request body was not valid JSON: ${parseErr}`),
      ),
      { status: 400, headers: { "content-type": "application/json" } },
    );
  }

  const workflowProfile = body.workflow_profile ?? null;
  const referenceData = body.reference_data ?? {};
  const parameters = body.parameters ?? {};
  const currentUrl =
    typeof body.current_url === "string" ? body.current_url : "about:blank";
  const screenshotB64 =
    typeof body.screenshot_b64 === "string" ? body.screenshot_b64 : "";
  // accessibility_tree contract: a string (Playwright ariaSnapshot YAML).
  // Task 5 review I-2: be stricter than the previous "accept anything" path —
  // if a future caller passes a JSON tree, coerce to a stringified form and
  // log a console warning. The prompt is tuned for the YAML shape.
  let accessibilityTree: string;
  if (typeof body.accessibility_tree === "string") {
    accessibilityTree = body.accessibility_tree;
  } else if (body.accessibility_tree == null) {
    accessibilityTree = "";
  } else {
    console.warn(
      "[/workflow/replay-step] accessibility_tree is not a string; coercing via JSON.stringify. " +
      "The prompt expects Playwright ariaSnapshot YAML — consider updating the caller.",
    );
    accessibilityTree = JSON.stringify(body.accessibility_tree);
  }
  const stepHistory = Array.isArray(body.step_history) ? body.step_history : [];

  // Build the multimodal user-turn content. Image goes first if present
  // (Claude attends to images placed early). The accessibility tree is
  // expected to be a YAML-ish string (Playwright's ariaSnapshot()), but
  // we accept JSON-stringifiable shapes too for forward compat.
  const userContent: Record<string, unknown>[] = [];
  if (screenshotB64.length > 0) {
    userContent.push({
      type: "image",
      source: {
        type: "base64",
        media_type: "image/jpeg",
        data: screenshotB64,
      },
    });
  }
  userContent.push({
    type: "text",
    text: `CURRENT_URL: ${currentUrl}`,
  });
  userContent.push({
    type: "text",
    text:
      "ACCESSIBILITY_TREE (Playwright ariaSnapshot — YAML-ish, [ref=eN] handles):\n" +
      (typeof accessibilityTree === "string"
        ? accessibilityTree
        : JSON.stringify(accessibilityTree)),
  });
  userContent.push({
    type: "text",
    text: `REFERENCE_DATA:\n${JSON.stringify(referenceData)}`,
  });
  userContent.push({
    type: "text",
    text: `PARAMETERS:\n${JSON.stringify(parameters)}`,
  });
  userContent.push({
    type: "text",
    text: `STEP_HISTORY:\n${JSON.stringify(stepHistory)}`,
  });
  userContent.push({
    type: "text",
    text: "Return the AgentAction JSON now. JSON only.",
  });

  // System prompt is two cached blocks:
  //   1. The replay-step instructions (stable across ALL jobs).
  //   2. The workflow profile (stable across ALL steps of THIS job).
  // Both get cache_control: ephemeral. The second is the bigger win on
  // multi-step jobs (e.g. 10 jobs × 6 steps each = 60 calls sharing the
  // same workflow_profile cache block).
  const systemBlocks: Record<string, unknown>[] = [
    {
      type: "text",
      text: REPLAY_SYSTEM_PROMPT,
      cache_control: { type: "ephemeral" },
    },
    {
      type: "text",
      text: `WORKFLOW_PROFILE_FOR_REPLAY:\n${JSON.stringify(workflowProfile)}`,
      cache_control: { type: "ephemeral" },
    },
  ];

  let claudeResponse: Response;
  try {
    claudeResponse = await callClaude(env, {
      max_tokens: MAX_OUTPUT_TOKENS,
      system: systemBlocks,
      messages: [{ role: "user", content: userContent }],
    });
  } catch (callErr) {
    console.error(`[/workflow/replay-step] callClaude threw: ${callErr}`);
    return new Response(
      JSON.stringify(safeHaltAction(`Anthropic call failed: ${callErr}`)),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }

  if (!claudeResponse.ok) {
    const errorBody = await claudeResponse.text();
    console.error(
      `[/workflow/replay-step] Anthropic error ${claudeResponse.status}: ${errorBody}`,
    );
    // Return halt to keep the agent safe even on upstream failure.
    return new Response(
      JSON.stringify(
        safeHaltAction(
          `Anthropic API error ${claudeResponse.status}; halting to be safe`,
        ),
      ),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }

  let claudeJson: unknown;
  try {
    claudeJson = await claudeResponse.json();
  } catch (jsonErr) {
    return new Response(
      JSON.stringify(
        safeHaltAction(`Anthropic response was not JSON: ${jsonErr}`),
      ),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }

  const rawActionText = extractTextFromClaudeResponse(claudeJson);
  if (rawActionText === null) {
    return new Response(
      JSON.stringify(
        safeHaltAction("Anthropic response had no text content block"),
      ),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(stripCodeFences(rawActionText));
  } catch (parseErr) {
    console.error(
      `[/workflow/replay-step] Claude produced invalid JSON: ${parseErr}\n---\n${rawActionText}`,
    );
    return new Response(
      JSON.stringify(safeHaltAction("model produced invalid JSON")),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }

  // Output-validate: must have `action.type` matching the allowed set.
  // If the shape is wrong, fall back to safe halt so the agent doesn't
  // do anything dangerous with garbage input.
  const validated = validateAgentActionEnvelope(parsed);
  if (validated === null) {
    return new Response(
      JSON.stringify(
        safeHaltAction("model output did not match the AgentAction schema"),
      ),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }

  return new Response(JSON.stringify(validated), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

/**
 * Lightweight shape validator for the model's output.
 *
 * Required: `action.type` is one of the five allowed verbs.
 * Optional: every other field — but if the action is `halt`, we make
 * sure `submit_selector` is present (even as `null`). This is the
 * 2026-05-22 § A.3 amendment — the Review Queue UI reads this field by
 * name and we don't want it accidentally nested.
 *
 * Returns the normalized envelope on success, or null on failure.
 */
function validateAgentActionEnvelope(
  candidate: unknown,
): Record<string, unknown> | null {
  if (typeof candidate !== "object" || candidate === null) return null;
  const env = candidate as Record<string, unknown>;
  const action = env.action;
  if (typeof action !== "object" || action === null) return null;
  const actionObj = action as Record<string, unknown>;
  const allowedTypes = ["fill", "click", "navigate", "draft_text", "halt"];
  if (
    typeof actionObj.type !== "string" ||
    !allowedTypes.includes(actionObj.type)
  ) {
    return null;
  }
  // Stamp submit_selector as null on halt if Claude forgot to emit it.
  if (actionObj.type === "halt" && !("submit_selector" in actionObj)) {
    actionObj.submit_selector = null;
  }
  return env;
}
