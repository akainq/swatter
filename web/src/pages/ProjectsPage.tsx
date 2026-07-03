import { useEffect, useState } from "react";
import { Link, useParams } from "react-router";
import { ApiError, fetchProjects, updateProject } from "../api/client";
import type { Project } from "../api/client";

export default function ProjectsPage() {
  const { orgSlug = "" } = useParams();
  const [projects, setProjects] = useState<Project[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    fetchProjects(orgSlug)
      .then((loaded) => {
        if (!cancelled) setProjects(loaded);
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
  }, [orgSlug]);

  const onRenamed = (updated: Project) => {
    setProjects((current) => current.map((p) => (p.slug === updated.slug ? { ...p, ...updated } : p)));
  };

  return (
    <div className="page">
      <div className="page-header">
        <h2>Projects</h2>
        <Link to={`/${orgSlug}/projects/new`} className="btn primary">
          New project
        </Link>
      </div>

      {error && <p className="error-text">{error}</p>}
      {loading && <p className="muted">Loading…</p>}
      {!loading && projects.length === 0 && !error && (
        <p className="muted">No projects yet — create the first one.</p>
      )}

      <div className="project-grid">
        {projects.map((project) => (
          <ProjectCard key={project.slug} orgSlug={orgSlug} project={project} onRenamed={onRenamed} />
        ))}
      </div>
    </div>
  );
}

function ProjectCard({
  orgSlug,
  project,
  onRenamed,
}: {
  orgSlug: string;
  project: Project;
  onRenamed: (p: Project) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(project.name);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      onRenamed(await updateProject(orgSlug, project.slug, name.trim()));
      setEditing(false);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  const copyDsn = async () => {
    if (!project.dsn) return;
    await navigator.clipboard.writeText(project.dsn);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div className="card project-card">
      <div className="project-card-head">
        {editing ? (
          <div className="rename-row">
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void save();
                if (e.key === "Escape") setEditing(false);
              }}
              autoFocus
            />
            <button className="btn primary" disabled={busy || name.trim() === ""} onClick={() => void save()}>
              Save
            </button>
            <button className="btn" onClick={() => setEditing(false)}>
              Cancel
            </button>
          </div>
        ) : (
          <>
            <h3 className="project-name">{project.name}</h3>
            <button className="btn small-btn" onClick={() => setEditing(true)}>
              Rename
            </button>
          </>
        )}
      </div>
      <p className="muted small">
        {project.slug}
        {project.platform ? ` · ${project.platform}` : ""}
      </p>
      {error && <p className="error-text small">{error}</p>}

      <div className="project-stats">
        <div className="meta">
          <span className="muted small">Unresolved</span>
          <span className="count">{project.unresolvedIssues ?? 0}</span>
        </div>
        <div className="meta">
          <span className="muted small">Events, 24h</span>
          <span className="count">{project.events24h ?? 0}</span>
        </div>
      </div>

      {project.dsn && (
        <div className="dsn-row">
          <code className="dsn">{project.dsn}</code>
          <button className="btn small-btn" onClick={() => void copyDsn()}>
            {copied ? "Copied!" : "Copy"}
          </button>
        </div>
      )}

      <div className="project-actions">
        <Link to={`/${orgSlug}/${project.slug}`} className="btn wide">
          Open issues
        </Link>
        <Link to={`/${orgSlug}/${project.slug}/settings/alerts`} className="btn">
          Alerts
        </Link>
      </div>
    </div>
  );
}
