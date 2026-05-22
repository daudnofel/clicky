// Minimal Vitest-style test. If the repo has no test framework set up,
// install vitest now: `npm i -D vitest @cloudflare/vitest-pool-workers`.
import { describe, it, expect } from "vitest";

describe("worker routes", () => {
  it("POST /workflow/learn returns a stub WorkflowProfile", async () => {
    const res = await fetch("http://localhost:8787/workflow/learn", {
      method: "POST",
      body: new FormData(), // empty for the stub
    });
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json.profile).toBeDefined();
    expect(json.profile.id).toBeDefined();
    expect(json.profile.procedure).toBeInstanceOf(Array);
  });

  it("POST /workflow/replay-step returns a stub action", async () => {
    const res = await fetch("http://localhost:8787/workflow/replay-step", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        session_id: "test",
        workflow_profile: { id: "test", procedure: [] },
        reference_data: {},
        parameters: {},
        current_url: "about:blank",
        screenshot_b64: "",
        accessibility_tree: {},
        step_history: [],
      }),
    });
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json.action).toBeDefined();
    expect(["fill", "click", "navigate", "draft_text", "halt"]).toContain(json.action.type);
  });
});
