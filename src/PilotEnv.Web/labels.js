export const environmentStates = {
  provisioning: "Создаётся",
  starting: "Запускается",
  running: "Работает",
  degraded: "Работает с ошибками",
  stopping: "Останавливается",
  stopped: "Остановлена",
  recreating: "Пересоздаётся",
  deleting: "Удаляется",
  failed: "Ошибка",
};
export const operationStates = {
  queued: "В очереди",
  running: "Выполняется",
  succeeded: "Завершено",
  failed: "Ошибка",
};
export const actions = {
  create: "Создание стенда",
  start: "Запуск",
  stop: "Остановка",
  restart: "Перезапуск",
  recreate: "Пересоздание",
  delete: "Удаление",
  "refresh-release": "Проверка обновлений Pilot",
};
export const components = [
  "pilot-server",
  "pilot-bim-server",
  "pilot-web-server",
  "pilot-web-myadmin",
];
export const errors = {
  invalid_name: "Недопустимое имя среды",
  invalid_owner: "Укажите владельца или команду",
  environment_exists: "Среда с таким именем уже существует",
  capacity_unavailable: "Недостаточно ресурсов для запуска",
  operation_conflict: "Над средой уже выполняется операция",
  already_running: "Среда уже работает",
  already_stopped: "Среда уже остановлена",
  environment_not_running: "Среда должна работать для перезапуска компонента",
  component_unavailable: "Компонент недоступен",
  confirmation_required: "Подтвердите имя среды",
  platform_updating: "Платформа обновляется. Повторите позже",
  legacy_read_only: "Эта среда доступна только для просмотра",
  idempotency_conflict:
    "Команда с этим ключом уже была отправлена с другими параметрами",
  invalid_filter: "Проверьте фильтры журнала",
  invalid_cursor: "Не удалось загрузить страницу журнала. Обновите список",
  not_found: "Запись не найдена",
  unauthorized: "Требуется авторизация",
  invalid_token: "Неверный токен доступа",
};
export const blockers = {
  insufficient_memory: "Недостаточно оперативной памяти",
  memory_unavailable: "Не удалось определить доступную память",
  insufficient_disk: "Недостаточно свободного места на диске",
  docker_unavailable: "Docker недоступен",
  license_invalid: "Лицензия повреждена или не подходит",
  license_missing: "Лицензия не подготовлена",
  license_unavailable: "Лицензия недоступна",
  release_missing: "Нет проверенного набора образов Pilot",
  template_missing: "Шаблон базы не подготовлен",
  ports_unavailable: "Нет свободных внутренних портов",
  public_ports_unavailable: "Нет свободных публичных портов",
};
export const stateLabel = (state) =>
  environmentStates[state] || "Состояние неизвестно";
export const operationLabel = (state) =>
  operationStates[state] || "Состояние неизвестно";
export function componentLabel(c) {
  if (c.state === "running") return c.healthy ? "Работает" : "Не готов";
  return (
    {
      created: "Запускается",
      starting: "Запускается",
      restarting: "Перезапускается",
      stopped: "Остановлен",
      exited: "Остановлен",
      dead: "Завершился с ошибкой",
      failed: "Завершился с ошибкой",
      removing: "Удаляется",
      paused: "Приостановлен",
    }[c.state] || "Состояние неизвестно"
  );
}
export function errorLabel(error) {
  return (
    errors[error.code] ||
    (error.status === 401
      ? "Требуется авторизация"
      : error.status === 403
        ? "Доступ запрещён"
        : error.status === 503
          ? "Сервис временно недоступен"
          : "Не удалось выполнить действие")
  );
}
export const environmentName = (name) =>
  name === "$release-validation" ? "Обновления Pilot" : name || "—";
export const escapeHtml = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
export const dateLabel = (value) =>
  value ? new Date(value).toLocaleString("ru-RU") : "—";
export function duration(op) {
  const from = op.startedAt || op.createdAt;
  if (!from) return "";
  const seconds = Math.max(
    0,
    Math.floor((new Date(op.finishedAt || Date.now()) - new Date(from)) / 1000),
  );
  return seconds < 60
    ? `${seconds} с`
    : `${Math.floor(seconds / 60)} мин ${seconds % 60} с`;
}
export function resultLabel(op) {
  if (op.state === "failed") return "Не удалось выполнить операцию";
  if (op.state !== "succeeded")
    return `${actions[op.kind] || "Операция"} · ${operationLabel(op.state)}`;
  return (
    {
      create: "Стенд создан",
      start: "Среда запущена",
      stop: "Среда остановлена",
      restart:
        op.component === "pilot-web-server"
          ? "Веб-сервер перезапущен"
          : "Компонент перезапущен",
      recreate: "Стенд пересоздан",
      delete: "Стенд удалён",
      "refresh-release": "Проверка обновлений завершена",
    }[op.kind] || "Операция завершена"
  );
}
