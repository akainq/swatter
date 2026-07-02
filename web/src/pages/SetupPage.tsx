import { useState } from "react";
import type { FormEvent } from "react";
import { ApiError, setup } from "../api/client";

export default function SetupPage({ onDone }: { onDone: () => Promise<void> }) {
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [orgName, setOrgName] = useState("Swatter");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await setup({
        email,
        password,
        name,
        orgName,
        orgSlug: slugify(orgName) || "swatter",
      });
      await onDone();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
      setBusy(false);
    }
  };

  return (
    <div className="screen-center">
      <form className="card auth-card" onSubmit={(e) => void submit(e)}>
        <h1 className="brand big">Swatter</h1>
        <p className="muted">Welcome! Create the first (owner) account of this instance.</p>
        <label>
          Email
          <input
            id="email"
            type="email"
            autoComplete="username"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
          />
        </label>
        <label>
          Name
          <input id="name" value={name} onChange={(e) => setName(e.target.value)} />
        </label>
        <label>
          Password <span className="muted">(min 8 chars)</span>
          <input
            id="password"
            type="password"
            autoComplete="new-password"
            minLength={8}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
        </label>
        <label>
          Organization
          <input id="orgName" value={orgName} onChange={(e) => setOrgName(e.target.value)} required />
        </label>
        {error && <p className="error-text">{error}</p>}
        <button id="submit" className="btn primary" disabled={busy}>
          {busy ? "Creating…" : "Create account"}
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
