import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
const url = (source) =>
  "data:text/javascript;base64," + Buffer.from(source).toString("base64");
const labels = await import(
  url(
    await readFile(
      new URL("../src/PilotEnv.Web/labels.js", import.meta.url),
      "utf8",
    ),
  )
);
assert.equal(labels.stateLabel("degraded"), "Работает с ошибками");
assert.equal(labels.stateLabel("new-state"), "Состояние неизвестно");
assert.equal(
  labels.componentLabel({ state: "running", healthy: false }),
  "Не готов",
);
const storage = new Map();
globalThis.sessionStorage = {
  getItem: (k) => storage.get(k),
  setItem: (k, v) => storage.set(k, v),
};
globalThis.window = { dispatchEvent() {} };
const apiSource = await readFile(
  new URL("../src/PilotEnv.Web/api-client.js", import.meta.url),
  "utf8",
);
const apiUrl = url(apiSource);
const api = await import(apiUrl);
const stateSource = (
  await readFile(
    new URL("../src/PilotEnv.Web/operation-state.js", import.meta.url),
    "utf8",
  )
).replace(/(['"])\.\/api-client\.js\1/, JSON.stringify(apiUrl));
const { OperationState } = await import(url(stateSource));
let calls = [];
let release;
let changed = 0;
globalThis.fetch = async (path, options) => {
  calls.push({ path, options });
  if (options.method === "POST")
    await new Promise((resolve) => {
      release = resolve;
    });
  return new Response(
    JSON.stringify(
      path.includes("/operations/")
        ? {
            id: "id-1",
            kind: "start",
            environmentName: "demo",
            state: "running",
          }
        : { operationId: "id-1", state: "queued" },
    ),
    { headers: { "content-type": "application/json" } },
  );
};
const state = new OperationState(
  () => changed++,
  () => {},
);
const command = { target: "demo", kind: "start", url: "/start" };
const sending = state.send(command);
assert.equal(state.pending.get("demo").status, "sending");
assert.ok(changed > 0);
await state.send(command);
assert.equal(calls.length, 1);
release();
await sending;
assert.equal(state.pending.size, 0);
state.observe({ id: "id-1", state: "succeeded" });
state.observe({ id: "id-1", state: "queued" });
assert.equal(state.operations.get("id-1").state, "succeeded");
globalThis.fetch = async (path, options) => {
  calls.push({ path, options });
  throw new TypeError("offline");
};
await assert.rejects(state.send({ ...command, target: "uncertain" }));
const saved = state.pending.get("uncertain");
assert.equal(saved.status, "uncertain");
const before = calls.length;
const restored = new OperationState(
  () => {},
  () => {},
);
assert.equal(calls.length, before);
assert.equal(restored.pending.get("uncertain").key, saved.key);
await assert.rejects(restored.send(saved));
assert.equal(calls.at(-1).options.headers["Idempotency-Key"], saved.key);
globalThis.fetch = async (path, options) =>
  new Promise((resolve, reject) =>
    options.signal.addEventListener("abort", () =>
      reject(new DOMException("Aborted", "AbortError")),
    ),
  );
await assert.rejects(
  api.request("/slow", { timeoutMs: 5 }),
  (e) => e.code === "timeout" && !e.ambiguous,
);
globalThis.fetch = async () =>
  new Response(
    JSON.stringify({
      code: "operation_conflict",
      detail: "Existing operation",
    }),
    { status: 409, headers: { "content-type": "application/problem+json" } },
  );
await assert.rejects(state.send({ ...command, target: "rejected" }));
assert.equal(state.pending.has("rejected"), false);
assert.equal(state.failures.get("rejected").error.code, "operation_conflict");
// A disabled storage must not prevent sending, and must never leak a token.
globalThis.sessionStorage.setItem = () => {
  throw new Error("disabled");
};
globalThis.fetch = async () =>
  new Response(
    JSON.stringify({ operationId: "storage-off", state: "queued" }),
    { headers: { "content-type": "application/json" } },
  );
await state.send({ ...command, target: "storage-off" });
assert.equal(state.pending.has("storage-off"), false);
let concurrent = 0,
  maxConcurrent = 0;
const completions = [];
globalThis.fetch = async (path) => {
  concurrent++;
  maxConcurrent = Math.max(maxConcurrent, concurrent);
  await new Promise((resolve) => completions.push(resolve));
  concurrent--;
  return new Response(
    JSON.stringify({ id: path.split("/").at(-1), state: "succeeded" }),
    { headers: { "content-type": "application/json" } },
  );
};
const limited = new OperationState(
  () => {},
  () => {},
);
const reads = Array.from({ length: 9 }, (_, i) =>
  limited.fetch("limited-" + i),
);
while (limited.inFlight.size) {
  await new Promise((resolve) => setTimeout(resolve, 1));
  for (const done of completions.splice(0)) done();
}
await Promise.all(reads);
assert.equal(maxConcurrent, 4);
console.log(
  "UI state: immediate feedback, duplicate guard, stable idempotency, reload without mutation, terminal state and timeout PASS",
);
