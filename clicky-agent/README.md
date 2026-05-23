# clicky-agent

Headless Chromium agent runner for Clicky / Apprentice mode. The Swift
menu-bar app spawns this Node process per replay job (one process drives N
workflow instances in series), opens each instance in a fresh Chromium
context, drives it step-by-step via the Cloudflare Worker's
`/workflow/replay-step`, halts when the agent decides the form is
submit-ready, and streams JPEG frames of the live page over a local
websocket so the Swift POV window can render them.

## Setup

```bash
npm install
npm run build
npx playwright install chromium
```

## Dev / test

```bash
npm run dev      # starts on ws://127.0.0.1:9876, worker at localhost:8787
npm test         # vitest, unit tests in tests/
npm run smoke    # end-to-end smoke client (see tests/smoke_client.ts)
```

`npm run dev` accepts `--ws-port <N>` and `--worker-url <url>` CLI args.

## Protocol

The Swift <-> Node websocket protocol is defined in
`docs/plans/2026-05-22-clicky-apprentice-mode-IMPLEMENTATION.md` § A.4.
The discriminated union in `src/types.ts` (`OutboundAgentMessage`) is the
TypeScript encoding of the Node->Swift half of that contract; any drift
should surface as a `tsc --noEmit` error.
