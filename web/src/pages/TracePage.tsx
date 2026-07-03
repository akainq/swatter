import { useEffect, useMemo, useState } from "react";
import { Link, useParams } from "react-router";
import { fetchTrace } from "../api/client";
import type { TraceSpan } from "../api/client";

interface SpanNode {
  span: TraceSpan;
  depth: number;
}

// Trace waterfall (ADR-0014): дерево спанов трейса по всем проектам
// организации (кросс-сервисно), бары — относительно окна всего трейса.
export default function TracePage() {
  const { orgSlug = "", traceId = "" } = useParams();
  const [spans, setSpans] = useState<TraceSpan[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetchTrace(orgSlug, traceId)
      .then((trace) => {
        if (!cancelled) setSpans(trace.spans);
      })
      .catch((err) => {
        if (!cancelled) setError(String(err));
      });
    return () => {
      cancelled = true;
    };
  }, [orgSlug, traceId]);

  const { nodes, minStart, total, multiProject } = useMemo(() => layout(spans ?? []), [spans]);

  if (error) return <div className="page error-text">{error}</div>;
  if (!spans) return <div className="page muted">Loading…</div>;

  return (
    <div className="page">
      <div className="page-header">
        <div>
          <h2>
            Trace <code className="event-id">{traceId.slice(0, 16)}</code>
          </h2>
          <p className="muted small">
            {spans.length} spans · {Math.round(total)} ms total
          </p>
        </div>
      </div>

      <div className="card waterfall">
        {nodes.map(({ span, depth }) => {
          const left = ((toMs(span.startTs) - minStart) / total) * 100;
          const width = Math.max((span.durationMs / total) * 100, 0.4);

          return (
            <div className="wf-row" key={span.spanId}>
              <div className="wf-label" style={{ paddingLeft: `${depth * 16}px` }}>
                <span className={span.isSegment ? "wf-op segment" : "wf-op"}>{span.op || "span"}</span>
                <span className="wf-desc" title={span.description}>
                  {span.description || span.transaction}
                </span>
                {multiProject && span.projectSlug && (
                  <span className="badge project-badge">{span.projectSlug}</span>
                )}
              </div>
              <div className="wf-track">
                <span
                  className={span.isSegment ? "wf-bar segment" : "wf-bar"}
                  style={{ left: `${left}%`, width: `${width}%` }}
                />
                <span className="wf-ms" style={{ left: `${Math.min(left + width, 92)}%` }}>
                  {span.durationMs} ms
                </span>
              </div>
            </div>
          );
        })}
      </div>

      <p className="muted small">
        <Link to={`/${orgSlug}/projects`} className="muted">
          ← projects
        </Link>
      </p>
    </div>
  );
}

function toMs(iso: string): number {
  return new Date(iso).getTime();
}

// дерево по parent_span_id → плоский DFS-список с глубиной; сироты
// (родитель не в трейсе, например сегмент соседнего сервиса) — корни
function layout(spans: TraceSpan[]) {
  const byId = new Map(spans.map((s) => [s.spanId, s]));
  const children = new Map<string, TraceSpan[]>();
  const roots: TraceSpan[] = [];

  for (const span of spans) {
    if (span.parentSpanId && byId.has(span.parentSpanId)) {
      const list = children.get(span.parentSpanId) ?? [];
      list.push(span);
      children.set(span.parentSpanId, list);
    } else {
      roots.push(span);
    }
  }

  const byStart = (a: TraceSpan, b: TraceSpan) => toMs(a.startTs) - toMs(b.startTs);
  const nodes: SpanNode[] = [];

  const visit = (span: TraceSpan, depth: number) => {
    nodes.push({ span, depth });
    for (const child of (children.get(span.spanId) ?? []).sort(byStart)) {
      visit(child, depth + 1);
    }
  };

  for (const root of roots.sort(byStart)) visit(root, 0);

  const minStart = Math.min(...spans.map((s) => toMs(s.startTs)), Infinity);
  const maxEnd = Math.max(...spans.map((s) => toMs(s.endTs)), 0);
  const total = Math.max(maxEnd - minStart, 1);
  const multiProject = new Set(spans.map((s) => s.projectSlug)).size > 1;

  return { nodes, minStart, total, multiProject };
}
