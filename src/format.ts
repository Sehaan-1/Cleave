import type { DependencyEdgeKind, SelectionReason } from "./types/cleave";
export const basename = (path: string) => path.split("/").at(-1)!;
export const dirname = (path: string) => path.slice(0, path.lastIndexOf("/"));
export const integer = (n: number) => n.toLocaleString("en-US");
export const percent = (part: number, total: number) =>
  `${((100 * part) / total).toFixed(1)}%`;
export const bitIndex = (n: number) => `#${String(n).padStart(4, "0")}`;
export const duration = (ms: number) =>
  ms < 60_000
    ? `${(ms / 1000).toFixed(1)}s`
    : `${Math.floor(ms / 60_000)}m ${Math.floor(ms / 1000) % 60}s`;
export const edgeLabels: Record<DependencyEdgeKind, string> = {
  PRISM_AST_CONSTANT: "Prism constant",
  PRISM_AST_REQUIRE: "require_relative",
  SYSCALL_FILE_OPEN: "File.open",
  ROOT_SCOPE_PRELOAD: "Root preload",
};
export const reasons: Record<SelectionReason, { label: string; tone: string }> =
  {
    BITMAP_DIRECT_HIT: { label: "Bitmap hit", tone: "green" },
    GUARDRAIL_PRISM_GLOB: { label: "Prism guardrail", tone: "amber" },
    GUARDRAIL_PREV_FAILURE: { label: "Previous failure", tone: "red" },
    GUARDRAIL_ROOT_SCOPE: { label: "Root fallback", tone: "red" },
    SKIPPED: { label: "Skipped", tone: "slate" },
  };
