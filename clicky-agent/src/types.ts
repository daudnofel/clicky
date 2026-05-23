/**
 * Shared types for the clicky-agent.
 *
 * Shapes are copied verbatim from the apprentice-mode implementation plan:
 *   - § A.1: WorkflowProfile (stored at ~/Library/Application Support/Clicky/workflows/<id>.json)
 *   - § A.3: AgentAction (the action half of /workflow/replay-step's response)
 *
 * Do NOT invent fields. If a contract changes, update Section A first and
 * propagate here.
 */

// ---------------------------------------------------------------------------
// WorkflowProfile (§ A.1)
// ---------------------------------------------------------------------------

export interface WorkflowProfileStep {
  step_index: number;
  intent: string;
}

export interface WorkflowProfileParameter {
  name: string;
  type: string;
  example_from_demo?: string;
}

export interface WorkflowProfileStyleProfile {
  applicable: boolean;
  tone_descriptors?: string[];
  avg_sentence_length?: number;
  avoids_phrases?: string[];
  uses_phrases?: string[];
  verbatim_examples?: Array<{
    question: string;
    user_answer: string;
  }>;
}

export interface WorkflowProfile {
  id: string;
  name?: string;
  created_from_demo_at?: string;
  source_demo_uuid?: string;
  procedure: WorkflowProfileStep[];
  parameters: WorkflowProfileParameter[];
  decision_rules: string[];
  reference_keys: string[];
  style_profile?: WorkflowProfileStyleProfile;
  stop_condition: string;
  output_format: string;
}

// ---------------------------------------------------------------------------
// AgentAction (§ A.3)
// ---------------------------------------------------------------------------

export type AgentActionType =
  | "fill"
  | "click"
  | "navigate"
  | "draft_text"
  | "halt";

export interface AgentAction {
  type: AgentActionType;
  selector?: string;        // for fill/click
  value?: string;           // for fill
  url?: string;             // for navigate
  drafted_text?: string;    // for draft_text
  target_selector?: string; // for draft_text result
  submit_selector?: string; // for halt — selector of the final-submit button so Approve & Submit can click it later (§ A.3 amendment)
  confidence: number;       // 0.0..1.0
  reasoning: string;        // human-readable trace (kept short)
}

export type NextStateHint =
  | "filling"
  | "navigating"
  | "drafting"
  | "submit_ready";

// ---------------------------------------------------------------------------
// Reference data (§ A.5) — opaque to the agent, passed through to the Worker.
// ---------------------------------------------------------------------------

export type ReferenceData = Record<string, unknown>;

// ---------------------------------------------------------------------------
// Step history element (§ A.3 request shape)
// ---------------------------------------------------------------------------

export interface StepHistoryEntry {
  action: AgentAction;
  result: string;
}

// ---------------------------------------------------------------------------
// Outbound websocket messages (Node → Swift) — § A.4
// ---------------------------------------------------------------------------
//
// Discriminated union covering every Node→Swift message defined in § A.4.
// Every emit / broadcast site in the agent must produce a value of this type.
// A missing or renamed field will surface as a TypeScript compile error rather
// than as a silent drift between the agent and the Swift client.
//
// Field shapes are taken verbatim from the implementation plan; in particular,
// `submit_selector` is a TOP-LEVEL field on `queue_item_ready` (per the
// 2026-05-22 § A.3/§ A.4 amendment) — NOT nested inside `filled_fields`.

export interface FrameMessage {
  type: "frame";
  queue_id: string;
  jpeg_b64: string;
  width: number;
  height: number;
}

export interface QueueItemStartedMessage {
  type: "queue_item_started";
  queue_id: string;
  job_url: string;
  company_guess?: string;
}

export interface QueueItemProgressMessage {
  type: "queue_item_progress";
  queue_id: string;
  step: number;
  intent?: string;
}

export interface QueueItemReadyMessage {
  type: "queue_item_ready";
  queue_id: string;
  drafted_text?: string;
  filled_fields: Record<string, string>;
  submit_selector?: string;
}

export interface QueueItemSubmittedMessage {
  type: "queue_item_submitted";
  queue_id: string;
  result: "success" | "failed";
  error_message?: string;
}

export interface ErrorMessage {
  type: "error";
  queue_id?: string;
  error: string;
}

export type OutboundAgentMessage =
  | FrameMessage
  | QueueItemStartedMessage
  | QueueItemProgressMessage
  | QueueItemReadyMessage
  | QueueItemSubmittedMessage
  | ErrorMessage;
