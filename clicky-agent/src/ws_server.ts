import { WebSocketServer, WebSocket } from "ws";
import type { OutboundAgentMessage } from "./types.js";

/**
 * Local-only websocket server (§ A.4).
 *
 * The Swift app spawns this process with `--ws-port <N>` and connects to
 * ws://127.0.0.1:<N>/. No auth — bound to 127.0.0.1 only so it isn't
 * reachable off-host.
 *
 * Messages are JSON objects in both directions. See § A.4 for the schema.
 */
export type IncomingMessageHandler = (
  message: Record<string, unknown>
) => Promise<void> | void;

/**
 * Minimal shape guard for inbound Swift → Node messages.
 *
 * The full per-type validation lives in the orchestrator (it pattern-matches
 * on `type`); this is a ground-floor check so a buggy Swift client that
 * sends a non-object or a payload missing `type` gets a clear error back
 * instead of silently advancing into the orchestrator's switch.
 */
function isWellFormedInboundMessage(
  value: unknown
): value is Record<string, unknown> & { type: string } {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof (value as { type?: unknown }).type === "string"
  );
}

export class AgentWebSocketServer {
  private wss: WebSocketServer;
  private clients = new Set<WebSocket>();

  constructor(
    port: number,
    private readonly onMessage: IncomingMessageHandler
  ) {
    this.wss = new WebSocketServer({ port, host: "127.0.0.1" });
    this.wss.on("connection", (socket) => {
      this.clients.add(socket);
      socket.on("close", () => this.clients.delete(socket));
      socket.on("error", () => this.clients.delete(socket));
      socket.on("message", (raw) => {
        let parsed: unknown;
        try {
          parsed = JSON.parse(raw.toString());
        } catch (err) {
          console.error(
            "[ws_server] dropped malformed message:",
            (err as Error).message
          );
          this.sendErrorToSender(socket, "malformed inbound message");
          return;
        }
        if (!isWellFormedInboundMessage(parsed)) {
          console.error(
            "[ws_server] dropped inbound message lacking string 'type'"
          );
          this.sendErrorToSender(socket, "malformed inbound message");
          return;
        }
        Promise.resolve(this.onMessage(parsed)).catch((err) => {
          console.error("[ws_server] handler error:", err);
        });
      });
    });
  }

  /**
   * Send an error message back to a single sender (used when their inbound
   * payload was malformed — we don't want to broadcast that to every
   * client). Tolerates a closed socket.
   */
  private sendErrorToSender(socket: WebSocket, errorText: string): void {
    if (socket.readyState !== WebSocket.OPEN) return;
    const message: OutboundAgentMessage = { type: "error", error: errorText };
    try {
      socket.send(JSON.stringify(message));
    } catch {
      /* tolerate — sender may have already disconnected */
    }
  }

  /**
   * Broadcast a message to every connected Swift client. There should only
   * ever be one — the Swift app — but multiple sockets are tolerated.
   *
   * Typed as the § A.4 OutboundAgentMessage union so missing or renamed
   * fields fail at compile time, not silently on the Swift side.
   */
  broadcast(message: OutboundAgentMessage): void {
    const payload = JSON.stringify(message);
    for (const socket of this.clients) {
      if (socket.readyState === WebSocket.OPEN) {
        socket.send(payload);
      }
    }
  }

  close(): Promise<void> {
    return new Promise((resolve) => {
      for (const socket of this.clients) {
        try {
          socket.close();
        } catch {
          /* ignore */
        }
      }
      this.clients.clear();
      this.wss.close(() => resolve());
    });
  }

  get port(): number {
    const address = this.wss.address();
    if (typeof address === "object" && address !== null) {
      return address.port;
    }
    return -1;
  }
}
