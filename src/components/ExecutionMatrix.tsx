import { useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  flexRender,
  getCoreRowModel,
  useReactTable,
  type ColumnDef,
} from "@tanstack/react-table";
import { useVirtualizer } from "@tanstack/react-virtual";
import {
  Binary,
  ChevronLeft,
  ChevronRight,
  CircleMinus,
  List,
  ScanLine,
  Search,
  ShieldAlert,
} from "lucide-react";
import type { Selection, SpecDecision } from "../engine/bitmapSelector";
import { bit, hexWord } from "../engine/bitmapSelector";
import {
  basename,
  bitIndex,
  dirname,
  edgeLabels,
  integer,
  reasons,
} from "../format";
import { index, snapshot, useWorkbench } from "../state/workbench";
import type { SelectionReason } from "../types/cleave";

export function Reason({ reason }: { reason: SelectionReason }) {
  const { tone, label } = reasons[reason];
  return (
    <span className={`reason reason-${tone}`}>
      <i className={`status-dot ${tone}`} />
      {label}
    </span>
  );
}
const ROW = 38,
  HEAD = 27;
type Filter = "All" | "Selected" | "Guardrails" | "Skipped";
const filters: Filter[] = ["All", "Selected", "Guardrails", "Skipped"];
function SpecTable({ result }: { result: Selection }) {
  const [filter, setFilter] = useState<Filter>("All"),
    [query, setQuery] = useState("");
  const counts = {
    All: snapshot.specs.length,
    Selected: result.selected,
    Guardrails: result.mandatory,
    Skipped: result.skipped,
  };
  const data = useMemo(
    () =>
      result.rows.filter(
        ({ spec, reason }) =>
          (filter === "All" ||
            (filter === "Guardrails"
              ? reason.startsWith("GUARDRAIL_")
              : (reason === "SKIPPED") === (filter === "Skipped"))) &&
          spec.path.includes(query.toLowerCase().trim()),
      ),
    [result, filter, query],
  );
  const inspect = useWorkbench((s) => s.inspect);
  const columns = useMemo<ColumnDef<SpecDecision>[]>(
    () => [
      {
        id: "bit",
        header: "Bit index",
        size: 8,
        cell: ({ row }) => (
          <span className="index-num">{bitIndex(row.original.spec.id)}</span>
        ),
      },
      {
        id: "path",
        header: "RSpec file",
        size: 34,
        cell: ({
          row: {
            original: { spec },
          },
        }) => (
          <button
            className="spec-path"
            title={spec.path}
            onClick={(e) => {
              e.stopPropagation();
              inspect({ type: "spec", id: spec.id });
            }}
          >
            <strong>{basename(spec.path)}</strong>
            <small>{dirname(spec.path)}/</small>
          </button>
        ),
      },
      {
        id: "status",
        header: "Selection reason",
        size: 16,
        cell: ({ row }) => <Reason reason={row.original.reason} />,
      },
      {
        id: "trigger",
        header: "Trigger / edge",
        size: 25,
        cell: ({ row: { original: r } }) => {
          const hit = r.hits[0];
          const trigger =
            r.reason === "GUARDRAIL_ROOT_SCOPE"
              ? [basename(result.roots[0].path), "Root preload"]
              : r.reason === "GUARDRAIL_PREV_FAILURE"
                ? ["Baseline failure", "Previous CI replay"]
                : r.reason === "GUARDRAIL_PRISM_GLOB"
                  ? [r.spec.watchedGlob ?? "Unbounded glob", "Prism::CallNode"]
                  : hit
                    ? [
                        basename(hit.file.path),
                        edgeLabels[hit.kind] +
                          (r.hits.length > 1 ? ` +${r.hits.length - 1}` : ""),
                      ]
                    : null;
          return trigger ? (
            <span className="trigger" title={trigger.join(" · ")}>
              <strong>{trigger[0]}</strong>
              <small>{trigger[1]}</small>
            </span>
          ) : (
            <span className="muted">—</span>
          );
        },
      },
      {
        id: "hazard",
        header: "AST flag",
        size: 8,
        cell: ({ row }) =>
          row.original.spec.hasPrismDynamicHazard ? (
            <span
              className="hazard-flag"
              title={row.original.spec.hazardDetail}
            >
              <ShieldAlert size={12} />
              glob
            </span>
          ) : (
            <span className="muted">—</span>
          ),
      },
      {
        id: "time",
        header: "Time",
        size: 9,
        cell: ({ row }) => (
          <span className="row-time">
            {integer(row.original.spec.avgDurationMs)}
            <small> ms</small>
          </span>
        ),
      },
    ],
    [inspect, result.roots],
  );
  const table = useReactTable({
    data,
    columns,
    getRowId: (r) => String(r.spec.id),
    getCoreRowModel: getCoreRowModel(),
  });
  const { rows } = table.getRowModel();
  const scroll = useRef<HTMLDivElement>(null);
  const virtual = useVirtualizer({
    count: rows.length,
    estimateSize: () => ROW,
    getScrollElement: () => scroll.current,
    getItemKey: (i) => rows[i].id,
    overscan: 6,
    scrollMargin: HEAD,
  });
  useLayoutEffect(() => {
    if (scroll.current) scroll.current.scrollTop = 0;
  }, [filter, query, result]);
  const items = virtual.getVirtualItems();
  return (
    <>
      <div className="matrix-toolbar">
        <div className="result-filters" aria-label="Spec filters">
          {filters.map((f) => (
            <button
              key={f}
              onClick={() => setFilter(f)}
              aria-pressed={filter === f}
            >
              {f}
              <b>{integer(counts[f])}</b>
            </button>
          ))}
        </div>
        <label className="spec-search">
          <Search size={13} />
          <input
            type="search"
            aria-label="Search specs"
            placeholder="Find spec…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
      </div>
      <div
        className="table-scroll"
        ref={scroll}
        tabIndex={0}
        aria-label="Scrollable spec decisions"
      >
        <table
          className="spec-table"
          aria-label="Spec decisions"
          aria-rowcount={rows.length + 1}
        >
          <colgroup>
            {columns.map((c) => (
              <col
                key={c.id}
                className={`col-${c.id}`}
                style={{ width: `${c.size}%` }}
              />
            ))}
          </colgroup>
          <thead>
            {table.getHeaderGroups().map((g) => (
              <tr key={g.id}>
                {g.headers.map((h) => (
                  <th scope="col" className={`col-${h.id}`} key={h.id}>
                    {flexRender(h.column.columnDef.header, h.getContext())}
                  </th>
                ))}
              </tr>
            ))}
          </thead>
          <tbody>
            {items.length > 0 && items[0].index > 0 && (
              <tr aria-hidden="true" className="spacer">
                <td
                  colSpan={columns.length}
                  style={{ height: items[0].start - HEAD }}
                />
              </tr>
            )}
            {items.map((v) => {
              const row = rows[v.index];
              return (
                <tr
                  key={row.id}
                  data-spec-id={row.original.spec.id}
                  aria-rowindex={v.index + 2}
                  onClick={() =>
                    inspect({ type: "spec", id: row.original.spec.id })
                  }
                >
                  {row.getVisibleCells().map((c) => (
                    <td key={c.id} className={`col-${c.column.id}`}>
                      {flexRender(c.column.columnDef.cell, c.getContext())}
                    </td>
                  ))}
                </tr>
              );
            })}
            {items.length > 0 && (
              <tr aria-hidden="true" className="spacer">
                <td
                  colSpan={columns.length}
                  style={{
                    height: Math.max(
                      0,
                      virtual.getTotalSize() - items.at(-1)!.end + HEAD,
                    ),
                  }}
                />
              </tr>
            )}
          </tbody>
        </table>
        {!rows.length && (
          <div className="empty-inline">
            <CircleMinus size={18} />
            No specs match this filter.
          </div>
        )}
      </div>
    </>
  );
}
function Hex({ value, word }: { value: bigint; word: number }) {
  return (
    <code className="hex-word">
      {hexWord(value, word)
        .split(/([1-9a-f]+)/)
        .map((p, i) => (i % 2 ? <b key={i}>{p}</b> : p))}
    </code>
  );
}
function BitmapWords({ result }: { result: Selection }) {
  const [word, setWord] = useState(0);
  const inspect = useWorkbench((s) => s.inspect);
  const n = snapshot.specs.length,
    words = Math.ceil(n / 64);
  const operands: [string, bigint, string][] = [
    ...result.changed.map((f): [string, bigint, string] => [
      f.path,
      index.fileMasks.get(f.id)!,
      "green",
    ]),
    ["MANDATORY_GUARDRAIL_MASK", result.guardMask, "amber"],
    ["PREV_FAILED_MASK", result.failedMask, "red"],
    ...(result.rootMask
      ? [
          ["ROOT_SCOPE_MASK", result.rootMask, "red"] as [
            string,
            bigint,
            string,
          ],
        ]
      : []),
    ["FINAL_EXECUTION_MASK", result.finalMask, "green"],
  ];
  const bits = Array.from({ length: 64 }, (_, i) => word * 64 + 63 - i);
  return (
    <>
      <div className="word-toolbar">
        <span className="eyebrow">
          <ScanLine size={13} />
          64-bit word
        </span>
        <div className="word-control">
          <button
            aria-label="Previous word"
            disabled={!word}
            onClick={() => setWord(word - 1)}
          >
            <ChevronLeft />
          </button>
          <select
            aria-label="Bitmap word"
            value={word}
            onChange={(e) => setWord(Number(e.target.value))}
          >
            {Array.from({ length: words }, (_, i) => (
              <option
                key={i}
                value={i}
              >{`W${String(i).padStart(2, "0")} · ${bitIndex(i * 64)}–${bitIndex(Math.min(n - 1, i * 64 + 63))}`}</option>
            ))}
          </select>
          <button
            aria-label="Next word"
            disabled={word === words - 1}
            onClick={() => setWord(word + 1)}
          >
            <ChevronRight />
          </button>
        </div>
      </div>
      <div className="word-scroll">
        <div className="word-rows">
          {operands.map(([name, value, tone], i) => (
            <div
              className={`word-row ${i === operands.length - 1 ? "union-row" : ""}`}
              key={name}
            >
              <i>{i === operands.length - 1 ? "=" : i === 0 ? " " : "|"}</i>
              <span className="word-name" title={name}>
                {name}
              </span>
              <Hex value={value} word={word} />
              <div className="word-shape" aria-hidden="true">
                {bits.map((id) => (
                  <i
                    key={id}
                    className={value & bit(id) ? `fill-${tone}` : ""}
                  />
                ))}
              </div>
            </div>
          ))}
        </div>
        <div className="bit-readout">
          <div>
            <strong>Inspect a bit</strong>
            <span>Most significant → least significant</span>
          </div>
          <div className="bit-grid">
            {bits.map((id) => {
              const on = !!(result.finalMask & bit(id)),
                s = snapshot.specs[id];
              return (
                <button
                  key={id}
                  disabled={!s}
                  title={s ? `${bitIndex(id)} · ${s.path}` : "Padding: no spec"}
                  aria-label={
                    s
                      ? `Inspect bit ${id}: ${on ? "selected" : "skipped"}`
                      : "Padding bit"
                  }
                  className={
                    on ? `bit-${reasons[result.rows[id].reason].tone}` : ""
                  }
                  onClick={() => inspect({ type: "spec", id })}
                >
                  {s ? Number(on) : "·"}
                </button>
              );
            })}
          </div>
        </div>
      </div>
    </>
  );
}
export function ExecutionMatrix() {
  const result = useWorkbench((s) => s.selection);
  const [view, setView] = useState<"specs" | "words">("specs");
  return (
    <section className="matrix-pane pane" aria-label="Execution matrix">
      <div className="matrix-heading">
        <div>
          <div className="section-kicker">
            <span>03</span> / SELECTION ENGINE
          </div>
          <h2>Execution matrix</h2>
        </div>
        <div className="matrix-tabs">
          <button
            aria-pressed={view === "specs"}
            onClick={() => setView("specs")}
          >
            <List size={14} />
            Spec table
          </button>
          <button
            aria-pressed={view === "words"}
            onClick={() => setView("words")}
          >
            <Binary size={14} />
            Bitmap words
          </button>
        </div>
      </div>
      {view === "specs" ? (
        <SpecTable result={result} />
      ) : (
        <BitmapWords result={result} />
      )}
    </section>
  );
}
