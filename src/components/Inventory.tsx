import { useEffect, useRef, useState } from "react";
import {
  Check,
  ChevronDown,
  ChevronRight,
  FilePlus2,
  FolderClosed,
  FolderOpen,
  Search,
  X,
} from "lucide-react";
import { basename, dirname } from "../format";
import { snapshot, useWorkbench } from "../state/workbench";

const folders = [...new Set(snapshot.files.map((f) => dirname(f.path)))].sort(
  (a, b) => {
    const rank = (s: string) =>
      [
        "app/models",
        "app/services",
        "config",
        "db/migrations",
        "spec/support",
        "app/middleware",
        "spec",
      ].indexOf(s);
    return rank(a) - rank(b);
  },
);
export function Inventory() {
  const changed = useWorkbench((s) => s.selection.changed);
  const lazy = useWorkbench((s) => s.lazyRoot);
  const { toggle, clear, inspect } = useWorkbench.getState();
  const [query, setQuery] = useState(""),
    [onlyChanged, setOnlyChanged] = useState(false);
  const [closed, setClosed] = useState<Set<string>>(new Set());
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (
        e.key === "/" &&
        !e.metaKey &&
        !e.ctrlKey &&
        !e.altKey &&
        !(e.target instanceof HTMLInputElement) &&
        !document.querySelector("dialog[open]") &&
        input.current?.offsetParent
      ) {
        e.preventDefault();
        input.current.focus();
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, []);
  const ids = new Set(changed.map((f) => f.id));
  const files = snapshot.files.filter(
    (f) =>
      f.path.toLowerCase().includes(query.trim().toLowerCase()) &&
      (!onlyChanged || ids.has(f.id)),
  );
  return (
    <aside className="inventory pane" aria-label="File inventory">
      <div className="pane-intro">
        <div className="section-kicker">
          <span>01</span> / HASHDEEP
        </div>
        <div className="pane-title">
          <h2>File inventory</h2>
          <span className="count-tag">{snapshot.files.length}</span>
        </div>
      </div>
      <div className="inventory-controls">
        <label className="search-box">
          <Search size={14} />
          <input
            ref={input}
            type="search"
            aria-label="Search file paths"
            placeholder="Find a file…"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setClosed(new Set());
            }}
          />
          <kbd>/</kbd>
        </label>
        <div className="tree-filter">
          <button
            aria-pressed={!onlyChanged}
            onClick={() => setOnlyChanged(false)}
          >
            All files
          </button>
          <button
            aria-pressed={onlyChanged}
            onClick={() => setOnlyChanged(true)}
          >
            Modified <b>{ids.size}</b>
          </button>
        </div>
      </div>
      <div className="tree-scroll">
        {folders.map((folder) => {
          const group = files.filter((f) => dirname(f.path) === folder);
          if (!group.length) return null;
          const expanded = !closed.has(folder);
          return (
            <div key={folder} className="tree-group">
              <button
                className="folder"
                aria-expanded={expanded}
                onClick={() =>
                  setClosed((prev) => {
                    const next = new Set(prev);
                    if (!next.delete(folder)) next.add(folder);
                    return next;
                  })
                }
              >
                {expanded ? (
                  <ChevronDown size={12} />
                ) : (
                  <ChevronRight size={12} />
                )}
                {expanded ? (
                  <FolderOpen size={14} />
                ) : (
                  <FolderClosed size={14} />
                )}
                <span>{folder}/</span>
                <small>{group.length}</small>
              </button>
              {expanded &&
                group.map((f) => {
                  const on = ids.has(f.id),
                    root =
                      f.scope === "ROOT" &&
                      !(lazy && f.id === snapshot.lazyRootId);
                  return (
                    <div
                      className={`file-row ${on ? "modified" : ""}`}
                      key={f.id}
                    >
                      <label className="file-check" title={`Toggle ${f.path}`}>
                        <input
                          type="checkbox"
                          aria-label={`Modify ${f.path}`}
                          checked={on}
                          onChange={() => toggle(f.id)}
                        />
                        <span>{on && <Check size={12} strokeWidth={3} />}</span>
                      </label>
                      <button
                        className="file-detail"
                        onClick={() => inspect({ type: "file", id: f.id })}
                        title={`Inspect ${f.path}`}
                      >
                        <span className="file-line">
                          <span className="file-name">{basename(f.path)}</span>
                          <small title="Isolated readers">
                            {f.impactedTestIds.length}
                          </small>
                        </span>
                        <span className="file-meta">
                          <b className={root ? "root-tag" : ""}>
                            {root ? "ROOT (r)" : "TEST"}
                          </b>
                          {!f.baselineSha256 ? (
                            <span>
                              <FilePlus2 size={10} /> new file
                            </span>
                          ) : (
                            <span>{f.baselineSha256.slice(0, 6)}</span>
                          )}
                          {on && (
                            <span className="new-sha">
                              → {f.currentSha256.slice(0, 6)}
                            </span>
                          )}
                        </span>
                      </button>
                    </div>
                  );
                })}
            </div>
          );
        })}
        {!files.length && (
          <div className="empty-inline">
            {query ? "No matching paths." : "No modified files."}
            <button
              onClick={() => {
                setQuery("");
                setOnlyChanged(false);
              }}
            >
              Show all files
            </button>
          </div>
        )}
      </div>
      <div className="inventory-foot">
        <span>
          <i className="status-dot green" />
          {ids.size} modified
        </span>
        <button disabled={!ids.size} onClick={clear}>
          <X size={12} />
          Clear diff
        </button>
      </div>
    </aside>
  );
}
