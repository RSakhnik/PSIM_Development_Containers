import { request, setCsrfToken } from "./api-client.js";
import {
  actions,
  errors,
  blockers,
  errorLabel,
  escapeHtml as e,
} from "./labels.js";
import { OperationState, active } from "./operation-state.js";
import { Cards, createFeedback, updateFeedback } from "./cards.js";
import { Journal } from "./journal.js";
const $ = (id) => document.getElementById(id);
let authenticated = false,
  compatible = false,
  connected = false,
  capacity = null,
  environments = [],
  platform = null,
  lastUpdated = null,
  refreshing = false,
  refreshAgain = false,
  timer = null,
  operationTimer = null,
  toastTimer = null,
  createSubmitting = false;
let publicHost = null,
  allowedPorts = [];
const loadedUiHash = new URL(import.meta.url).pathname.split("/")[2];
const operations = new OperationState(render, () => {
  refresh();
  journal.load();
});
const cards = new Cards(
  $("environments"),
  handleAction,
  (id) => operations.fetch(id).catch(() => {}),
  retry,
);
const journal = new Journal((op) => operations.observe(op));
createFeedback(
  $("release-feedback"),
  () => retry("$release-validation"),
  (id) => operations.fetch(id).catch(() => {}),
);
createFeedback(
  $("create-feedback"),
  () => {
    const item = [...operations.pending.values()].find(
      (x) => x.kind === "create",
    );
    if (item) retry(item.target);
  },
  (id) => operations.fetch(id).catch(() => {}),
);
function toast(message) {
  clearTimeout(toastTimer);
  $("toast").textContent = message;
  $("toast").classList.remove("hidden");
  toastTimer = setTimeout(() => $("toast").classList.add("hidden"), 6000);
}
function showLogin() {
  authenticated = false;
  clearTimeout(timer);
  clearTimeout(operationTimer);
  $("dashboard").classList.add("hidden");
  $("logout").classList.add("hidden");
  $("login-card").classList.remove("hidden");
}
window.addEventListener("pilot-auth-required", showLogin);
function sessionReady(session) {
  setCsrfToken(session.csrfToken);
  publicHost = session.publicHost;
  allowedPorts = session.allowedPorts || [];
  authenticated = true;
  $("login-card").classList.add("hidden");
  $("dashboard").classList.remove("hidden");
  $("logout").classList.remove("hidden");
  render();
  refresh();
  scheduleOperations();
}
async function initialize() {
  try {
    sessionReady(await request("/api/v1/session"));
  } catch {
    showLogin();
  }
}
$("login-form").onsubmit = async (event) => {
  event.preventDefault();
  const button = event.submitter;
  button.disabled = true;
  button.textContent = "Вход…";
  $("login-error").textContent = "";
  try {
    const session = await request("/api/v1/session", {
      method: "POST",
      body: { token: $("token").value },
    });
    $("token").value = "";
    sessionReady(session);
    const value = new URLSearchParams(location.search).get("returnUrl");
    if (value) {
      const target = new URL(value, location.origin);
      const port = Number(target.port || 443);
      if (
        target.protocol === "https:" &&
        target.hostname === publicHost &&
        allowedPorts.includes(port)
      )
        location.href = target.href;
    }
  } catch (error) {
    $("login-error").textContent =
      error.status === 401 ? "Неверный токен доступа" : errorLabel(error);
  } finally {
    button.disabled = false;
    button.textContent = "Войти";
  }
};
$("logout").onclick = async () => {
  const b = $("logout");
  b.disabled = true;
  b.textContent = "Выход…";
  try {
    await request("/api/v1/session", { method: "DELETE" });
    sessionStorage.removeItem("pilot-pending");
    operations.pending.clear();
    operations.operations.clear();
    environments = [];
    $("environments").replaceChildren();
    cards.cards.clear();
    setCsrfToken(null);
    showLogin();
  } catch (error) {
    toast(errorLabel(error));
  } finally {
    b.disabled = false;
    b.textContent = "Выйти";
  }
};
function scheduleRefresh() {
  clearTimeout(timer);
  if (authenticated)
    timer = setTimeout(refresh, document.hidden ? 15000 : 5000);
}
function scheduleOperations() {
  clearTimeout(operationTimer);
  if (authenticated)
    operationTimer = setTimeout(
      async () => {
        await operations.poll();
        scheduleOperations();
      },
      document.hidden ? 15000 : 3000,
    );
}
async function refresh() {
  if (!authenticated) return;
  if (refreshing) {
    refreshAgain = true;
    return;
  }
  refreshing = true;
  $("refresh").disabled = true;
  $("refresh").textContent = "Обновление…";
  try {
    const tasks = [
      async () => {
        const value = await request("/api/v1/platform");
        platform = value;
        compatible = value.apiContractVersion === 2;
        journal.setEnabled(
          (value.capabilities || []).includes("operations-journal-v1"),
        );
        $("platform-builds").textContent =
          `Панель: ${value.components["web-ui"].buildHash} · API: ${value.components["control-api"].buildHash} · Движок: ${value.components["environment-engine"].buildHash}`;
        const notice = $("platform-notice");
        notice.textContent = !compatible
          ? "Панель несовместима с API. Обновите платформу"
          : value.components["web-ui"].buildHash !== loadedUiHash
            ? "Панель обновлена. Перезагрузите страницу"
            : "";
        notice.classList.toggle("hidden", !notice.textContent);
      },
      async () => {
        const values = await request("/api/v1/environments");
        environments = values;
        connected = true;
        lastUpdated = new Date();
        $("loading").classList.add("hidden");
        for (const env of values) {
          if (env.lastOperation) operations.observe(env.lastOperation);
          if (
            env.activeOperationId &&
            !operations.operations.has(env.activeOperationId)
          )
            operations.fetch(env.activeOperationId).catch(() => {});
        }
        render();
      },
      async () => {
        capacity = await request("/api/v1/capacity");
        $("capacity-error").textContent = "";
        renderCapacity();
      },
    ];
    const results = await Promise.allSettled(tasks.map((fn) => fn()));
    if (results[1].status === "rejected") connected = false;
    if (results[2].status === "rejected") {
      $("capacity-error").textContent = "Не удалось обновить ресурсы";
      capacity = null;
    }
    if (results[0].status === "rejected") compatible = false;
    $("connection").classList.toggle(
      "hidden",
      connected && results.every((x) => x.status === "fulfilled"),
    );
    $("connection").querySelector("span").textContent =
      `${!connected ? "Нет связи с сервером" : "Не удалось обновить часть данных"}${lastUpdated ? ". Последнее обновление: " + lastUpdated.toLocaleTimeString("ru-RU") : ""}`;
    render();
    await journal.load();
    if (journal.enabled) {
      try {
        const latest = await request(
          "/api/v1/operations?environmentName=%24release-validation&limit=1",
        );
        if (latest.items[0]) operations.observe(latest.items[0]);
      } catch {}
    }
  } finally {
    refreshing = false;
    $("refresh").disabled = false;
    $("refresh").textContent = "Обновить";
    if (refreshAgain) {
      refreshAgain = false;
      queueMicrotask(refresh);
    } else scheduleRefresh();
  }
}
function render() {
  cards.render(environments, { compatible, connected, operations });
  $("environment-count").textContent = lastUpdated ? environments.length : "—";
  $("empty").classList.toggle(
    "hidden",
    environments.length !== 0 || !lastUpdated,
  );
  $("updated-at").textContent = lastUpdated
    ? `Обновлено ${lastUpdated.toLocaleTimeString("ru-RU")}${!connected ? " · Данные устарели" : ""}`
    : "";
  const releasePending =
    operations.pending.get("$release-validation") ||
    operations.failures.get("$release-validation");
  const release = operations.failures.has("$release-validation")
    ? null
    : operations.forTarget("$release-validation");
  updateFeedback($("release-feedback"), release, releasePending);
  $("refresh-release").disabled =
    !connected ||
    !compatible ||
    operations.pending.has("$release-validation") ||
    active(release);
  $("refresh-release").textContent =
    releasePending?.status === "sending"
      ? "Отправка…"
      : "Проверить обновления Pilot";
  const createPending = [...operations.pending.values()].find(
    (x) => x.kind === "create",
  );
  const createOp = [...operations.operations.values()]
    .filter((x) => x.kind === "create")
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))[0];
  const createFailure = [...operations.failures.values()].find(
    (x) => x.kind === "create",
  );
  updateFeedback(
    $("create-feedback"),
    createFailure ? null : createOp,
    createPending || createFailure,
  );
  for (const input of $("create-form").querySelectorAll("input"))
    input.disabled = createSubmitting || createPending?.status === "sending";
  $("create-button").disabled =
    createSubmitting ||
    !!createPending ||
    !compatible ||
    !connected ||
    !capacity?.canStart;
  $("create-button").textContent = createSubmitting
    ? "Отправка…"
    : "Создать и запустить";
  for (const op of operations.operations.values()) journal.updateOperation(op);
}
function renderCapacity() {
  if (!capacity) return;
  const round = (v) =>
    Number(v || 0)
      .toFixed(1)
      .replace(/\.0$/, "");
  $("can-start").textContent = capacity.canStart ? "Да" : "Нет";
  $("slots").textContent = capacity.availableSlots;
  $("memory").textContent =
    `${round(capacity.memory.reservedGiB)} / ${round(capacity.memory.dockerTotalGiB)} ГБ`;
  $("disk").textContent = round(capacity.disk.freeGiB) + " ГБ";
  $("public-ports").textContent = capacity.publicPorts?.availablePairs ?? "—";
  const messages = capacity.blockers.map(
    (x) => blockers[x.code] || "Не выполнены условия запуска",
  );
  $("blockers").textContent = messages.join(" · ");
  $("blockers").classList.toggle("hidden", !messages.length);
  $("create-blockers").textContent = messages.join(" · ");
}
async function confirmAction(action, name) {
  const dialog = $("confirm-dialog");
  $("confirm-title").textContent = {
    delete: "Удалить стенд?",
    recreate: "Пересоздать стенд?",
    "refresh-release": "Проверить обновления Pilot?",
  }[action];
  $("confirm-description").textContent =
    action === "refresh-release"
      ? "Будут загружены образы Pilot и запущена временная проверочная среда."
      : `Данные среды «${name}» будут удалены без возможности восстановления. Введите имя среды для подтверждения.`;
  $("confirm-name-label").classList.toggle(
    "hidden",
    action === "refresh-release",
  );
  $("confirm-name").value = "";
  const submit = $("confirm-submit");
  submit.textContent = {
    delete: "Удалить",
    recreate: "Пересоздать",
    "refresh-release": "Проверить",
  }[action];
  submit.className = action === "delete" ? "red" : "blue";
  submit.disabled = action !== "refresh-release";
  $("confirm-name").oninput = () => {
    submit.disabled = $("confirm-name").value !== name;
  };
  dialog.returnValue = "";
  dialog.showModal();
  return new Promise((resolve) =>
    dialog.addEventListener(
      "close",
      () => resolve(dialog.returnValue === "confirm"),
      { once: true },
    ),
  );
}
async function send(command) {
  try {
    const op = await operations.send(command);
    if (op) {
      toast("Команда принята");
      refresh();
    }
    return op;
  } catch (error) {
    if (error.ambiguous) toast("Не удалось подтвердить принятие команды");
    else toast(errorLabel(error));
    if (error.diagnostic) {
      const target =
        cards.cards.get(command.target)?.querySelector(".operation-feedback") ||
        $(command.kind === "create" ? "create-feedback" : "release-feedback");
      target.querySelector(".feedback-text").textContent = errorLabel(error);
      const d = target.querySelector("details");
      d.classList.remove("hidden");
      d.querySelector("pre").textContent = error.diagnostic;
    }
    if (error.ambiguous) refresh();
  }
}
async function retry(target) {
  const item = operations.pending.get(target);
  if (item) await send(item);
}
async function handleAction(action, env, component, cascade) {
  let url = `/api/v1/environments/${encodeURIComponent(env.name)}/${action}`;
  let method = "POST",
    body;
  let kind = action;
  if (action === "restart-web" || action === "restart-component") {
    kind = "restart";
    component = action === "restart-web" ? "pilot-web-server" : component;
    url = `/api/v1/environments/${encodeURIComponent(env.name)}/components/${component}/restart`;
    body = {
      cascade:
        action === "restart-component" &&
        component === "pilot-server" &&
        cascade,
    };
  }
  if (action === "delete" || action === "recreate") {
    if (!(await confirmAction(action, env.name))) return;
    body = { confirmName: env.name };
    if (action === "delete") {
      method = "DELETE";
      url = `/api/v1/environments/${encodeURIComponent(env.name)}?confirmName=${encodeURIComponent(env.name)}`;
      body = undefined;
    }
  }
  await send({
    target: env.name,
    action,
    kind,
    url,
    method,
    body,
    component: kind === "restart" ? component : null,
  });
}
$("create-form").onsubmit = async (event) => {
  event.preventDefault();
  if (createSubmitting || $("create-button").disabled) return;
  const name = $("environment-name").value;
  const valid =
    /^[a-z0-9][a-z0-9-]{0,39}$/.test(name) &&
    !["control", "api"].includes(name) &&
    !name.startsWith("admin-");
  $("name-error").textContent = valid
    ? ""
    : "Используйте строчные латинские буквы, цифры и дефис. Первый символ — буква или цифра. Не более 40 символов" +
      (["control", "api"].includes(name) || name.startsWith("admin-")
        ? ". Это имя зарезервировано"
        : "");
  $("environment-name").setAttribute("aria-invalid", String(!valid));
  if (!valid) {
    $("environment-name").focus();
    return;
  }
  if (!$("owner").value.trim()) {
    $("owner").setCustomValidity("Укажите владельца или команду");
    $("owner").reportValidity();
    return;
  }
  createSubmitting = true;
  render();
  try {
    const op = await send({
      target: name,
      kind: "create",
      action: "create",
      url: "/api/v1/environments",
      body: {
        name,
        owner: $("owner").value,
        description: $("description").value || null,
      },
    });
    if (op) {
      $("environment-name").value = "";
      $("description").value = "";
    }
  } finally {
    createSubmitting = false;
    render();
  }
};
$("owner").oninput = () => $("owner").setCustomValidity("");
$("refresh").onclick = refresh;
$("retry-connection").onclick = refresh;
$("refresh-release").onclick = async () => {
  if (await confirmAction("refresh-release"))
    await send({
      target: "$release-validation",
      kind: "refresh-release",
      action: "refresh-release",
      url: "/api/v1/releases/refresh",
    });
};
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && authenticated) refresh();
  scheduleOperations();
});
initialize();
