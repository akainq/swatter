import { useEffect, useState } from "react";
import { Link, useParams } from "react-router";
import { ApiError, fetchAlertSettings, updateAlertSettings } from "../api/client";
import type { AlertSettings } from "../api/client";

// Настройки Telegram-алертов проекта (ADR-0013): куда слать (chat_id)
// и какие правила включены. Бот-токен общий на инстанс (env), здесь
// только показываем, задан ли он.
export default function AlertSettingsPage() {
  const { orgSlug = "", projectSlug = "" } = useParams();
  const [settings, setSettings] = useState<AlertSettings | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);

  // локальное поле порога строкой: пустая строка = правило выключено
  const [threshold, setThreshold] = useState("");

  useEffect(() => {
    let cancelled = false;
    fetchAlertSettings(orgSlug, projectSlug)
      .then((loaded) => {
        if (cancelled) return;
        setSettings(loaded);
        setThreshold(loaded.frequencyThreshold != null ? String(loaded.frequencyThreshold) : "");
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      });
    return () => {
      cancelled = true;
    };
  }, [orgSlug, projectSlug]);

  if (error) return <div className="page error-text">{error}</div>;
  if (!settings) return <div className="page muted">Loading…</div>;

  const patch = (changes: Partial<AlertSettings>) => {
    setSettings({ ...settings, ...changes });
    setSaved(false);
  };

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      const parsed = threshold.trim() === "" ? null : Number.parseInt(threshold, 10);
      const updated = await updateAlertSettings(orgSlug, projectSlug, {
        enabled: settings.enabled,
        telegramChatId: settings.telegramChatId ?? "",
        onNewIssue: settings.onNewIssue,
        onRegression: settings.onRegression,
        frequencyThreshold: Number.isNaN(parsed as number) ? null : parsed,
        frequencyWindowSeconds: settings.frequencyWindowSeconds,
      });
      setSettings(updated);
      setThreshold(updated.frequencyThreshold != null ? String(updated.frequencyThreshold) : "");
      setSaved(true);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="page">
      <Link to={`/${orgSlug}/${projectSlug}`} className="muted small">
        ← back to issues
      </Link>

      <div className="page-header">
        <h2>Alerts · {projectSlug}</h2>
      </div>

      {!settings.telegramConfigured && (
        <p className="card warning">
          TELEGRAM_BOT_TOKEN is not set on this instance — alerts will not be delivered until the
          operator configures it.
        </p>
      )}

      <div className="card settings-form">
        <label className="settings-row">
          <input
            type="checkbox"
            checked={settings.enabled}
            onChange={(e) => patch({ enabled: e.target.checked })}
          />
          <span>
            Alerts enabled
            <span className="muted small block">Master switch for this project</span>
          </span>
        </label>

        <label className="settings-row">
          <span className="settings-label">
            Telegram chat ID
            <span className="muted small block">
              User, group or channel id the bot will post to
            </span>
          </span>
          <input
            type="text"
            value={settings.telegramChatId ?? ""}
            placeholder="e.g. 146075783 or -1001234567890"
            onChange={(e) => patch({ telegramChatId: e.target.value })}
          />
        </label>

        <label className="settings-row">
          <input
            type="checkbox"
            checked={settings.onNewIssue}
            onChange={(e) => patch({ onNewIssue: e.target.checked })}
          />
          <span>
            New issue
            <span className="muted small block">First occurrence of an error group</span>
          </span>
        </label>

        <label className="settings-row">
          <input
            type="checkbox"
            checked={settings.onRegression}
            onChange={(e) => patch({ onRegression: e.target.checked })}
          />
          <span>
            Regression
            <span className="muted small block">Resolved issue came back in a newer release</span>
          </span>
        </label>

        <label className="settings-row">
          <span className="settings-label">
            Frequency threshold
            <span className="muted small block">
              Events per issue within the window; empty disables the rule
            </span>
          </span>
          <input
            type="number"
            min={1}
            value={threshold}
            placeholder="off"
            onChange={(e) => {
              setThreshold(e.target.value);
              setSaved(false);
            }}
          />
        </label>

        <label className="settings-row">
          <span className="settings-label">
            Frequency window, seconds
            <span className="muted small block">Counting window for the threshold rule</span>
          </span>
          <input
            type="number"
            min={1}
            value={settings.frequencyWindowSeconds}
            onChange={(e) =>
              patch({ frequencyWindowSeconds: Number.parseInt(e.target.value, 10) || 300 })
            }
          />
        </label>

        <div className="toolbar">
          <button className="btn primary" disabled={saving} onClick={() => void save()}>
            {saving ? "Saving…" : "Save"}
          </button>
          {saved && <span className="muted small">Saved.</span>}
        </div>
      </div>
    </div>
  );
}
