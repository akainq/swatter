// Типобезопасный клиент dashboard API (ADR-0008).
// Типы генерируются из OpenAPI-спеки сервера: `bun run api:types`
// (свежесть schema.d.ts проверяет CI).
import type { components } from "./schema";

export type Organization = components["schemas"]["Organization"];
export type Project = components["schemas"]["Project"];
export type Issue = components["schemas"]["Issue"];
export type IssueEvent = components["schemas"]["Event"];
export type CurrentUser = components["schemas"]["CurrentUser"];
export type SetupRequest = components["schemas"]["SetupRequest"];
export type Release = components["schemas"]["Release"];
export type ReleaseDetail = components["schemas"]["ReleaseDetail"];
export type AIAnalysis = components["schemas"]["AIAnalysis"];
export type TransactionStat = components["schemas"]["TransactionStat"];
export type TraceSummary = components["schemas"]["TraceSummary"];
export type Trace = components["schemas"]["Trace"];
export type TraceSpan = components["schemas"]["TraceSpan"];
export type AlertSettings = components["schemas"]["AlertSettings"];
export type AlertSettingsUpdate = components["schemas"]["AlertSettingsUpdateRequest"];

export class ApiError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export interface Page<T> {
  data: T[];
  nextCursor: string | null;
}

// SPA отдаётся тем же Phoenix (same-origin, ADR-0007): сессионный cookie
// уходит с fetch автоматически; в dev Vite проксирует /api на сервер
// либо задаётся VITE_API_URL
const BASE: string = import.meta.env.VITE_API_URL ?? "";

async function request(path: string, init?: RequestInit): Promise<Response> {
  const res = await fetch(`${BASE}${path}`, {
    headers: { "content-type": "application/json" },
    credentials: "same-origin",
    ...init,
  });
  if (!res.ok) {
    let detail = res.statusText;
    try {
      const body = (await res.json()) as { detail?: string };
      if (body.detail) detail = body.detail;
    } catch {
      // тело не JSON — оставляем statusText
    }
    throw new ApiError(res.status, detail);
  }
  return res;
}

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await request(path, init);
  if (res.status === 204) {
    return undefined as T;
  }
  return res.json() as Promise<T>;
}

// keyset-пагинация (ADR-0008): курсор приходит в Link-заголовке
async function apiPage<T>(path: string): Promise<Page<T>> {
  const res = await request(path);
  const link = res.headers.get("link");
  const match = link?.match(/cursor="([^"]+)"/);
  return { data: (await res.json()) as T[], nextCursor: match ? match[1] : null };
}

export const fetchOrganizations = () => api<Organization[]>("/api/0/organizations");

export const fetchProjects = (orgSlug: string) =>
  api<Project[]>(`/api/0/organizations/${orgSlug}/projects`);

export const createProject = (orgSlug: string, name: string, slug: string) =>
  api<Project>(`/api/0/organizations/${orgSlug}/projects`, {
    method: "POST",
    body: JSON.stringify({ name, slug }),
  });

export const updateProject = (orgSlug: string, projectSlug: string, name: string) =>
  api<Project>(`/api/0/projects/${orgSlug}/${projectSlug}`, {
    method: "PUT",
    body: JSON.stringify({ name }),
  });

export interface IssueListParams {
  status?: string;
  sort?: string;
  query?: string;
  environment?: string;
  release?: string;
  cursor?: string;
}

export const fetchIssuesPage = (
  orgSlug: string,
  projectSlug: string,
  params: IssueListParams = {},
) => {
  const query = new URLSearchParams();
  for (const key of ["status", "sort", "query", "environment", "release", "cursor"] as const) {
    const value = params[key];
    if (value) query.set(key, value);
  }
  const qs = query.toString();
  return apiPage<Issue>(`/api/0/projects/${orgSlug}/${projectSlug}/issues${qs ? `?${qs}` : ""}`);
};

export const fetchFilterValues = (orgSlug: string, projectSlug: string) =>
  api<{ environments: string[]; releases: string[] }>(
    `/api/0/projects/${orgSlug}/${projectSlug}/filters`,
  );

export const fetchReleases = (orgSlug: string, projectSlug: string) =>
  api<Release[]>(`/api/0/projects/${orgSlug}/${projectSlug}/releases`);

export const fetchRelease = (orgSlug: string, projectSlug: string, version: string) =>
  api<ReleaseDetail>(
    `/api/0/projects/${orgSlug}/${projectSlug}/releases/${encodeURIComponent(version)}`,
  );

export const fetchIssue = (issueId: string) => api<Issue>(`/api/0/issues/${issueId}`);

export const fetchLatestEvent = (issueId: string) =>
  api<IssueEvent>(`/api/0/issues/${issueId}/events/latest`);

export const fetchIssueEvents = (issueId: string, cursor?: string) => {
  const qs = cursor ? `?cursor=${encodeURIComponent(cursor)}` : "";
  return apiPage<IssueEvent>(`/api/0/issues/${issueId}/events${qs}`);
};

export const updateIssueStatus = (issueId: string, status: Issue["status"]) =>
  api<Issue>(`/api/0/issues/${issueId}`, {
    method: "PUT",
    body: JSON.stringify({ status }),
  });

// AI-анализ по запросу (ADR-0016): ставит фоновую джобу; результат
// опрашивается повторными fetchIssue
export const analyzeIssue = (issueId: string) =>
  api<AIAnalysis>(`/api/0/issues/${issueId}/analyze`, { method: "POST" });

export const fetchTransactionStats = (orgSlug: string, projectSlug: string, window: string) =>
  api<TransactionStat[]>(
    `/api/0/projects/${orgSlug}/${projectSlug}/performance/transactions?window=${window}`,
  );

export const fetchTransactionTraces = (
  orgSlug: string,
  projectSlug: string,
  transaction: string,
  window: string,
  sort: string,
) =>
  api<TraceSummary[]>(
    `/api/0/projects/${orgSlug}/${projectSlug}/performance/traces?` +
      new URLSearchParams({ transaction, window, sort }).toString(),
  );

export const fetchTrace = (orgSlug: string, traceId: string) =>
  api<Trace>(`/api/0/organizations/${orgSlug}/traces/${traceId}`);

export const fetchAlertSettings = (orgSlug: string, projectSlug: string) =>
  api<AlertSettings>(`/api/0/projects/${orgSlug}/${projectSlug}/alert-settings`);

export const updateAlertSettings = (
  orgSlug: string,
  projectSlug: string,
  body: AlertSettingsUpdate,
) =>
  api<AlertSettings>(`/api/0/projects/${orgSlug}/${projectSlug}/alert-settings`, {
    method: "PUT",
    body: JSON.stringify(body),
  });

// --- auth (ADR-0007) ---

export const fetchSetupStatus = () => api<{ setupRequired: boolean }>("/api/0/auth/setup");

export const setup = (body: SetupRequest) =>
  api<CurrentUser>("/api/0/auth/setup", { method: "POST", body: JSON.stringify(body) });

export const login = (email: string, password: string) =>
  api<CurrentUser>("/api/0/auth/login", {
    method: "POST",
    body: JSON.stringify({ email, password }),
  });

export const logout = () => api<void>("/api/0/auth/logout", { method: "POST" });

export const fetchMe = () => api<CurrentUser>("/api/0/auth/me");
