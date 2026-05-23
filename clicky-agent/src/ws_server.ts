import { WebSocketServer, WebSocket } from "ws";

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
        let parsed: Record<string, unknown>;
        try {
          parsed = JSON.parse(raw.toString());
        } catch (err) {
          console.error(
            "[ws_server] dropped malformed message:",
            (err as Error).message
          );
          return;
        }
        Promise.resolve(this.onMessage(parsed)).catch((err) => {
          console.error("[ws_server] handler error:", err);
        });
      });
    });
  }

  /**
   * Broadcast a message to every connected Swift client. There should only
   * ever be one — the Swift app — but multiple sockets are tolerated.
   */
  broadcast(message: Record<string, unknown>): void {
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
