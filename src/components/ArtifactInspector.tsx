import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowLeft, FileJson, ShieldAlert } from "lucide-react";
import { importArtifacts, MAX_ARTIFACT_BYTES, type ImportedArtifacts } from "../engine/artifactImport";
import { integer } from "../format";

const PAGE_SIZE = 40;
async function readArtifact(file: File): Promise<string> {
  if (file.size > MAX_ARTIFACT_BYTES) throw new Error(`${file.name} exceeds the 10 MiB limit.`);
  try { return new TextDecoder("utf-8", { fatal: true }).decode(await file.arrayBuffer()); }
  catch { throw new Error(`${file.name} could not be read as UTF-8.`); }
}
export function ArtifactInspector({ onBack, onPlan, compact, localMode = false }: { onBack: () => void; onPlan?: () => void; compact: boolean; localMode?: boolean }) {
  const [inventoryFile, setInventoryFile] = useState<File | null>(null);
  const [indexFile, setIndexFile] = useState<File | null>(null);
  const [data, setData] = useState<ImportedArtifacts | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(localMode);
  const [source, setSource] = useState<"project" | "manual" | null>(null);
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState<string | null>(null);
  const [filePage, setFilePage] = useState(0);
  const [specPage, setSpecPage] = useState(0);
  const [inspectedSpec, setInspectedSpec] = useState<string | null>(null);
  const [pane, setPane] = useState<"files" | "details">("files");
  const request = useRef(0);
  const filtered = useMemo(() => data?.files.filter(f => f.path.toLowerCase().includes(search.toLowerCase())) ?? [], [data, search]);
  const file = data?.files.find(f => f.path === selected);
  const associated = useMemo(() => data && file ? data.specs.filter((_, id) => (file.mask & (1n << BigInt(id))) !== 0n) : [], [data, file]);
  const specPaths = useMemo(() => {
    if (!data || inspectedSpec === null) return [];
    const id = data.specs.indexOf(inspectedSpec);
    return id < 0 ? [] : data.files.filter(f => (f.mask & (1n << BigInt(id))) !== 0n);
  }, [data, inspectedSpec]);
  useEffect(() => {
    if (!localMode) return;
    const controller = new AbortController();
    const token = ++request.current;
    setBusy(true);
    async function loadProject() {
      try {
        const read = async (name: string) => {
          const response = await fetch(`./artifacts/${name}`, { signal: controller.signal, credentials: "omit", mode: "same-origin", redirect: "error", cache: "no-store" });
          if (!response.ok) throw new Error(`Unable to read project ${name} (HTTP ${response.status}).`);
          const length = response.headers.get("content-length");
          if (length && Number(length) > MAX_ARTIFACT_BYTES) throw new Error(`${name} exceeds the 10 MiB limit.`);
          const bytes = await response.arrayBuffer();
          if (bytes.byteLength > MAX_ARTIFACT_BYTES) throw new Error(`${name} exceeds the 10 MiB limit.`);
          return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
        };
        const [inv, idx] = await Promise.all([read("inventory.json"), read("bitmap_index.json")]);
        const result = importArtifacts(inv, idx);
        if (token !== request.current || controller.signal.aborted) return;
        setData(result); setSource("project"); setSelected(result.files[0]?.path ?? null); setError("");
      } catch (e) {
        if (token === request.current && !controller.signal.aborted) { setData(null); setSource(null); setError(e instanceof Error ? e.message : "Unable to load project artifacts."); }
      } finally { if (token === request.current && !controller.signal.aborted) setBusy(false); }
    }
    void loadProject();
    return () => controller.abort();
  }, [localMode]);
  function changed() { request.current++; setData(null); setSource(null); setError(""); setBusy(false); setSelected(null); setInspectedSpec(null); setSearch(""); setFilePage(0); setSpecPage(0); }
  async function load() {
    if (!inventoryFile || !indexFile || busy) return;
    const token = ++request.current; setBusy(true); setError("");
    try {
      const [inv, idx] = await Promise.all([readArtifact(inventoryFile), readArtifact(indexFile)]);
      const result = importArtifacts(inv, idx);
      if (token !== request.current) return;
      setData(result); setSource("manual"); setSelected(result.files[0]?.path ?? null); setInspectedSpec(null); setSearch(""); setFilePage(0); setSpecPage(0); setPane("files");
    } catch (e) {
      if (token === request.current) { setData(null); setError(e instanceof Error ? e.message : "Unable to import artifacts."); }
    } finally { if (token === request.current) setBusy(false); }
  }
  return <div className="artifact-frame">
    <header className="artifact-header"><div className="brand"><span aria-hidden="true">//</span>CLEAVE</div><span className="artifact-header-title">Artifact inspector</span><span className="artifact-local">{source === "project" ? "Project snapshot · loopback" : "Local files only"}</span>{onPlan && <button type="button" onClick={onPlan}>Project plan</button>}<button type="button" onClick={onBack}><ArrowLeft size={14}/> Simulator</button></header>
    <div className="artifact-warning"><ShieldAlert size={16}/><span><strong>Incomplete index.</strong> Recorded observations only. Never use this data to skip tests.</span></div>
    <section className="artifact-import" aria-label="Import artifact pair">
      <div className="artifact-intro"><span className="eyebrow">Artifact pair · v1</span><h1>Inspect real observations</h1><p>{source === "project" ? "Showing the CLI’s startup snapshot. Restart the CLI to refresh; or import another pair below." : "Choose the inventory and bitmap index produced together by Cleave. Files stay in this browser."}</p></div>
      <div className="artifact-inputs"><label><span>Inventory JSON</span><input type="file" accept=".json,application/json" onChange={e => { changed(); setInventoryFile(e.target.files?.[0] ?? null); }}/></label><label><span>Bitmap index JSON</span><input type="file" accept=".json,application/json" onChange={e => { changed(); setIndexFile(e.target.files?.[0] ?? null); }}/></label><button type="button" className="artifact-load" disabled={!inventoryFile || !indexFile || busy} onClick={load}>{busy ? "Validating…" : "Load artifacts"}</button></div>
      {error && <p className="artifact-error" role="alert">{error}</p>}
    </section>
    {!data ? <div className="artifact-empty"><FileJson size={24}/><strong>{busy && localMode ? "Loading project artifacts…" : "No artifacts loaded"}</strong><span>{busy && localMode ? "Validating the loopback snapshot." : "Import a matching v1 pair to explore its recorded paths and spec associations."}</span></div> : <>
      <div className="artifact-meta"><span><strong>{integer(data.files.filter(f => f.sha256 !== null).length)}</strong> inventory files</span><span><strong>{integer(data.specs.length)}</strong> indexed specs</span><span><strong>{integer(data.files.filter(f => f.root).length)}</strong> root paths</span><span className="artifact-fingerprint mono" title={data.fingerprint}>Inventory {data.fingerprint}</span></div>
      {compact && <nav className="artifact-mobile-tabs" aria-label="Artifact panels"><button type="button" aria-pressed={pane === "files"} onClick={() => setPane("files")}>Paths</button><button type="button" aria-pressed={pane === "details"} onClick={() => setPane("details")}>Relationships</button></nav>}
      <main className="artifact-workspace">
        {(!compact || pane === "files") && <section className="artifact-paths" aria-label="Artifact paths"><div className="artifact-panel-head"><span className="eyebrow">Inventory + observations</span><h2>Paths</h2><label><span className="sr-only">Search artifact paths</span><input type="search" value={search} placeholder="Search paths" onChange={e => { setSearch(e.target.value); setFilePage(0); }}/></label><p>{integer(filtered.length)} matching paths</p></div><div className="artifact-path-list">{filtered.slice(filePage * PAGE_SIZE, (filePage + 1) * PAGE_SIZE).map(f => <button type="button" key={f.path} aria-pressed={f.path === selected} title={f.path} onClick={() => { setSelected(f.path); setInspectedSpec(null); setSpecPage(0); if (compact) setPane("details"); }}><span className={f.root ? "artifact-root" : "artifact-dot"}>{f.root ? "r" : "·"}</span><span className="mono">{f.path}</span></button>)}{!filtered.length && <p className="artifact-none">No matching paths.</p>}</div><div className="artifact-pager"><span>{filtered.length ? `${filePage * PAGE_SIZE + 1}–${Math.min((filePage + 1) * PAGE_SIZE, filtered.length)} / ${filtered.length}` : "0 / 0"}</span><button disabled={filePage === 0} onClick={() => setFilePage(filePage - 1)}>Previous</button><button disabled={(filePage + 1) * PAGE_SIZE >= filtered.length} onClick={() => setFilePage(filePage + 1)}>Next</button></div></section>}
        {(!compact || pane === "details") && <section className="artifact-details" aria-label="Observed relationships">{inspectedSpec !== null ? <><div className="artifact-panel-head"><span className="eyebrow">Indexed spec</span><h2 className="mono artifact-path-title">{inspectedSpec}</h2><p>Observed paths associated with this spec · missing edges do not prove independence.</p></div><div className="artifact-detail-scroll"><div className="artifact-edges-head"><div><span className="eyebrow">Recorded associations</span><h3>Observed paths</h3></div><span className="mono">{integer(specPaths.length)}</span></div><div className="artifact-specs">{specPaths.slice(specPage * PAGE_SIZE, (specPage + 1) * PAGE_SIZE).map(f => <button type="button" className="artifact-spec artifact-association mono" key={f.path} onClick={() => { setSelected(f.path); setInspectedSpec(null); setSpecPage(0); }}><span>↳</span>{f.path}</button>)}{!specPaths.length && <p className="artifact-none">No per-spec associations recorded.</p>}</div></div><div className="artifact-pager"><span>{specPaths.length ? `${specPage * PAGE_SIZE + 1}–${Math.min((specPage + 1) * PAGE_SIZE, specPaths.length)} / ${specPaths.length}` : "0 / 0"}</span><button disabled={specPage === 0} onClick={() => setSpecPage(specPage - 1)}>Previous</button><button disabled={(specPage + 1) * PAGE_SIZE >= specPaths.length} onClick={() => setSpecPage(specPage + 1)}>Next</button></div></> : file ? <><div className="artifact-panel-head"><span className="eyebrow">Selected path</span><h2 className="mono artifact-path-title">{file.path}</h2><p>{file.root ? "Recorded in root scope" : "Not recorded in root scope"} · {file.sha256 ? "Present in baseline inventory" : "Absent from baseline inventory"}</p></div><div className="artifact-detail-scroll">{data.specs.includes(file.path) && <button type="button" className="artifact-spec-lookup" onClick={() => { setInspectedSpec(file.path); setSpecPage(0); }}>Inspect this spec’s observed paths</button>}<div className="artifact-hash"><span className="eyebrow">Baseline SHA-256</span><code>{file.sha256 ?? "Unavailable · path not in inventory"}</code></div>{file.root && <div className="artifact-root-note">Root scope has no individual spec attribution. A change to this path triggers diagnostic full-suite fallback.</div>}<div className="artifact-edges-head"><div><span className="eyebrow">Recorded associations</span><h3>Observed specs</h3></div><span className="mono">{integer(associated.length)}</span></div><p className="artifact-explainer">Bitmap observations combine operation types, attempts and successes. Missing edges do not prove independence.</p><div className="artifact-specs">{associated.slice(specPage * PAGE_SIZE, (specPage + 1) * PAGE_SIZE).map(s => <button type="button" className="artifact-spec artifact-association mono" key={s} onClick={() => { setInspectedSpec(s); setSpecPage(0); }}><span>↳</span>{s}</button>)}{associated.length === 0 && <p className="artifact-none">No per-spec associations recorded.</p>}</div></div><div className="artifact-pager"><span>{associated.length ? `${specPage * PAGE_SIZE + 1}–${Math.min((specPage + 1) * PAGE_SIZE, associated.length)} / ${associated.length}` : "0 / 0"}</span><button disabled={specPage === 0} onClick={() => setSpecPage(specPage - 1)}>Previous</button><button disabled={(specPage + 1) * PAGE_SIZE >= associated.length} onClick={() => setSpecPage(specPage + 1)}>Next</button></div></> : <div className="artifact-none">No paths in this artifact pair.</div>}</section>}
        {!compact && <aside className="artifact-context"><div className="artifact-panel-head"><span className="eyebrow">Artifact context</span><h2>Coverage limits</h2></div><div className="artifact-context-scroll"><p>These are baseline artifacts, not a current diff or a live trace.</p><h3>Recorded limitations</h3><ul>{data.limitations.map(l => <li key={l}>{l}</li>)}</ul><h3>Not included</h3><dl><div><dt>Source / AST</dt><dd>Unavailable</dd></div><div><dt>Timing</dt><dd>Unavailable</dd></div><div><dt>Shadow audit</dt><dd>Unavailable</dd></div><div><dt>Suite coverage</dt><dd>Unverified</dd></div></dl></div></aside>}
      </main>
      {compact && <details className="artifact-limits"><summary>Coverage limits · source, AST, timings and audit unavailable</summary><ul>{data.limitations.map(l => <li key={l}>{l}</li>)}</ul></details>}
    </>}
    <footer className="artifact-footer">Imported artifact inspector · diagnostic only · full-suite fallback required</footer>
  </div>;
}
