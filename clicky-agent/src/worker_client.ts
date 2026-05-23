import type { AgentAction, NextStateHint, WorkflowProfile } from "./types";

/**
 * Thin HTTP wrapper around the Worker's /workflow/replay-step route (§ A.3).
 *
 * The agent_loop calls replayStep() once per agent iteration. The Worker
 * stub returns `{action: {type: "halt"}, next_state_hint: "submit_ready"}`
 * until Task 5 fills in the real Claude integration.
 */
export interface ReplayStepResponse {
  action: AgentAction;
  next_state_hint: NextStateHint;
}

export interface ReplayStepRequest {
  session_id: string;
  workflow_profile: WorkflowProfile;
  reference_data: Record<string, unknown>;
  parameters: Record<string, unknown>;
  current_url: string;
  screenshot_b64: string;
  accessibility_tree: unknown;
  step_history: unknown[];
}

export class WorkerClient {
  constructor(private readonly workerUrl: string) {}

  async replayStep(payload: ReplayStepRequest): Promise<ReplayStepResponse> {
    const res = await fetch(`${this.workerUrl}/workflow/replay-step`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const body = await res.text();
      throw new Error(`replay-step ${res.status}: ${body}`);
    }
    return (await res.json()) as ReplayStepResponse;
  }
}
