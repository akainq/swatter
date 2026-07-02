import { useState } from "react";
import type { FormEvent } from "react";
import { useNavigate, useParams } from "react-router";
import { ApiError, createProject } from "../api/client";

export default function CreateProjectPage() {
  const { orgSlug = "" } = useParams();
  const navigate = useNavigate();
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [slugTouched, setSlugTouched] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const project = await createProject(orgSlug, name, slug);
      navigate(`/${orgSlug}/${project.slug}`, { replace: true });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
      setBusy(false);
    }
  };

  const onNameChange = (value: string) => {
    setName(value);
    if (!slugTouched) setSlug(slugify(value));
  };

  return (
    <div className="screen-center">
      <form className="card auth-card" onSubmit={(e) => void submit(e)}>
        <h2>Create a project</h2>
        <p className="muted">Errors are grouped per project; each project gets its own DSN.</p>
        <label>
          Name
          <input
            id="project-name"
            value={name}
            onChange={(e) => onNameChange(e.target.value)}
            required
          />
        </label>
        <label>
          Slug
          <input
            id="project-slug"
            value={slug}
            pattern="[a-z0-9][a-z0-9-]*"
            onChange={(e) => {
              setSlugTouched(true);
              setSlug(e.target.value);
            }}
            required
          />
        </label>
        {error && <p className="error-text">{error}</p>}
        <button id="submit" className="btn primary" disabled={busy}>
          {busy ? "Creating…" : "Create project"}
        </button>
      </form>
    </div>
  );
}

function slugify(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}
