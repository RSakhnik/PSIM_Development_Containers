import {
  components,
  stateLabel,
  componentLabel,
  escapeHtml as e,
  operationLabel,
  resultLabel,
  duration,
  dateLabel,
  errorLabel,
} from "./labels.js";
import { active } from "./operation-state.js";
export function createFeedback(root, onRetry, onDetails) {
  root.innerHTML =
    '<div class="feedback-text"></div><button class="retry secondary hidden">Повторить отправку</button><details class="diagnostics hidden"><summary>Диагностика</summary><pre></pre></details><button class="copy secondary hidden">Скопировать ID операции</button>';
  root.querySelector(".retry").onclick = onRetry;
  root.querySelector(".copy").onclick = () => {
    if (root.dataset.operation)
      navigator.clipboard
        .writeText(root.dataset.operation)
        .then(() => {
          root.querySelector(".copy").textContent = "ID скопирован";
        })
        .catch(() => {
          root.querySelector(".copy").textContent = root.dataset.operation;
        });
  };
  root.querySelector("details").addEventListener("toggle", () => {
    if (root.querySelector("details").open && root.dataset.operation)
      onDetails(root.dataset.operation);
  });
}
export function updateFeedback(root, op, pending, env) {
  if (pending) op = null;
  const text = root.querySelector(".feedback-text");
  let value = "";
  if (pending)
    value =
      pending.status === "sending"
        ? "Отправка…"
        : pending.status === "failed"
          ? errorLabel(pending.error)
          : "Не удалось подтвердить принятие команды";
  else if (op)
    value = resultLabel(op) + (active(op) ? ` · ${duration(op)}` : "");
  if (op?.state === "succeeded" && env?.state === "degraded")
    value = "Операция завершена. Среда работает с ошибками";
  text.textContent = value;
  root.classList.toggle("working", pending?.status === "sending" || active(op));
  root
    .querySelector(".retry")
    .classList.toggle("hidden", pending?.status !== "uncertain");
  root.dataset.operation = op?.id || "";
  root.querySelector(".copy").classList.toggle("hidden", !op);
  const diagnostic =
    op?.error ||
    pending?.error?.diagnostic ||
    pending?.diagnostic ||
    env?.lastError;
  root.querySelector("details").classList.toggle("hidden", !op && !diagnostic);
  root.querySelector("pre").textContent =
    diagnostic ||
    (op
      ? `ID: ${op.id}
Создана: ${dateLabel(op.createdAt)}
Начата: ${dateLabel(op.startedAt)}
Завершена: ${dateLabel(op.finishedAt)}
${operationLabel(op.state)}`
      : "");
}
export class Cards {
  constructor(root, action, details, retry) {
    Object.assign(this, { root, action, details, retry });
    this.cards = new Map();
  }
  render(values, context) {
    const keep = new Set();
    for (const env of values) {
      keep.add(env.name);
      let card = this.cards.get(env.name);
      if (!card) {
        card = this.create(env);
        this.cards.set(env.name, card);
        this.root.append(card);
      }
      this.update(card, env, context);
    }
    for (const [name, card] of this.cards)
      if (!keep.has(name)) {
        card.remove();
        this.cards.delete(name);
      }
  }
  create(env) {
    const card = document.createElement("article");
    card.className = "card environment";
    card.dataset.environment = env.name;
    card.innerHTML = `<div class="environment-top"><div><h3></h3><div class="meta"><span class="owner"></span><span class="description"></span><span class="readonly hidden">Только просмотр</span></div></div><span class="badge"></span></div><div class="components"></div><div class="environment-links"><a class="web" target="_blank" rel="noopener">Открыть веб-клиент</a><a class="admin" target="_blank" rel="noopener">Открыть myAdmin</a></div><div class="actions"><button data-action="start" class="green">Запустить</button><button data-action="stop" class="orange">Завершить</button><button data-action="restart-web" class="blue">Перезапустить веб-сервер</button><button data-action="recreate" class="blue">Пересоздать</button><button data-action="delete" class="red">Удалить</button></div><div class="operation-feedback" aria-live="polite"></div><div class="component-restart"><label>Перезапуск компонента<select aria-label="Компонент">${components.map((c) => `<option>${e(c)}</option>`).join("")}</select></label><label class="cascade"><input type="checkbox">Также перезапустить зависимые компоненты</label><button data-action="restart-component" class="blue">Перезапустить</button></div>`;
    card.querySelector("h3").textContent = env.name;
    for (const name of components) {
      const node = document.createElement("span");
      node.className = "component";
      node.dataset.component = name;
      card.querySelector(".components").append(node);
    }
    card.querySelector("select").onchange = () => {
      card
        .querySelector(".cascade")
        .classList.toggle(
          "hidden",
          card.querySelector("select").value !== "pilot-server",
        );
    };
    card.addEventListener("click", (event) => {
      const button = event.target.closest("button[data-action]");
      if (button && !button.disabled)
        this.action(
          button.dataset.action,
          card.env,
          card.querySelector("select").value,
          card.querySelector("input[type=checkbox]").checked,
        );
    });
    createFeedback(
      card.querySelector(".operation-feedback"),
      () => this.retry(env.name),
      (id) => this.details(id),
    );
    return card;
  }
  update(card, env, { compatible, connected, operations }) {
    card.env = env;
    card.querySelector(".owner").textContent = env.owner || "";
    card.querySelector(".description").textContent = env.description || "";
    card.querySelector(".readonly").classList.toggle("hidden", !env.readOnly);
    const badge = card.querySelector(".badge");
    badge.textContent = stateLabel(env.state);
    badge.className = `badge ${env.state}`;
    for (const name of components) {
      const node = card.querySelector(`[data-component="${name}"]`);
      const c = env.components?.find((x) => x.name === name);
      node.classList.toggle("hidden", !c);
      if (c) {
        node.textContent = `${name} · ${componentLabel(c)}`;
        node.className = `component ${c.state === "running" ? (c.healthy ? "ok" : "warn") : ""}`;
      }
    }
    for (const [cls, component, url] of [
      ["web", "pilot-web-server", env.webUrl],
      ["admin", "pilot-web-myadmin", env.adminUrl],
    ]) {
      const a = card.querySelector("." + cls);
      const c = env.components?.find((x) => x.name === component);
      const enabled = url && c?.state === "running";
      a.classList.toggle("disabled", !enabled);
      a.setAttribute("aria-disabled", String(!enabled));
      if (enabled) a.href = url;
      else a.removeAttribute("href");
    }
    const pending =
      operations.pending.get(env.name) || operations.failures.get(env.name);
    const op = operations.failures.has(env.name)
      ? null
      : operations.operations.get(env.activeOperationId) ||
        operations.forTarget(env.name) ||
        env.lastOperation;
    const busy =
      operations.pending.has(env.name) || !!env.activeOperationId || active(op);
    const blocked = !compatible || !connected || env.readOnly || busy;
    for (const button of card.querySelectorAll("button[data-action]")) {
      const action = button.dataset.action;
      button.disabled =
        blocked ||
        (action === "start" && env.state === "running") ||
        (action === "stop" && env.state === "stopped") ||
        (action.startsWith("restart") &&
          !["running", "degraded"].includes(env.state));
      const sending =
        pending?.status === "sending" && pending.action === action;
      if (!button.dataset.label) button.dataset.label = button.textContent;
      button.textContent = sending ? "Отправка…" : button.dataset.label;
      button.classList.toggle("sending", sending);
    }
    card.querySelector("select").disabled = blocked;
    card.querySelector("input[type=checkbox]").disabled = blocked;
    updateFeedback(card.querySelector(".operation-feedback"), op, pending, env);
  }
}
