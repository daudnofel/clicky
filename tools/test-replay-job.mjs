#!/usr/bin/env node
// Connects to the running clicky-agent on ws://127.0.0.1:9876 and sends a
// start_job message using a previously-extracted WorkflowProfile.
//
// Usage:  node tools/test-replay-job.mjs <profile.json>
//
// The script stays connected, prints every event the agent emits, and exits
// when a terminal event (queue_item_ready / error / queue_item_submitted)
// arrives for the test queue id. Frames are summarized (not dumped).

import fs from "node:fs";
import path from "node:path";
// Use the global WebSocket from Node 21+. Avoids depending on the `ws`
// package being reachable from this script's resolver path.

const profilePath = process.argv[2];
if (!profilePath) {
  console.error("Usage: node tools/test-replay-job.mjs <profile.json>");
  process.exit(1);
}

const workflowProfile = JSON.parse(fs.readFileSync(profilePath, "utf8")).profile
  ?? JSON.parse(fs.readFileSync(profilePath, "utf8"));

const wsUrl = process.env.AGENT_WS_URL ?? "ws://127.0.0.1:9876/";
const sessionId = `replay-test-${Date.now()}`;
const expectedQueueId = `${sessionId}-0`;

console.log(`Connecting to ${wsUrl} ...`);
const socket = new WebSocket(wsUrl);

socket.addEventListener("open", () => {
  console.log(`Connected. Sending start_job with session_id=${sessionId}`);
  const startJob = {
    type: "start_job",
    session_id: sessionId,
    workflow_profile: workflowProfile,
    reference_data: {
      identity: { name: "Daud Nofel", city: "Austin" },
    },
    parameters_list: [
      // For a flight-search profile, the parameters are origin/destination/dates.
      // The agent will start at about:blank and the first replay-step decision
      // should be a `navigate` action to google.com/travel/flights or similar.
      {
        origin_city: "Austin",
        destination_city: "New York",
        depart_date: "2026-06-08",
        return_date: "2026-06-12",
      },
    ],
  };
  socket.send(JSON.stringify(startJob));
});

let frameCount = 0;
socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data.toString());
  if (message.type === "frame") {
    frameCount++;
    // Print one summary line per 10 frames so the output is readable.
    if (frameCount % 10 === 1) {
      console.log(`  [frame #${frameCount}] queue_id=${message.queue_id} ${message.width}x${message.height}`);
    }
    return;
  }
  // Pretty-print everything else.
  console.log(`<- ${message.type}`, JSON.stringify(message, null, 2));

  if (
    message.queue_id === expectedQueueId &&
    (message.type === "queue_item_ready" ||
      message.type === "queue_item_submitted" ||
      (message.type === "error" && !message.queue_id))
  ) {
    console.log(`\nFinal event received. Total frames streamed: ${frameCount}`);
    setTimeout(() => {
      socket.close();
      process.exit(0);
    }, 500);
  }
  if (message.type === "error") {
    // Error events without a queue_id are fatal at the agent level.
    console.error("Agent emitted an error.");
    setTimeout(() => {
      socket.close();
      process.exit(1);
    }, 500);
  }
});

socket.addEventListener("close", () => {
  console.log("ws closed");
});
socket.addEventListener("error", (event) => {
  console.error("ws error:", event.message ?? event);
  process.exit(1);
});

// Hard timeout after 3 minutes — runs that long are almost certainly stuck.
setTimeout(() => {
  console.error("\nTimed out after 180s — killing.");
  process.exit(2);
}, 180_000);
