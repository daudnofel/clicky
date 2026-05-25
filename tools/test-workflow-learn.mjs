#!/usr/bin/env node
// POSTs a recording dir to /workflow/learn and prints the returned profile.
// Usage:  node tools/test-workflow-learn.mjs <recording-dir>

import fs from "node:fs";
import path from "node:path";

const recordingDir = process.argv[2];
if (!recordingDir) {
  console.error("Usage: node tools/test-workflow-learn.mjs <recording-dir>");
  process.exit(1);
}

const workerUrl = process.env.WORKER_URL ?? "http://localhost:8787";

const manifest = fs.readFileSync(path.join(recordingDir, "manifest.json"), "utf8");
const events = fs.readFileSync(path.join(recordingDir, "events.jsonl"), "utf8");
const transcript = fs.readFileSync(path.join(recordingDir, "transcript.json"), "utf8");

const form = new FormData();
form.append("manifest", manifest);
form.append("events", events);
form.append("transcript", transcript);

const framesDir = path.join(recordingDir, "frames");
const frames = fs
  .readdirSync(framesDir)
  .filter((f) => f.endsWith(".jpg"))
  .sort();

for (const frameFile of frames) {
  const buf = fs.readFileSync(path.join(framesDir, frameFile));
  const blob = new Blob([buf], { type: "image/jpeg" });
  const fieldName = `frame_${frameFile.replace(".jpg", "")}`;
  form.append(fieldName, blob, frameFile);
}

console.log(`Posting ${frames.length} frames + manifest + events + transcript to ${workerUrl}/workflow/learn`);
const startedAt = Date.now();
const response = await fetch(`${workerUrl}/workflow/learn`, {
  method: "POST",
  body: form,
});
const elapsedMs = Date.now() - startedAt;
console.log(`Status ${response.status} (${elapsedMs} ms)`);
const responseJson = await response.json();
console.log(JSON.stringify(responseJson, null, 2));
