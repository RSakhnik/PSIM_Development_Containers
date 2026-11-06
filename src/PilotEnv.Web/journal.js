import { request } from "./api-client.js";
import {
  actions,
  operationLabel,
  environmentName,
  dateLabel,
  duration,
  escapeHtml as e,
  errorLabel,
  resultLabel,
} from "./labels.js";
export class Journal {
  constructor(observe) {
    this.observe = observe;
    this.rows = new Map();
    this.items = new Map();
    this.cursor = null;
    this.pages = 1;
    this.enabled = false;
    this.loading = false;
    this.filter = {};
    this.generation = 0;
    const kinds = document.getElementById("filter-kind");
    for (const [value, label] of Object.entries(actions)) {
      const o = new Option(label, value);
      kinds.add(o);
    }
    document.getElementById("journal-filters").onsubmit = (event) => {
      event.preventDefault();
      this.filter = {
        environmentName: document
          .getElementById("filter-environment")
          .value.trim(),
        kind: kinds.value,
        state: document.getElementById("filter-state").value,
      };
      this.reset();
    };
    document.getElementById("journal-refresh").onclick = () => this.reset();
    document.getElementById("journal-new").onclick = () => this.reset();
    document.getElementById("journal-more").onclick = () => this.load(true);
  }
  setEnabled(value) {
    this.enabled = value;
    document
      .getElementById("journal-unavailable")
      .classList.toggle("hidden", value);
    document
      .getElementById("journal-content")
      .classList.toggle("hidden", !value);
    document.getElementById("journal-refresh").disabled = !value;
  }
  reset() {
    this.generation++;
    this.resetRequested = true;
    if (!this.loading) this.load(false, true);
  }
  async load(more = false, reset = false) {
    if (!this.enabled || this.loading) return;
    this.loading = true;
    const generation = this.generation;
    const moreButton = document.getElementById("journal-more");
    moreButton.disabled = true;
    moreButton.textContent = more ? "Загрузка…" : "Показать ещё";
    document.getElementById("journal-refresh").disabled = true;
    document.getElementById("journal-refresh").textContent = "Обновление…";
    let params = new URLSearchParams({ limit: "25" });
    for (const [key, value] of Object.entries(this.filter))
      if (value) params.set(key, value);
    if (more && this.cursor) params.set("cursor", this.cursor);
    try {
      const page = await request("/api/v1/operations?" + params);
      if (generation !== this.generation) return;
      document.getElementById("journal-error").textContent = "";
      for (const op of page.items) this.observe(op);
      if (!more && !reset && this.pages > 1) {
        if (page.items[0]?.id !== this.firstId)
          document.getElementById("journal-new").classList.remove("hidden");
        for (const op of page.items)
          if (this.items.has(op.id)) {
            this.items.set(op.id, op);
            this.updateRow(op);
          }
        return;
      }
      if (reset) {
        document.getElementById("journal-new").classList.add("hidden");
        for (const row of this.rows.values()) {
          row.main.remove();
          row.details.remove();
        }
        this.rows.clear();
        this.items.clear();
        this.pages = 1;
        this.resetRequested = false;
      }
      const pageIds = new Set(page.items.map((x) => x.id));
      if (!more && this.pages === 1) {
        for (const [id, row] of this.rows)
          if (!pageIds.has(id)) {
            row.main.remove();
            row.details.remove();
            this.rows.delete(id);
            this.items.delete(id);
          }
      }
      for (const op of page.items) {
        this.items.set(op.id, op);
        this.updateRow(op);
      }
      const ordered = [...this.items.values()].sort(
        (a, b) =>
          b.createdAt.localeCompare(a.createdAt) || b.id.localeCompare(a.id),
      );
      const body = document.getElementById("journal-rows");
      let anchor = body.firstChild;
      for (const op of ordered) {
        const row = this.rows.get(op.id);
        for (const node of [row.main, row.details]) {
          if (node !== anchor) body.insertBefore(node, anchor);
          anchor = node.nextSibling;
        }
      }
      this.cursor = page.nextCursor;
      this.firstId = ordered[0]?.id;
      if (more) this.pages++;
      moreButton.classList.toggle("hidden", !this.cursor);
      document
        .getElementById("journal-empty")
        .classList.toggle("hidden", ordered.length !== 0);
    } catch (error) {
      document.getElementById("journal-error").textContent = errorLabel(error);
    } finally {
      this.loading = false;
      moreButton.disabled = false;
      moreButton.textContent = "Показать ещё";
      document.getElementById("journal-refresh").disabled = !this.enabled;
      document.getElementById("journal-refresh").textContent =
        "Обновить журнал";
      if (this.resetRequested && generation !== this.generation)
        this.load(false, true);
    }
  }
  updateRow(op) {
    let row = this.rows.get(op.id);
    if (!row) {
      const main = document.createElement("tr");
      main.innerHTML =
        '<td></td><td></td><td></td><td></td><td><span class="badge"></span></td><td></td><td><button class="secondary" aria-expanded="false">Подробнее</button></td>';
      const details = document.createElement("tr");
      details.className = "operation-details hidden";
      details.innerHTML =
        '<td colspan="7"><p></p><pre></pre><button class="secondary">Скопировать ID операции</button></td>';
      row = { main, details };
      this.rows.set(op.id, row);
      main.querySelector("button").onclick = async () => {
        const open = details.classList.contains("hidden");
        details.classList.toggle("hidden", !open);
        main
          .querySelector("button")
          .setAttribute("aria-expanded", String(open));
        if (open) {
          details.querySelector("p").textContent = "Загрузка…";
          try {
            const value = await request(`/api/v1/operations/${op.id}`);
            this.observe(value);
            this.items.set(value.id, value);
            this.updateRow(value);
          } catch (error) {
            details.querySelector("p").textContent = errorLabel(error);
          }
        }
      };
      details.querySelector("button").onclick = () =>
        navigator.clipboard
          .writeText(op.id)
          .then(() => {
            details.querySelector("button").textContent = "ID скопирован";
          })
          .catch(() => {
            details.querySelector("button").textContent = op.id;
          });
    }
    const cells = row.main.children;
    cells[0].textContent = dateLabel(op.createdAt);
    cells[1].textContent = environmentName(op.environmentName);
    cells[2].textContent = actions[op.kind] || "Операция";
    cells[3].textContent = op.component || "—";
    cells[4].firstChild.textContent = operationLabel(op.state);
    cells[4].firstChild.className = `badge ${op.state}`;
    cells[5].textContent = duration(op);
    row.details.querySelector("p").textContent = resultLabel(op);
    row.details.querySelector("pre").textContent = `ID: ${op.id}
Создана: ${dateLabel(op.createdAt)}
Начата: ${dateLabel(op.startedAt)}
Завершена: ${dateLabel(op.finishedAt)}${op.error ? "\n" + op.error : ""}`;
  }
  updateOperation(op) {
    if (this.items.has(op.id)) {
      this.items.set(op.id, { ...this.items.get(op.id), ...op });
      this.updateRow(this.items.get(op.id));
    }
  }
}
