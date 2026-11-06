import { request } from "./api-client.js";
export const active = (op) => ["queued", "running"].includes(op?.state);
export class OperationState {
  constructor(changed, terminal) {
    this.changed = changed;
    this.terminal = terminal;
    this.operations = new Map();
    this.failures = new Map();
    this.pending = new Map();
    this.busy = new Set();
    this.inFlight = new Set();
    this.fetchCount = 0;
    this.fetchWaiters = [];
    try {
      for (const item of JSON.parse(
        sessionStorage.getItem("pilot-pending") || "[]",
      ))
        this.pending.set(item.target, { ...item, status: "uncertain" });
    } catch {}
  }
  save() {
    try {
      sessionStorage.setItem(
        "pilot-pending",
        JSON.stringify(
          [...this.pending.values()].map(
            ({ status, error, diagnostic, ...item }) => item,
          ),
        ),
      );
    } catch {
      /* Storage can be disabled; an in-memory retry still keeps its key. */
    }
  }
  observe(op) {
    if (!op) return;
    const old = this.operations.get(op.id);
    if (
      old &&
      ((!active(old) && active(op)) ||
        (old.state === "running" && op.state === "queued"))
    )
      return;
    this.operations.set(op.id, { ...old, ...op });
    this.changed();
    if (old && active(old) && !active(op)) this.terminal(op);
  }
  async send(command) {
    if (this.busy.has(command.target)) return;
    this.busy.add(command.target);
    this.failures.delete(command.target);
    const item = this.pending.get(command.target) || {
      ...command,
      key: crypto.randomUUID(),
    };
    item.status = "sending";
    this.pending.set(item.target, item);
    this.save();
    this.changed();
    try {
      const response = await request(item.url, {
        method: item.method || "POST",
        body: item.body,
        headers: { "Idempotency-Key": item.key },
      });
      this.pending.delete(item.target);
      this.save();
      const op = {
        id: response.operationId,
        state: response.state,
        kind: item.kind,
        environmentName: item.target,
        component: item.component,
        createdAt: new Date().toISOString(),
      };
      this.observe(op);
      this.fetch(op.id).catch(() => {});
      return op;
    } catch (error) {
      if (error.ambiguous) {
        item.status = "uncertain";
        item.diagnostic = error.diagnostic;
        this.pending.set(item.target, item);
      } else {
        this.pending.delete(item.target);
        this.failures.set(item.target, { ...item, status: "failed", error });
      }
      this.save();
      this.changed();
      throw error;
    } finally {
      this.busy.delete(command.target);
      this.changed();
    }
  }
  async fetch(id) {
    if (this.inFlight.has(id)) return;
    this.inFlight.add(id);
    if (this.fetchCount >= 4)
      await new Promise((resolve) => this.fetchWaiters.push(resolve));
    else this.fetchCount++;
    try {
      const op = await request(`/api/v1/operations/${id}`);
      this.observe(op);
      return op;
    } finally {
      this.inFlight.delete(id);
      const next = this.fetchWaiters.shift();
      if (next) next();
      else this.fetchCount--;
    }
  }
  async poll() {
    const ids = [...this.operations.values()].filter(active).map((x) => x.id);
    let next = 0;
    await Promise.all(
      Array.from({ length: Math.min(4, ids.length) }, async () => {
        while (next < ids.length) {
          const id = ids[next++];
          try {
            await this.fetch(id);
          } catch {}
        }
      }),
    );
  }
  forTarget(target) {
    return [...this.operations.values()]
      .filter((x) => x.environmentName === target)
      .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))[0];
  }
}
