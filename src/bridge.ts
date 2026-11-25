import http from "node:http";
import { randomUUID } from "node:crypto";

export interface BridgeCommand {
  id: string;
  action: string;
  params: Record<string, unknown>;
}

export interface BridgeResult {
  id: string;
  ok: boolean;
  data?: unknown;
  error?: string;
}

interface PendingCommand {
  command: BridgeCommand;
  resolve: (result: BridgeResult) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface WaitingPoll {
  resolve: (command: BridgeCommand | null) => void;
  timer: ReturnType<typeof setTimeout>;
}

export class RobloxBridge {
  private server: http.Server | null = null;
  private queue: PendingCommand[] = [];
  private waitingPolls: WaitingPoll[] = [];
  private lastPluginSeenAt: number | null = null;
  private readonly port: number;
  private readonly host: string;
  private readonly commandTimeoutMs: number;

  constructor(options?: { port?: number; host?: string; commandTimeoutMs?: number }) {
    this.port = options?.port ?? Number(process.env.MINT_BRIDGE_PORT ?? 5123);
    this.host = options?.host ?? process.env.MINT_BRIDGE_HOST ?? "127.0.0.1";
    this.commandTimeoutMs = options?.commandTimeoutMs ?? 30_000;
  }

  get isConnected(): boolean {
    return this.lastPluginSeenAt !== null && Date.now() - this.lastPluginSeenAt < 15_000;
  }

  get status() {
    return {
      host: this.host,
      port: this.port,
      pluginConnected: this.isConnected,
      lastPluginSeenAt: this.lastPluginSeenAt ? new Date(this.lastPluginSeenAt).toISOString() : null,
      pendingCommands: this.queue.length,
    };
  }

  async start(): Promise<void> {
    if (this.server) return;
    this.server = http.createServer((req, res) => this.handleRequest(req, res));
    await new Promise<void>((resolve, reject) => {
      this.server!.on("error", reject);
      this.server!.listen(this.port, this.host, () => resolve());
    });
    // eslint-disable-next-line no-console
    console.error(`[mint] Roblox bridge listening on http://${this.host}:${this.port}`);
  }

  async stop(): Promise<void> {
    for (const poll of this.waitingPolls) {
      clearTimeout(poll.timer);
      poll.resolve(null);
    }
    this.waitingPolls = [];
    for (const pending of this.queue) {
      clearTimeout(pending.timer);
      pending.reject(new Error("Bridge stopped"));
    }
    this.queue = [];
    if (!this.server) return;
    await new Promise<void>((resolve) => this.server!.close(() => resolve()));
    this.server = null;
  }

  async sendCommand(action: string, params: Record<string, unknown> = {}): Promise<BridgeResult> {
    const command: BridgeCommand = { id: randomUUID(), action, params };

    return new Promise<BridgeResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.queue = this.queue.filter((p) => p.command.id !== command.id);
        resolve({
          id: command.id,
          ok: false,
          error:
            `Timed out waiting for Roblox Studio plugin response for "${action}". ` +
            `Make sure Roblox Studio is open and the Mint plugin is installed and enabled.`,
        });
      }, this.commandTimeoutMs);

      const pending: PendingCommand = { command, resolve, reject, timer };

      // If a plugin poll is already waiting, hand it the command immediately.
      const poll = this.waitingPolls.shift();
      if (poll) {
        clearTimeout(poll.timer);
        this.queue.push(pending);
        poll.resolve(command);
        return;
      }

      this.queue.push(pending);
    });
  }

  private handleRequest(req: http.IncomingMessage, res: http.ServerResponse): void {
    const url = new URL(req.url ?? "/", `http://${this.host}:${this.port}`);

    // Basic CORS/local safety headers; plugin runs locally.
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type");

    if (req.method === "OPTIONS") {
      res.writeHead(204).end();
      return;
    }

    if (req.method === "GET" && url.pathname === "/status") {
      this.json(res, 200, this.status);
      return;
    }

    if (req.method === "GET" && url.pathname === "/poll") {
      this.handlePoll(res);
      return;
    }

    if (req.method === "POST" && url.pathname === "/result") {
      this.readBody(req)
        .then((body) => this.handleResult(body, res))
        .catch((err) => this.json(res, 400, { ok: false, error: String(err) }));
      return;
    }

    this.json(res, 404, { ok: false, error: "Not found" });
  }

  private handlePoll(res: http.ServerResponse): void {
    this.lastPluginSeenAt = Date.now();

    // If there is a queued command, deliver it immediately.
    const next = this.queue.find((p) => !this.isDelivered(p.command.id));
    // We mark delivery by moving it to a "delivered" state; simpler: keep in queue
    // until result arrives, but only deliver once. Track delivered ids.
    const undelivered = this.queue.find((p) => !(p as any)._delivered);
    if (undelivered) {
      (undelivered as any)._delivered = true;
      this.json(res, 200, { type: "command", command: undelivered.command });
      return;
    }

    // Long-poll: hold until a command arrives or timeout.
    const timer = setTimeout(() => {
      this.waitingPolls = this.waitingPolls.filter((p) => p.resolve !== resolve);
      if (!res.writableEnded) this.json(res, 204, null);
    }, 25_000);

    const resolve = (command: BridgeCommand | null) => {
      clearTimeout(timer);
      if (res.writableEnded) return;
      if (command) this.json(res, 200, { type: "command", command });
      else this.json(res, 204, null);
    };

    this.waitingPolls.push({ resolve, timer });
  }

  private isDelivered(_id: string): boolean {
    return false; // unused; delivery tracked via _delivered flag
  }

  private handleResult(body: string, res: http.ServerResponse): void {
    this.lastPluginSeenAt = Date.now();
    let parsed: BridgeResult;
    try {
      parsed = JSON.parse(body) as BridgeResult;
    } catch {
      this.json(res, 400, { ok: false, error: "Invalid JSON" });
      return;
    }

    if (!parsed || typeof parsed.id !== "string") {
      this.json(res, 400, { ok: false, error: "Missing result id" });
      return;
    }

    const idx = this.queue.findIndex((p) => p.command.id === parsed.id);
    if (idx === -1) {
      this.json(res, 200, { ok: true, ignored: true });
      return;
    }

    const [pending] = this.queue.splice(idx, 1);
    clearTimeout(pending.timer);
    pending.resolve({
      id: parsed.id,
      ok: Boolean(parsed.ok),
      data: parsed.data,
      error: parsed.error,
    });
    this.json(res, 200, { ok: true });
  }

  private async readBody(req: http.IncomingMessage): Promise<string> {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(Buffer.from(chunk));
    return Buffer.concat(chunks).toString("utf8");
  }

  private json(res: http.ServerResponse, status: number, payload: unknown): void {
    if (res.writableEnded) return;
    const body = payload === null ? "" : JSON.stringify(payload);
    res.writeHead(status, {
      "Content-Type": payload === null ? "text/plain" : "application/json",
      "Content-Length": Buffer.byteLength(body),
    });
    res.end(body);
  }
}
