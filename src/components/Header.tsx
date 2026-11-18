import {
  ArrowDownRight,
  ArrowRight,
  ArrowUpRight,
  Binary,
  Braces,
  ChevronDown,
  CircleCheck,
  Clock3,
  GitBranch,
  GitCompareArrows,
  Layers3,
  Radar,
} from "lucide-react";
import { duration, integer, percent } from "../format";
import { index, snapshot, useWorkbench } from "../state/workbench";
import type { ScenarioId } from "../types/cleave";

const shortTitles = [
  "Surgical edit",
  "Config edit",
  "New migration",
  "Root preload",
];
export function CommandBar({ onOpenArtifacts }: { onOpenArtifacts: () => void }) {
  const scenario = useWorkbench((s) => s.selection.scenario);
  const preset = useWorkbench((s) => s.preset);
  return (
    <header className="command-bar">
      <div className="brand" aria-label="Cleave">
        <span aria-hidden="true">//</span>CLEAVE
      </div>
      <div className="brand-sub mono">
        STE
        <br />
        WORKBENCH
      </div>
      <div className="command-spacer" />
      <button className="artifact-open" type="button" onClick={onOpenArtifacts}>Import artifacts</button>
      <nav className="preset-nav" aria-label="Commit scenarios">
        <span className="eyebrow">Commit scenario</span>
        <div className="preset-buttons">
          {snapshot.scenarios.map((p, i) => (
            <button
              key={p.id}
              type="button"
              aria-label={`Scenario ${p.id}: ${p.title}`}
              aria-pressed={scenario?.id === p.id}
              title={p.description}
              onClick={() => preset(p.id)}
            >
              <b>{p.id}</b>
              {shortTitles[i]}
            </button>
          ))}
        </div>
      </nav>
      <label className="compact-preset">
        <span className="sr-only">Commit scenario</span>
        <GitBranch size={14} />
        <select
          value={scenario?.id ?? ""}
          onChange={(e) => preset(e.target.value as ScenarioId)}
        >
          {!scenario && (
            <option value="" disabled>
              Custom diff
            </option>
          )}
          {snapshot.scenarios.map((s) => (
            <option key={s.id} value={s.id}>
              {s.id} · {s.title}
            </option>
          ))}
        </select>
        <ChevronDown size={12} />
      </label>
    </header>
  );
}
export function Overview() {
  const result = useWorkbench((s) => s.selection);
  const inspect = useWorkbench((s) => s.inspect);
  const count = snapshot.specs.length,
    saved = percent(index.baselineMs - result.selectedMs, index.baselineMs);
  return (
    <section className="overview" aria-label="Selection telemetry">
      <div className="overview-title">
        <div className="title-line">
          <h1>Selection overview</h1>
          <span className="snapshot-name">
            <GitBranch size={13} />
            {snapshot.name}
          </span>
        </div>
        <span className="engine-indicator">
          <i className="status-dot green" />
          Browser simulator
        </span>
      </div>
      <div className="metrics">
        <article className="metric primary-metric">
          <div className="metric-label">
            <Layers3 />
            Selected specs
          </div>
          <div className="metric-value">
            <strong data-testid="selected-count">
              {integer(result.selected)}
            </strong>
            <span> / {integer(count)}</span>
          </div>
          <div className="metric-foot">
            <span className="green-text">
              {percent(result.selected, count)}
            </span>{" "}
            of suite{" "}
            <div
              className="composition"
              title={`${result.direct} direct, ${result.guardrails} Prism guardrails, ${result.failures + result.rootCount} failures or root fallback`}
            >
              {[
                [result.direct, "green"],
                [result.guardrails, "amber"],
                [result.failures + result.rootCount, "red"],
              ]
                .filter(([n]) => n !== 0)
                .map(([n, tone]) => (
                  <i
                    key={tone}
                    className={`fill-${tone}`}
                    style={{ flexGrow: Number(n) }}
                  />
                ))}
            </div>
          </div>
        </article>
        <article className="metric">
          <div className="metric-label">
            <Clock3 />
            CI compute saved
          </div>
          <div className="metric-value">
            <strong>{saved}</strong>
            <ArrowDownRight className="metric-trend" />
          </div>
          <div className="metric-foot mono">
            {duration(index.baselineMs)}
            <ArrowRight size={12} />
            <span className="light">{duration(result.selectedMs)}</span>
          </div>
        </article>
        <article
          className="metric"
          title="Wall time of this union only. A sub-tick reading is below the browser clock's resolution."
        >
          <div className="metric-label">
            <Binary />
            Bitmap union
          </div>
          <div className="metric-value">
            <strong>
              {result.unionUs
                ? result.unionUs >= 1000
                  ? (result.unionUs / 1000).toFixed(2)
                  : result.unionUs.toFixed(0)
                : "< 1"}
            </strong>
            <span className="unit">
              {result.unionUs ? (result.unionUs >= 1000 ? "ms" : "µs") : "tick"}
            </span>
          </div>
          <div className="metric-foot">
            BigInt OR <em>·</em>
            <span className="mono">{Math.ceil(count / 64)} × 64-bit</span>
          </div>
        </article>
        <article className="metric">
          <div className="metric-label">
            <Braces />
            Dependency coverage
          </div>
          <div className="metric-value">
            <strong>{integer(result.staticCovered)}</strong>
            <span className="split-slash">/</span>
            <strong className="secondary-number">
              {integer(result.dynamicOnly)}
            </strong>
          </div>
          <div className="metric-foot">
            Static AST <em>/</em> Runtime only
          </div>
        </article>
        <button
          className="metric audit-metric"
          onClick={() => inspect({ type: "audit" })}
        >
          <div className="metric-label">
            <Radar />
            Shadow audit
            <ArrowUpRight className="jump" />
          </div>
          <div className="metric-value">
            {result.missed ? (
              <>
                <strong>{result.missed.length}</strong>
                <span className="unit">missed</span>
              </>
            ) : (
              <span className="no-replay">Not run</span>
            )}
          </div>
          <div className="metric-foot">
            {result.missed ? (
              <>
                <CircleCheck size={12} className="green-text" />
                <span className="mono">
                  {percent(
                    result.missed.length,
                    result.shadow!.observedFailureIds.length,
                  )}
                </span>{" "}
                in demo replay
              </>
            ) : (
              "No replay for this diff"
            )}
          </div>
        </button>
      </div>
    </section>
  );
}
export function StatusBar() {
  const selection = useWorkbench((s) => s.selection);
  return (
    <footer className="status-bar">
      <span>
        <i className="status-dot green" />
        Engine ready
      </span>
      <span>
        <GitCompareArrows size={12} />
        {selection.scenario
          ? `Scenario ${selection.scenario.id}`
          : "Custom diff"}
      </span>
      <span className="footer-tech">Prism AST + scoped file access</span>
      <span className="footer-size">
        {integer(snapshot.specs.length)}-bit index <em>/</em> local simulation
      </span>
    </footer>
  );
}
