import type { Env } from "./types";

export async function handleWorkflowLearn(request: Request, env: Env): Promise<Response> {
  // STUB: real implementation lives in Task 5. For now, return a
  // syntactically valid WorkflowProfile so downstream consumers can wire up.
  const stubProfile = {
    id: `stub-${crypto.randomUUID()}`,
    name: "Stub workflow",
    created_from_demo_at: new Date().toISOString(),
    source_demo_uuid: "stub",
    procedure: [{ step_index: 0, intent: "stub step" }],
    parameters: [],
    decision_rules: [],
    reference_keys: [],
    style_profile: { applicable: false },
    stop_condition: "submit-ready",
    output_format: "review-queue-card",
  };
  return new Response(JSON.stringify({ profile: stubProfile }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}
