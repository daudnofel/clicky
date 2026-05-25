import type { Env } from "./types";
import { getModelClient } from "./get_model_client";
import { LEARN_SYSTEM_PROMPT } from "./prompts/learn_system";

/**
 * Number of demonstration frames to include in the model vision request.
 * 12 was chosen as a middle-ground — enough temporal resolution for a
 * ~30-second demo without bloating the multimodal payload past the point
 * where prompt caching savings stop mattering.
 */
const MAX_FRAMES_TO_SAMPLE = 12;

/**
 * Cap on the model's response length. WorkflowProfiles are typically
 * 600-1200 tokens; 4096 gives plenty of headroom without runaway costs.
 */
const MAX_OUTPUT_TOKENS = 4096;

/**
 * `POST /workflow/learn` — extract a WorkflowProfile from a demo recording.
 *
 * Request: `multipart/form-data` with three string fields and N JPEG files:
 *   - `manifest`     (string, JSON-encoded RecordingManifest from § A.2)
 *   - `events`       (string, raw JSONL event log)
 *   - `transcript`   (string, JSON-encoded AssemblyAI transcript)
 *   - `frame_NNNN`   (file, JPEG screenshot — N copies, monotonically named)
 *
 * Response: `{ "profile": <WorkflowProfile> }` on success,
 *           `{ "error": "<message>" }` with non-200 status otherwise.
 *
 * Backend dispatch: this handler is backend-agnostic. The actual API call
 * (Anthropic Claude by default, Azure OpenAI when
 * `WORKFLOW_MODEL_BACKEND=azure_openai`) lives behind the `ModelClient`
 * interface returned by `getModelClient(env)`. The PROMPT
 * (`learn_system.md`) is also backend-agnostic and unchanged.
 */
export async function handleWorkflowLearn(
  request: Request,
  env: Env,
): Promise<Response> {
  // Parse multipart/form-data. Cloudflare Workers' built-in `request.formData()`
  // handles this natively and gives us back string parts and File parts.
  let formData: FormData;
  try {
    formData = await request.formData();
  } catch (parseErr) {
    return jsonError(400, `failed to parse multipart/form-data: ${parseErr}`);
  }

  const manifestRaw = formData.get("manifest");
  const eventsRaw = formData.get("events");
  const transcriptRaw = formData.get("transcript");

  if (typeof manifestRaw !== "string") {
    return jsonError(400, "missing required form field: manifest");
  }
  if (typeof eventsRaw !== "string") {
    return jsonError(400, "missing required form field: events");
  }
  // transcript is allowed to be absent (the user may not have narrated).
  const transcriptString =
    typeof transcriptRaw === "string" ? transcriptRaw : "{}";

  let manifest: { uuid?: string; [key: string]: unknown };
  try {
    manifest = JSON.parse(manifestRaw);
  } catch (parseErr) {
    return jsonError(400, `manifest is not valid JSON: ${parseErr}`);
  }

  // Collect every uploaded frame, preserve their submitted order by name
  // (frame_0000 < frame_0001 < ...) so the visual timeline is monotonic.
  const frameEntries: { name: string; base64Jpeg: string }[] = [];
  for (const [key, value] of formData.entries()) {
    if (!key.startsWith("frame_")) continue;
    if (!(value instanceof File)) continue;
    const arrayBuffer = await value.arrayBuffer();
    frameEntries.push({
      name: key,
      base64Jpeg: arrayBufferToBase64(arrayBuffer),
    });
  }
  frameEntries.sort((a, b) => a.name.localeCompare(b.name));

  const sampledFrames = pickEvenlySpaced(frameEntries, MAX_FRAMES_TO_SAMPLE);

  // Build the user-turn text payload. Frames are passed separately via
  // `userImages` and rendered backend-appropriately by the ModelClient
  // (Anthropic base64 image blocks vs. OpenAI data-URL image_url blocks).
  const userText =
    `EVENTS (JSONL — one event per line, time-ordered):\n${eventsRaw}\n\n` +
    `TRANSCRIPT (AssemblyAI):\n${transcriptString}\n\n` +
    `MANIFEST:\n${manifestRaw}\n\n` +
    "Return the WorkflowProfile JSON now. JSON only.";

  const userImages = sampledFrames.map((frame) => ({
    b64: frame.base64Jpeg,
    mediaType: "image/jpeg",
  }));

  // Backend selection: `getModelClient` returns `AnthropicClient` by
  // default and `AzureOpenAIClient` when `WORKFLOW_MODEL_BACKEND ===
  // "azure_openai"`. Anthropic is the default that ships in the
  // submission fork; Azure is opt-in for free dev against Azure credits.
  const modelClient = getModelClient(env);
  let output;
  try {
    output = await modelClient.generateStructured({
      systemPrompt: LEARN_SYSTEM_PROMPT,
      userText,
      userImages,
      maxOutputTokens: MAX_OUTPUT_TOKENS,
      responseShape: "json_object",
    });
  } catch (callErr) {
    return jsonError(502, `model call failed: ${callErr}`);
  }

  // Surface upstream HTTP errors with the same status code (the original
  // behavior was to forward the Anthropic status — keep that for parity).
  if (output.upstreamError) {
    console.error(
      `[/workflow/learn] upstream error ${output.upstreamError.status}: ${output.upstreamError.body}`,
    );
    // Generic "upstream model API" label — applies to whichever backend
    // (Anthropic or Azure OpenAI) the ModelClient routed to. The UI / Swift
    // surfaces this string directly, so don't mention a specific provider.
    return jsonError(
      output.upstreamError.status,
      `Upstream model API error: ${output.upstreamError.body}`,
    );
  }

  if (output.json === null) {
    // The model returned text but it wasn't valid JSON. Log the raw
    // output (which the client already stripped of code fences) so we
    // can debug from the Worker tail.
    console.error(
      `[/workflow/learn] model produced invalid JSON:\n---\n${output.rawText}`,
    );
    return jsonError(
      502,
      "Claude produced text that was not valid JSON. See worker logs for the raw output.",
    );
  }

  // Defensive: we only proceed if the parsed value is an object. A bare
  // string / number / array would be a contract violation.
  if (typeof output.json !== "object" || Array.isArray(output.json)) {
    return jsonError(502, "model output was not a JSON object");
  }

  const profile = output.json as Record<string, unknown>;

  // Stamp identity / provenance fields so the Worker is the single source of
  // truth for them — don't trust whatever the model invented.
  if (typeof profile.id !== "string" || profile.id.length === 0) {
    profile.id = `wf-${crypto.randomUUID()}`;
  }
  profile.created_from_demo_at = new Date().toISOString();
  profile.source_demo_uuid =
    typeof manifest.uuid === "string" ? manifest.uuid : "unknown";

  // Validate the shape minimally — `procedure` must exist as an array, the
  // rest of the contract is "fill what you can." A missing procedure is a
  // hard failure because downstream replay has nothing to do.
  if (!Array.isArray(profile.procedure)) {
    return jsonError(
      502,
      "Claude output is missing required `procedure` array.",
    );
  }

  // Defensive defaulting for slots downstream consumers iterate or branch on.
  // Task 5 review I-3: don't trust the model to emit `parameters` as an
  // array or `stop_condition` as a string — supply safe defaults instead
  // of crashing a downstream JSON.parse / for-of loop.
  if (!Array.isArray(profile.parameters)) {
    profile.parameters = [];
  }
  if (typeof profile.stop_condition !== "string") {
    profile.stop_condition = "submit-ready";
  }
  if (typeof profile.output_format !== "string") {
    profile.output_format = "review-queue-card";
  }
  if (!Array.isArray(profile.decision_rules)) {
    profile.decision_rules = [];
  }
  if (!Array.isArray(profile.reference_keys)) {
    profile.reference_keys = [];
  }

  return new Response(JSON.stringify({ profile }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

/**
 * Picks at most `count` items from `items`, evenly spaced across the input.
 * If the input is shorter than `count`, returns it as-is.
 */
function pickEvenlySpaced<T>(items: T[], count: number): T[] {
  if (items.length <= count) return items;
  if (count <= 0) return [];
  const stride = (items.length - 1) / (count - 1);
  const sampled: T[] = [];
  for (let i = 0; i < count; i++) {
    const indexFloat = i * stride;
    const indexRounded = Math.min(items.length - 1, Math.round(indexFloat));
    sampled.push(items[indexRounded]);
  }
  return sampled;
}

/**
 * Base64-encode an `ArrayBuffer`. Cloudflare Workers don't have Node's
 * `Buffer`, so we walk the bytes ourselves and feed `btoa`. This loop is
 * fine for screenshots (~50-200KB each); if we ever upload large videos
 * we'd want a streaming approach instead.
 */
function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binaryString = "";
  const CHUNK_SIZE = 0x8000; // 32KB — avoids stack overflow on apply().
  for (let offset = 0; offset < bytes.length; offset += CHUNK_SIZE) {
    const chunk = bytes.subarray(offset, offset + CHUNK_SIZE);
    binaryString += String.fromCharCode(...chunk);
  }
  return btoa(binaryString);
}

function jsonError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "content-type": "application/json" },
  });
}
