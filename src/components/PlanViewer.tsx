import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, FileJson, ShieldAlert } from "lucide-react";
import { importDiagnosticPlan, type DiagnosticPlan, type PlanDecision } from "../engine/diagnosticPlan";
import { MAX_ARTIFACT_BYTES } from "../engine/artifactImport";
import { integer } from "../format";

const PAGE = 40;
const reasonText: Record<string, string> = { bitmap_hit: "Observed dependency", changed_spec: "Changed spec", unindexed_spec: "New / unindexed spec", prism_hazard: "Prism hazard", root_scope_fallback: "Root-scope fallback", incomplete_index_fallback: "Full-suite fallback", previous_failure: "Previous failure" };
const fallbackText: Record<string, string> = { incomplete_index: "Incomplete index", root_scope_changed: "Root-scope change", spec_universe_changed: "Discovered specs differ from baseline", unmapped_changes: "Unmapped changes", previous_failures_unavailable: "Previous failures unavailable", previous_failures_unmatched: "Previous failures unmatched" };

export function PlanViewer({ onArtifacts, onSimulator, compact }: { onArtifacts: () => void; onSimulator: () => void; compact: boolean }) {
  const [plan, setPlan] = useState<DiagnosticPlan | null>(null);
  const [error, setError] = useState("");
  const [selected, setSelected] = useState<string | null>(null);
  const [change, setChange] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [candidateOnly, setCandidateOnly] = useState(false);
  const [page, setPage] = useState(0);
  const [pane, setPane] = useState<"changes" | "specs" | "details">("specs");
  useEffect(() => {
    const controller = new AbortController();
    async function load() {
      try {
        const response = await fetch("./artifacts/plan.json", { signal: controller.signal, credentials: "omit", mode: "same-origin", redirect: "error", cache: "no-store" });
        if (!response.ok) throw new Error(`Unable to read project plan (HTTP ${response.status}).`);
        const length = response.headers.get("content-length");
        if (length && Number(length) > MAX_ARTIFACT_BYTES) throw new Error("Diagnostic plan exceeds the 10 MiB limit.");
        const bytes = await response.arrayBuffer();
        if (bytes.byteLength > MAX_ARTIFACT_BYTES) throw new Error("Diagnostic plan exceeds the 10 MiB limit.");
        const result = importDiagnosticPlan(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
        if (!controller.signal.aborted) { setPlan(result); setSelected(result.decisions[0]?.spec ?? null); }
      } catch (e) { if (!controller.signal.aborted) setError(e instanceof Error ? e.message : "Unable to read project plan."); }
    }
    void load();
    return () => controller.abort();
  }, []);
  const filtered = useMemo(() => {
    if (!plan) return [];
    const root = change !== null && plan.root_changes.includes(change);
    return plan.decisions.filter(d => (!candidateOnly || d.candidate) && d.spec.toLowerCase().includes(query.toLowerCase()) && (!change || root || d.bitmap_sources.includes(change) || (d.spec === change && d.changed_spec)));
  }, [plan, change, candidateOnly, query]);
  const decision = plan?.decisions.find(d => d.spec === selected);
  function chooseChange(path: string | null) { setChange(path); setPage(0); if (compact) setPane("specs"); }
  function chooseSpec(item: PlanDecision) { setSelected(item.spec); if (compact) setPane("details"); }
  return <div className="artifact-frame plan-frame">
    <header className="artifact-header"><div className="brand"><span aria-hidden="true">//</span>CLEAVE</div><span className="artifact-header-title">Project plan</span><span className="artifact-local">Startup snapshot · loopback</span><button type="button" onClick={onArtifacts}><FileJson size={14}/> Artifacts</button><button type="button" onClick={onSimulator}><ArrowLeft size={14}/> Simulator</button></header>
    <div className="artifact-warning"><ShieldAlert size={16}/><span><strong>Diagnostic only.</strong> Candidate specs are not an execution list. Run the full configured suite.</span></div>
    {error ? <div className="artifact-empty"><p className="artifact-error" role="alert">{error}</p><span>No plan is shown. Restart the CLI to retry.</span></div> : !plan ? <div className="artifact-empty"><strong>Loading project plan…</strong><span>Validating the startup snapshot.</span></div> : <>
      <section className="plan-summary" aria-label="Plan summary"><div><span className="eyebrow">Current project · startup snapshot</span><h1>Diagnostic selection</h1><p>Restart <code>cleave ui --plan</code> to refresh. Discovery loaded spec files; suite coverage is unverified.</p></div><div className="plan-metrics"><div><strong>{integer(plan.changes.added.length + plan.changes.deleted.length + plan.changes.modified.length)}</strong><span>changed paths</span></div><div><strong>{integer(plan.candidate_specs.length)}</strong><span>candidate specs</span></div><div><strong>{integer(plan.discovered_specs.length)}</strong><span>discovered specs</span></div><div><strong>{integer(plan.union_nanoseconds)}</strong><span>bitmap OR · ns</span></div></div></section>
      {compact && <nav className="artifact-mobile-tabs" aria-label="Plan panels">{([['changes', 'Changes'], ['specs', 'Specs'], ['details', 'Details']] as const).map(([id, label]) => <button type="button" key={id} aria-pressed={pane === id} onClick={() => setPane(id)}>{label}</button>)}</nav>}
      <main className="plan-workspace">
        {(!compact || pane === "changes") && <section className="plan-column" aria-label="Changed paths"><div className="artifact-panel-head"><span className="eyebrow">Current vs baseline</span><h2>Changes</h2><p>Select a path to filter its associated specs.</p></div><div className="plan-scroll plan-changes">{(['added', 'modified', 'deleted'] as const).map(kind => <div key={kind}><div className="plan-group-heading"><span>{kind}</span><span className="mono">{integer(plan.changes[kind].length)}</span></div>{plan.changes[kind].map(path => <button key={path} type="button" aria-pressed={change === path} title={path} onClick={() => chooseChange(change === path ? null : path)}><span className={plan.root_changes.includes(path) ? "plan-root" : "plan-change-symbol"}>{plan.root_changes.includes(path) ? "r" : kind === 'added' ? '+' : kind === 'deleted' ? '−' : '•'}</span><span className="mono">{path}</span></button>)}</div>)}{!Object.values(plan.changes).some(paths => paths.length) && <p className="artifact-none">No inventoried changes.</p>}</div></section>}
        {(!compact || pane === "specs") && <section className="plan-column" aria-label="Discovered specs"><div className="artifact-panel-head"><span className="eyebrow">Diagnostic candidate</span><h2>Discovered specs</h2><label><span className="sr-only">Search discovered specs</span><input type="search" value={query} placeholder="Search spec paths" onChange={e => { setQuery(e.target.value); setPage(0); }}/></label><div className="plan-filter"><label><input type="checkbox" checked={candidateOnly} onChange={e => { setCandidateOnly(e.target.checked); setPage(0); }}/> Candidates only</label><span>{integer(filtered.length)} shown</span></div>{change && <div className="plan-active-filter"><span>Path: <code>{change}</code>{plan.root_changes.includes(change) ? " · root fallback" : ""}</span><button onClick={() => chooseChange(null)}>Clear</button></div>}</div><div className="plan-scroll plan-spec-list">{filtered.slice(page * PAGE, (page + 1) * PAGE).map(item => <button type="button" key={item.spec} aria-pressed={selected === item.spec} onClick={() => chooseSpec(item)}><span className={item.candidate ? "plan-candidate" : "plan-not-candidate"}>{item.candidate ? "●" : "○"}</span><span className="mono">{item.spec}</span><span className="plan-row-label">{item.candidate ? "candidate" : "fallback"}</span></button>)}{!filtered.length && <p className="artifact-none">No specs match this filter. Guardrails and full-suite fallback still apply.</p>}</div><div className="artifact-pager"><span>{filtered.length ? `${page * PAGE + 1}–${Math.min((page + 1) * PAGE, filtered.length)} / ${filtered.length}` : "0 / 0"}</span><button disabled={page === 0} onClick={() => setPage(page - 1)}>Previous</button><button disabled={(page + 1) * PAGE >= filtered.length} onClick={() => setPage(page + 1)}>Next</button></div></section>}
        {(!compact || pane === "details") && <section className="plan-column" aria-label="Plan details">{decision ? <><div className="artifact-panel-head"><span className="eyebrow">Selected spec · {decision.candidate ? "candidate" : "full-suite fallback"}</span><h2 className="mono artifact-path-title">{decision.spec}</h2><p>All discovered specs remain subject to full-suite fallback.</p></div><div className="plan-scroll plan-detail"><h3>Attribution</h3><ul>{decision.reasons.map(reason => <li key={reason}>{reasonText[reason] ?? reason}</li>)}</ul><h3>Observed changed paths</h3>{decision.bitmap_sources.length ? <ul className="mono">{decision.bitmap_sources.map(path => <li key={path}>{path}</li>)}</ul> : <p>No recorded bitmap hits for changed paths.</p>}<h3>Prism hazards</h3>{decision.hazards.length ? <ul>{decision.hazards.map((h, i) => <li key={`${h.line}:${h.column}:${i}`}><span className="mono">{h.name}</span> · {h.node_type} · line {h.line}, byte column {h.column}</li>)}</ul> : <p>No recorded hazards in this spec.</p>}<h3>Fallback reasons</h3><ul>{plan.fallback_reasons.map(reason => <li key={reason}>{fallbackText[reason] ?? reason}</li>)}</ul><h3>Previous failures</h3>{plan.previous_failures_available ? <><p>Latest run observations · unsigned, coverage unverified.</p>{plan.unmatched_previous_failures.length > 0 && <><p>Not in the discovered suite:</p><ul className="mono">{plan.unmatched_previous_failures.map(path => <li key={path}>{path}</li>)}</ul></>}<p>Source SHA-256: <span className="mono">{plan.previous_failures_source_sha256}</span></p></> : <p>Not requested. Use <code>--previous-failures</code> to include the latest completed run.</p>}<h3>Coverage limitations</h3><ul>{plan.limitations.map(limit => <li key={limit}>{limit}</li>)}</ul><h3>Snapshot fingerprints</h3><dl><dt>Baseline</dt><dd className="mono">{plan.baseline_fingerprint}</dd><dt>Current</dt><dd className="mono">{plan.current_fingerprint}</dd></dl><p>Fingerprints detect content differences; they do not establish artifact provenance.</p></div></> : <p className="artifact-none">Select a spec to inspect its attribution.</p>}</section>}
      </main>
    </>}
    <footer className="artifact-footer">Real project plan · startup snapshot · full-suite fallback required</footer>
  </div>;
}
