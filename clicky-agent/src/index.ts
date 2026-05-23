/**
 * clicky-agent entry point.
 *
 * Spawned by the Swift app (see plan § Task 6 / AgentSpawner) with:
 *   node dist/index.js --ws-port <N> --worker-url <url>
 *
 * Responsibilities:
 *   1. Parse --ws-port and --worker-url CLI flags.
 *   2. Start an AgentWebSocketServer listening on 127.0.0.1:<ws-port>.
 *   3. On `start_job` from Swift, launch a headless Chromium browser and
 *      iterate the parameters_list, running runWorkflowOnUrl() per item.
 *   4. Stream JPEG frames over the websocket via FrameStreamer.
 *   5. Leave each page open after halt so a future `approve_submit` can
 *      re-attach. (Real submit-click logic is deferred — see TODO below.)
 */

import { chromium, type Browser, type Page } from "playwright";
import { runWorkflowOnUrl } from "./agent_loop.js";
import { FrameStreamer } from "./frame_streamer.js";
import { WorkerClient } from "./worker_client.js";
import { AgentWebSocketServer } from "./ws_server.js";
import type { ReferenceData, WorkflowProfile } from "./types.js";

interface ParsedArgs {
  wsPort: number;
  workerUrl: string;
}

function parseArgs(argv: string[]): ParsedArgs {
  let wsPort = 9876;
  let workerUrl = "http://localhost:8787";
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (flag === "--ws-port" && value) {
      wsPort = Number(value);
      i++;
    } else if (flag === "--worker-url" && value) {
      workerUrl = value;
      i++;
    }
  }
  if (!Number.isFinite(wsPort) || wsPort <= 0) {
    throw new Error(`Invalid --ws-port: ${argv.join(" ")}`);
  }
  return { wsPort, workerUrl };
}

interface StartJobMessage {
  type: "start_job";
  session_id: string;
  workflow_profile: WorkflowProfile;
  reference_data: ReferenceData;
  parameters_list: Array<Record<string, unknown>>;
}

interface ApproveSubmitMessage {
  type: "approve_submit";
  session_id: string;
  queue_id: string;
}

interface DiscardMessage {
  type: "discard";
  session_id: string;
  queue_id: string;
}

interface StopMessage {
  type: "stop";
}

type IncomingMessage =
  | StartJobMessage
  | ApproveSubmitMessage
  | DiscardMessage
  | StopMessage;

/**
 * Per-queue-item state we hang on to after the agent halts so a later
 * `approve_submit` or `discard` can find the right Playwright page.
 */
interface QueueItemSession {
  queueId: string;
  page: Page;
  draftedText: string;
  filledFields: Record<string, string>;
  submitSelector?: string;
}

class AgentOrchestrator {
  private worker: WorkerClient;
  private server: AgentWebSocketServer;
  private browser: Browser | null = null;
  private queueSessions = new Map<string, QueueItemSession>();
  private shuttingDown = false;

  constructor(args: ParsedArgs) {
    this.worker = new WorkerClient(args.workerUrl);
    this.server = new AgentWebSocketServer(args.wsPort, (msg) =>
      this.handleMessage(msg as unknown as IncomingMessage)
    );
    console.log(
      `[clicky-agent] ws listening on 127.0.0.1:${args.wsPort}, worker=${args.workerUrl}`
    );
  }

  private async ensureBrowser(): Promise<Browser> {
    if (!this.browser) {
      this.browser = await chromium.launch({ headless: true });
    }
    return this.browser;
  }

  private async handleMessage(message: IncomingMessage): Promise<void> {
    if (message.type === "start_job") {
      await this.handleStartJob(message);
    } else if (message.type === "approve_submit") {
      await this.handleApproveSubmit(message);
    } else if (message.type === "discard") {
      await this.handleDiscard(message);
    } else if (message.type === "stop") {
      await this.shutdown();
    } else {
      console.warn(
        "[clicky-agent] unknown message type:",
        (message as { type: string }).type
      );
    }
  }

  private startJobInFlight: boolean = false;

  private async handleStartJob(message: StartJobMessage): Promise<void> {
    // V1: serialize start_job. Concurrent jobs would share `this.browser` and
    // interleave events; Swift owns the queueing instead.
    if (this.startJobInFlight) {
      this.server.broadcast({
        type: "error",
        queue_id: message.session_id,
        error: "another start_job is already in flight — wait for it to finish",
      });
      return;
    }
    this.startJobInFlight = true;
    try {
      await this.runStartJob(message);
    } finally {
      this.startJobInFlight = false;
    }
  }

  private async runStartJob(message: StartJobMessage): Promise<void> {
    const browser = await this.ensureBrowser();
    for (
      let parameterIndex = 0;
      parameterIndex < message.parameters_list.length;
      parameterIndex++
    ) {
      const parameters = message.parameters_list[parameterIndex];
      const queueId = `${message.session_id}-${parameterIndex}`;
      const context = await browser.newContext({
        viewport: { width: 1280, height: 800 },
      });
      const page = await context.newPage();
      const streamer = new FrameStreamer(
        page,
        (frameMessage) => this.server.broadcast(frameMessage),
        queueId
      );
      streamer.start(8);

      const filledFields: Record<string, string> = {};
      let draftedText = "";

      let teedSubmitSelector: string | undefined;
      try {
        await runWorkflowOnUrl({
          sessionId: message.session_id,
          queueId,
          workflowProfile: message.workflow_profile,
          referenceData: message.reference_data,
          parameters,
          worker: this.worker,
          emit: (event) => {
            this.server.broadcast(event);
            // Tee a few fields out so we can store them on the session
            // for a later approve_submit. submit_selector is a first-class
            // queue_item_ready field per § A.4 (not buried in filled_fields).
            if (event.type === "queue_item_ready") {
              const filled =
                (event.filled_fields as Record<string, string>) ?? {};
              Object.assign(filledFields, filled);
              draftedText = (event.drafted_text as string) ?? "";
              teedSubmitSelector = event.submit_selector as string | undefined;
            }
          },
          playwright: { page },
        });
      } catch (err) {
        this.server.broadcast({
          type: "error",
          queue_id: queueId,
          error: (err as Error).message,
        });
      } finally {
        streamer.stop();
      }

      // Persist the session so a later `approve_submit` for this queue_id
      // can re-attach. The page stays open in the headless browser context.
      this.queueSessions.set(queueId, {
        queueId,
        page,
        draftedText,
        filledFields,
        submitSelector: teedSubmitSelector,
      });
    }
  }

  /**
   * approve_submit handler.
   *
   * NOTE (deferred — see plan § Task 4 Step 7 hand-wave): the plan describes
   * "re-look up the open page for that queue_id, click the submit button"
   * but the stub Worker (Task 2) returns halt with no submit selector. So
   * this handler:
   *   - Looks up the persisted QueueItemSession.
   *   - If a submitSelector was stored (will be once Task 5 lands a real
   *     /workflow/replay-step that emits it), clicks it and emits success.
   *   - Otherwise emits queue_item_submitted with result="failed" + a clear
   *     error_message so the Swift UI can show a sensible state.
   * Real submit-button discovery + click will be filled in alongside Task 5.
   */
  private async handleApproveSubmit(
    message: ApproveSubmitMessage
  ): Promise<void> {
    const session = this.queueSessions.get(message.queue_id);
    if (!session) {
      this.server.broadcast({
        type: "error",
        queue_id: message.queue_id,
        error: "no agent session for that queue_id (may have been discarded)",
      });
      return;
    }
    if (!session.submitSelector) {
      this.server.broadcast({
        type: "queue_item_submitted",
        queue_id: message.queue_id,
        result: "failed",
        error_message:
          "no submit_selector recorded by agent — re-attach not yet implemented",
      });
      return;
    }
    try {
      await session.page.click(session.submitSelector);
      this.server.broadcast({
        type: "queue_item_submitted",
        queue_id: message.queue_id,
        result: "success",
      });
    } catch (err) {
      this.server.broadcast({
        type: "queue_item_submitted",
        queue_id: message.queue_id,
        result: "failed",
        error_message: (err as Error).message,
      });
    }
  }

  private async handleDiscard(message: DiscardMessage): Promise<void> {
    const session = this.queueSessions.get(message.queue_id);
    if (session) {
      try {
        await session.page.context().close();
      } catch {
        /* tolerate */
      }
      this.queueSessions.delete(message.queue_id);
    }
  }

  async shutdown(): Promise<void> {
    if (this.shuttingDown) return;
    this.shuttingDown = true;
    console.log("[clicky-agent] shutting down");
    for (const session of this.queueSessions.values()) {
      try {
        await session.page.context().close();
      } catch {
        /* tolerate */
      }
    }
    this.queueSessions.clear();
    if (this.browser) {
      try {
        await this.browser.close();
      } catch {
        /* tolerate */
      }
      this.browser = null;
    }
    await this.server.close();
    process.exit(0);
  }
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const orchestrator = new AgentOrchestrator(args);

  const onSignal = () => {
    orchestrator.shutdown().catch((err) => {
      console.error("[clicky-agent] shutdown error:", err);
      process.exit(1);
    });
  };
  process.on("SIGINT", onSignal);
  process.on("SIGTERM", onSignal);
}

main().catch((err) => {
  console.error("[clicky-agent] fatal:", err);
  process.exit(1);
});
