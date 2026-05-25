import type { Env } from "./types";
import { getModelClient } from "./get_model_client";
import { REPLAY_SYSTEM_PROMPT } from "./prompts/replay_system";

/**
 * Cap on the model's response length. A simple action (fill/click/navigate)
 * is small — a few hundred tokens — but a results-list halt can carry up to
 * 15 items, each with a title, ~5 small fields, and a URL. At ~80 tokens
 * per item plus JSON framing that's ~1500 tokens just for the results array.
 * 4096 gives comfortable headroom for verbose drafts (cover letters) AND
 * full results-list halts without ever truncating into invalid JSON.
 */
const MAX_OUTPUT_TOKENS = 4096;

/**
 * Default action returned when ANYTHING goes wrong (model unreachable,
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
 * Backend dispatch: backend-agnostic. The actual API call (Anthropic
 * Claude by default, Azure OpenAI when
 * `WORKFLOW_MODEL_BACKEND=azure_openai`) lives behind the `ModelClient`
 * interface. The PROMPT (`replay_system.md`) is also backend-agnostic and
 * unchanged.
 *
 * Caching strategy: the WorkflowProfile is the largest static input
 * across every step of a single replay job (often 1-2KB; sometimes
 * larger when style_profile.verbatim_examples is rich). We send it as a
 * SECOND cacheable system block. On the Anthropic backend the
 * `ModelClient` adds `cache_control: ephemeral` to it; on the Azure
 * backend it just becomes a stable prefix of the system message so
 * Azure's implicit prefix caching can pick it up.
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

  // Build the user-turn text payload. The image (if present) is passed
  // separately via `userImages` and rendered backend-appropriately by
  // the ModelClient.
  const userText =
    `CURRENT_URL: ${currentUrl}\n\n` +
    "ACCESSIBILITY_TREE (Playwright ariaSnapshot — YAML-ish, [ref=eN] handles):\n" +
    accessibilityTree +
    "\n\n" +
    `REFERENCE_DATA:\n${JSON.stringify(referenceData)}\n\n` +
    `PARAMETERS:\n${JSON.stringify(parameters)}\n\n` +
    `STEP_HISTORY:\n${JSON.stringify(stepHistory)}\n\n` +
    "Return the AgentAction JSON now. JSON only.";

  const userImages =
    screenshotB64.length > 0
      ? [{ b64: screenshotB64, mediaType: "image/jpeg" }]
      : [];

  // Second cacheable system block: the workflow_profile. Stable across
  // ALL steps of THIS job, which is the big multi-step cache win.
  const workflowProfileBlock = `WORKFLOW_PROFILE_FOR_REPLAY:\n${JSON.stringify(workflowProfile)}`;

  // Backend selection: `getModelClient` returns `AnthropicClient` by
  // default and `AzureOpenAIClient` when `WORKFLOW_MODEL_BACKEND ===
  // "azure_openai"`. Anthropic is the default that ships in the
  // submission fork; Azure is opt-in for free dev against Azure credits.
  const modelClient = getModelClient(env);
  let output;
  try {
    output = await modelClient.generateStructured({
      systemPrompt: REPLAY_SYSTEM_PROMPT,
      cacheableSystemBlocks: [workflowProfileBlock],
      userText,
      userImages,
      maxOutputTokens: MAX_OUTPUT_TOKENS,
      responseShape: "json_object",
    });
  } catch (callErr) {
    console.error(`[/workflow/replay-step] model client threw: ${callErr}`);
    return new Response(
      JSON.stringify(safeHaltAction(`model call failed: ${callErr}`)),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }

  if (output.upstreamError) {
    console.error(
      `[/workflow/replay-step] upstream error ${output.upstreamError.status}: ${output.upstreamError.body}`,
    );
    // Return halt to keep the agent safe even on upstream failure. We
    // include the status code in the reasoning so the operator can see
    // what happened from the queue card / agent logs.
    return new Response(
      JSON.stringify(
        safeHaltAction(
          `Upstream model API error ${output.upstreamError.status}; halting to be safe`,
        ),
      ),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }

  if (output.json === null) {
    console.error(
      `[/workflow/replay-step] model produced invalid JSON:\n---\n${output.rawText}`,
    );
    return new Response(
      JSON.stringify(safeHaltAction("model produced invalid JSON")),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  }

  // Output-validate: must have `action.type` matching the allowed set.
  // If the shape is wrong, fall back to safe halt so the agent doesn't
  // do anything dangerous with garbage input.
  const validated = validateAgentActionEnvelope(output.json);
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
 * On halt we also sanitize an optional `results` field per the
 * 2026-05-23 § A.3 amendment: it's the peer payload the model emits
 * when the workflow's `output_format === "results-list"`. We drop
 * malformed shapes here so the Swift side can decode without
 * defensive code: results must be an array, each entry must have a
 * string `title`, `fields` must be an object (else coerced to `{}`),
 * `url` must be a string (else stripped), and we cap the array at 15
 * items to keep cards readable and the wire payload bounded.
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
  // Stamp submit_selector as null on halt if the model forgot to emit it.
  if (actionObj.type === "halt" && !("submit_selector" in actionObj)) {
    actionObj.submit_selector = null;
  }
  // Sanitize `results` on halt (§ A.3 amendment 2026-05-23). If the field
  // is present but malformed we strip it rather than rejecting the whole
  // action — the model may have produced a perfectly-good halt with a
  // half-formed list, and a partial list is more useful than a dropped run.
  if (actionObj.type === "halt" && "results" in actionObj) {
    const sanitizedResults = sanitizeResultsList(actionObj.results);
    if (sanitizedResults === null) {
      delete actionObj.results;
    } else {
      actionObj.results = sanitizedResults;
    }
  }
  return env;
}

/** Cap on the number of results allowed in a single halt. Beyond this the
 *  cards become unreadable and the wire payload grows linearly with junk. */
const MAX_RESULTS_LIST_ITEMS = 15;

/**
 * Defensively coerce a candidate `results` payload into the on-the-wire
 * `ResultsListItem[]` shape, or return null if the candidate isn't an
 * array at all (in which case the caller strips the field entirely).
 *
 * Per-item rules (each runs independently so a single bad item doesn't
 * tank the whole list):
 *   - `title` must be a non-empty string. Missing/empty -> drop the item.
 *   - `fields` must be a plain object whose values are strings; non-string
 *     values are stringified, non-object payloads are replaced with `{}`.
 *   - `url` must be a string. Anything else is stripped.
 */
function sanitizeResultsList(
  candidate: unknown,
): Array<Record<string, unknown>> | null {
  if (!Array.isArray(candidate)) return null;
  const sanitized: Array<Record<string, unknown>> = [];
  for (const rawItem of candidate) {
    if (sanitized.length >= MAX_RESULTS_LIST_ITEMS) break;
    if (typeof rawItem !== "object" || rawItem === null) continue;
    const itemObj = rawItem as Record<string, unknown>;
    const titleCandidate = itemObj.title;
    if (typeof titleCandidate !== "string" || titleCandidate.length === 0) {
      continue;
    }
    // fields: must be an object whose values are coerced to string.
    let coercedFields: Record<string, string> = {};
    const fieldsCandidate = itemObj.fields;
    if (
      typeof fieldsCandidate === "object" &&
      fieldsCandidate !== null &&
      !Array.isArray(fieldsCandidate)
    ) {
      const fieldsObj = fieldsCandidate as Record<string, unknown>;
      for (const [fieldKey, fieldValue] of Object.entries(fieldsObj)) {
        if (typeof fieldValue === "string") {
          coercedFields[fieldKey] = fieldValue;
        } else if (fieldValue != null) {
          coercedFields[fieldKey] = String(fieldValue);
        }
      }
    }
    // url: optional string; strip if wrong type.
    const urlCandidate = itemObj.url;
    const builtItem: Record<string, unknown> = {
      title: titleCandidate,
      fields: coercedFields,
    };
    if (typeof urlCandidate === "string" && urlCandidate.length > 0) {
      builtItem.url = urlCandidate;
    }
    sanitized.push(builtItem);
  }
  return sanitized;
}
