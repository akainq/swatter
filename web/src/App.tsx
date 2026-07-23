import { useCallback, useEffect, useState } from "react";
import { BrowserRouter, Link, Navigate, Route, Routes, useNavigate } from "react-router";
import { ApiError, fetchMe, fetchProjects, fetchSetupStatus, logout } from "./api/client";
import type { CurrentUser } from "./api/client";
import AlertSettingsPage from "./pages/AlertSettingsPage";
import ApiTokensPage from "./pages/ApiTokensPage";
import CreateProjectPage from "./pages/CreateProjectPage";
import IssueDetailPage from "./pages/IssueDetailPage";
import IssuesPage from "./pages/IssuesPage";
import LoginPage from "./pages/LoginPage";
import PerformancePage from "./pages/PerformancePage";
import ProjectsPage from "./pages/ProjectsPage";
import TracePage from "./pages/TracePage";
import TransactionTracesPage from "./pages/TransactionTracesPage";
import ReleasesPage from "./pages/ReleasesPage";
import SetupPage from "./pages/SetupPage";

type AuthState =
  | { kind: "loading" }
  | { kind: "setup" }
  | { kind: "login" }
  | { kind: "error"; message: string }
  | { kind: "ready"; user: CurrentUser };

export default function App() {
  const [state, setState] = useState<AuthState>({ kind: "loading" });

  const load = useCallback(async () => {
    try {
      setState({ kind: "ready", user: await fetchMe() });
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        try {
          const { setupRequired } = await fetchSetupStatus();
          setState({ kind: setupRequired ? "setup" : "login" });
        } catch (inner) {
          setState({ kind: "error", message: String(inner) });
        }
      } else {
        setState({ kind: "error", message: String(err) });
      }
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  switch (state.kind) {
    case "loading":
      return <div className="screen-center muted">Loading…</div>;
    case "error":
      return <div className="screen-center error-text">{state.message}</div>;
    case "setup":
      return <SetupPage onDone={load} />;
    case "login":
      return <LoginPage onDone={load} />;
    case "ready":
      return (
        <BrowserRouter>
          <Shell user={state.user} onSignedOut={load} />
        </BrowserRouter>
      );
  }
}

function Shell({ user, onSignedOut }: { user: CurrentUser; onSignedOut: () => Promise<void> }) {
  const orgSlug = user.memberships[0]?.organization.slug;

  const signOut = async () => {
    await logout();
    await onSignedOut();
  };

  return (
    <div className="app">
      <header className="app-header">
        <nav className="header-left">
          <Link to="/" className="brand">
            Swatter
          </Link>
          {orgSlug && (
            <Link to={`/${orgSlug}/projects`} className="muted">
              Projects
            </Link>
          )}
          <Link to="/settings/tokens" className="muted">
            API
          </Link>
        </nav>
        <div className="header-right">
          <span className="muted">{user.email}</span>
          <button className="btn" onClick={() => void signOut()}>
            Sign out
          </button>
        </div>
      </header>
      <main className="app-main">
        <Routes>
          <Route
            path="/"
            element={
              orgSlug ? (
                <HomeRedirect orgSlug={orgSlug} />
              ) : (
                <div className="screen-center muted">You are not a member of any organization.</div>
              )
            }
          />
          <Route path="/settings/tokens" element={<ApiTokensPage />} />
          <Route path="/:orgSlug/projects" element={<ProjectsPage />} />
          <Route path="/:orgSlug/projects/new" element={<CreateProjectPage />} />
          <Route path="/:orgSlug/:projectSlug/releases" element={<ReleasesPage />} />
          <Route path="/:orgSlug/:projectSlug/performance" element={<PerformancePage />} />
          <Route
            path="/:orgSlug/:projectSlug/performance/transaction"
            element={<TransactionTracesPage />}
          />
          <Route path="/:orgSlug/traces/:traceId" element={<TracePage />} />
          <Route path="/:orgSlug/:projectSlug/settings/alerts" element={<AlertSettingsPage />} />
          <Route path="/:orgSlug/:projectSlug" element={<IssuesPage />} />
          <Route path="/:orgSlug/:projectSlug/issues/:issueId" element={<IssueDetailPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
    </div>
  );
}

function HomeRedirect({ orgSlug }: { orgSlug: string }) {
  const navigate = useNavigate();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetchProjects(orgSlug)
      .then((projects) => {
        if (cancelled) return;
        if (projects.length > 0) {
          navigate(`/${orgSlug}/${projects[0].slug}`, { replace: true });
        } else {
          navigate(`/${orgSlug}/projects/new`, { replace: true });
        }
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      });
    return () => {
      cancelled = true;
    };
  }, [orgSlug, navigate]);

  if (error) return <div className="screen-center error-text">{error}</div>;
  return <div className="screen-center muted">Loading…</div>;
}
