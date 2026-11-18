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
