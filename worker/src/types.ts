/**
 * Cloudflare Worker environment bindings.
 *
 * Anthropic + ElevenLabs + AssemblyAI keys are required and always present
 * in the deployed Worker. The Azure OpenAI fields are optional — they are
 * only consumed when `WORKFLOW_MODEL_BACKEND === "azure_openai"`. The
 * default behavior (no var set, or any other value) routes to Anthropic.
 */
export interface Env {
  // Required for the existing /chat, /tts, /transcribe-token routes and
  // for the default Anthropic backend of /workflow/learn + /workflow/replay-step.
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;

  // Optional — only required when WORKFLOW_MODEL_BACKEND === "azure_openai".
  //
  // Anthropic remains the DEFAULT backend that ships in the submission
  // fork. To flip to Azure for free local dev:
  //   - Set WORKFLOW_MODEL_BACKEND = "azure_openai" (as a wrangler [vars]).
  //   - Set AZURE_OPENAI_ENDPOINT to your resource URL.
  //   - `wrangler secret put AZURE_OPENAI_API_KEY` with your key.
  //   - Set AZURE_OPENAI_DEPLOYMENT to the deployment NAME (not model name)
  //     of a vision-capable deployment (e.g. gpt-4o, gpt-4.1).
  //   - Optionally override AZURE_OPENAI_API_VERSION (default "2024-10-21").
  WORKFLOW_MODEL_BACKEND?: string;
  AZURE_OPENAI_ENDPOINT?: string;
  AZURE_OPENAI_API_KEY?: string;
  AZURE_OPENAI_DEPLOYMENT?: string;
  AZURE_OPENAI_API_VERSION?: string;

  // Escape hatch for newer Azure OpenAI deployments that require
  // `max_completion_tokens` instead of `max_tokens` (e.g. some reasoning
  // model deployments). Default behavior uses `max_tokens` which works
  // for gpt-4o / gpt-4.1.
  AZURE_OPENAI_MAX_TOKENS_PARAM?: string;
}
