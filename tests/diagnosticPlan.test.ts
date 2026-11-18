import { readFileSync } from "node:fs";
import { test } from "node:test";
import { strict as assert } from "node:assert";
import { importDiagnosticPlan } from "../src/engine/diagnosticPlan";

const text = readFileSync("tests/fixtures/plans/plan.json", "utf8");
const raw = () => JSON.parse(text);
test("imports attributed diagnostic plan without granting execution", () => {
  const plan = importDiagnosticPlan(text);
  assert.equal(plan.candidate_specs.length, 2);
  assert.equal(plan.decisions[2].candidate, false);
  assert.deepEqual(plan.decisions[1].hazards[0], { name: "glob", node_type: "CallNode", line: 3, column: 0, length: 7 });
  assert.equal(plan.decisions[0].bitmap_sources[0], "app/服务.rb");
});
test("rejects malformed and inconsistent plan data", () => {
  const invalid: unknown[] = [];
  let d = raw(); d.execution_ready = true; invalid.push(d);
  d = raw(); d.suite_coverage_verified = true; invalid.push(d);
  d = raw(); d.version = 2; invalid.push(d);
  d = raw(); d.candidate_specs = ["spec/alpha_spec.rb"]; invalid.push(d);
  d = raw(); d.decisions[0].bitmap_sources = ["not_changed.rb"]; invalid.push(d);
  d = raw(); d.decisions[0].candidate = false; invalid.push(d);
  d = raw(); d.decisions[1].hazards[0].line = 0; invalid.push(d);
  d = raw(); d.discovered_specs.reverse(); invalid.push(d);
  d = raw(); d.changes.deleted = ["new.txt"]; invalid.push(d);
  d = raw(); d.fallback_reasons = []; invalid.push(d);
  d = raw(); d.decisions[0].reasons = []; invalid.push(d);
  d = raw(); d.root_changes = ["../bad"]; invalid.push(d);
  for (const item of invalid) assert.throws(() => importDiagnosticPlan(JSON.stringify(item)));
  assert.throws(() => importDiagnosticPlan(text.replace('"version": 1,', '"version": 1, "version": 1,')), /duplicate key/);
  assert.throws(() => importDiagnosticPlan("not json"));
});

test("imports v2 prior failure attribution and rejects inconsistent metadata", () => {
  const d = raw();
  d.version = 2; d.previous_failures_available = true;
  d.previous_failures_source_sha256 = "a".repeat(64);
  d.unmatched_previous_failures = ["spec/deleted_spec.rb"];
  d.fallback_reasons = d.fallback_reasons.filter((s: string) => s !== "previous_failures_unavailable");
  d.fallback_reasons.push("previous_failures_unmatched");
  d.decisions[2].candidate = true; d.decisions[2].reasons.push("previous_failure");
  d.candidate_specs.push(d.decisions[2].spec);
  const plan = importDiagnosticPlan(JSON.stringify(d));
  assert.equal(plan.previous_failures_available, true);
  assert.deepEqual(plan.unmatched_previous_failures, ["spec/deleted_spec.rb"]);
  assert.equal(plan.decisions[2].candidate, true);
  const bad = structuredClone(d); bad.unmatched_previous_failures = []; assert.throws(() => importDiagnosticPlan(JSON.stringify(bad)));
  const bad2 = structuredClone(d); bad2.previous_failures_source_sha256 = "bad"; assert.throws(() => importDiagnosticPlan(JSON.stringify(bad2)));
  const bad3 = structuredClone(d); bad3.decisions[2].reasons = ["incomplete_index_fallback"]; assert.throws(() => importDiagnosticPlan(JSON.stringify(bad3)));
  const bad4 = structuredClone(d); bad4.unmatched_previous_failures = [d.decisions[0].spec]; assert.throws(() => importDiagnosticPlan(JSON.stringify(bad4)));
});

test("imports v3 static candidates and rejects invalid static attribution", () => {
  const d = raw(); d.version = 3;
  d.previous_failures_source_sha256 = null; d.unmatched_previous_failures = []; d.static_deleted_fallback = false;
  d.decisions.forEach((item: { static_sources: string[], static_uncertainties: string[] }) => { item.static_sources = []; item.static_uncertainties = []; });
  d.decisions[2].candidate = true; d.decisions[2].static_sources = ["app/服务.rb"];
  d.decisions[2].static_uncertainties = ["unresolved_constant"];
  d.decisions[2].reasons.push("static_dependency", "static_uncertainty");
  d.fallback_reasons.push("static_uncertainty"); d.candidate_specs.push("spec/gamma_spec.rb");
  const plan = importDiagnosticPlan(JSON.stringify(d));
  assert.equal(plan.static_dependencies, true);
  assert.deepEqual(plan.decisions[2].static_sources, ["app/服务.rb"]);
  assert.deepEqual(plan.decisions[2].static_uncertainties, ["unresolved_constant"]);
  for (const change of [
    (v: any) => { v.decisions[2].static_sources = ["unchanged.rb"]; },
    (v: any) => { v.decisions[2].static_uncertainties = ["invented"]; },
    (v: any) => { v.decisions[2].reasons = ["incomplete_index_fallback"]; },
    (v: any) => { v.static_deleted_fallback = true; },
    (v: any) => { v.fallback_reasons = v.fallback_reasons.filter((s: string) => s !== "static_uncertainty"); },
    (v: any) => { v.previous_failures_source_sha256 = "a".repeat(64); },
  ]) { const bad = structuredClone(d); change(bad); assert.throws(() => importDiagnosticPlan(JSON.stringify(bad))); }
  const withFailures = structuredClone(d); withFailures.previous_failures_available = true;
  withFailures.previous_failures_source_sha256 = "a".repeat(64);
  withFailures.fallback_reasons = withFailures.fallback_reasons.filter((s: string) => s !== "previous_failures_unavailable");
  assert.equal(importDiagnosticPlan(JSON.stringify(withFailures)).previous_failures_available, true);
});
