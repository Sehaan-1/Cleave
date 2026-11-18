import { strict as assert } from "node:assert";
import { test } from "node:test";
import { createPayServerMini } from "../src/data/payServerMini";
import {
  bit,
  buildIndex,
  hexWord,
  maskOf,
  selectTests,
  wordAt,
} from "../src/engine/bitmapSelector";
import { layoutGraph, traceLanes } from "../src/engine/blastGraph";

const snapshot = createPayServerMini();
const index = buildIndex(snapshot);
const scenario = (id: string, lazy = false) =>
  selectTests(
    index,
    snapshot.scenarios.find((s) => s.id === id)!.changedIds,
    lazy,
  );

test("fixture is deterministic and internally cross-referenced", () => {
  assert.deepEqual(createPayServerMini(), snapshot);
  assert.equal(snapshot.files.length, 24);
  assert.equal(snapshot.specs.length, 1200);
  assert.equal(index.baselineMs, 912000);
  assert.equal(new Set(snapshot.files.map((f) => f.path)).size, 24);
  assert.equal(new Set(snapshot.specs.map((s) => s.path)).size, 1200);
  for (const [id, spec] of snapshot.specs.entries()) {
    assert.equal(spec.id, id);
    assert.ok(spec.rubySpecPreview.startsWith("# typed: strict"));
    for (const fileId of spec.accessedFileIds) {
      const file = snapshot.files[fileId];
      assert.ok(
        file.impactedTestIds.includes(id),
        `${file.path}: ${spec.path}`,
      );
      assert.ok(file.edgeKindsByTestId[id]);
    }
  }
  for (const file of snapshot.files) {
    assert.match(file.currentSha256, /^[a-f0-9]{64}$/);
    assert.ok(
      !file.baselineSha256 || /^[a-f0-9]{64}$/.test(file.baselineSha256),
    );
    for (const id of file.impactedTestIds)
      assert.ok(snapshot.specs[id].accessedFileIds.includes(file.id));
    for (const node of file.astNodes)
      assert.ok(
        file.rubySourcePreview
          .split("\n")
          [node.line - 1].includes(node.snippet),
      );
  }
});

test("presets match selection totals, reason precedence and demo replay", () => {
  const a = scenario("A");
  assert.deepEqual(
    [
      a.selected,
      a.direct,
      a.guardrails,
      a.failures,
      a.bitmapHits,
      a.selectedMs,
    ],
    [41, 38, 2, 1, 38, 31400],
  );
  const b = scenario("B");
  assert.deepEqual(
    [b.selected, b.bitmapHits, b.staticCovered, b.dynamicOnly],
    [25, 25, 0, 25],
  );
  const c = scenario("C");
  assert.deepEqual(
    [c.selected, c.bitmapHits, c.guardrails, c.failures],
    [10, 0, 9, 1],
  );
  const migration = c.rows.find(
    (r) => r.spec.path === "spec/linters/migration_schema_spec.rb",
  )!;
  assert.equal(migration.reason, "GUARDRAIL_PRISM_GLOB");
  assert.equal(
    migration.guardFiles[0].path,
    "db/migrations/20261118_add_settlement_index.rb",
  );
  const d = scenario("D");
  assert.equal(d.selected, 1200);
  assert.equal(d.rootMask, index.suiteMask);
  assert.equal(scenario("D", true).selected, 23);
  for (const id of ["A", "B", "C", "D"])
    assert.deepEqual(scenario(id).missed, []);
});

test("OR operands and word boundaries match individual decisions for custom diffs", () => {
  for (let seed = 0; seed < 35; seed++) {
    const ids = snapshot.files
      .filter((f) => (f.id * 19 + seed * 7) % 31 < 4)
      .map((f) => f.id);
    const result = selectTests(index, ids, seed % 2 === 0);
    assert.equal(
      result.finalMask,
      result.directMask |
        result.guardMask |
        result.failedMask |
        result.rootMask,
    );
    assert.equal(
      result.selected,
      result.rows.filter((r) => r.reason !== "SKIPPED").length,
    );
    for (const row of result.rows)
      assert.equal(
        Boolean(result.finalMask & bit(row.spec.id)),
        row.reason !== "SKIPPED",
      );
    assert.ok(result.unionUs >= 0);
  }
  const mask = maskOf([0, 63, 64, 1199]);
  assert.equal(hexWord(mask, 0), "0x8000_0000_0000_0001");
  assert.equal(wordAt(mask, 1), 1n);
  assert.equal(wordAt(mask, 18), 1n << 47n);
});

test("lazy preview only exempts its nominated root file", () => {
  const other = snapshot.files.find(
    (f) => f.scope === "ROOT" && f.id !== snapshot.lazyRootId,
  )!;
  const result = selectTests(index, [snapshot.lazyRootId, other.id], true);
  assert.equal(result.selected, 1200);
  assert.deepEqual(
    result.roots.map((f) => f.id),
    [other.id],
  );
  assert.equal(result.shadow, undefined);
});

test("graph filters reflect recorded edges and bound the rendered nodes", () => {
  for (const id of ["A", "B", "C", "D"]) {
    const result = scenario(id);
    for (const filter of ["all", "static", "runtime", "guard"] as const) {
      const lanes = traceLanes(snapshot, result, filter);
      const graph = layoutGraph(lanes, snapshot);
      assert.ok(graph.nodes.length <= 25);
      assert.ok(
        graph.edges.every(
          (edge) =>
            graph.nodes.some((n) => n.id === edge.source) &&
            graph.nodes.some((n) => n.id === edge.target),
        ),
      );
      if (filter !== "all") assert.ok(lanes.every((l) => l.family === filter));
    }
  }
  assert.equal(traceLanes(snapshot, scenario("B"), "static").length, 0);
  assert.ok(
    traceLanes(snapshot, scenario("C"), "guard").some(
      (l) => l.relay === "Dir.glob",
    ),
  );
});

test("watched globs treat punctuation literally and do not cross directories", () => {
  const migration = snapshot.scenarios.find((s) => s.id === "C")!.changedIds[0];
  const altered = structuredClone(snapshot);
  for (const path of [
    "db/migrations/otherXrb",
    "db/migrations/nested/other.rb",
  ]) {
    altered.files[migration].path = path;
    const result = selectTests(buildIndex(altered), [migration]);
    assert.equal(result.guardrails, 2, path);
  }
});
