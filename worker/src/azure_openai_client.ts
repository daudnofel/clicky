import type { Env } from "./types";
import type {
  ModelClient,
  GenerationInput,
  GenerationOutput,
} from "./model_client";
import { stripCodeFences } from "./model_client";

/**
 * Default Azure OpenAI API version used when `AZURE_OPENAI_API_VERSION`
 * is unset. 2024-10-21 is a stable GA version that supports vision input,
 * JSON mode (`response_format: {type: "json_object"}`), and implicit
 * prompt caching (Azure's caching does not require explicit markers — it
 * kicks in automatically for prefixes >= 1024 tokens).
 */
export const DEFAULT_AZURE_OPENAI_API_VERSION = "2024-10-21";

/**
 * Optional override hook used by unit tests. Same contract as the
 * Anthropic client's override — set in `beforeEach`, reset in `afterEach`.
 */
export type FetchLike = (
  input: string,
  init: RequestInit,
) => Promise<Response>;

let testFetchOverride: FetchLike | null = null;

export function __setAzureFetchOverrideForTests(
  override: FetchLike | null,
): void {
  testFetchOverride = override;
}

/**
 * Azure OpenAI implementation of the `ModelClient` interface.
 *
 * Why this exists: lets the user dev for free against their Azure credits
 * while leaving Anthropic as the default backend that ships in the
 * submission fork.
 *
 * URL shape:
 *   ${endpoint}/openai/deployments/${deployment}/chat/completions?api-version=${apiVersion}
 *
 * Auth: `api-key: <key>` header (NOT a bearer token — Azure OpenAI uses
 * a different auth header from public OpenAI).
 *
 * Request translation:
 *   - `systemPrompt` + every `cacheableSystemBlocks` entry are concatenated
 *     (in order, double-newline-separated) into the FIRST
 *     `{role: "system", content: "..."}` message. Azure OpenAI's prompt
 *     caching is implicit on prefixes >= 1024 tokens — no explicit
 *     `cache_control` markers needed. Keeping cacheable content first +
 *     deterministically-ordered preserves the prefix-cache benefit across
 *     calls.
 *   - `userText` + `userImages` become a single `{role: "user"}` message
 *     with multimodal content. Images use the OpenAI shape:
 *     `{type: "image_url", image_url: {url: "data:<mediaType>;base64,<b64>"}}`.
 *   - `responseShape === "json_object"` sets
 *     `response_format: {type: "json_object"}` so OpenAI returns
 *     guaranteed-parseable JSON (no code-fence stripping needed).
 *   - `maxOutputTokens` becomes `max_tokens` by default. Newer Azure
 *     OpenAI deployments (e.g. some reasoning models) require
 *     `max_completion_tokens` instead — set
 *     `AZURE_OPENAI_MAX_TOKENS_PARAM=max_completion_tokens` to switch.
 *
 * Response parsing:
 *   - Extracts `choices[0].message.content` (a string).
 *   - Strips code fences defensively (in JSON mode they shouldn't appear,
 *     but the helper is cheap and idempotent).
 *   - `JSON.parse` with safe fallback — `json: null` on parse failure,
 *     never throws.
 *   - Usage: `usage.prompt_tokens` -> `inputTokens`,
 *     `usage.completion_tokens` -> `outputTokens`.
 */
export class AzureOpenAIClient implements ModelClient {
  private readonly endpoint: string;
  private readonly apiKey: string;
  private readonly deployment: string;
  private readonly apiVersion: string;
  private readonly maxTokensParam: "max_tokens" | "max_completion_tokens";

  constructor(env: Env) {
    // We intentionally read these lazily (not at module import) so the
    // Anthropic-default code path is never gated on Azure config. The
    // dispatcher in `get_model_client.ts` only instantiates us when
    // WORKFLOW_MODEL_BACKEND === "azure_openai".
    const endpoint = env.AZURE_OPENAI_ENDPOINT;
    const apiKey = env.AZURE_OPENAI_API_KEY;
    const deployment = env.AZURE_OPENAI_DEPLOYMENT;
    if (!endpoint) {
      throw new Error(
        "AZURE_OPENAI_ENDPOINT is required when WORKFLOW_MODEL_BACKEND=azure_openai. " +
          "Set it via `wrangler.toml` [vars] or `wrangler secret put`.",
      );
    }
    if (!apiKey) {
      throw new Error(
        "AZURE_OPENAI_API_KEY is required when WORKFLOW_MODEL_BACKEND=azure_openai. " +
          "Set it via `wrangler secret put AZURE_OPENAI_API_KEY`.",
      );
    }
    if (!deployment) {
      throw new Error(
        "AZURE_OPENAI_DEPLOYMENT is required when WORKFLOW_MODEL_BACKEND=azure_openai. " +
          "This is the DEPLOYMENT NAME (not the model name) you created in Azure AI Studio.",
      );
    }
    // Trim a trailing slash from the endpoint so URL concatenation is
    // robust to either `https://my-resource.openai.azure.com` or
    // `https://my-resource.openai.azure.com/`.
    this.endpoint = endpoint.replace(/\/+$/, "");
    this.apiKey = apiKey;
    this.deployment = deployment;
    this.apiVersion =
      env.AZURE_OPENAI_API_VERSION ?? DEFAULT_AZURE_OPENAI_API_VERSION;
    // Default to `max_tokens` because the GA chat-completions schema uses
    // it; flip via env var if your deployment errors on 400 (some newer
    // reasoning models require `max_completion_tokens`).
    this.maxTokensParam =
      env.AZURE_OPENAI_MAX_TOKENS_PARAM === "max_completion_tokens"
        ? "max_completion_tokens"
        : "max_tokens";
  }

  async generateStructured(
    input: GenerationInput,
  ): Promise<GenerationOutput> {
    // Concatenate the primary system prompt with every cacheable block.
    // Order: primary first, then each cacheable block in the order
    // provided. Double-newline separation makes the boundary readable in
    // logs without inflating token counts noticeably.
    const systemContentParts: string[] = [input.systemPrompt];
    if (input.cacheableSystemBlocks) {
      for (const block of input.cacheableSystemBlocks) {
        systemContentParts.push(block);
      }
    }
    const systemContent = systemContentParts.join("\n\n");

    // Build the user message. OpenAI's multimodal content shape uses an
    // array of `{type, ...}` parts, same idea as Anthropic but different
    // field names.
    const userContent: Array<Record<string, unknown>> = [];
    if (input.userImages) {
      for (const image of input.userImages) {
        userContent.push({
          type: "image_url",
          image_url: {
            url: `data:${image.mediaType};base64,${image.b64}`,
          },
        });
      }
    }
    userContent.push({
      type: "text",
      text: input.userText,
    });

    const requestBody: Record<string, unknown> = {
      messages: [
        { role: "system", content: systemContent },
        { role: "user", content: userContent },
      ],
    };
    requestBody[this.maxTokensParam] = input.maxOutputTokens;

    // OpenAI's JSON mode: the model is guaranteed to return a parseable
    // JSON object as `choices[0].message.content`. Note that the prompt
    // must still mention JSON somewhere — our `learn_system.md` and
    // `replay_system.md` both already say "Return JSON only," which
    // satisfies the OpenAI requirement.
    if (input.responseShape === "json_object") {
      requestBody.response_format = { type: "json_object" };
    }

    const url =
      `${this.endpoint}/openai/deployments/${encodeURIComponent(this.deployment)}` +
      `/chat/completions?api-version=${encodeURIComponent(this.apiVersion)}`;

    const init: RequestInit = {
      method: "POST",
      headers: {
        "api-key": this.apiKey,
        "content-type": "application/json",
      },
      body: JSON.stringify(requestBody),
    };

    let response: Response;
    if (testFetchOverride !== null) {
      response = await testFetchOverride(url, init);
    } else {
      response = await fetch(url, init);
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
          body: `Azure OpenAI response was not JSON: ${jsonErr}`,
        },
      };
    }

    const rawText = extractTextFromOpenAIResponse(responseJson);
    if (rawText === null) {
      return {
        json: null,
        rawText: "",
        usage: extractUsageFromOpenAIResponse(responseJson),
        upstreamError: {
          status: 502,
          body: "Azure OpenAI response had no choices[0].message.content",
        },
      };
    }

    // Strip code fences defensively. In JSON mode they shouldn't appear,
    // but if a user hits a deployment that doesn't support response_format
    // (very old chat-completions versions), the fallback is identical to
    // the Anthropic path.
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
      usage: extractUsageFromOpenAIResponse(responseJson),
    };
  }
}

/**
 * Pulls `choices[0].message.content` out of an OpenAI Chat Completions
 * response. Returns `null` if the shape is unexpected (defensive — we
 * don't want a malformed upstream to throw).
 */
function extractTextFromOpenAIResponse(
  openaiJson: unknown,
): string | null {
  if (typeof openaiJson !== "object" || openaiJson === null) return null;
  const choices = (openaiJson as { choices?: unknown }).choices;
  if (!Array.isArray(choices) || choices.length === 0) return null;
  const firstChoice = choices[0];
  if (typeof firstChoice !== "object" || firstChoice === null) return null;
  const message = (firstChoice as { message?: unknown }).message;
  if (typeof message !== "object" || message === null) return null;
  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") return content;
  // Some Azure deployments return content as an array of parts (e.g.
  // tool-use models). Concatenate any text parts as a best-effort
  // fallback so callers still get something parseable.
  if (Array.isArray(content)) {
    const textParts: string[] = [];
    for (const part of content) {
      if (
        typeof part === "object" &&
        part !== null &&
        (part as { type?: unknown }).type === "text" &&
        typeof (part as { text?: unknown }).text === "string"
      ) {
        textParts.push((part as { text: string }).text);
      }
    }
    if (textParts.length > 0) return textParts.join("");
  }
  return null;
}

/**
 * Best-effort usage extraction. OpenAI returns
 *   usage: { prompt_tokens, completion_tokens, total_tokens, ... }
 * We surface only the headline input/output counts to match the
 * Anthropic shape.
 */
function extractUsageFromOpenAIResponse(
  openaiJson: unknown,
): { inputTokens?: number; outputTokens?: number } {
  if (typeof openaiJson !== "object" || openaiJson === null) return {};
  const usage = (openaiJson as { usage?: unknown }).usage;
  if (typeof usage !== "object" || usage === null) return {};
  const usageObj = usage as Record<string, unknown>;
  const result: { inputTokens?: number; outputTokens?: number } = {};
  if (typeof usageObj.prompt_tokens === "number") {
    result.inputTokens = usageObj.prompt_tokens;
  }
  if (typeof usageObj.completion_tokens === "number") {
    result.outputTokens = usageObj.completion_tokens;
  }
  return result;
}
