# Azure OpenAI Backend (Optional)

The two workflow endpoints — `POST /workflow/learn` and
`POST /workflow/replay-step` — default to **Anthropic Claude** (this is
what ships in the submission fork). You can flip them to **Azure OpenAI**
to dev for free against your Azure credits, with no change to the
prompts, schemas, or contracts.

## When to use it

- Local dev where you don't want to spend Anthropic credits.
- Quick A/B between Claude and GPT-4o on a recorded demo (verify the
  prompts are model-agnostic before shipping).

The default that ships in the submission fork is Anthropic. The Azure
path is opt-in via a single env var.

## How to configure

Set these in `wrangler.toml` `[vars]` (non-secret) and `wrangler secret`
(the API key):

```toml
# wrangler.toml
[vars]
WORKFLOW_MODEL_BACKEND     = "azure_openai"
AZURE_OPENAI_ENDPOINT      = "https://my-resource.openai.azure.com"
AZURE_OPENAI_DEPLOYMENT    = "gpt-4o"          # deployment NAME, not model name
AZURE_OPENAI_API_VERSION   = "2024-10-21"      # optional, this is the default
```

```bash
cd fork/worker
npx wrangler secret put AZURE_OPENAI_API_KEY   # paste your Azure key
npx wrangler deploy
```

For local dev, put the same values in `worker/.dev.vars` and run
`npx wrangler dev`.

## Switching back to Anthropic

Either remove `WORKFLOW_MODEL_BACKEND` from `wrangler.toml`, set it to
`"anthropic"`, or set it to anything other than the literal string
`"azure_openai"`. The dispatcher uses strict equality on
`"azure_openai"`, so typos (e.g. `"azure-openai"`) safely fall back to
Anthropic — you won't accidentally bill the wrong account because of a
hyphen.

## Differences from the Anthropic path

| Concern              | Anthropic (default)                                 | Azure OpenAI                                          |
|----------------------|-----------------------------------------------------|-------------------------------------------------------|
| Vision input shape   | `{type: "image", source: {type: "base64", ...}}`    | `{type: "image_url", image_url: {url: "data:..."}}`   |
| Prompt caching       | Explicit `cache_control: {type: "ephemeral"}`       | Implicit, prefixes >= 1024 tokens, no markers needed  |
| JSON output          | Prompt-engineered + defensive code-fence stripping  | Native `response_format: {type: "json_object"}`       |
| Token-budget field   | `max_tokens`                                        | `max_tokens` (or `max_completion_tokens` for newer reasoning deployments — set `AZURE_OPENAI_MAX_TOKENS_PARAM=max_completion_tokens`) |
| Auth header          | `x-api-key`                                         | `api-key`                                             |

Recommend **GPT-4o** or **GPT-4.1** deployments for the workflow
endpoints since both `/workflow/learn` and `/workflow/replay-step` send
images. Reasoning-only deployments without vision will 400 on the image
parts.

## Contract impact (none)

The § A.1 `WorkflowProfile`, § A.3 `AgentAction`, and the system prompts
(`learn_system.md`, `replay_system.md`) are unchanged regardless of
backend. The differences above are entirely inside the `ModelClient`
implementations (`src/anthropic_client.ts` vs. `src/azure_openai_client.ts`).
