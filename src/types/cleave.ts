/** Normalized workbench model. The CLI artifact adapter belongs at the boundary. */
export type ScopeType = "ROOT" | "TEST_ISOLATED";
export type DependencyEdgeKind =
  | "PRISM_AST_CONSTANT"
  | "PRISM_AST_REQUIRE"
  | "SYSCALL_FILE_OPEN"
  | "ROOT_SCOPE_PRELOAD";
export type SelectionReason =
  | "BITMAP_DIRECT_HIT"
  | "GUARDRAIL_PRISM_GLOB"
  | "GUARDRAIL_PREV_FAILURE"
  | "GUARDRAIL_ROOT_SCOPE"
  | "SKIPPED";

export interface PrismAstNodeSummary {
  nodeType: "ConstantPathNode" | "ConstantReadNode" | "CallNode";
  symbol: string;
  line: number; // one-based, as in Prism::Location
  column: number; // zero-based byte offset (the fixture source is ASCII)
  isDynamicHazard: boolean;
  snippet: string;
}
export interface RepoFileItem {
  id: number;
  path: string;
  category: "model" | "service" | "config_yaml" | "migration" | "root_helper";
  baselineSha256: string; // empty for an addition with no baseline content
  currentSha256: string;
  scope: ScopeType;
  definedConstants: string[];
  astNodes: PrismAstNodeSummary[];
  rubySourcePreview: string; // native text for non-Ruby inputs
  impactedTestIds: number[]; // isolated readers, including readers in the lazy-load counterfactual
  edgeKindsByTestId: Record<number, DependencyEdgeKind>;
}
export interface SpecFileItem {
  id: number;
  path: string;
  domain:
    | "payments"
    | "ledger"
    | "webhooks"
    | "rate_limiter"
    | "fx_routing"
    | "linters";
  avgDurationMs: number;
  failedInBaseline: boolean;
  hasPrismDynamicHazard: boolean;
  hazardDetail?: string;
  /** Absent on unbounded hazards, which are always mandatory. */
  watchedGlob?: string;
  accessedFileIds: number[];
  rubySpecPreview: string;
  astNodes: PrismAstNodeSummary[];
}
export type ScenarioId = "A" | "B" | "C" | "D";
export interface CommitScenario {
  id: ScenarioId;
  title: string;
  description: string;
  changedIds: number[];
}
export interface ShadowRun {
  scenario: ScenarioId;
  lazyRoot: boolean;
  observedFailureIds: number[];
}
export interface Snapshot {
  name: string;
  files: RepoFileItem[];
  specs: SpecFileItem[];
  scenarios: CommitScenario[];
  lazyRootId: number;
  shadowRuns: ShadowRun[];
}
