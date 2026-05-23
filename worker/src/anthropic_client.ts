import type { Env } from "./types";
import type {
  ModelClient,
  GenerationInput,
  GenerationOutput,
} from "./model_client";
import { stripCodeFences } from "./model_client";

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
 * Optional override hook used by unit tests. When set, the client will
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
 * Anthropic implementation of the `ModelClient` interface.
 *
 * Translates the abstract `GenerationInput` into an Anthropic Messages API
 * request:
 *   - `systemPrompt` becomes the FIRST cached system block (cache_control:
 *     ephemeral) — matches the pre-abstraction behavior of both workflow
 *     handlers.
 *   - Each entry in `cacheableSystemBlocks` becomes an ADDITIONAL cached
 *     system block in order. (This is how `/workflow/replay-step` caches
 *     the workflow_profile separately from the static REPLAY_SYSTEM_PROMPT.)
 *   - `userText` + `userImages` become a single `{role: "user"}` message
 *     with image blocks first (Claude attends to images placed early),
 *     then text.
 *   - `maxOutputTokens` becomes `max_tokens`.
 *   - `responseShape` is informational only — Anthropic doesn't have a
 *     native JSON mode. We rely on prompt engineering (the prompts already
 *     instruct "JSON only") + defensive `stripCodeFences` to recover from
 *     occasional markdown fence leaks.
 *
 * NOTE on prompt caching: see
 * https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching for
 * the contract. The `cache_control: ephemeral` marker on the system blocks
 * is what unlocks the multi-step cost win on `/workflow/replay-step`
 * (every step of a single job shares the same workflow_profile block).
 */
export class AnthropicClient implements ModelClient {
  private readonly apiKey: string;

  constructor(env: Env) {
    this.apiKey = env.ANTHROPIC_API_KEY;
  }

  async generateStructured(
    input: GenerationInput,
  ): Promise<GenerationOutput> {
    // Build the system block list. First block is always the primary
    // system prompt; subsequent blocks come from cacheableSystemBlocks
    // (e.g. the per-job WORKFLOW_PROFILE_FOR_REPLAY block).
    const systemBlocks: Record<string, unknown>[] = [
      {
        type: "text",
        text: input.systemPrompt,
        cache_control: { type: "ephemeral" },
      },
    ];
    if (input.cacheableSystemBlocks) {
      for (const block of input.cacheableSystemBlocks) {
        systemBlocks.push({
          type: "text",
          text: block,
          cache_control: { type: "ephemeral" },
        });
      }
    }

    // Build the user-turn multimodal content. Images first (Claude
    // attends to images placed early in a turn), then the text payload.
    const userContent: Record<string, unknown>[] = [];
    if (input.userImages) {
      for (const image of input.userImages) {
        userContent.push({
          type: "image",
          source: {
            type: "base64",
            media_type: image.mediaType,
            data: image.b64,
          },
        });
      }
    }
    userContent.push({
      type: "text",
      text: input.userText,
    });

    const requestBody = JSON.stringify({
      model: CLAUDE_MODEL,
      max_tokens: input.maxOutputTokens,
      system: systemBlocks,
      messages: [{ role: "user", content: userContent }],
    });

    const init: RequestInit = {
      method: "POST",
      headers: {
        "x-api-key": this.apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
        "content-type": "application/json",
      },
      body: requestBody,
    };

    let response: Response;
    if (testFetchOverride !== null) {
      response = await testFetchOverride(ANTHROPIC_MESSAGES_URL, init);
    } else {
      response = await fetch(ANTHROPIC_MESSAGES_URL, init);
    }

    if (!response.ok) {
      const errorBody = await response.text();
      return {
        json: null,
        rawText: errorBody,
        usage: {},
        upstreamError: { status: response.status, body: errorBody },
      };
    }

    let responseJson: unknown;
    try {
      responseJson = await response.json();
    } catch (jsonErr) {
      return {
        json: null,
        rawText: "",
        usage: {},
        upstreamError: {
          status: 502,
          body: `Anthropic response was not JSON: ${jsonErr}`,
        },
      };
    }

    const rawText = extractTextFromClaudeResponse(responseJson);
    if (rawText === null) {
      return {
        json: null,
        rawText: "",
        usage: extractUsageFromClaudeResponse(responseJson),
        upstreamError: {
          status: 502,
          body: "Anthropic response did not include a text content block",
        },
      };
    }

    const cleaned = stripCodeFences(rawText);
    let parsedJson: unknown = null;
    try {
      parsedJson = JSON.parse(cleaned);
    } catch {
      parsedJson = null;
    }

    return {
      json: parsedJson,
      rawText: cleaned,
      usage: extractUsageFromClaudeResponse(responseJson),
    };
  }
}

/**
 * Pulls the first text content block out of a successful Claude Messages
 * API response payload. Returns `null` if the shape is unexpected.
 *
 * Exported for direct use by the legacy `/chat` proxy handler in
 * `index.ts` (which doesn't use the `ModelClient` abstraction because
 * it's a transparent pass-through).
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
 * Best-effort usage extraction. Anthropic returns
 *   usage: { input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens }
 * We surface only the headline input/output counts here.
 */
function extractUsageFromClaudeResponse(
  claudeJson: unknown,
): { inputTokens?: number; outputTokens?: number } {
  if (typeof claudeJson !== "object" || claudeJson === null) return {};
  const usage = (claudeJson as { usage?: unknown }).usage;
  if (typeof usage !== "object" || usage === null) return {};
  const usageObj = usage as Record<string, unknown>;
  const result: { inputTokens?: number; outputTokens?: number } = {};
  if (typeof usageObj.input_tokens === "number") {
    result.inputTokens = usageObj.input_tokens;
  }
  if (typeof usageObj.output_tokens === "number") {
    result.outputTokens = usageObj.output_tokens;
  }
  return result;
}

/**
 * Re-export of the shared code-fence stripper so callers that imported it
 * from this module before the abstraction (workflow handlers, tests)
 * continue to work without touching their import sites.
 */
export { stripCodeFences };
