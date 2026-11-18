import { test } from "node:test";
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { importArtifacts } from "../src/engine/artifactImport";

const inventory = readFileSync("tests/fixtures/artifacts/inventory.json", "utf8");
const index = readFileSync("tests/fixtures/artifacts/bitmap_index.json", "utf8");
const inv = JSON.parse(inventory), idx = JSON.parse(index);
const run = (a: unknown, b: unknown) => importArtifacts(JSON.stringify(a), JSON.stringify(b));

test("imports the Ruby-emitted v1 pair without inventing data", () => {
  const result = importArtifacts(inventory, index);
  assert.equal(result.fingerprint, inv.fingerprint);
  assert.deepEqual(result.specs, ["spec/alpha_spec.rb", "spec/beta_spec.rb"]);
  assert.equal(result.files.find(f => f.path === "app/服务.rb")?.mask, 3n);
  assert.equal(result.files.find(f => f.path === "config/missing.json")?.sha256, null);
  assert.equal(result.files.find(f => f.path === "config/missing.json")?.mask, 2n);
  assert.equal(result.files.find(f => f.path === "config/boot.yml")?.root, true);
  assert.deepEqual(result.limitations, idx.limitations);
});

test("rejects malformed, ambiguous and mismatched artifacts", () => {
  assert.throws(() => importArtifacts('{"schema":"x","schema":"y"}', index), /duplicate key/);
  assert.throws(() => importArtifacts(inventory + ' {}', index), /valid JSON/);
  assert.throws(() => run({ ...inv, extra:true }, idx), /fields/);
  assert.throws(() => run({ ...inv, fingerprint:'0'.repeat(64) }, idx), /fingerprint mismatch/);
  assert.throws(() => run(inv, { ...idx, inventory_fingerprint:'0'.repeat(64) }), /does not match/);
  assert.throws(() => run(inv, { ...idx, complete:true }), /must be incomplete/);
  assert.throws(() => run(inv, { ...idx, version:2 }), /Unsupported/);
  assert.throws(() => run(inv, { ...idx, specs:['spec/beta_spec.rb','spec/alpha_spec.rb'] }), /sorted and unique/);
  assert.throws(() => run(inv, { ...idx, specs:['spec/unknown.rb'] }), /present in the inventory/);
  assert.throws(() => run(inv, { ...idx, root_paths:['../bad'] }), /Invalid repository-relative/);
  assert.throws(() => run(inv, { ...idx, masks:[{ path:'app/a.rb', hex:'0x04' }] }), /Invalid bitmap/);
  assert.throws(() => run(inv, { ...idx, masks:[{ path:'app/a.rb', hex:'0x4' }] }), /outside spec range/);
  assert.throws(() => run(inv, { ...idx, limitations:[] }), /must include limitations/);
  assert.throws(() => run(inv, { ...idx, masks:[{ path:'a', hex:'0x1' },{ path:'a', hex:'0x2' }] }), /sorted and unique/);
});


test("uses Ruby UTF-8 sort and canonical fingerprint for Unicode paths", () => {
  const invText = readFileSync("tests/fixtures/unicode-artifacts/inventory.json", "utf8");
  const idxText = readFileSync("tests/fixtures/unicode-artifacts/bitmap_index.json", "utf8");
  const result = importArtifacts(invText, idxText);
  assert.deepEqual(result.files.map(f => f.path), ["app/eol\n.rb", "app/x\u2028.rb", "app/\ue000.rb", "app/𐀀.rb", "spec/alpha_spec.rb"]);
});
