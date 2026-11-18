import dagre from "@dagrejs/dagre";
import type { Edge, Node } from "@xyflow/react";
import { basename, dirname, integer } from "../format";
import type { InspectorTarget } from "../state/workbench";
import type { Snapshot } from "../types/cleave";
import { staticEdge, type Selection } from "./bitmapSelector";

export type EdgeFilter = "all" | "static" | "runtime" | "guard";
type Family = Exclude<EdgeFilter, "all"> | "root";
export interface Lane {
  origin: string;
  originMeta: string;
  fileId?: number;
  relay: string;
  family: Family;
  specs: number[];
}
export function traceLanes(
  data: Snapshot,
  result: Selection,
  filter: EdgeFilter,
): Lane[] {
  const lanes: Lane[] = [];
  const rootWins = result.roots.length > 0 && filter === "all";
  for (const f of result.changed) {
    const origin = {
      origin: basename(f.path),
      originMeta: dirname(f.path),
      fileId: f.id,
    };
    if (rootWins) {
      if (result.roots.includes(f))
        lanes.push({
          ...origin,
          family: "root",
          relay: "Root scope (r)",
          specs: data.specs.map((s) => s.id),
        });
      continue;
    }
    for (const family of ["static", "runtime"] as const) {
      if (filter !== "all" && filter !== family) continue;
      const specs = f.impactedTestIds.filter((id) =>
        result.rows[id].hits.some(
          (hit) =>
            hit.file.id === f.id &&
            (family === "static"
              ? staticEdge(hit.kind)
              : hit.kind === "SYSCALL_FILE_OPEN"),
        ),
      );
      if (specs.length)
        lanes.push({
          ...origin,
          family,
          specs,
          relay:
            family === "static"
              ? f.definedConstants[0]
              : f.path.endsWith(".yml")
                ? "YAML.load_file"
                : f.path.endsWith(".json")
                  ? "JSON.parse / File.read"
                  : "File.open",
        });
    }
    if (filter === "all" || filter === "guard") {
      const specs = result.rows
        .filter(({ guardFiles }) => guardFiles.includes(f))
        .map(({ spec }) => spec.id);
      if (specs.length)
        lanes.push({ ...origin, family: "guard", relay: "Dir.glob", specs });
    }
  }
  if (!rootWins && (filter === "guard" || filter === "all")) {
    const specs = data.specs
      .filter((s) => s.hasPrismDynamicHazard && !s.watchedGlob)
      .map((s) => s.id);
    lanes.push({
      origin: "Recorded Prism AST",
      originMeta: "baseline / guardrails",
      relay: "Dynamic directory read",
      family: "guard",
      specs,
    });
  }
  return lanes;
}
export const familyNames: Record<Family, string> = {
  static: "Prism AST",
  runtime: "Scoped file access",
  guard: "Prism guardrail",
  root: "Pre-isolation preload",
};
export interface TraceData extends Record<string, unknown> {
  title: string;
  meta: string;
  role: "source" | "relay" | "spec" | "cluster";
  family: Family;
  target: InspectorTarget;
}
export type TraceNode = Node<TraceData, "trace">;
export const NODE_W = 264,
  NODE_H = 44;
const palette = {
  static: "#6d8377",
  runtime: "#60ad83",
  guard: "#d29922",
  root: "#e5534b",
};
/** Keep the poster legible at desktop scale; the cluster retains every undisplayed endpoint. */
export function layoutGraph(lanes: Lane[], snapshot: Snapshot) {
  const nodes: TraceNode[] = [],
    edges: Edge[] = [];
  const graph = new dagre.graphlib.Graph()
    .setGraph({
      rankdir: "LR",
      ranksep: 61,
      nodesep: 9,
      marginx: 4,
      marginy: 4,
    })
    .setDefaultEdgeLabel(() => ({}));
  const node = (id: string, data: TraceData) => {
    if (!graph.hasNode(id)) {
      graph.setNode(id, { width: NODE_W, height: NODE_H });
      nodes.push({
        id,
        type: "trace",
        data,
        position: { x: 0, y: 0 },
        width: NODE_W,
        height: NODE_H,
        ariaLabel: `${data.title}, ${data.meta}`,
        focusable: false,
      });
    }
    return id;
  };
  const edge = (source: string, target: string, family: Family) => {
    const id = `${source}/${target}/${family}`;
    if (edges.some((e) => e.id === id)) return;
    graph.setEdge(source, target);
    edges.push({
      id,
      source,
      target,
      type: "default",
      focusable: false,
      style: {
        stroke: palette[family],
        strokeWidth: 1.7,
        strokeDasharray:
          family === "runtime" || family === "guard" ? "5 4" : undefined,
      },
    });
  };
  const visible = lanes.slice(0, 3);
  const endpoints = new Set(visible.flatMap((lane) => lane.specs));
  const displayed = new Set<number>();
  const sampledOrigins = new Set<string>();
  const via = visible.map((lane, i) => {
    const target: InspectorTarget =
      lane.fileId === undefined
        ? { type: "group", specIds: lane.specs, title: lane.origin }
        : { type: "file", id: lane.fileId };
    const source = node(`source:${lane.origin}`, {
      title: lane.origin,
      meta: lane.originMeta,
      role: "source",
      family: lane.family,
      target,
    });
    const relay = node(`via:${i}`, {
      title: lane.relay.split("::").at(-1)!,
      meta: [
        lane.relay.includes("::") && lane.relay.split("::")[0],
        familyNames[lane.family],
      ]
        .filter(Boolean)
        .join(" · "),
      role: "relay",
      family: lane.family,
      target:
        lane.family === "guard" ? { type: "spec", id: lane.specs[0] } : target,
    });
    edge(source, relay, lane.family);
    if (sampledOrigins.has(lane.origin) || displayed.size >= 2) return relay;
    sampledOrigins.add(lane.origin);
    const sample =
      lane.specs.find(
        (id) => !displayed.has(id) && !snapshot.specs[id].hasPrismDynamicHazard,
      ) ?? lane.specs[0];
    displayed.add(sample);
    const s = snapshot.specs[sample];
    node(`spec:${sample}`, {
      title: basename(s.path),
      meta: `RSpec · ${s.domain.replace("_", " ")}`,
      role: "spec",
      family: lane.family,
      target: { type: "spec", id: sample },
    });
    return relay;
  });
  const rest = [...endpoints].filter((id) => !displayed.has(id));
  if (rest.length)
    node("cluster", {
      title: `+${integer(rest.length)} more specs`,
      meta: "Inspect remaining hits",
      role: "cluster",
      family: visible[0].family,
      target: {
        type: "group",
        title: "Remaining impacted specs",
        specIds: rest,
      },
    });
  visible.forEach((lane, i) => {
    for (const id of displayed)
      if (lane.specs.includes(id)) edge(via[i], `spec:${id}`, lane.family);
    if (lane.specs.some((id) => !displayed.has(id)))
      edge(via[i], "cluster", lane.family);
  });
  dagre.layout(graph);
  nodes.forEach((n) => {
    const p = graph.node(n.id);
    n.position = { x: p.x - NODE_W / 2, y: p.y - NODE_H / 2 };
  });
  return {
    nodes,
    edges,
    endpoints: endpoints.size,
    remaining: rest,
    shown: visible.length,
  };
}
