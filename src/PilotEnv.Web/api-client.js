let csrfToken = null;
export function setCsrfToken(value) {
  csrfToken = value;
}
export class ApiError extends Error {
  constructor(code, status = 0, diagnostic = "", ambiguous = false) {
    super(code);
    Object.assign(this, { code, status, diagnostic, ambiguous });
  }
}
export async function request(url, options = {}) {
  const method = (options.method || "GET").toUpperCase();
  const mutation = !["GET", "HEAD"].includes(method);
  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(),
    options.timeoutMs ?? (mutation ? 120000 : 60000),
  );
  const headers = { ...(options.headers || {}) };
  if (csrfToken && mutation) headers["X-Pilot-Csrf"] = csrfToken;
  let body = options.body;
  if (body && typeof body !== "string") {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(body);
  }
  try {
    const response = await fetch(url, {
      ...options,
      headers,
      body,
      signal: controller.signal,
    });
    if (response.status === 401) {
      window.dispatchEvent(new Event("pilot-auth-required"));
      throw new ApiError("unauthorized", 401);
    }
    const json = (response.headers.get("content-type") || "").includes("json");
    if (!response.ok) {
      const problem = json ? await response.json() : {};
      throw new ApiError(
        problem.code || problem.title || "request_failed",
        response.status,
        problem.detail || problem.message || "",
        mutation && response.status >= 500,
      );
    }
    if (response.status === 204) return null;
    if (!json)
      throw new ApiError("invalid_response", response.status, "", mutation);
    return await response.json();
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(
      error.name === "AbortError" ? "timeout" : "network_error",
      0,
      "",
      mutation,
    );
  } finally {
    clearTimeout(timeout);
  }
}
