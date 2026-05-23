import type { Env } from "./types";
import type { ModelClient } from "./model_client";
import { AnthropicClient } from "./anthropic_client";
import { AzureOpenAIClient } from "./azure_openai_client";

/**
 * Dispatch the right `ModelClient` for the workflow handlers.
 *
 * Hard rule (see project CLAUDE.md + the 2026-05-22 Azure backend
 * addition): Anthropic remains the DEFAULT backend that ships in the
 * submission fork. The Azure path is opt-in via a single env var so the
 * user can dev for free against their Azure credits without changing any
 * other configuration.
 *
 * Selection logic:
 *   - `WORKFLOW_MODEL_BACKEND === "azure_openai"` -> Azure OpenAI
 *   - anything else (unset, "anthropic", "claude", typo) -> Anthropic
 *
 * The strict equality check is intentional. A typo like
 * `WORKFLOW_MODEL_BACKEND="azure-openai"` (hyphen instead of underscore)
 * falls back to Anthropic, which is the safe default — better to keep
 * billing the right account than to silently fail because of a typo.
 */
export function getModelClient(env: Env): ModelClient {
  if (env.WORKFLOW_MODEL_BACKEND === "azure_openai") {
    return new AzureOpenAIClient(env);
  }
  return new AnthropicClient(env);
}
