import { useEffect, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import { fetchTransactionTraces } from "../api/client";
import type { TraceSummary } from "../api/client";
import { formatDateTime, timeAgo } from "../lib/time";

const WINDOWS = ["1h", "24h", "7d"] as const;

// Деталка транзакции (ADR-0014): последние трейсы, медленные сверху,
// клик ведёт в waterfall.
export default function TransactionTracesPage() {
  const { orgSlug = "", projectSlug = "" } = useParams();
  const [searchParams, setSearchParams] = useSearchParams();
  const name = searchParams.get("name") ?? "";
  const window = searchParams.get("window") ?? "24h";
  const sort = searchParams.get("sort") ?? "slow";

  const [traces, setTraces] = useState<TraceSummary[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setTraces(null);
    fetchTransactionTraces(orgSlug, projectSlug, name, window, sort)
      .then((loaded) => {
        if (!cancelled) setTraces(loaded);
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      });
    return () => {
      cancelled = true;
    };
  }, [orgSlug, projectSlug, name, window, sort]);

  const setParam = (changes: Record<string, string>) => {
    const next = new URLSearchParams(searchParams);
    for (const [key, value] of Object.entries(changes)) next.set(key, value);
    setSearchParams(next, { replace: true });
  };

  if (error) return <div className="page error-text">{error}</div>;

  const maxDuration = Math.max(...(traces ?? []).map((t) => t.durationMs), 1);

  return (
    <div className="page">
      <Link to={`/${orgSlug}/${projectSlug}/performance`} className="muted small">
        ← back to performance
      </Link>

      <div className="page-header">
        <h2 className="perf-name">{name}</h2>
        <div className="toolbar">
          <button
            className={`btn ${sort === "slow" ? "primary" : ""}`}
            onClick={() => setParam({ sort: "slow" })}
          >
            Slowest
          </button>
          <button
            className={`btn ${sort === "recent" ? "primary" : ""}`}
            onClick={() => setParam({ sort: "recent" })}
          >
            Recent
          </button>
          {WINDOWS.map((w) => (
            <button
              key={w}
              className={`btn ${window === w ? "primary" : ""}`}
              onClick={() => setParam({ window: w })}
            >
              {w}
            </button>
          ))}
        </div>
      </div>

      {!traces && <p className="muted">Loading…</p>}
      {traces && traces.length === 0 && (
        <p className="muted">No traces for this transaction in the selected window.</p>
      )}

      {traces && traces.length > 0 && (
        <ul className="issue-list">
          {traces.map((trace) => (
            <li key={trace.traceId}>
              <Link to={`/${orgSlug}/traces/${trace.traceId}`} className="trace-row">
                <code className="event-id">{trace.traceId.slice(0, 8)}</code>
                <span className="trace-bar-cell">
                  <span
                    className="trace-bar"
                    style={{ width: `${(trace.durationMs / maxDuration) * 100}%` }}
                  />
                </span>
                <span className="num">{trace.durationMs} ms</span>
                <span className="muted small">
                  {[trace.environment, trace.release].filter(Boolean).join(" · ")}
                </span>
                <span className="muted small" title={formatDateTime(trace.startTs)}>
                  {timeAgo(trace.startTs)}
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
