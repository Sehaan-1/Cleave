import { parseTree, type Node, type ParseError } from "jsonc-parser";
import { sha256 } from "@noble/hashes/sha256";
import { bytesToHex, utf8ToBytes } from "@noble/hashes/utils";

export const MAX_ARTIFACT_BYTES = 10 * 1024 * 1024;
export interface ImportedFile {
  path: string;
  sha256: string | null;
  mask: bigint;
  root: boolean;
}
export interface ImportedArtifacts {
  fingerprint: string;
  files: ImportedFile[];
  specs: string[];
  limitations: string[];
}

function fail(message: string): never { throw new Error(message); }
function parseStrict(text: string, name: string): unknown {
  if (utf8ToBytes(text).length > MAX_ARTIFACT_BYTES) fail(`${name} exceeds the 10 MiB limit.`);
  const errors: ParseError[] = [];
  const tree = parseTree(text, errors, { disallowComments: true, allowTrailingComma: false });
  if (!tree || errors.length) fail(`${name} is not valid JSON.`);
  const stack: Node[] = [tree];
  while (stack.length) {
    const node = stack.pop()!;
    if (node.type === "object") {
      const keys = new Set<string>();
      for (const property of node.children ?? []) {
        const key = property.children?.[0]?.value as string;
        if (keys.has(key)) fail(`${name} contains duplicate key: ${key}`);
        keys.add(key);
      }
    }
    if (node.children) for (const child of node.children) stack.push(child);
  }
  try { return JSON.parse(text) as unknown; } catch { return fail(`${name} is not valid JSON.`); }
}
function object(value: unknown, keys: string[], label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} must be an object.`);
  const o = value as Record<string, unknown>;
  if (Object.keys(o).length !== keys.length || keys.some(k => !Object.hasOwn(o, k))) fail(`${label} has unexpected or missing fields.`);
  return o;
}
function validString(value: unknown, label: string): string {
  if (typeof value !== "string" || /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value)) fail(`${label} must be a valid Unicode string.`);
  return value as string;
}
function path(value: unknown): string {
  const s = validString(value, "Path");
  if (!s || s.startsWith("/") || s.includes("\\") || s.includes("\0") || s.split("/").some(p => !p || p === "." || p === ".." || p === ".git")) fail(`Invalid repository-relative path: ${JSON.stringify(s)}`);
  return s;
}
// Ruby compares UTF-8 strings in byte/codepoint order, not UTF-16 code-unit order.
function compare(a: string, b: string): number {
  const aa = Array.from(a, c => c.codePointAt(0)!); const bb = Array.from(b, c => c.codePointAt(0)!);
  for (let i = 0; i < Math.min(aa.length, bb.length); i++) if (aa[i] !== bb[i]) return aa[i] - bb[i];
  return aa.length - bb.length;
}
function sortedUnique(values: string[], label: string): void {
  for (let i = 1; i < values.length; i++) if (compare(values[i - 1], values[i]) >= 0) fail(`${label} must be sorted and unique.`);
}
function array(value: unknown, label: string): unknown[] { return Array.isArray(value) ? value : fail(`${label} must be an array.`); }
function digest(value: unknown, label: string): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) fail(`${label} must be a lowercase SHA-256 digest.`);
  return value as string;
}
export function importArtifacts(inventoryText: string, indexText: string): ImportedArtifacts {
  const inv = object(parseStrict(inventoryText, "Inventory"), ["schema", "version", "files", "fingerprint"], "Inventory");
  if (inv.schema !== "cleave.inventory" || inv.version !== 1) fail("Unsupported inventory schema or version.");
  const entries = array(inv.files, "Inventory files").map(item => {
    const e = object(item, ["path", "sha256"], "Inventory entry");
    return { path: path(e.path), sha256: digest(e.sha256, "File digest") };
  });
  sortedUnique(entries.map(e => e.path), "Inventory paths");
  const fingerprint = digest(inv.fingerprint, "Inventory fingerprint");
  const payload = JSON.stringify({ schema: "cleave.inventory", version: 1, files: entries });
  if (bytesToHex(sha256(utf8ToBytes(payload))) !== fingerprint) fail("Inventory fingerprint mismatch.");
  const index = object(parseStrict(indexText, "Bitmap index"), ["schema", "version", "inventory_fingerprint", "specs", "masks", "root_paths", "limitations", "complete"], "Bitmap index");
  if (index.schema !== "cleave.bitmap_index" || index.version !== 1) fail("Unsupported bitmap index schema or version.");
  if (index.inventory_fingerprint !== fingerprint) fail("Bitmap index does not match this inventory.");
  if (index.complete !== false) fail("Version 1 indexes must be incomplete.");
  const specs = array(index.specs, "Specs").map(path); sortedUnique(specs, "Spec paths");
  const inventory = new Map(entries.map(e => [e.path, e.sha256]));
  if (specs.some(s => !inventory.has(s))) fail("Indexed specs must be present in the inventory.");
  const roots = array(index.root_paths, "Root paths").map(path); sortedUnique(roots, "Root paths");
  const limitations = array(index.limitations, "Limitations").map(v => validString(v, "Limitation"));
  sortedUnique(limitations, "Limitations");
  if (!limitations.length || limitations.some(s => !s)) fail("An incomplete index must include limitations.");
  const masks = array(index.masks, "Bitmaps").map(item => {
    const e = object(item, ["path", "hex"], "Bitmap entry");
    const p = path(e.path);
    if (typeof e.hex !== "string" || !/^0x[1-9a-f][0-9a-f]*$/.test(e.hex) || e.hex.length - 2 > Math.ceil(specs.length / 4)) fail(`Invalid bitmap for ${p}.`);
    const mask = BigInt(e.hex as string);
    if (mask >> BigInt(specs.length)) fail(`Bitmap outside spec range for ${p}.`);
    return { path: p, mask };
  });
  sortedUnique(masks.map(e => e.path), "Bitmap paths");
  const maskMap = new Map(masks.map(e => [e.path, e.mask])); const rootSet = new Set(roots);
  const paths = [...new Set([...inventory.keys(), ...maskMap.keys(), ...roots])].sort(compare);
  return { fingerprint, specs, limitations, files: paths.map(p => ({ path: p, sha256: inventory.get(p) ?? null, mask: maskMap.get(p) ?? 0n, root: rootSet.has(p) })) };
}
