import { useEffect, useState } from "react";
import { Link, useParams } from "react-router";
import {
  ApiError,
  fetchIssue,
  fetchIssueEvents,
  fetchLatestEvent,
  updateIssueStatus,
} from "../api/client";
import type { Issue, IssueEvent } from "../api/client";
import LevelBadge from "../components/LevelBadge";
import { formatDateTime, timeAgo } from "../lib/time";

// Форма exception/breadcrumbs в payload — свободная (см. ApiSchemas.Event);
// типизируем локально ровно то, что рендерим
interface SentryFrame {
  filename?: string;
  module?: string;
  function?: string;
  lineno?: number;
  colno?: number;
  in_app?: boolean;
  context_line?: string;
  pre_context?: string[];
  post_context?: string[];
  data?: { symbolicated?: boolean };
}

interface SentryExceptionValue {
  type?: string;
  value?: string;
  stacktrace?: { frames?: SentryFrame[] };
}

interface Breadcrumb {
  timestamp?: string | number;
  category?: string;
  message?: string;
  level?: string;
}

export default function IssueDetailPage() {
  const { orgSlug = "", projectSlug = "", issueId = "" } = useParams();
  const [issue, setIssue] = useState<Issue | null>(null);
  const [event, setEvent] = useState<IssueEvent | null>(null);
  const [error, setError] = useState<string | null>(null);
  // история вхождений
  const [events, setEvents] = useState<IssueEvent[]>([]);
  const [eventsCursor, setEventsCursor] = useState<string | null>(null);
  // event_id выбранного вручную вхождения (иначе показываем latest)
  const [selectedId, setSelectedId] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setIssue(null);
    setEvent(null);
    setEvents([]);
    setEventsCursor(null);
    setSelectedId(null);
    setError(null);

    fetchIssue(issueId)
      .then((loaded) => {
        if (!cancelled) setIssue(loaded);
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      });

    fetchLatestEvent(issueId)
      .then((loaded) => {
        if (!cancelled) setEvent(loaded);
      })
      .catch((err) => {
        // 404 = события ещё не доехали или срезаны retention — не фатально
        if (!cancelled && !(err instanceof ApiError && err.status === 404)) {
          setError(String(err));
        }
      });

    fetchIssueEvents(issueId)
      .then((page) => {
        if (cancelled) return;
        setEvents(page.data);
        setEventsCursor(page.nextCursor);
      })
      .catch(() => {
        // список вхождений не критичен для страницы
      });

    return () => {
      cancelled = true;
    };
  }, [issueId]);

  const setStatus = async (status: Issue["status"]) => {
    const updated = await updateIssueStatus(issueId, status);
    setIssue(updated);
  };

  const loadMoreEvents = async () => {
    if (!eventsCursor) return;
    const page = await fetchIssueEvents(issueId, eventsCursor);
    setEvents((current) => [...current, ...page.data]);
    setEventsCursor(page.nextCursor);
  };

  if (error) return <div className="page error-text">{error}</div>;
  if (!issue) return <div className="page muted">Loading…</div>;

  // показываем выбранное вручную вхождение, иначе latest
  const shown = (selectedId && events.find((e) => e.eventId === selectedId)) || event;
  const exception = extractException(shown);
  const frames = [...(exception?.stacktrace?.frames ?? [])].reverse();
  const breadcrumbs = extractBreadcrumbs(shown);

  return (
    <div className="page">
      <Link to={`/${orgSlug}/${projectSlug}`} className="muted small">
        ← back to issues
      </Link>

      <div className="page-header">
        <div>
          <h2 className="issue-heading">
            <LevelBadge level={issue.level} />
            {issue.title}
            {issue.regressed && <span className="badge regressed">regression</span>}
          </h2>
          <p className="muted">{issue.culprit}</p>
        </div>
        <div className="toolbar">
          {issue.status !== "resolved" && (
            <button className="btn primary" onClick={() => void setStatus("resolved")}>
              Resolve
            </button>
          )}
          {issue.status !== "ignored" && (
            <button className="btn" onClick={() => void setStatus("ignored")}>
              Ignore
            </button>
          )}
          {issue.status !== "unresolved" && (
            <button className="btn" onClick={() => void setStatus("unresolved")}>
              Reopen
            </button>
          )}
        </div>
      </div>

      <div className="meta-grid card">
        <Meta label="Status" value={issue.status} />
        <Meta label="Events" value={String(issue.count)} />
        <Meta label="First seen" value={`${timeAgo(issue.firstSeen)}`} title={formatDateTime(issue.firstSeen)} />
        <Meta label="Last seen" value={`${timeAgo(issue.lastSeen)}`} title={formatDateTime(issue.lastSeen)} />
        {shown && <Meta label="Environment" value={shown.environment ?? ""} />}
        {shown && <Meta label="Release" value={shown.release ?? ""} />}
        {shown && (
          <Meta label="SDK" value={`${shown.sdk?.name ?? ""} ${shown.sdk?.version ?? ""}`} />
        )}
        {shown?.user?.email && <Meta label="User" value={shown.user.email} />}
      </div>

      {shown?.message && (
        <section>
          <h3>Message</h3>
          <pre className="snippet">{shown.message}</pre>
        </section>
      )}

      {exception && (
        <section>
          <h3>
            Stack trace{" "}
            <span className="muted small">
              {selectedId ? "selected" : "latest"} event {shown?.eventId}
            </span>
          </h3>
          <div className="card stacktrace">
            <p className="exception-line">
              <strong>{exception.type ?? "Error"}</strong>
              {exception.value ? `: ${exception.value}` : ""}
            </p>
            {frames.map((frame, index) => (
              <Frame key={index} frame={frame} defaultOpen={index === firstInApp(frames)} />
            ))}
          </div>
        </section>
      )}

      {shown && shown.tags && shown.tags.length > 0 && (
        <section>
          <h3>Tags</h3>
          <div className="tag-list">
            {shown.tags.map((tag) => (
              <span className="tag" key={tag.key}>
                <span className="muted">{tag.key}</span> {tag.value}
              </span>
            ))}
          </div>
        </section>
      )}

      {breadcrumbs.length > 0 && (
        <section>
          <h3>Breadcrumbs</h3>
          <ul className="card breadcrumbs">
            {breadcrumbs.slice(-20).map((crumb, index) => (
              <li key={index}>
                <span className="muted small">{crumb.category ?? "-"}</span>
                <span>{crumb.message ?? ""}</span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {events.length > 0 && (
        <section>
          <h3>All events ({issue.count})</h3>
          <ul className="issue-list">
            {events.map((ev) => {
              const active = ev.eventId === (shown?.eventId ?? "");
              return (
                <li key={ev.eventId}>
                  <button
                    className={`event-row ${active ? "active" : ""}`}
                    onClick={() => setSelectedId(ev.eventId)}
                  >
                    <code className="event-id">{ev.eventId.slice(0, 8)}</code>
                    <span className="muted small">
                      {[ev.environment, ev.release].filter(Boolean).join(" · ")}
                    </span>
                    <span className="muted small" title={formatDateTime(ev.timestamp)}>
                      {timeAgo(ev.timestamp)}
                    </span>
                  </button>
                </li>
              );
            })}
          </ul>
          {eventsCursor && (
            <button className="btn wide" onClick={() => void loadMoreEvents()}>
              Load more events
            </button>
          )}
        </section>
      )}
    </div>
  );
}

function Meta({ label, value, title }: { label: string; value: string; title?: string }) {
  return (
    <div className="meta" title={title}>
      <span className="muted small">{label}</span>
      <span>{value || "—"}</span>
    </div>
  );
}

function Frame({ frame, defaultOpen }: { frame: SentryFrame; defaultOpen: boolean }) {
  const location = frame.module ?? basename(frame.filename) ?? "?";
  const hasContext = typeof frame.context_line === "string";

  const header = (
    <span className="frame-line">
      <span className={frame.in_app ? "frame-module in-app" : "frame-module"}>{location}</span>
      {" in "}
      <span className="frame-fn">{frame.function ?? "?"}</span>
      {frame.lineno != null && <span className="muted"> at line {frame.lineno}</span>}
      {frame.data?.symbolicated && (
        <span className="badge symbolicated" title="mapped from a source map">
          source
        </span>
      )}
    </span>
  );

  if (!hasContext) {
    return <div className={`frame ${frame.in_app ? "frame-app" : ""}`}>{header}</div>;
  }

  return (
    <details className={`frame ${frame.in_app ? "frame-app" : ""}`} open={defaultOpen}>
      <summary>{header}</summary>
      <pre className="code-context">
        {(frame.pre_context ?? []).map((line, i) => (
          <div className="code-line" key={`pre-${i}`}>
            {line || " "}
          </div>
        ))}
        <div className="code-line highlight">{frame.context_line}</div>
        {(frame.post_context ?? []).map((line, i) => (
          <div className="code-line" key={`post-${i}`}>
            {line || " "}
          </div>
        ))}
      </pre>
    </details>
  );
}

function extractException(event: IssueEvent | null): SentryExceptionValue | null {
  if (!event) return null;
  const exception = event.exception as { values?: SentryExceptionValue[] } | null | undefined;
  const values = exception?.values;
  if (!Array.isArray(values) || values.length === 0) return null;
  // последний в цепочке — то, что реально поймали
  return values[values.length - 1];
}

function extractBreadcrumbs(event: IssueEvent | null): Breadcrumb[] {
  if (!event) return [];
  const raw = event.breadcrumbs as Breadcrumb[] | { values?: Breadcrumb[] } | null | undefined;
  if (Array.isArray(raw)) return raw;
  if (raw && Array.isArray(raw.values)) return raw.values;
  return [];
}

function firstInApp(frames: SentryFrame[]): number {
  const index = frames.findIndex((f) => f.in_app);
  return index === -1 ? 0 : index;
}

function basename(path?: string): string | undefined {
  if (!path) return undefined;
  const parts = path.split(/[\\/]/);
  return parts[parts.length - 1];
}
