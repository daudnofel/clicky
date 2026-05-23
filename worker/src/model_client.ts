/**
 * Backend-agnostic interface for the workflow handlers' LLM calls.
 *
 * The two workflow endpoints (`/workflow/learn` and `/workflow/replay-step`)
 * historically called Anthropic Claude directly via `anthropic_client.ts`.
 * Per the 2026-05-22 Azure OpenAI backend addition, both endpoints now go
 * through this abstraction so the same handler code can talk to either
 * Anthropic (the default — what ships in the submission fork) or Azure
 * OpenAI (selectable via the `WORKFLOW_MODEL_BACKEND=azure_openai` Worker
 * var so the user can dev for free against their Azure credits).
 *
 * The PROMPTS (`learn_system.md`, `replay_system.md`) stay backend-agnostic.
 * Only the message-shape translation, image encoding, and JSON-output
 * convention differ between backends — and those differences live entirely
 * inside the two `ModelClient` implementations.
 *
 * Hard rule: Anthropic remains the default. If `WORKFLOW_MODEL_BACKEND` is
 * unset or set to anything other than the literal string `"azure_openai"`,
 * the dispatcher in `get_model_client.ts` returns the `AnthropicClient`.
 */

/**
 * Inputs to a single structured-output generation. All backends must be
 * able to honor every field — but each backend translates the request in
 * its own way (e.g. Anthropic uses `cache_control: ephemeral` markers on
 * the listed cacheable blocks; Azure OpenAI ignores the marker because
 * its prompt caching is implicit for prefixes >= 1024 tokens).
 */
export interface GenerationInput {
  /**
   * The primary system prompt. For Anthropic this becomes the first cached
   * system block. For Azure OpenAI it's concatenated as the first
   * `{role: "system"}` message.
   */
  systemPrompt: string;

  /**
   * Additional system blocks that callers want to mark as cacheable. The
   * Anthropic backend adds `cache_control: {type: "ephemeral"}` to each
   * one. The Azure backend ignores the hint (OpenAI's caching is implicit
   * for prefixes >=1024 tokens, no explicit markers needed). Order
   * matters: cacheable blocks come BEFORE the dynamic user content so
   * they form a stable prefix.
   */
  cacheableSystemBlocks?: string[];

  /**
   * The user-turn text. For multimodal inputs, this is the text portion
   * (sent alongside any images via `userImages`).
   */
  userText: string;

  /**
   * Optional image inputs for vision. Each image is a raw base64 string
   * plus its media type (e.g. "image/jpeg"). Anthropic encodes these as
   * `{type: "image", source: {type: "base64", media_type, data}}`. Azure
   * OpenAI encodes them as `{type: "image_url", image_url: {url:
   * "data:<mediaType>;base64,<b64>"}}`.
   */
  userImages?: Array<{ b64: string; mediaType: string }>;

  /**
   * Maximum number of output tokens. Both backends honor this — Anthropic
   * as `max_tokens`, Azure OpenAI as `max_tokens` (or
   * `max_completion_tokens` on newer reasoning deployments — see
   * `AZURE_OPENAI_MAX_TOKENS_PARAM` env var for the override).
   */
  maxOutputTokens: number;

  /**
   * Hint that we want strict JSON output. When `"json_object"`:
   *   - Anthropic: relies on prompt engineering (we already instruct
   *     "JSON only" in `learn_system.md` / `replay_system.md`) plus
   *     defensive code-fence stripping in `stripCodeFences`.
   *   - Azure OpenAI: sets `response_format: {type: "json_object"}` so
   *     the model is guaranteed to return parseable JSON natively — no
   *     code fences to strip.
   */
  responseShape?: "json_object";
}

/**
 * Result of a structured generation. `json` is the parsed payload or
 * `null` if parsing failed; callers MUST handle the null case explicitly
 * (the workflow handlers fall back to safe error envelopes).
 *
 * `rawText` is included for logging — the workflow handlers log it on
 * parse failure so we can see exactly what the model emitted.
 */
export interface GenerationOutput {
  /**
   * The JSON value parsed out of the model's text output, or `null` if
   * the output was not parseable as JSON. Callers must check for `null`
   * before using this field.
   */
  json: unknown;

  /**
   * The raw text the model emitted, with markdown code fences stripped
   * if any. Logged on parse failure so the worker logs show the actual
   * model output, not just the parse error.
   */
  rawText: string;

  /**
   * Best-effort token usage breakdown for cost telemetry. Both fields
   * are optional because the two backends report token counts under
   * different field names — callers should treat any missing field as
   * "unknown" rather than zero.
   */
  usage: { inputTokens?: number; outputTokens?: number };

  /**
   * Optional carrier for upstream HTTP failures so callers can surface
   * the real status code. When set, `json` is null and `rawText` is
   * the upstream error body. The workflow handlers use this to return
   * the upstream status to the client (matches the pre-abstraction
   * behavior of `/workflow/learn` returning the Anthropic 429 as 429).
   */
  upstreamError?: { status: number; body: string };
}

/**
 * Backend interface. Every workflow handler depends on this — never on
 * a concrete client class — so swapping backends is one env var away.
 */
export interface ModelClient {
  /**
   * Produce a structured (JSON) generation. Implementations must:
   *   1. Translate the abstract `GenerationInput` into their backend's
   *      native request body (Anthropic Messages vs. OpenAI Chat
   *      Completions).
   *   2. Strip markdown code fences from the model's text output (the
   *      Azure OpenAI path can skip this when `responseShape ===
   *      "json_object"` because the response is guaranteed clean JSON).
   *   3. `JSON.parse` the cleaned text with a safe fallback — return
   *      `{json: null, rawText, ...}` on parse failure, NEVER throw.
   *   4. Populate `usage` with whatever the backend exposes.
   *
   * Implementations should NOT throw on upstream HTTP failures either —
   * set `upstreamError` and return so the handler can decide what to do
   * (the learn handler forwards the status; the replay handler halts).
   */
  generateStructured(input: GenerationInput): Promise<GenerationOutput>;
}

/**
 * Code-fence stripping shared by both backends. Anthropic occasionally
 * wraps JSON in ```json ... ```; Azure OpenAI in JSON mode does not, but
 * we strip defensively anyway so the helper is safe to call either way.
 */
export function stripCodeFences(raw: string): string {
  let cleaned = raw.trim();
  if (cleaned.startsWith("```")) {
    // Drop the opening fence (optionally followed by a language tag like "json").
    const firstNewline = cleaned.indexOf("\n");
    if (firstNewline !== -1) {
      cleaned = cleaned.slice(firstNewline + 1);
    } else {
      cleaned = cleaned.slice(3);
    }
  }
  if (cleaned.endsWith("```")) {
    cleaned = cleaned.slice(0, cleaned.length - 3);
  }
  return cleaned.trim();
}
