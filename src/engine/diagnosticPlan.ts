import { array, digest, object, parseStrict, path, sortedUnique, validString } from "./artifactImport";

export interface PlanHazard { name: string; node_type: string; line: number; column: number; length: number }
export interface PlanDecision { spec: string; candidate: boolean; bitmap_sources: string[]; changed_spec: boolean; unindexed_spec: boolean; reasons: string[]; hazards: PlanHazard[] }
export interface DiagnosticPlan {
  baseline_fingerprint: string; current_fingerprint: string;
  changes: { added: string[]; deleted: string[]; modified: string[] };
  discovered_specs: string[]; candidate_specs: string[]; root_changes: string[]; unmapped_changes: string[];
  fallback_reasons: string[]; union_nanoseconds: number; limitations: string[]; decisions: PlanDecision[];
  previous_failures_available: boolean; unmatched_previous_failures: string[]; previous_failures_source_sha256: string | null;
}
function fail(message: string): never { throw new Error(message); }
function paths(value: unknown, label: string): string[] {
  const result = array(value, label).map(path); sortedUnique(result, label); return result;
}
function strings(value: unknown, label: string): string[] {
  const result = array(value, label).map(v => validString(v, label));
  if (result.some(s => !s) || new Set(result).size !== result.length) fail(`${label} must contain unique nonempty strings.`);
  return result;
}
function bool(value: unknown, label: string): boolean {
  return typeof value === "boolean" ? value : fail(`${label} must be boolean.`);
}
function natural(value: unknown, label: string, min = 0): number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= min ? value : fail(`${label} must be a safe integer.`);
}
export function importDiagnosticPlan(text: string): DiagnosticPlan {
  const raw = parseStrict(text, "Diagnostic plan");
  const version = raw && typeof raw === "object" && !Array.isArray(raw) ? (raw as Record<string, unknown>).version : undefined;
  const data = object(raw, ["schema", "version", "diagnostic_only", "suite_coverage_verified", "requires_full_suite", "execution_ready", "baseline_fingerprint", "current_fingerprint", "changes", "discovered_specs", "candidate_specs", "root_changes", "unmapped_changes", "fallback_reasons", "previous_failures_available", "union_nanoseconds", "limitations", "decisions", ...(version === 2 ? ["previous_failures_source_sha256", "unmatched_previous_failures"] : [])], "Diagnostic plan");
  if (data.schema !== "cleave.diagnostic_plan" || (data.version !== 1 && data.version !== 2)) fail("Unsupported diagnostic plan schema or version.");
  if (data.diagnostic_only !== true || data.requires_full_suite !== true || data.execution_ready !== false || data.suite_coverage_verified !== false || data.previous_failures_available !== (data.version === 2)) fail("Invalid diagnostic safety flags.");
  const previous_failures_available = data.version === 2;
  const previous_failures_source_sha256 = previous_failures_available ? digest(data.previous_failures_source_sha256, "Previous failures source digest") : null;
  const unmatched_previous_failures = previous_failures_available ? paths(data.unmatched_previous_failures, "Unmatched previous failures") : [];
  const baseline_fingerprint = digest(data.baseline_fingerprint, "Baseline fingerprint");
  const current_fingerprint = digest(data.current_fingerprint, "Current fingerprint");
  const changeData = object(data.changes, ["added", "deleted", "modified"], "Changes");
  const changes = { added: paths(changeData.added, "Added paths"), deleted: paths(changeData.deleted, "Deleted paths"), modified: paths(changeData.modified, "Modified paths") };
  const allChanges = [...changes.added, ...changes.deleted, ...changes.modified];
  if (new Set(allChanges).size !== allChanges.length) fail("Change categories overlap.");
  const changedSet = new Set(allChanges);
  const discovered_specs = paths(data.discovered_specs, "Discovered specs");
  if (!discovered_specs.length) fail("No discovered specs.");
  const discoveredSet = new Set(discovered_specs);
  if (unmatched_previous_failures.some(p => discoveredSet.has(p))) fail("Unmatched previous failure is a discovered spec.");
  const candidate_specs = paths(data.candidate_specs, "Candidate specs");
  const root_changes = paths(data.root_changes, "Root changes");
  const unmapped_changes = paths(data.unmapped_changes, "Unmapped changes");
  if ([...root_changes, ...unmapped_changes].some(p => !changedSet.has(p))) fail("Change attribution refers to an unchanged path.");
  const fallback_reasons = strings(data.fallback_reasons, "Fallback reasons");
  if (!fallback_reasons.includes("incomplete_index")) fail("Incomplete index fallback is missing.");
  if (fallback_reasons.includes("previous_failures_unavailable") === previous_failures_available || fallback_reasons.includes("previous_failures_unmatched") !== !!unmatched_previous_failures.length) fail("Previous failure fallback is inconsistent.");
  const limitations = strings(data.limitations, "Limitations"); sortedUnique(limitations, "Limitations");
  if (!limitations.length) fail("Coverage limitations are missing.");
  const union_nanoseconds = natural(data.union_nanoseconds, "Union time");
  const decisions = array(data.decisions, "Decisions").map(item => {
    const d = object(item, ["spec", "candidate", "bitmap_sources", "changed_spec", "unindexed_spec", "reasons", "hazards"], "Decision");
    const spec = path(d.spec); const candidate = bool(d.candidate, "Candidate");
    const bitmap_sources = paths(d.bitmap_sources, "Bitmap sources");
    if (bitmap_sources.some(p => !changedSet.has(p))) fail("Bitmap source is not a changed path.");
    const changed_spec = bool(d.changed_spec, "Changed spec"); const unindexed_spec = bool(d.unindexed_spec, "Unindexed spec");
    if (changed_spec !== changedSet.has(spec)) fail("Changed-spec attribution is inconsistent.");
    const reasons = strings(d.reasons, "Decision reasons");
    if (!reasons.includes("incomplete_index_fallback")) fail("Decision is missing full-suite fallback.");
    const hazards = array(d.hazards, "Hazards").map(item => {
      const h = object(item, ["name", "node_type", "line", "column", "length"], "Hazard");
      const name = validString(h.name, "Hazard name"); const node_type = validString(h.node_type, "Hazard node type");
      if (!name || !node_type) fail("Hazard fields must not be empty.");
      return { name, node_type, line: natural(h.line, "Hazard line", 1), column: natural(h.column, "Hazard column"), length: natural(h.length, "Hazard length") };
    });
    const previous_failure = reasons.includes("previous_failure");
    if (previous_failure && !previous_failures_available) fail("Previous failure attribution is unavailable.");
    const expectedCandidate = !!bitmap_sources.length || changed_spec || unindexed_spec || !!hazards.length || !!root_changes.length || previous_failure;
    if (candidate !== expectedCandidate || reasons.includes("bitmap_hit") !== !!bitmap_sources.length || reasons.includes("prism_hazard") !== !!hazards.length || reasons.includes("root_scope_fallback") !== !!root_changes.length || reasons.includes("changed_spec") !== changed_spec || reasons.includes("unindexed_spec") !== unindexed_spec) fail("Decision attribution is inconsistent.");
    return { spec, candidate, bitmap_sources, changed_spec, unindexed_spec, reasons, hazards };
  });
  if (decisions.length !== discovered_specs.length || decisions.some((d, i) => d.spec !== discovered_specs[i])) fail("Decisions do not match discovered specs.");
  if (decisions.filter(d => d.candidate).map(d => d.spec).join("\0") !== candidate_specs.join("\0")) fail("Candidate list does not match decisions.");
  return { baseline_fingerprint, current_fingerprint, changes, discovered_specs, candidate_specs, root_changes, unmapped_changes, fallback_reasons, union_nanoseconds, limitations, decisions, previous_failures_available, previous_failures_source_sha256, unmatched_previous_failures };
}
