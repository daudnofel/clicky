import type { Page } from "playwright";
import type {
  AgentAction,
  OutboundAgentMessage,
  ReferenceData,
  StepHistoryEntry,
  WorkflowProfile,
} from "./types";
import type { WorkerClient } from "./worker_client";

/**
 * The core single-URL replay loop (§ A.3 / § A.4).
 *
 * Inputs are passed explicitly so this function is unit-testable without
 * Playwright: pass `playwright: undefined` and a fake `worker`, and the loop
 * runs in a pure mode (no screenshots, no DOM mutations).
 */
export interface RunInputs {
  sessionId: string;
  queueId: string;
  workflowProfile: WorkflowProfile;
  referenceData: ReferenceData;
  parameters: Record<string, unknown>;
  worker: WorkerClient;
  /**
   * Emit an outbound § A.4 message. Typed as the OutboundAgentMessage union
   * so any drift between the agent and the Swift client surfaces as a
   * TypeScript compile error rather than a silent contract break.
   */
  emit: (event: OutboundAgentMessage) => void;
  /** Pass `{page}` in prod; pass `undefined` for unit tests. */
  playwright: { page: Page } | undefined;
}

/**
 * Bound the loop so a runaway agent can't burn through tokens.
 * 30 is plenty for typical job-application flows (the demo had ~12 steps).
 */
const MAX_STEPS = 30;

export async function runWorkflowOnUrl(inputs: RunInputs): Promise<void> {
  const stepHistory: StepHistoryEntry[] = [];
  let currentUrl =
    (inputs.parameters as Record<string, unknown>).job_url?.toString() ??
    "about:blank";
  const filledFields: Record<string, string> = {};
  let draftedText = "";

  inputs.emit({
    type: "queue_item_started",
    queue_id: inputs.queueId,
    job_url: currentUrl,
  });

  // In prod we navigate to the initial URL once before the first replay-step
  // call so the screenshot/accessibility tree we send Claude reflects the page.
  if (inputs.playwright && currentUrl !== "about:blank") {
    try {
      await inputs.playwright.page.goto(currentUrl, {
        waitUntil: "domcontentloaded",
        timeout: 15000,
      });
    } catch (err) {
      inputs.emit({
        type: "error",
        queue_id: inputs.queueId,
        error: `initial navigation failed: ${(err as Error).message}`,
      });
      return;
    }
  }

  for (let stepIndex = 0; stepIndex < MAX_STEPS; stepIndex++) {
    const { screenshotB64, accessibilityTree } = inputs.playwright
      ? await snapshot(inputs.playwright.page)
      : { screenshotB64: "", accessibilityTree: {} };

    const resp = await inputs.worker.replayStep({
      session_id: inputs.sessionId,
      workflow_profile: inputs.workflowProfile,
      reference_data: inputs.referenceData,
      parameters: inputs.parameters,
      current_url: currentUrl,
      screenshot_b64: screenshotB64,
      accessibility_tree: accessibilityTree,
      step_history: stepHistory,
    });

    inputs.emit({
      type: "queue_item_progress",
      queue_id: inputs.queueId,
      step: stepIndex,
      intent: resp.action.reasoning,
    });

    const action: AgentAction = resp.action;
    if (action.type === "halt") {
      // submit_selector is a first-class field on queue_item_ready (§ A.4),
      // not buried in filled_fields. Claude embeds it on the halt action so
      // the eventual Approve & Submit can re-attach to this Playwright page
      // and click the right button without conflating with form data.
      //
      // `results` is the peer field added in the § A.3 / § A.4 2026-05-23
      // amendment. When the workflow's `output_format === "results-list"`
      // the model extracts the visible items here; we pass them straight
      // through to the Swift app, which renders ResultsListCard. The Worker
      // validator (workflow_replay_step.ts) is what guarantees this array,
      // when present, is well-shaped — we don't re-validate.
      inputs.emit({
        type: "queue_item_ready",
        queue_id: inputs.queueId,
        drafted_text: draftedText,
        filled_fields: filledFields,
        submit_selector: action.submit_selector,
        results: action.results,
      });
      return;
    }

    if (inputs.playwright) {
      try {
        if (
          action.type === "fill" &&
          action.selector &&
          action.value !== undefined
        ) {
          await inputs.playwright.page.fill(
            action.selector,
            String(action.value)
          );
          filledFields[action.selector] = String(action.value);
        } else if (action.type === "click" && action.selector) {
          // force:true bypasses Playwright's "actionability" check that
          // refuses to click an element when another DOM node (overlay,
          // tab bar, modal backdrop) intercepts pointer events. Hostile
          // sites like Google Flights pile invisible layers on top of
          // form fields; the model sees the field in the screenshot and
          // a11y tree and is correct that it should be clicked — we just
          // need to override Playwright's protective heuristic.
          await inputs.playwright.page.click(action.selector, { force: true });
        } else if (action.type === "navigate" && action.url) {
          await inputs.playwright.page.goto(action.url, {
            waitUntil: "domcontentloaded",
            timeout: 15000,
          });
          currentUrl = action.url;
        } else if (
          action.type === "draft_text" &&
          action.target_selector &&
          action.drafted_text
        ) {
          await inputs.playwright.page.fill(
            action.target_selector,
            action.drafted_text
          );
          draftedText = action.drafted_text;
        }
        // Refresh current URL after possible page navigations.
        try {
          currentUrl = inputs.playwright.page.url();
        } catch {
          /* page may have been closed by the action; tolerate */
        }
        stepHistory.push({ action, result: "ok" });
      } catch (err) {
        const errorMessage = (err as Error).message;
        stepHistory.push({ action, result: `error: ${errorMessage}` });
        inputs.emit({
          type: "error",
          queue_id: inputs.queueId,
          error: errorMessage,
        });
        return;
      }
    } else {
      // Unit-test mode: don't actually execute the action.
      stepHistory.push({ action, result: "ok" });
    }
  }

  inputs.emit({
    type: "error",
    queue_id: inputs.queueId,
    error: "MAX_STEPS exceeded",
  });
}

/**
 * Take a JPEG screenshot + accessibility-tree snapshot of the current page.
 * Returns base64-encoded JPEG so it can be embedded directly in JSON.
 *
 * Uses Playwright's ariaSnapshot() which returns a YAML-like string
 * representation of the accessibility tree — Claude can consume it directly
 * as text. (The older `page.accessibility.snapshot()` API was removed.)
 */
async function snapshot(page: Page) {
  const screenshotBuffer = await page.screenshot({ type: "jpeg", quality: 75 });
  const screenshotB64 = screenshotBuffer.toString("base64");
  let accessibilityTree: string = "";
  try {
    // mode: "ai" gives Claude a snapshot with stable [ref=eN] handles it can
    // emit back as selectors (Playwright re-resolves them). Rooted at <html>
    // so dialog/modal content portaled outside <body> is still visible.
    accessibilityTree = await page.locator("html").ariaSnapshot({ mode: "ai" });
  } catch {
    // Page may have just navigated or be blank; tolerate.
    accessibilityTree = "";
  }
  return { screenshotB64, accessibilityTree };
}
