import { useEffect, useState } from "react";
import { Link, useParams } from "react-router";
import { fetchTransactionStats } from "../api/client";
import type { TransactionStat } from "../api/client";
import { formatDateTime, timeAgo } from "../lib/time";

const WINDOWS = ["1h", "24h", "7d"] as const;

// Performance (ADR-0014): агрегаты по транзакциям проекта — p50/p95/rpm
// на лету из ClickHouse по корневым спанам.
export default function PerformancePage() {
  const { orgSlug = "", projectSlug = "" } = useParams();
  const [window, setWindow] = useState<string>("24h");
  const [stats, setStats] = useState<TransactionStat[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setStats(null);
    fetchTransactionStats(orgSlug, projectSlug, window)
      .then((loaded) => {
        if (!cancelled) setStats(loaded);
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      });
    return () => {
      cancelled = true;
    };
  }, [orgSlug, projectSlug, window]);

  if (error) return <div className="page error-text">{error}</div>;

  return (
    <div className="page">
      <Link to={`/${orgSlug}/${projectSlug}`} className="muted small">
        ← back to issues
      </Link>

      <div className="page-header">
        <h2>Performance · {projectSlug}</h2>
        <div className="toolbar">
          {WINDOWS.map((w) => (
            <button
              key={w}
              className={`btn ${window === w ? "primary" : ""}`}
              onClick={() => setWindow(w)}
            >
              {w}
            </button>
          ))}
        </div>
      </div>

      {!stats && <p className="muted">Loading…</p>}

      {stats && stats.length === 0 && (
        <div className="card empty-state">
          <h3>NO TRANSACTIONS</h3>
          <p className="muted">
            Enable tracing in your SDK — set <code>tracesSampleRate</code> and transactions will
            appear here:
          </p>
          <pre className="snippet">{`Sentry.init({\n  dsn: "...",\n  tracesSampleRate: 1.0,\n});`}</pre>
        </div>
      )}

      {stats && stats.length > 0 && (
        <table className="perf-table card">
          <thead>
            <tr>
              <th>Transaction</th>
              <th className="num">rpm</th>
              <th className="num">p50, ms</th>
              <th className="num">p95, ms</th>
              <th className="num">count</th>
              <th className="num">last seen</th>
            </tr>
          </thead>
          <tbody>
            {stats.map((stat) => (
              <tr key={stat.transaction}>
                <td className="perf-name">{stat.transaction}</td>
                <td className="num">{stat.rpm}</td>
                <td className="num">{stat.p50}</td>
                <td className="num">{stat.p95}</td>
                <td className="num">{stat.count}</td>
                <td className="num muted small" title={formatDateTime(stat.lastSeen)}>
                  {timeAgo(stat.lastSeen)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
