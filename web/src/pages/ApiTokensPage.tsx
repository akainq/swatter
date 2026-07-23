import { useEffect, useState } from "react";
import { ApiError, createApiToken, deleteApiToken, fetchApiTokens } from "../api/client";
import type { ApiToken } from "../api/client";
import { formatDateTime, timeAgo } from "../lib/time";

// API-токены swt_ (ADR-0017): подключение MCP-сервера к Claude Code и
// прочей автоматизации. Плейнтекст показывается один раз — при создании.
export default function ApiTokensPage() {
  const [tokens, setTokens] = useState<ApiToken[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [created, setCreated] = useState<{ name: string; token: string } | null>(null);
  const [copied, setCopied] = useState(false);

  const load = () => {
    fetchApiTokens()
      .then(setTokens)
      .catch((err) => setError(String(err)));
  };

  useEffect(load, []);

  const create = async () => {
    setBusy(true);
    setError(null);
    try {
      const result = await createApiToken(name.trim());
      setCreated({ name: result.name, token: result.token });
      setName("");
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  };

  const revoke = async (id: string) => {
    await deleteApiToken(id);
    load();
  };

  const copy = async (value: string) => {
    await navigator.clipboard.writeText(value);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  const mcpSnippet = created
    ? `claude mcp add --transport http swatter ${window.location.origin}/mcp --header "Authorization: Bearer ${created.token}"`
    : "";

  return (
    <div className="page">
      <div className="page-header">
        <h2>API tokens</h2>
      </div>

      <p className="muted">
        Tokens authenticate the MCP server (<code>/mcp</code>) and other automation. A token sees
        the same organizations you do.
      </p>

      {error && <p className="error-text">{error}</p>}

      <div className="card settings-form">
        <label className="settings-row">
          <span className="settings-label">
            New token name
            <span className="muted small block">e.g. “claude-code on my laptop”</span>
          </span>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && name.trim() !== "") void create();
            }}
          />
        </label>
        <div className="toolbar">
          <button className="btn primary" disabled={busy || name.trim() === ""} onClick={() => void create()}>
            Create token
          </button>
        </div>
      </div>

      {created && (
        <div className="card token-created">
          <p>
            <strong>{created.name}</strong> — copy the token now, it will not be shown again:
          </p>
          <div className="dsn-row">
            <code className="dsn">{created.token}</code>
            <button className="btn small-btn" onClick={() => void copy(created.token)}>
              {copied ? "Copied!" : "Copy"}
            </button>
          </div>
          <p className="muted small">Connect Claude Code:</p>
          <pre className="snippet">{mcpSnippet}</pre>
        </div>
      )}

      {tokens && tokens.length > 0 && (
        <ul className="issue-list">
          {tokens.map((token) => (
            <li key={token.id} className="token-row">
              <span>{token.name}</span>
              <span className="muted small" title={formatDateTime(token.insertedAt)}>
                created {timeAgo(token.insertedAt)}
              </span>
              <button className="btn small-btn" onClick={() => void revoke(token.id)}>
                Revoke
              </button>
            </li>
          ))}
        </ul>
      )}
      {tokens && tokens.length === 0 && <p className="muted">No tokens yet.</p>}
    </div>
  );
}
