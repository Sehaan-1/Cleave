import { memo, useEffect, useMemo, useState } from "react";
import {
  Background,
  Handle,
  Panel,
  Position,
  ReactFlow,
  useNodesInitialized,
  useReactFlow,
  useStore,
  type NodeProps,
} from "@xyflow/react";
import {
  ArrowDown,
  ArrowUpRight,
  Braces,
  Check,
  ChevronsRight,
  FileCode2,
  FileDiff,
  Focus,
  GitFork,
  Layers2,
  Minus,
  Plus,
  ShieldAlert,
  Waypoints,
} from "lucide-react";
import {
  familyNames,
  layoutGraph,
  traceLanes,
  type EdgeFilter,
  type TraceNode,
} from "../engine/blastGraph";
import { basename, integer } from "../format";
import { snapshot, useWorkbench } from "../state/workbench";

const TraceCard = memo(function TraceCard({ data }: NodeProps<TraceNode>) {
  const Icon =
    data.role === "source"
      ? FileDiff
      : data.role === "cluster"
        ? Layers2
        : data.role === "spec"
          ? FileCode2
          : data.family === "guard" || data.family === "root"
            ? ShieldAlert
            : Braces;
  return (
    <>
      <Handle
        type="target"
        position={Position.Left}
        isConnectable={false}
        style={{ visibility: data.role === "source" ? "hidden" : "visible" }}
      />
      <button
        className={`trace-card trace-${data.role} family-${data.family}`}
        title={`${data.title} · ${data.meta}`}
      >
        <span className="trace-icon">
          <Icon size={16} />
        </span>
        <span className="trace-text">
          <strong>{data.title}</strong>
          <small>{data.meta}</small>
        </span>
      </button>
      <Handle
        type="source"
        position={Position.Right}
        isConnectable={false}
        style={{
          visibility:
            data.role === "relay" || data.role === "source"
              ? "visible"
              : "hidden",
        }}
      />
    </>
  );
});
const nodeTypes = { trace: TraceCard };
const fitOpts = { padding: 0.07, minZoom: 0.42, maxZoom: 1.24 };
function CanvasTools({ layoutKey }: { layoutKey: string }) {
  const { fitView, zoomIn, zoomOut } = useReactFlow();
  const ready = useNodesInitialized();
  const width = useStore((s) => s.width),
    height = useStore((s) => s.height);
  useEffect(() => {
    if (ready && width && height) void fitView(fitOpts);
  }, [ready, width, height, layoutKey, fitView]);
  return (
    <Panel position="bottom-left" className="canvas-tools">
      <button aria-label="Zoom out" onClick={() => void zoomOut()}>
        <Minus />
      </button>
      <button aria-label="Zoom in" onClick={() => void zoomIn()}>
        <Plus />
      </button>
      <button
        aria-label="Fit graph to view"
        onClick={() => void fitView(fitOpts)}
      >
        <Focus />
      </button>
    </Panel>
  );
}
const filters: [EdgeFilter, string][] = [
  ["all", "All edges"],
  ["static", "Prism AST"],
  ["runtime", "File.open"],
  ["guard", "Guardrails"],
];
export function BlastRadius({ compact }: { compact: boolean }) {
  const result = useWorkbench((s) => s.selection);
  const lazy = useWorkbench((s) => s.lazyRoot);
  const { toggleLazy, inspect } = useWorkbench.getState();
  const [filter, setFilter] = useState<EdgeFilter>("all");
  const lanes = useMemo(
    () => traceLanes(snapshot, result, filter),
    [result, filter],
  );
  const layout = useMemo(() => layoutGraph(lanes, snapshot), [lanes]);
  const hasPreview = result.changed.some((f) => f.id === snapshot.lazyRootId);
  const hasNew = result.changed.some((f) => !f.baselineSha256);
  const tone = result.roots.length ? "red" : hasNew ? "amber" : "green";
  const message = result.roots.length
    ? "Root scope (r) changed before isolation. The full suite must run."
    : lazy
      ? "Lazy autoload preview: only isolated readers and mandatory specs run."
      : result.scenario?.id === "B"
        ? `0 static AST changes. Scoped File.open caught ${result.dynamicOnly} specs.`
        : hasNew
          ? "New path, no baseline reads. Prism Dir.glob guardrails keep migration linters in scope."
          : `${result.changed.length} modified ${result.changed.length === 1 ? "file" : "files"} · ${result.bitmapHits} bitmap hits · ${result.mandatory} mandatory specs`;
  return (
    <section className="graph-pane pane" aria-label="Blast radius">
      <div className="graph-heading">
        <div>
          <div className="section-kicker">
            <span>02</span> / DEPENDENCY MAP
          </div>
          <h2>Blast radius</h2>
        </div>
        <div className="edge-filters" aria-label="Edge filters">
          {filters.map(([id, label]) => (
            <button
              key={id}
              onClick={() => setFilter(id)}
              aria-pressed={id === filter}
            >
              {label}
            </button>
          ))}
        </div>
      </div>
      {!lanes.length ? (
        <div className="empty-inline graph-empty">
          <Waypoints size={24} />
          <strong>No matching edges</strong>
          <span>
            Try another edge filter or modify a file with this access kind.
          </span>
          <button onClick={() => setFilter("all")}>Show all edges</button>
        </div>
      ) : compact ? (
        <div className="compact-lanes">
          {lanes.map((lane, i) => (
            <div key={i}>
              <small className="eyebrow">{familyNames[lane.family]}</small>
              <button
                onClick={() =>
                  inspect(
                    lane.fileId !== undefined
                      ? { type: "file", id: lane.fileId }
                      : { type: "spec", id: lane.specs[0] },
                  )
                }
              >
                <FileDiff size={14} />
                {lane.origin}
                <ArrowUpRight size={12} />
              </button>
              <span>
                <ArrowDown size={12} />
                {lane.relay}
              </span>
              <button
                onClick={() =>
                  inspect({
                    type: "group",
                    title: lane.origin,
                    specIds: lane.specs,
                  })
                }
              >
                <FileCode2 size={14} />
                {integer(lane.specs.length)} affected specs
                <ArrowUpRight size={12} />
              </button>
            </div>
          ))}
        </div>
      ) : (
        <>
          <div className="column-key">
            <span>
              <i>01</i> Modified inputs
            </span>
            <span>
              <i>02</i> Resolved access
            </span>
            <span>
              <i>03</i> Impacted specs
            </span>
          </div>
          <div className="flow-wrap">
            <ReactFlow
              nodes={layout.nodes}
              edges={layout.edges}
              nodeTypes={nodeTypes}
              fitView
              fitViewOptions={fitOpts}
              minZoom={0.2}
              maxZoom={2}
              nodesDraggable={false}
              nodesConnectable={false}
              elementsSelectable={false}
              edgesFocusable={false}
              onNodeClick={(_, node) => inspect(node.data.target)}
              deleteKeyCode={null}
              colorMode="dark"
              aria-label="Interactive dependency graph"
            >
              <Background color="#373b42" gap={16} size={1} />
              <CanvasTools
                layoutKey={`${filter}:${result.changed.map((f) => f.id).join(",")}:${lazy}`}
              />
            </ReactFlow>
          </div>
        </>
      )}
      <div className={`scenario-note note-${tone}`}>
        <span className="note-icon">
          {tone === "green" ? <GitFork size={14} /> : <ShieldAlert size={15} />}
        </span>
        <span>{message}</span>
        {hasPreview ? (
          <button
            aria-pressed={lazy}
            onClick={toggleLazy}
            title={`Preview moving ${basename(snapshot.files[snapshot.lazyRootId].path)} out of root scope`}
          >
            {lazy ? <Check size={12} /> : <ChevronsRight size={12} />}Preview
            root-scope refactor
          </button>
        ) : (
          lanes.length > layout.shown && (
            <small>
              {layout.shown} of {lanes.length} paths shown
            </small>
          )
        )}
      </div>
    </section>
  );
}
