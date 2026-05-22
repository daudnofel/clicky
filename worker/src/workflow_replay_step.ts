import type { Env } from "./types";

export async function handleWorkflowReplayStep(request: Request, env: Env): Promise<Response> {
  // STUB: real implementation lives in Task 5. Returns "halt" so the agent
  // does nothing dangerous while wired against the stub.
  return new Response(JSON.stringify({
    action: { type: "halt", confidence: 1.0, reasoning: "stub response" },
    next_state_hint: "submit_ready",
  }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}
