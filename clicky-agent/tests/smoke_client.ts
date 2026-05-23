/**
 * End-to-end smoke client.
 *
 * Run alongside `npm run dev` (clicky-agent) and `npx wrangler dev` (worker):
 *
 *   # Terminal 1 (worker)
 *   cd ../worker && npx wrangler dev
 *   # Terminal 2 (agent)
 *   cd ../clicky-agent && npm run dev
 *   # Terminal 3 (this script)
 *   cd ../clicky-agent && npm run smoke
 *
 * Sends a minimal `start_job` and prints every incoming ws message to stdout.
 * Exits 0 once we see queue_item_ready or queue_item_submitted (success path),
 * or after a 30s timeout (failure path).
 *
 * Designed as a drop-in for `wscat` — same transcript, deterministic exit.
 */

import { WebSocket } from "ws";

const WS_URL = process.env.AGENT_WS_URL ?? "ws://127.0.0.1:9876";
const TIMEOUT_MS = 30_000;

const startJob = {
  type: "start_job" as const,
  session_id: "smoke-1",
  workflow_profile: {
    id: "p",
    procedure: [],
    parameters: [],
    decision_rules: [],
    reference_keys: [],
    stop_condition: "submit-ready",
    output_format: "review-queue-card",
  },
  reference_data: {},
  parameters_list: [{ job_url: "https://example.com" }],
};

const socket = new WebSocket(WS_URL);

let timer: NodeJS.Timeout | null = null;

socket.on("open", () => {
  console.log(`[smoke] connected to ${WS_URL}`);
  console.log(`[smoke] sending start_job:`, JSON.stringify(startJob));
  socket.send(JSON.stringify(startJob));
  timer = setTimeout(() => {
    console.error(`[smoke] timeout after ${TIMEOUT_MS}ms`);
    socket.close();
    process.exit(2);
  }, TIMEOUT_MS);
});

socket.on("message", (raw) => {
  const text = raw.toString();
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(text);
  } catch {
    console.log("[smoke] <- (non-JSON):", text);
    return;
  }
  // Frames are big base64 blobs — log their shape, not their bytes.
  if (parsed.type === "frame") {
    const b64 = parsed.jpeg_b64 as string | undefined;
    console.log(
      `[smoke] <- frame queue_id=${parsed.queue_id} width=${parsed.width} height=${parsed.height} bytes=${b64?.length ?? 0}`
    );
  } else {
    console.log("[smoke] <-", JSON.stringify(parsed));
  }

  if (
    parsed.type === "queue_item_ready" ||
    parsed.type === "queue_item_submitted" ||
    parsed.type === "error"
  ) {
    if (timer) clearTimeout(timer);
    // Wait briefly to flush any trailing frames, then exit.
    setTimeout(() => {
      socket.close();
      process.exit(parsed.type === "error" ? 1 : 0);
    }, 250);
  }
});

socket.on("error", (err) => {
  console.error("[smoke] ws error:", err.message);
  process.exit(1);
});

socket.on("close", () => {
  console.log("[smoke] ws closed");
});
