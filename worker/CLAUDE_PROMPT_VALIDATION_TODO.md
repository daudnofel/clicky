# Claude Prompt Validation TODO

Task 5 of the apprentice-mode implementation plan landed the real Claude integration for `/workflow/learn` and `/workflow/replay-step`. The code is shipped and the mocked tests are green, but **no part of this has been exercised against a real Anthropic API response** because the user didn't have an API key when the code was written.

This file is the checklist of things to verify once an Anthropic API key is in hand. Until every box here is checked, treat the prompts as *plausibly correct but unverified*.

---

## Optional: Azure OpenAI backend

If you don't have Anthropic credits but DO have Azure OpenAI credits, you can flip the backend with one env var while keeping the prompts and contracts byte-identical. Anthropic stays the default that ships in the submission fork.

```bash
cd fork/worker

# Secret: the Azure API key (rotate when needed).
npx wrangler secret put AZURE_OPENAI_API_KEY        # paste key

# Non-secret config — either via `wrangler.toml [vars]` (preferred) or
# `wrangler secret put` (works too, but config-y values fit better in vars).
# Add this block to wrangler.toml:
#
#   [vars]
#   WORKFLOW_MODEL_BACKEND   = "azure_openai"
#   AZURE_OPENAI_ENDPOINT    = "https://my-resource.openai.azure.com"
#   AZURE_OPENAI_DEPLOYMENT  = "gpt-4o"
#   AZURE_OPENAI_API_VERSION = "2024-10-21"    # optional, this is the default
#
# Then deploy:
npx wrangler deploy
```

Switch back to Anthropic at any time by removing `WORKFLOW_MODEL_BACKEND` (or setting it to `"anthropic"`). The dispatcher uses strict equality on `"azure_openai"`, so typos safely fall back to Anthropic.

Notes:
- The Azure path uses native JSON mode (`response_format: {type: "json_object"}`) instead of prompt-engineered JSON, so the model is guaranteed to return parseable JSON.
- Azure prompt caching is **implicit** for prefixes >= 1024 tokens — no explicit `cache_control` markers like on Anthropic. Multi-step replay still benefits from the shared system+workflow_profile prefix, but you won't see explicit `cache_read_input_tokens` / `cache_creation_input_tokens` in the response (Azure reports caching differently — check the usage breakdown in the Azure portal).
- Use a **GPT-4o** or **GPT-4.1** deployment — both workflow endpoints send images, so vision support is required.
- See `worker/AZURE_OPENAI_BACKEND.md` for the full diff between the two paths.

---

## Setup (one-time)

- [ ] Sign in / sign up to https://console.anthropic.com.
- [ ] Create an API key with at least Messages API access.
- [ ] From `fork/worker/`:
      ```bash
      npx wrangler secret put ANTHROPIC_API_KEY    # paste the key
      ```
- [ ] Deploy:
      ```bash
      cd fork/worker
      npx wrangler deploy
      ```
- [ ] Or for local testing, create `fork/worker/.dev.vars` with:
      ```
      ANTHROPIC_API_KEY=sk-ant-...
      ELEVENLABS_API_KEY=...
      ASSEMBLYAI_API_KEY=...
      ```
      and run `npx wrangler dev`.

---

## Step 1 — Verify `/workflow/learn` against a real demo recording

Pick the smallest possible recording: one job application, 30 seconds, 10-20 frames.

- [ ] Find a recording in `~/Library/Application Support/Clicky/recordings/<uuid>/`. If empty, capture one via the Swift app's "Teach me a workflow" toggle.
- [ ] Write a small `scripts/post-learn.ts` (or use `curl`) that posts the recording as `multipart/form-data` per § A.3:
      - field `manifest`: contents of `manifest.json`
      - field `events`: contents of `events.jsonl`
      - field `transcript`: contents of `transcript.json`
      - field `frame_0000`, `frame_0001`, ... `frame_NNNN`: each frame JPEG as a file part
- [ ] Hit `POST /workflow/learn` on the deployed worker (or `http://localhost:8787/workflow/learn` against `wrangler dev`).
- [ ] **Sanity-check the returned `profile`** by hand. Look for:
  - `procedure[].intent` describes WHY, not pixel coordinates.
  - `parameters` captures the URL (or whatever varies).
  - `reference_keys` is populated if the user pulled info from `identity.*`.
  - If the user wrote freeform text, `style_profile.applicable` is `true` AND `verbatim_examples[].user_answer` matches the text the user typed *letter-for-letter*. This is the #1 thing to verify — paraphrased examples make replay text feel generic.
- [ ] **If the profile is wrong**: do NOT immediately retune the prompt. First check whether the events.jsonl actually contained the text events Claude would have needed to see. (Task 3 had a follow-up about `url_change` events that may still be missing — TaskList #12.)

---

## Step 2 — Verify `/workflow/replay-step` against a real page

Once Task 5 + Task 4 (Node agent) are both live, you can run an end-to-end replay against a Greenhouse / Lever / Ashby test job.

- [ ] In one terminal: `cd fork/worker && npx wrangler dev`.
- [ ] In another: `cd fork/clicky-agent && npm run dev`.
- [ ] In a third: `wscat -c ws://127.0.0.1:9876` and send:
      ```jsonc
      {"type":"start_job","session_id":"s1","workflow_profile":<paste profile from Step 1>,"reference_data":{"identity":{"name":"Daud Nofel","email":"..."}},"parameters_list":[{"job_url":"<real test job URL>"}]}
      ```
- [ ] Watch the agent loop. **Verify each replay-step response:**
  - `action.selector` uses `aria-ref=eN` handles (the format from Playwright `ariaSnapshot()`) when the accessibility tree had one.
  - On `halt`, `submit_selector` is set to the real submit button's selector (or `null` with a reasoning explaining why).
  - On `draft_text` for a freeform field, the drafted text is in the user's voice — short sentences, no "passionate about", uses the verbatim_examples as a tonal anchor.
- [ ] Confirm the agent NEVER actually clicks a submit button (it should halt and queue the item for review instead).

---

## Step 3 — Verify prompt caching is actually firing

- [ ] In the Anthropic Console (https://console.anthropic.com), look at the response payload for each Messages API call. Search for `usage.cache_read_input_tokens` and `usage.cache_creation_input_tokens`.
- [ ] First step of a replay job should show `cache_creation_input_tokens > 0` and `cache_read_input_tokens` close to 0.
- [ ] Second and subsequent steps of the SAME job should show `cache_read_input_tokens` close to the size of the system prompt + workflow_profile, and `cache_creation_input_tokens` close to 0. That's the cache win.
- [ ] If you don't see cache hits: confirm the `cache_control: { type: "ephemeral" }` annotation made it through the JSON serialization, and that the system blocks are byte-identical across calls (no per-call timestamps or jitter in the system content).

---

## Step 4 — Tune what doesn't work

After Steps 1-3, you'll have evidence on which prompt rules Claude respects and which it ignores. Common issues to expect:

- [ ] **Claude over-paraphrases the verbatim example.** Strengthen the rule in `learn_system.md`: add an explicit "do not paraphrase" + show a wrong example.
- [ ] **Claude invents brittle CSS selectors instead of using `[ref=eN]`.** Strengthen `replay_system.md`'s SELECTOR RULES with a concrete example of the YAML-ish accessibility tree shape and the corresponding `aria-ref=eN` selector.
- [ ] **Claude forgets `submit_selector` on halt.** The handler stamps `null` for safety, but ideally Claude populates it. Strengthen the HALT RULES wording — or move to Anthropic's structured-output / tool-use API so the schema is enforced server-side.
- [ ] **Claude leaks markdown fences.** The handler strips them, so this is cosmetic. But if it persists, add `"Output JSON directly, no fences"` again at the END of the prompt (Claude weights recency).

Each time you tune a prompt, update BOTH `learn_system.md`/`replay_system.md` (source of truth) AND `learn_system.ts`/`replay_system.ts` (runtime constant). They must stay byte-identical.

---

## Step 5 — Cost sanity check

Track Anthropic spend during validation. Expected order of magnitude for one full job (1 demonstration learn + ~10 jobs × ~6 replay steps with 1 image each):

- See the "Token-cost back-of-envelope" section of the Task 5 report. With prompt caching working, expect ~$0.10-0.30 per replay job. Without caching, expect 3-5x that.

---

## Step 6 — Long-running validation

Once Steps 1-4 are clean, run the full IG DM triage workflow (Task 8 of the plan). It's the schema generalization test — if learn/replay work on both job apps AND IG DMs without prompt changes, the contract is sound.

- [ ] Demo: teach an IG DM triage workflow.
- [ ] Replay: 5 unread DMs, agent drafts one reply each, all halt at "send" without sending.
- [ ] Style match: replies sound like the user, not like a chatbot.

---

## What's NOT validated yet (the gap)

- The system prompts themselves — neither has ever been seen by Claude.
- Anthropic's prompt caching headers and behavior (we set `cache_control` but never observed `cache_read_input_tokens`).
- The interaction between the 12-frame downsampling and Claude's vision attention.
- Whether `[ref=eN]` selectors actually round-trip through the Playwright `aria-ref=eN` engine (this is the Task 4 deviation — confirm with the Node agent maintainer).
- End-to-end: demonstration -> learn -> replay -> queue card -> approve & submit.

Once this checklist is fully green, delete this file and update the Task 5 entry in `docs/plans/2026-05-22-clicky-apprentice-mode-IMPLEMENTATION.md` to "validated."
