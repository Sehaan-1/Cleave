import type {
  CommitScenario,
  DependencyEdgeKind,
  PrismAstNodeSummary,
  Snapshot,
  SpecFileItem,
} from "../types/cleave";
import { landmark, makeFiles, recipes } from "./sources";

const SIZE = 1_200;
const GLOB = "db/migrations/*.rb";
const markets = [
  "usd",
  "eur",
  "gbp",
  "cad",
  "jpy",
  "mxn",
  "brl",
  "aud",
  "sgd",
  "sek",
  "inr",
  "chf",
];
const cases = [
  "authorization",
  "capture",
  "partial_refund",
  "reversal",
  "settlement",
  "retry",
  "expiry",
  "replay",
  "cutoff",
  "rounding",
];
const scenarios: CommitScenario[] = [
  {
    id: "A",
    title: "Surgical service edit",
    description: "Change an idempotency service and its ledger model.",
    changedIds: [0, 1],
  },
  {
    id: "B",
    title: "Non-Ruby fixture edit",
    description: "Trace a YAML and JSON edit through runtime reads.",
    changedIds: [2, 3],
  },
  {
    id: "C",
    title: "Directory glob guardrail",
    description: "Add a migration that was absent from the baseline.",
    changedIds: [4],
  },
  {
    id: "D",
    title: "Root-scope pollution",
    description: "Edit a global helper loaded before test isolation.",
    changedIds: [5],
  },
];
type Read = readonly [fileId: number, kind: DependencyEdgeKind];
interface Case {
  path: string;
  domain: SpecFileItem["domain"];
  source: string;
  nodes: PrismAstNodeSummary[];
  reads: Read[];
  failed?: boolean;
  hazard?: string;
  watchedGlob?: string;
}

function relativeRequire(specPath: string, targetPath: string) {
  const from = specPath.split("/").slice(0, -1),
    to = targetPath.replace(/\.rb$/, "").split("/");
  while (from.length && from[0] === to[0]) {
    from.shift();
    to.shift();
  }
  return "../".repeat(from.length) + to.join("/");
}
function ordinaryCase(fileId: number, i: number): Case {
  const r = recipes[fileId];
  const stem = r.path
    .replace(/^(app|spec)\//, "")
    .replace(/\.(rb|yml|json)$/, "");
  const market = markets[i % markets.length],
    behavior = cases[Math.floor(i / markets.length)];
  const path =
    i === 0
      ? `spec/${stem}_spec.rb`
      : `spec/${stem}/${market}/${behavior}_spec.rb`;
  const kind: DependencyEdgeKind =
    !r.constant || (fileId === 0 && i % 6 === 5)
      ? "SYSCALL_FILE_OPEN"
      : r.path.startsWith("spec/")
        ? "ROOT_SCOPE_PRELOAD"
        : i % 5 === 4
          ? "PRISM_AST_REQUIRE"
          : "PRISM_AST_CONSTANT";
  const dynamic = kind === "SYSCALL_FILE_OPEN";
  const reads: Read[] = [[fileId, kind]];
  const requires = ['require "spec_helper"'];
  if (kind === "PRISM_AST_REQUIRE")
    requires.push(`require_relative "${relativeRequire(path, r.path)}"`);
  if (!r.constant)
    requires.push(`require "${r.path.endsWith(".json") ? "json" : "yaml"}"`);
  const subject = dynamic ? `"${stem.split("/").at(-1)} contract"` : r.constant;
  let assertion =
    dynamic && r.constant
      ? `expect(File.read("${r.path}").lines.first.chomp).to eq("# typed: strict")`
      : r.assertion;
  // Six payment examples also assert the ledger amount. They occupy the same six bits in both masks.
  if (fileId === 0 && i < 6) {
    reads.push([1, "PRISM_AST_CONSTANT"]);
    assertion +=
      '\n    expect(Ledger::LedgerEntry.new(amount_minor: 100, currency: "USD").major_units).to eq(1)';
  }
  assertion = assertion
    .replaceAll("acct_us", `acct_${market}`)
    .replaceAll('"USD"', `"${market.toUpperCase()}"`);
  const source = `# typed: strict\n${requires.join("\n")}\n\nRSpec.describe ${subject} do\n  it "checks the ${market.toUpperCase()} ${behavior.replace("_", " ")} contract" do\n    ${assertion}\n  end\nend\n`;
  const nodes = [landmark(source, "RSpec.describe", "CallNode")];
  if (!dynamic && r.constant)
    nodes.push(
      landmark(
        source,
        r.constant,
        r.constant.includes("::") ? "ConstantPathNode" : "ConstantReadNode",
      ),
    );
  if (dynamic)
    nodes.push(
      landmark(
        source,
        r.path.endsWith(".yml") ? "YAML.load_file" : "File.read",
        "CallNode",
      ),
    );
  if (kind === "PRISM_AST_REQUIRE")
    nodes.push(landmark(source, "require_relative", "CallNode"));
  if (reads.length > 1)
    nodes.push(landmark(source, "Ledger::LedgerEntry", "ConstantPathNode"));
  return { path, domain: r.domain, source, nodes, reads };
}
function linter(
  name: string,
  call: string,
  pattern?: string,
  configId?: number,
): Case {
  const config =
    configId === 2
      ? 'YAML.load_file("config/payment_rails.yml")'
      : 'JSON.parse(File.read("config/fx_curated_rates.json"))';
  const source = `# typed: strict\nrequire "spec_helper"\n${configId === undefined ? "" : `require "${configId === 2 ? "yaml" : "json"}"\n`}\nRSpec.describe "${name.replaceAll("_", " ")}" do\n  it "validates each matching input" do\n${configId === undefined ? "" : `    expect(${config}).to be_a(Hash)\n`}    paths = ${call}\n    expect(paths).to all(be_a(String))\n  end\nend\n`;
  const symbol = call.startsWith("Dir[") ? "Dir[" : "Dir.glob";
  return {
    path: `spec/linters/${name}_spec.rb`,
    domain: "linters",
    source,
    nodes: [
      landmark(source, "RSpec.describe", "CallNode"),
      landmark(source, symbol, "CallNode", true),
    ],
    hazard: call,
    watchedGlob: pattern,
    reads: configId === undefined ? [] : [[configId, "SYSCALL_FILE_OPEN"]],
  };
}
function previousFailure(): Case {
  const source =
    '# typed: strict\nrequire "spec_helper"\nrequire "yaml"\n\nRSpec.describe "settlement replay" do\n  it "keeps the payment rail stable on retry" do\n    rails = YAML.load_file("config/payment_rails.yml")\n    expect(rails.fetch("rails").fetch("usd")).to eq("ach")\n  end\nend\n';
  return {
    path: "spec/payments/settlement_replay_spec.rb",
    domain: "payments",
    source,
    nodes: [landmark(source, "YAML.load_file", "CallNode")],
    failed: true,
    reads: [[2, "SYSCALL_FILE_OPEN"]],
  };
}

export function createPayServerMini(): Snapshot {
  const files = makeFiles();
  const lintCases = [
    linter(
      "rail_manifest",
      'Dir.glob(ENV.fetch("RAIL_MANIFEST_GLOB"))',
      undefined,
      2,
    ),
    linter("fx_fixtures", 'Dir[ENV.fetch("FX_FIXTURE_GLOB")]', undefined, 3),
    previousFailure(),
    ...[
      "migration_schema",
      "settlement_uniqueness",
      "reversible_change",
      "index_lock",
      "table_naming",
      "foreign_key",
      "column_defaults",
    ].map((name) => linter(name, `Dir.glob("${GLOB}")`, GLOB)),
  ];
  const counts = [24, 14, 14, 8, 0, 20];
  const otherIds = files
    .filter((f) => f.id >= counts.length && f.category !== "migration")
    .map((f) => f.id);
  const remaining = SIZE - counts.reduce((a, b) => a + b, 0) - lintCases.length;
  const groups = files.map((file) => {
    const rank = otherIds.indexOf(file.id);
    const count =
      counts[file.id] ??
      (rank < 0
        ? 0
        : Math.floor(remaining / otherIds.length) +
          Number(rank < remaining % otherIds.length));
    return Array.from({ length: count }, (_, i) => ordinaryCase(file.id, i));
  });
  // Interleave source groups: bit positions span words rather than contiguous runs of related tests.
  groups.splice(2, 0, lintCases);
  const specs: SpecFileItem[] = [];
  for (let i = 0; i < Math.max(...groups.map((g) => g.length)); i++) {
    for (const group of groups) {
      const item = group[i];
      if (!item) continue;
      const id = specs.length;
      for (const [fileId, kind] of item.reads) {
        files[fileId].impactedTestIds.push(id);
        files[fileId].edgeKindsByTestId[id] = kind;
      }
      specs.push({
        id,
        path: item.path,
        domain: item.domain,
        avgDurationMs: 420 + ((id * 317 + 97) % 683),
        failedInBaseline: !!item.failed,
        hasPrismDynamicHazard: !!item.hazard,
        hazardDetail: item.hazard,
        watchedGlob: item.watchedGlob,
        accessedFileIds: item.reads.map(([fileId]) => fileId),
        rubySpecPreview: item.source,
        astNodes: item.nodes,
      });
    }
  }
  // Calibrate fixture durations once, not at selection time. Both totals are sums of integer milliseconds.
  const surgicalIds = new Set([
    ...files[0].impactedTestIds,
    ...files[1].impactedTestIds,
    ...specs
      .filter(
        (s) =>
          s.failedInBaseline || (s.hasPrismDynamicHazard && !s.watchedGlob),
      )
      .map((s) => s.id),
  ]);
  const scale = (group: SpecFileItem[], total: number) => {
    const sum = group.reduce((n, s) => n + s.avgDurationMs, 0);
    let remainder = total;
    group.forEach((s) => {
      s.avgDurationMs = Math.floor((s.avgDurationMs / sum) * total);
      remainder -= s.avgDurationMs;
    });
    group.slice(0, remainder).forEach((s) => s.avgDurationMs++);
  };
  scale(
    specs.filter((s) => surgicalIds.has(s.id)),
    31_400,
  );
  scale(
    specs.filter((s) => !surgicalIds.has(s.id)),
    912_000 - 31_400,
  );
  const bitOf = (path: string) => {
    const spec = specs.find((s) => s.path === path);
    if (!spec) throw new Error(`Unknown shadow observation: ${path}`);
    return spec.id;
  };
  // Fixed observations of hypothetical full-suite replays, independent of current selection masks.
  return {
    name: "pay-server-mini",
    files,
    specs,
    scenarios,
    lazyRootId: 5,
    shadowRuns: [
      {
        scenario: "A",
        lazyRoot: false,
        observedFailureIds: [
          "spec/services/idempotency_coordinator_spec.rb",
          "spec/models/ledger_entry_spec.rb",
        ].map(bitOf),
      },
      {
        scenario: "B",
        lazyRoot: false,
        observedFailureIds: [
          "spec/config/payment_rails_spec.rb",
          "spec/config/fx_curated_rates_spec.rb",
        ].map(bitOf),
      },
      {
        scenario: "C",
        lazyRoot: false,
        observedFailureIds: [bitOf("spec/linters/migration_schema_spec.rb")],
      },
      {
        scenario: "D",
        lazyRoot: false,
        observedFailureIds: [
          bitOf("spec/support/root_boot_helper_spec.rb"),
          bitOf("spec/services/webhook_signer_spec.rb"),
        ],
      },
      {
        scenario: "D",
        lazyRoot: true,
        observedFailureIds: [bitOf("spec/support/root_boot_helper_spec.rb")],
      },
    ],
  };
}
