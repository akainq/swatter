import { useEffect, useState } from "react";
import { Link, useParams } from "react-router";
import { fetchRelease, fetchReleases } from "../api/client";
import type { Release, ReleaseDetail } from "../api/client";
import LevelBadge from "../components/LevelBadge";
import { formatDateTime, timeAgo } from "../lib/time";

export default function ReleasesPage() {
  const { orgSlug = "", projectSlug = "" } = useParams();
  const [releases, setReleases] = useState<Release[]>([]);
  const [selected, setSelected] = useState<ReleaseDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    fetchReleases(orgSlug, projectSlug)
      .then((loaded) => {
        if (cancelled) return;
        setReleases(loaded);
        if (loaded.length > 0) void openRelease(loaded[0].version);
      })
      .catch((err) => !cancelled && setError(String(err)))
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgSlug, projectSlug]);

  const openRelease = async (version: string) => {
    setSelected(await fetchRelease(orgSlug, projectSlug, version));
  };

  return (
    <div className="page">
      <h2>Releases</h2>
      {error && <p className="error-text">{error}</p>}
      {loading && <p className="muted">Loading…</p>}
      {!loading && releases.length === 0 && !error && (
        <p className="muted">No releases yet — send events with a `release` set in the SDK.</p>
      )}

      {releases.length > 0 && (
        <div className="releases-layout">
          <ul className="release-list">
            {releases.map((r) => (
              <li key={r.version}>
                <button
                  className={`release-row ${selected?.version === r.version ? "active" : ""}`}
                  onClick={() => void openRelease(r.version)}
                >
                  <span className="release-version">{r.version}</span>
                  <span className="muted small">{r.newIssues ?? 0} new</span>
                </button>
              </li>
            ))}
          </ul>

          <div className="release-detail">
            {selected && (
              <>
                <h3 className="release-heading">{selected.version}</h3>
                {selected.firstEventAt && (
                  <p className="muted small" title={formatDateTime(selected.firstEventAt)}>
                    first event {timeAgo(selected.firstEventAt)}
                  </p>
                )}
                <h3>New issues in this release ({selected.newIssues.length})</h3>
                {selected.newIssues.length === 0 ? (
                  <p className="muted">No new issues introduced here.</p>
                ) : (
                  <ul className="issue-list">
                    {selected.newIssues.map((issue) => (
                      <li key={issue.id}>
                        <Link
                          to={`/${orgSlug}/${projectSlug}/issues/${issue.id}`}
                          className="issue-row"
                        >
                          <LevelBadge level={issue.level} />
                          <div className="issue-text">
                            <span className="issue-title">
                              {issue.title}
                              {issue.regressed && <span className="badge regressed">regression</span>}
                            </span>
                            <span className="muted small">{issue.culprit}</span>
                          </div>
                          <span className="count">{issue.count}</span>
                        </Link>
                      </li>
                    ))}
                  </ul>
                )}
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
