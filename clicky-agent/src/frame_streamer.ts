import type { Page } from "playwright";
import type { FrameMessage } from "./types.js";

/**
 * FrameStreamer — emits periodic JPEG screenshots of a Playwright Page
 * to the Swift app over the local websocket (§ A.4 frame messages).
 *
 * Per the spec: ~8 fps during active "drafting" / "filling" tasks, 1 fps
 * during idle / navigating. The caller decides which rate to use by passing
 * an fps argument to start().
 */
export type FrameEmit = (msg: FrameMessage) => void;

export class FrameStreamer {
  private interval: NodeJS.Timeout | null = null;
  private capturing = false;

  constructor(
    private readonly page: Page,
    private readonly emit: FrameEmit,
    private readonly queueId: string
  ) {}

  start(fps: number = 8): void {
    this.stop();
    const periodMs = Math.max(50, Math.round(1000 / fps));
    this.interval = setInterval(() => {
      // Drop frames if a previous capture is still in flight — otherwise
      // a slow disk + 8fps will queue up indefinitely.
      if (this.capturing) return;
      this.capturing = true;
      this.captureOnce()
        .catch(() => {
          /* page may have closed during shutdown; tolerate */
        })
        .finally(() => {
          this.capturing = false;
        });
    }, periodMs);
  }

  private async captureOnce(): Promise<void> {
    let viewport = this.page.viewportSize();
    if (!viewport) {
      viewport = { width: 1280, height: 800 };
    }
    const buffer = await this.page.screenshot({ type: "jpeg", quality: 50 });
    this.emit({
      type: "frame",
      queue_id: this.queueId,
      jpeg_b64: buffer.toString("base64"),
      width: viewport.width,
      height: viewport.height,
    });
  }

  stop(): void {
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = null;
    }
  }
}
