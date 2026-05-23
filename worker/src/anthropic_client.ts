import type { Env } from "./types";

/**
 * Anthropic model id. Matches the default used in `ClaudeAPI.swift`
 * (`claude-sonnet-4-6`). Keep in sync if the Swift default changes.
 */
export const CLAUDE_MODEL = "claude-sonnet-4-6";

/**
 * Anthropic Messages API version. Matches the value used in `index.ts`'s
 * existing `/chat` proxy handler.
 */
export const ANTHROPIC_VERSION = "2023-06-01";

/**
 * Anthropic Messages API endpoint.
 */
export const ANTHROPIC_MESSAGES_URL = "https://api.anthropic.com/v1/messages";

/**
 * Optional override hook used by unit tests. When set, `callClaude` will
 * invoke this instead of the real `fetch`. Tests mutate this from inside
 * their test setup and reset it in `afterEach`.
 *
 * IMPORTANT: do not use this for anything other than testing. The
 * production code path goes through the global `fetch` available in
 * Cloudflare Workers.
 */
export type FetchLike = (
  input: string,
  init: RequestInit,
) => Promise<Response>;

let testFetchOverride: FetchLike | null = null;

export function __setFetchOverrideForTests(override: FetchLike | null): void {
  testFetchOverride = override;
}

/**
 * Thin wrapper around the Anthropic Messages API. Always sends the model id
 * and authentication headers; everything else (`messages`, `system`,
 * `max_tokens`, `tools`, etc.) is passed through from the caller.
 *
 * Returns the raw `Response` so callers can inspect status codes / stream
 * the body if they want. Workflow handlers should `await res.json()` after
 * checking `res.ok`.
 *
 * NOTE on prompt caching: callers should set `cache_control: { type:
 * "ephemeral" }` on the system block (and on any repeated content blocks
 * like the workflow profile) to opt-in to prompt caching. See the Anthropic
 * docs at https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching
 * and the user-invocable `claude-api` skill for guidance.
 */
export async function callClaude(
  env: Env,
  body: Record<string, unknown>,
): Promise<Response> {
  const requestBody = JSON.stringify({ model: CLAUDE_MODEL, ...body });
  const init: RequestInit = {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": ANTHROPIC_VERSION,
      "content-type": "application/json",
    },
    body: requestBody,
  };

  if (testFetchOverride !== null) {
    return await testFetchOverride(ANTHROPIC_MESSAGES_URL, init);
  }

  return await fetch(ANTHROPIC_MESSAGES_URL, init);
}

/**
 * Pulls the first text content block out of a successful Claude Messages
 * API response payload. Returns `null` if the shape is unexpected.
 */
export function extractTextFromClaudeResponse(
  claudeJson: unknown,
): string | null {
  if (typeof claudeJson !== "object" || claudeJson === null) return null;
  const content = (claudeJson as { content?: unknown }).content;
  if (!Array.isArray(content) || content.length === 0) return null;
  for (const block of content) {
    if (
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string"
    ) {
      return (block as { text: string }).text;
    }
  }
  return null;
}

/**
 * Claude occasionally wraps its JSON output in markdown code fences
 * (```json ... ```), even when instructed not to. Strip those defensively
 * before `JSON.parse`.
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
