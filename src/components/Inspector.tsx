import { useEffect, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import {
  ArrowDown,
  ArrowRight,
  Braces,
  ChevronRight,
  FileCode2,
  FileDiff,
  GitFork,
  Layers2,
  Radar,
  Search,
  ShieldAlert,
  X,
} from "lucide-react";
import {
  basename,
  bitIndex,
  edgeLabels,
  integer,
  percent,
  reasons,
} from "../format";
import {
  snapshot,
  useWorkbench,
  type InspectorTarget,
} from "../state/workbench";
import type { PrismAstNodeSummary } from "../types/cleave";
import { Reason } from "./ExecutionMatrix";

function CodeAndAst({
  source,
  nodes,
  path,
}: {
  source: string;
  nodes: PrismAstNodeSummary[];
  path: string;
}) {
  const [activeLine, setActiveLine] = useState<number>();
  const code = useRef<HTMLOListElement>(null);
  const ruby = path.endsWith(".rb");
  return (
    <>
      <section className="detail-section">
        <div className="detail-label">
          <Braces size={14} />
          <h3>Prism AST landmarks</h3>
          <span>{nodes.length}</span>
        </div>
        {nodes.length ? (
          <div className="ast-list">
            {nodes.map((n, i) => (
              <button
                key={i}
                className={n.isDynamicHazard ? "ast-hazard" : ""}
                title={n.snippet}
                onClick={() => {
                  setActiveLine(n.line);
                  code.current?.children[n.line - 1]?.scrollIntoView({
                    block: "nearest",
                  });
                }}
              >
                <span>
                  {n.isDynamicHazard ? (
                    <ShieldAlert size={13} />
                  ) : (
                    <GitFork size={13} />
                  )}
                  {n.nodeType}
                </span>
                <strong>{n.symbol}</strong>
                <small>
                  L{n.line}:{n.column}
                </small>
              </button>
            ))}
          </div>
        ) : (
          <p>
            {ruby
              ? "No recorded Prism landmarks for this preview."
              : "Non-Ruby input. There is no Prism constant tree for this file; attribution comes from scoped runtime reads."}
          </p>
        )}
      </section>
      <section className="detail-section">
        <div className="detail-label">
          <FileCode2 size={14} />
          <h3>
            {path.startsWith("spec/") && path.endsWith("_spec.rb")
              ? "Spec source"
              : "Proposed source"}
          </h3>
          <span>
            {ruby ? "Ruby / Sorbet" : path.endsWith(".json") ? "JSON" : "YAML"}
          </span>
        </div>
        <div className="source-scroll">
          <ol className="code-lines" ref={code}>
            {source
              .trimEnd()
              .split("\n")
              .map((line, i) => (
                <li
                  key={i}
                  className={i + 1 === activeLine ? "active-line" : ""}
                >
                  <span>{i + 1}</span>
                  <code>
                    {line
                      .split(
                        /("[^"\n]*"|#.*$|\b(?:class|module|def|end|do|require|require_relative|sig|extend|const|returns|params)\b)/g,
                      )
                      .map((token, j) => (
                        <b
                          className={
                            token.startsWith("#")
                              ? "code-comment"
                              : token.startsWith('"')
                                ? "code-string"
                                : j % 2
                                  ? "code-key"
                                  : undefined
                          }
                          key={j}
                        >
                          {token}
                        </b>
                      ))}
                  </code>
                </li>
              ))}
          </ol>
        </div>
      </section>
    </>
  );
}
function GroupList({ ids }: { ids: number[] }) {
  const [query, setQuery] = useState("");
  const scroll = useRef<HTMLDivElement>(null);
  const inspect = useWorkbench((s) => s.inspect);
  const filtered = ids.filter((id) =>
    snapshot.specs[id].path.includes(query.toLowerCase().trim()),
  );
  const list = useVirtualizer({
    count: filtered.length,
    getScrollElement: () => scroll.current,
    estimateSize: () => 48,
    overscan: 4,
  });
  return (
    <>
      <label className="search-box">
        <Search size={14} />
        <input
          type="search"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            if (scroll.current) scroll.current.scrollTop = 0;
          }}
          placeholder="Find an impacted spec…"
          aria-label="Find an impacted spec"
        />
      </label>
      <div className="group-list" ref={scroll}>
        <div style={{ height: list.getTotalSize(), position: "relative" }}>
          {list.getVirtualItems().map(({ index: i, start }) => {
            const s = snapshot.specs[filtered[i]];
            return (
              <button
                key={s.id}
                style={{ transform: `translateY(${start}px)` }}
                onClick={() => inspect({ type: "spec", id: s.id })}
              >
                <small>{bitIndex(s.id)}</small>
                <span>
                  <strong>{basename(s.path)}</strong>
                  <small>{s.path}</small>
                </span>
                <ChevronRight size={14} />
              </button>
            );
          })}
        </div>
        {!filtered.length && <p>No matching specs.</p>}
      </div>
    </>
  );
}
function SpecDetail({ id }: { id: number }) {
  const result = useWorkbench((s) => s.selection),
    inspect = useWorkbench((s) => s.inspect);
  const { spec, reason, hits, guardFiles: matchedPaths } = result.rows[id];
  const explanation =
    reason === "GUARDRAIL_ROOT_SCOPE"
      ? `${result.roots.map((f) => f.path).join(", ")} changed in boot scope r. No isolated test can be ruled out.`
      : reason === "GUARDRAIL_PREV_FAILURE"
        ? "This spec failed in the previous baseline. PREV_FAILED_MASK keeps it in the execution set, even without a source hit."
        : reason === "GUARDRAIL_PRISM_GLOB"
          ? `${spec.hazardDetail} is a directory read. ${matchedPaths.length ? `The watched pattern matches ${matchedPaths.map((f) => f.path).join(", ")}.` : "Its pattern is not bounded by a literal directory, so the linter is mandatory."}`
          : reason === "SKIPPED"
            ? `None of this spec’s baseline accesses intersects the current diff. No mandatory mask sets bit ${id}.`
            : `Bit ${id} is set in ${hits.length === 1 ? "a changed file’s bitmap" : `${hits.length} changed-file bitmaps`}. OR carries it into FINAL_EXECUTION_MASK.`;
  return (
    <>
      <div className="inspector-path">{spec.path}</div>
      <section className="detail-section">
        <div className="detail-label">
          <GitFork size={14} />
          <h3>Selection attribution</h3>
        </div>
        <Reason reason={reason} />
        <p>{explanation}</p>
        <div className="trace-list">
          {hits.map(({ file, kind }) => (
            <button
              key={file.id}
              onClick={() => inspect({ type: "file", id: file.id })}
            >
              <FileDiff size={14} />
              <span>
                {file.path}
                <small>{edgeLabels[kind]}</small>
              </span>
              <ChevronRight size={13} />
            </button>
          ))}
        </div>
        {reason === "SKIPPED" && spec.accessedFileIds.length > 0 && (
          <div className="trace-list">
            {spec.accessedFileIds.map((f) => (
              <button key={f} onClick={() => inspect({ type: "file", id: f })}>
                <FileCode2 size={13} />
                <span>
                  {snapshot.files[f].path}
                  <small>Unmodified access</small>
                </span>
                <ChevronRight size={13} />
              </button>
            ))}
          </div>
        )}
        <div className="scope-chain">
          <span>root (r)</span>
          <ArrowRight />
          <span>fork()</span>
          <ArrowRight />
          <strong>spec {bitIndex(spec.id)}</strong>
        </div>
      </section>
      <CodeAndAst
        source={spec.rubySpecPreview}
        nodes={spec.astNodes}
        path={spec.path}
      />
    </>
  );
}
function FileDetail({ id }: { id: number }) {
  const result = useWorkbench((s) => s.selection),
    lazy = useWorkbench((s) => s.lazyRoot),
    inspect = useWorkbench((s) => s.inspect);
  const file = snapshot.files[id],
    modified = result.changed.includes(file);
  const root = file.scope === "ROOT" && !(id === snapshot.lazyRootId && lazy);
  return (
    <>
      <div className="inspector-path">{file.path}</div>
      <section className="detail-section">
        <div className="detail-label">
          <GitFork size={14} />
          <h3>Scope attribution</h3>
        </div>
        <div className="scope-chain">
          <span>root (r)</span>
          <ArrowRight />
          {!root && (
            <>
              <span>fork()</span>
              <ArrowRight />
            </>
          )}
          <strong className={root ? "red-text" : ""}>
            {root ? "boot preload" : "isolated test"}
          </strong>
        </div>
        <p>
          {root
            ? "This file is opened before per-spec recording begins. Changing it forces a full-suite run."
            : file.baselineSha256
              ? "Only recorded isolated readers contribute to this file’s bitmap. Mandatory masks are applied separately."
              : "New migration: the baseline has no reads of this path. A watched directory can still select its linters."}
        </p>
        {file.impactedTestIds.length > 0 && (
          <button
            className="inspect-link"
            onClick={() =>
              inspect({
                type: "group",
                title: `Readers of ${basename(file.path)}`,
                specIds: file.impactedTestIds,
              })
            }
          >
            <Layers2 size={14} />
            Inspect {file.impactedTestIds.length} isolated readers
            <ChevronRight size={13} />
          </button>
        )}
      </section>
      <section className="detail-section">
        <div className="detail-label">
          <FileDiff size={14} />
          <h3>SHA-256 inventory</h3>
        </div>
        <div className="digest">
          <small>Baseline</small>
          <code>{file.baselineSha256 || "Absent · new file"}</code>
          <ArrowDown size={12} />
          <small>{modified ? "Modified" : "Current"} content</small>
          <code>
            {(modified ? file.currentSha256 : file.baselineSha256) ||
              "Not added to this diff"}
          </code>
        </div>
      </section>
      <CodeAndAst
        source={file.rubySourcePreview}
        nodes={file.astNodes}
        path={file.path}
      />
    </>
  );
}
function AuditDetail() {
  const result = useWorkbench((s) => s.selection),
    inspect = useWorkbench((s) => s.inspect);
  return (
    <section className="detail-section">
      <div className="audit-callout">
        <Radar size={22} />
        <strong>
          {result.missed
            ? `${result.missed.length} false negatives`
            : "No recorded replay"}
        </strong>
        <small>SIMULATED FULL-SUITE BASELINE</small>
      </div>
      <p>
        Shadow verification asks one question: did any spec that failed in a
        full-suite run have a zero bit in the selected mask?
      </p>
      {result.shadow && result.missed ? (
        <>
          <p>
            This fixture records{" "}
            <b>{result.shadow.observedFailureIds.length}</b> failing specs for
            this exact diff.{" "}
            <b>
              {percent(
                result.missed.length,
                result.shadow.observedFailureIds.length,
              )}
            </b>{" "}
            were missed. This is a deterministic replay, not a live CI result.
          </p>
          <div className="trace-list">
            {result.shadow.observedFailureIds.map((id) => (
              <button key={id} onClick={() => inspect({ type: "spec", id })}>
                <FileCode2 size={14} />
                <span>
                  {snapshot.specs[id].path}
                  <small>{reasons[result.rows[id].reason].label}</small>
                </span>
                <ChevronRight size={13} />
              </button>
            ))}
          </div>
        </>
      ) : (
        <p>
          No full-suite baseline was supplied for this custom diff. A zero
          false-negative rate cannot be inferred from a selection alone.
        </p>
      )}
      <h3 className="eyebrow verify-title">CLI verification</h3>
      <code className="verify-command">bundle exec cleave --verify</code>
      <p>
        In a CLI with shadow verification, compare the full-suite outcomes
        against the would-be skips before enforcing selection. This browser demo
        does not execute Ruby or tests.
      </p>
    </section>
  );
}
function Drawer({ target }: { target: InspectorTarget }) {
  const dialog = useRef<HTMLDialogElement>(null),
    body = useRef<HTMLDivElement>(null);
  const inspect = useWorkbench((s) => s.inspect);
  useEffect(() => {
    const d = dialog.current!;
    d.showModal();
    return () => d.close();
  }, []);
  useEffect(() => {
    if (body.current) body.current.scrollTop = 0;
  }, [target]);
  const file =
    target.type === "file"
      ? snapshot.files[target.id]
      : target.type === "spec"
        ? snapshot.specs[target.id]
        : null;
  const title =
    target.type === "audit"
      ? "Shadow audit"
      : target.type === "group"
        ? target.title
        : basename(file!.path);
  return (
    <dialog
      ref={dialog}
      className="drawer"
      aria-labelledby="inspector-title"
      onCancel={(e) => {
        e.preventDefault();
        inspect(null);
      }}
      onClick={(e) => {
        if (e.target === dialog.current) inspect(null);
      }}
    >
      <div className="drawer-inner">
        <header>
          <div className="section-kicker">
            <span>04</span> /{" "}
            {target.type === "audit" ? "VERIFICATION" : "SOURCE INSPECTOR"}
          </div>
          <button
            aria-label="Close inspector"
            className="icon-btn"
            autoFocus
            onClick={() => inspect(null)}
          >
            <X size={16} />
          </button>
        </header>
        <div className="drawer-body" ref={body}>
          <div className="eyebrow drawer-type">
            {target.type === "spec"
              ? `RSPEC FILE · BIT ${bitIndex(target.id)}`
              : target.type === "file"
                ? "REPOSITORY FILE"
                : target.type === "group"
                  ? `${integer(target.specIds.length)} ENDPOINTS`
                  : "BASELINE REPLAY"}
          </div>
          <h2 id="inspector-title">{title}</h2>
          {target.type === "spec" ? (
            <SpecDetail key={`s${target.id}`} id={target.id} />
          ) : target.type === "file" ? (
            <FileDetail key={`f${target.id}`} id={target.id} />
          ) : target.type === "group" ? (
            <GroupList ids={target.specIds} />
          ) : (
            <AuditDetail />
          )}
        </div>
        <footer>
          pay-server-mini <span>ESC to close</span>
        </footer>
      </div>
    </dialog>
  );
}
export function Inspector() {
  const target = useWorkbench((s) => s.target);
  return target && <Drawer target={target} />;
}
