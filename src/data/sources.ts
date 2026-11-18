import { sha256 } from "@noble/hashes/sha256";
import { bytesToHex, utf8ToBytes } from "@noble/hashes/utils";
import type {
  PrismAstNodeSummary,
  RepoFileItem,
  SpecFileItem,
} from "../types/cleave";

type Domain = SpecFileItem["domain"];
export interface SourceRecipe {
  path: string;
  domain: Domain;
  constant?: string;
  source: string;
  previous: string | null;
  assertion: string;
}

function service(
  name: string,
  domain: Domain,
  method: string,
  params: string,
  result: string,
  expression: string,
  assertion: string,
  previous: string,
  imports = "",
  folder = "services",
): SourceRecipe {
  const [namespace, klass] = name.split("::");
  const filename = klass.replace(/([a-z])([A-Z])/g, "$1_$2").toLowerCase();
  const args = params
    .split(", ")
    .map((p) => p.split(":")[0])
    .join(", ");
  const source = `# typed: strict\n${imports ? `${imports}\n\n` : ""}module ${namespace}\n  class ${klass}\n    extend T::Sig\n\n    sig { params(${params}).returns(${result}) }\n    def self.${method}(${args})\n      ${expression}\n    end\n  end\nend\n`;
  return {
    path: `app/${folder}/${filename}.rb`,
    domain,
    constant: name,
    source,
    previous: source.replace(expression, previous),
    assertion,
  };
}
function model(
  klass: string,
  domain: Domain,
  field: string,
  scale: number,
): SourceRecipe {
  const filename = klass.replace(/([a-z])([A-Z])/g, "$1_$2").toLowerCase();
  const source = `# typed: strict\nmodule Ledger\n  class ${klass} < T::Struct\n    extend T::Sig\n\n    const :${field}, Integer\n    const :currency, String\n\n    sig { returns(Rational) }\n    def major_units\n      Rational(${field}, ${scale})\n    end\n  end\nend\n`;
  return {
    path: `app/models/${filename}.rb`,
    constant: `Ledger::${klass}`,
    domain,
    source,
    previous: source.replace(`, ${scale})`, ", 1)"),
    assertion: `expect(described_class.new(${field}: 250, currency: "USD").major_units).to eq(Rational(250, ${scale}))`,
  };
}
function config(
  file: string,
  domain: Domain,
  source: string,
  previous: string,
): SourceRecipe {
  const path = `config/${file}`;
  return {
    path,
    domain,
    source,
    previous,
    assertion: `expect(${file.endsWith(".json") ? `JSON.parse(File.read("${path}"))` : `YAML.load_file("${path}")`}).to be_a(Hash)`,
  };
}
function migration(name: string, table: string, field: string): SourceRecipe {
  const klass = name
    .split("_")
    .map((word) => word[0].toUpperCase() + word.slice(1))
    .join("");
  return {
    path: `db/migrations/20261118_${name}.rb`,
    domain: "linters",
    constant: klass,
    previous: null,
    source: `# typed: strict\nclass ${klass} < ActiveRecord::Migration[7.2]\n  extend T::Sig\n\n  sig { void }\n  def change\n    add_index :${table}, :${field}, unique: true\n  end\nend\n`,
    assertion: "",
  };
}
function helper(path: string, name: string, key: string): SourceRecipe {
  const source = `# typed: strict\nmodule ${name}\n  extend T::Sig\n\n  RAIL = T.let(ENV.fetch("${key}", "sandbox"), String)\n\n  sig { returns(String) }\n  def self.rail\n    RAIL\n  end\nend\n`;
  return {
    path,
    domain: "payments",
    constant: name,
    source,
    previous: source.replace("sandbox", "test"),
    assertion: "expect(described_class.rail).to be_a(String)",
  };
}

export const recipes: SourceRecipe[] = [
  service(
    "Payments::IdempotencyCoordinator",
    "payments",
    "cache_key",
    "merchant: String, token: String",
    "String",
    '"v2:#{merchant}:#{token}"',
    'expect(described_class.cache_key("acct_us", "once")).to eq("v2:acct_us:once")',
    '"#{merchant}:#{token}"',
  ),
  model("LedgerEntry", "ledger", "amount_minor", 100),
  config(
    "payment_rails.yml",
    "payments",
    "rails:\n  usd: ach\n  eur: sepa\n  gbp: fps\n",
    "rails:\n  usd: ach\n  eur: sepa\n",
  ),
  config(
    "fx_curated_rates.json",
    "fx_routing",
    '{\n  "base": "USD",\n  "rates": { "EUR": 0.92, "GBP": 0.78 }\n}\n',
    '{"base":"USD","rates":{"EUR":0.91,"GBP":0.78}}\n',
  ),
  migration("add_settlement_index", "settlements", "transfer_id"),
  helper("spec/support/root_boot_helper.rb", "RootBootHelper", "PAYMENT_RAIL"),
  service(
    "Payments::PayoutRouter",
    "payments",
    "route",
    "currency: String",
    "String",
    'currency == "EUR" ? "sepa" : "ach"',
    'expect(described_class.route("EUR")).to eq("sepa")',
    '"ach"',
  ),
  service(
    "Webhooks::WebhookSigner",
    "webhooks",
    "sign",
    "payload: String, secret: String",
    "String",
    'OpenSSL::HMAC.hexdigest("SHA256", secret, payload)',
    'expect(described_class.sign("payout.paid", "test-key").size).to eq(64)',
    'OpenSSL::HMAC.hexdigest("SHA512", secret, payload)',
    'require "openssl"',
  ),
  service(
    "Limits::TokenBucketLimiter",
    "rate_limiter",
    "remaining",
    "capacity: Integer, used: Integer",
    "Integer",
    "[capacity - used, 0].max",
    "expect(described_class.remaining(8, 12)).to eq(0)",
    "capacity - used",
    "",
    "middleware",
  ),
  model("PaymentIntent", "payments", "authorized_minor", 100),
  model("BalanceTransaction", "ledger", "net_minor", 100),
  service(
    "Routing::FxSettlement",
    "fx_routing",
    "convert",
    "amount: Integer, rate: Rational",
    "Integer",
    "(amount * rate).round",
    "expect(described_class.convert(10, Rational(3, 2))).to eq(15)",
    "(amount * rate).floor",
  ),
  model("ExchangeQuote", "fx_routing", "quote_minor", 100),
  service(
    "Routing::RailResolver",
    "payments",
    "normalize",
    "rail: String",
    "String",
    "rail.strip.downcase",
    'expect(described_class.normalize(" ACH ")).to eq("ach")',
    "rail.downcase",
  ),
  config(
    "fx_rates.yml",
    "fx_routing",
    "base: USD\nrates:\n  CAD: 1.38\n  EUR: 0.92\n",
    "base: USD\nrates:\n  CAD: 1.37\n",
  ),
  service(
    "Webhooks::SignatureVerifier",
    "webhooks",
    "valid_size?",
    "signature: String",
    "T::Boolean",
    "signature.bytesize == 64",
    'expect(described_class.valid_size?("a" * 64)).to be(true)',
    "signature.bytesize == 128",
  ),
  service(
    "Ledger::SettlementBatcher",
    "ledger",
    "batch",
    "offset: Integer",
    "Integer",
    "offset.div(128)",
    "expect(described_class.batch(256)).to eq(2)",
    "offset.div(64)",
  ),
  model("Refund", "payments", "refunded_minor", 100),
  service(
    "Payments::RetrySchedule",
    "payments",
    "delay",
    "attempt: Integer",
    "Integer",
    "[2 ** attempt, 60].min",
    "expect(described_class.delay(3)).to eq(8)",
    "[2 ** attempt, 30].min",
  ),
  config(
    "webhook_events.yml",
    "webhooks",
    "events:\n  settled: payout.paid\n  reversed: payout.failed\n",
    "events:\n  settled: payout.paid\n",
  ),
  migration("add_fx_settlement", "fx_settlements", "quote_id"),
  helper("spec/support/global_auth_helper.rb", "GlobalAuthHelper", "AUTH_RAIL"),
  helper("spec/spec_helper.rb", "SpecBoot", "SPEC_RAIL"),
  model("Authorization", "payments", "captured_minor", 100),
];

/** Recorded landmarks in fixture source, not a pretend Ruby parser. */
export function landmark(
  source: string,
  symbol: string,
  nodeType: PrismAstNodeSummary["nodeType"],
  isDynamicHazard = false,
): PrismAstNodeSummary {
  const lines = source.split("\n");
  const i = lines.findIndex((line) => line.includes(symbol));
  if (i < 0) throw new Error(`Missing fixture landmark: ${symbol}`);
  return {
    nodeType,
    symbol,
    line: i + 1,
    column: lines[i].indexOf(symbol),
    isDynamicHazard,
    snippet: lines[i].trim(),
  };
}
const digest = (s: string) => bytesToHex(sha256(utf8ToBytes(s)));
export function makeFiles(): RepoFileItem[] {
  return recipes.map((r, id) => {
    const category = r.path.startsWith("app/models/")
      ? "model"
      : r.path.startsWith("config/")
        ? "config_yaml"
        : r.path.startsWith("spec/")
          ? "root_helper"
          : r.path.startsWith("db/")
            ? "migration"
            : "service";
    const astNodes: PrismAstNodeSummary[] = [];
    if (r.constant) {
      astNodes.push(
        landmark(r.source, r.constant.split("::")[0], "ConstantReadNode"),
      );
      astNodes.push(landmark(r.source, "T::Sig", "ConstantPathNode"));
      if (category === "model")
        astNodes.push(landmark(r.source, "T::Struct", "ConstantPathNode"));
      if (category === "migration")
        astNodes.push(landmark(r.source, "add_index", "CallNode"));
      if (category === "root_helper")
        astNodes.push(landmark(r.source, "ENV.fetch", "CallNode"));
    }
    return {
      id,
      path: r.path,
      category,
      scope: category === "root_helper" ? "ROOT" : "TEST_ISOLATED",
      baselineSha256: r.previous === null ? "" : digest(r.previous),
      currentSha256: digest(r.source),
      definedConstants: r.constant ? [r.constant] : [],
      astNodes,
      rubySourcePreview: r.source,
      impactedTestIds: [],
      edgeKindsByTestId: {},
    };
  });
}
