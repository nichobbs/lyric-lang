// Lyric UI host runtime: connection to the session (docs/65 §9.3, §10.1).
//
// The page shell (served by `Ui.Host.Web`) contains
//   <div id="lyric-ui" data-ws="ws://host:port/_ui"></div>
//   <script type="module" src="/_ui/runtime/main.js"></script>
// This module connects, says hello with the current URL, applies patch
// messages to the mirror tree (which drives the DOM), and reports events.

import { Tree, pathOf, type MNode, type Patch } from "./tree.js";
import { DomRenderer } from "./render.js";

export const PROTOCOL_VERSION = 1;

type ServerMessage =
  | { t: "patch"; v: number; ops: Patch[] }
  | { t: "navigate"; url: string }
  | { t: "back" }
  | { t: "toast"; m: string; level: string };

interface PendingInput {
  node: MNode;
  data: string;
  iv: number;
}

export class Host {
  private readonly tree: Tree;
  private socket: WebSocket | null = null;
  private version = 0;
  private retryMs = 500;
  private pendingInputs = new Map<MNode, PendingInput>();
  private flushScheduled = false;

  constructor(private readonly mount: HTMLElement, private readonly url: string) {
    this.tree = new Tree(new DomRenderer(mount, (node, event, data, iv) => this.onEvent(node, event, data, iv)));
  }

  connect(): void {
    const ws = new WebSocket(this.url);
    this.socket = ws;
    ws.addEventListener("open", () => {
      this.retryMs = 500;
      this.mount.removeAttribute("aria-busy");
      this.send({ t: "hello", pv: PROTOCOL_VERSION, url: location.pathname + location.search });
    });
    ws.addEventListener("message", (ev) => this.onMessage(String(ev.data)));
    ws.addEventListener("close", () => {
      this.socket = null;
      this.mount.setAttribute("aria-busy", "true");
      setTimeout(() => this.connect(), this.retryMs);
      this.retryMs = Math.min(this.retryMs * 2, 10_000);
    });
  }

  private onMessage(text: string): void {
    let msg: ServerMessage;
    try {
      msg = JSON.parse(text) as ServerMessage;
    } catch {
      console.error("lyric-ui: malformed server message", text);
      return;
    }
    switch (msg.t) {
      case "patch":
        try {
          for (const op of msg.ops) {
            this.tree.apply(op);
          }
          this.version = msg.v;
        } catch (e) {
          // A patch that does not apply means the host and session disagree;
          // a full re-render restores agreement.
          console.error("lyric-ui: patch failed, resynchronising", e);
          this.send({ t: "sync" });
        }
        return;
      case "navigate":
        location.assign(msg.url);
        return;
      case "back":
        history.back();
        return;
      case "toast":
        showToast(msg.m, msg.level);
        return;
    }
  }

  // Input events are coalesced per animation frame: only the latest text of
  // each input is sent, with the latest input version.
  private onEvent(node: MNode, event: string, data: string, iv: number): void {
    if (event === "input") {
      this.pendingInputs.set(node, { node, data, iv });
      if (!this.flushScheduled) {
        this.flushScheduled = true;
        requestAnimationFrame(() => this.flushInputs());
      }
      return;
    }
    this.flushInputs();
    this.sendEvent(node, event, data, 0);
  }

  private flushInputs(): void {
    this.flushScheduled = false;
    const pending = [...this.pendingInputs.values()];
    this.pendingInputs.clear();
    for (const p of pending) {
      this.sendEvent(p.node, "input", p.data, p.iv);
    }
  }

  private sendEvent(node: MNode, event: string, data: string, iv: number): void {
    const msg: Record<string, unknown> = { t: "event", v: this.version, p: pathOf(node), e: event, d: data };
    if (iv > 0) {
      msg.iv = iv;
    }
    this.send(msg);
  }

  private send(msg: object): void {
    if (this.socket && this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify(msg));
    }
  }
}

function showToast(message: string, level: string): void {
  let region = document.querySelector<HTMLElement>(".lui-toasts");
  if (!region) {
    region = document.createElement("div");
    region.className = "lui-toasts";
    region.setAttribute("aria-live", "polite");
    document.body.append(region);
  }
  const toast = document.createElement("div");
  toast.className = "lui-toast";
  toast.dataset.tone = level;
  toast.textContent = message;
  region.append(toast);
  setTimeout(() => toast.remove(), 4000);
}

const mount = document.getElementById("lyric-ui");
if (mount && mount.dataset.ws) {
  new Host(mount, mount.dataset.ws).connect();
}
