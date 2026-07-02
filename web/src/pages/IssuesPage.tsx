import { useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router";
import { fetchFilterValues, fetchIssuesPage, fetchProjects } from "../api/client";
import type { Issue, Project } from "../api/client";
import LevelBadge from "../components/LevelBadge";
import { timeAgo } from "../lib/time";

const STATUSES = ["unresolved", "resolved", "ignored", "all"] as const;

const SORTS: Array<[string, string]> = [
  ["date", "Last seen"],
  ["new", "First seen"],
  ["freq", "Events"],
];

export default function IssuesPage() {
  const { orgSlug = "", projectSlug = "" } = useParams();
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const status = searchParams.get("status") ?? "unresolved";
  const sort = searchParams.get("sort") ?? "date";
  const query = searchParams.get("query") ?? "";
  const environment = searchParams.get("environment") ?? "";
  const release = searchParams.get("release") ?? "";

  const [issues, setIssues] = useState<Issue[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [projects, setProjects] = useState<Project[]>([]);
  const [filters, setFilters] = useState<{ environments: string[]; releases: string[] }>({
    environments: [],
    releases: [],
  });
  // локальное значение поля поиска (в URL уходит с debounce)
  const [searchText, setSearchText] = useState(query);

  const dsn = projects.find((p) => p.slug === projectSlug)?.dsn ?? null;
  const params = useMemo(
    () => ({ status, sort, query, environment, release }),
    [status, sort, query, environment, release],
  );

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    fetchIssuesPage(orgSlug, projectSlug, params)
      .then((page) => {
        if (cancelled) return;
        setIssues(page.data);
        setNextCursor(page.nextCursor);
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [orgSlug, projectSlug, params]);

  // проекты (переключатель + DSN) и значения фильтров проекта
  useEffect(() => {
    let cancelled = false;
    fetchProjects(orgSlug)
      .then((loaded) => !cancelled && setProjects(loaded))
      .catch(() => {});
    fetchFilterValues(orgSlug, projectSlug)
      .then((values) => !cancelled && setFilters(values))
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [orgSlug, projectSlug]);

  // поле поиска сбрасывается при переключении проекта/очистке query извне
  useEffect(() => {
    setSearchText(query);
  }, [query, projectSlug]);

  // debounce: печатаем в поле, в URL уходит через 350 мс тишины
  useEffect(() => {
    if (searchText === query) return;
    const timer = setTimeout(() => setParam({ query: searchText }), 350);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchText]);

  const loadMore = async () => {
    if (!nextCursor) return;
    const page = await fetchIssuesPage(orgSlug, projectSlug, { ...params, cursor: nextCursor });
    setIssues((current) => [...current, ...page.data]);
    setNextCursor(page.nextCursor);
  };

  const setParam = (updates: Record<string, string>) => {
    const next = new URLSearchParams(searchParams);
    for (const [key, value] of Object.entries(updates)) {
      if (value) next.set(key, value);
      else next.delete(key);
    }
    setSearchParams(next, { replace: true });
  };

  return (
    <div className="page">
      <div className="page-header">
        {projects.length > 1 ? (
          <select
            className="select project-select"
            value={projectSlug}
            onChange={(e) => navigate(`/${orgSlug}/${e.target.value}`)}
            aria-label="Project"
          >
            {projects.map((p) => (
              <option key={p.slug} value={p.slug}>
                {p.name}
              </option>
            ))}
          </select>
        ) : (
          <h2>{projects.find((p) => p.slug === projectSlug)?.name ?? projectSlug}</h2>
        )}
        <div className="toolbar">
          <div className="tabs">
            {STATUSES.map((s) => (
              <button
                key={s}
                className={`tab ${s === status ? "active" : ""}`}
                onClick={() => setParam({ status: s })}
              >
                {s}
              </button>
            ))}
          </div>
          <select
            className="select"
            value={sort}
            onChange={(e) => setParam({ sort: e.target.value })}
            aria-label="Sort"
          >
            {SORTS.map(([value, label]) => (
              <option key={value} value={value}>
                Sort: {label}
              </option>
            ))}
          </select>
          <Link to={`/${orgSlug}/${projectSlug}/releases`} className="btn">
            Releases
          </Link>
        </div>
      </div>

      <div className="filter-bar">
        <input
          className="search-input"
          type="search"
          placeholder="Search issues…"
          value={searchText}
          onChange={(e) => setSearchText(e.target.value)}
          aria-label="Search"
        />
        {filters.environments.length > 0 && (
          <select
            className="select"
            value={environment}
            onChange={(e) => setParam({ environment: e.target.value })}
            aria-label="Environment"
          >
            <option value="">All environments</option>
            {filters.environments.map((env) => (
              <option key={env} value={env}>
                {env}
              </option>
            ))}
          </select>
        )}
        {filters.releases.length > 0 && (
          <select
            className="select"
            value={release}
            onChange={(e) => setParam({ release: e.target.value })}
            aria-label="Release"
          >
            <option value="">All releases</option>
            {filters.releases.map((rel) => (
              <option key={rel} value={rel}>
                {rel}
              </option>
            ))}
          </select>
        )}
      </div>

      {error && <p className="error-text">{error}</p>}
      {loading && <p className="muted">Loading…</p>}

      {!loading && issues.length === 0 && !error && (
        <div className="card empty-state">
          <h3>No matching issues</h3>
          {status === "unresolved" && !query && !environment && !release && (
            <>
              <p className="muted">
                Point any official Sentry SDK at this project — just swap the DSN:
              </p>
              <pre className="snippet">
                {`Sentry.init({\n  dsn: "${dsn ?? "…"}",\n});`}
              </pre>
            </>
          )}
        </div>
      )}

      <ul className="issue-list">
        {issues.map((issue) => (
          <li key={issue.id}>
            <Link to={`/${orgSlug}/${projectSlug}/issues/${issue.id}`} className="issue-row">
              <LevelBadge level={issue.level} />
              <div className="issue-text">
                <span className="issue-title">
                  {issue.title}
                  {issue.regressed && <span className="badge regressed">regression</span>}
                </span>
                <span className="muted small">{issue.culprit}</span>
              </div>
              <div className="issue-meta">
                <span className="count" title="events">
                  {issue.count}
                </span>
                <span className="muted small">{timeAgo(issue.lastSeen)}</span>
              </div>
            </Link>
          </li>
        ))}
      </ul>

      {nextCursor && (
        <button className="btn wide" onClick={() => void loadMore()}>
          Load more
        </button>
      )}
    </div>
  );
}
