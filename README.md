# Cleave UI

A static, interactive selective-test-execution workbench. Explore a deterministic 24-file, 1,200-spec Ruby payment fixture by switching scenarios or editing the file inventory. The dependency map, bitmap words, virtualized decisions, source inspector and telemetry all derive from the same in-browser selection.

## Run locally

Requires Node.js 22.12 or later.

```sh
npm ci
npm run dev
```

For a production bundle and checks:

```sh
npm run typecheck
npm test
npm run build
npm run preview
```

Browser tests use Playwright. Install its Chromium browser with `npx playwright install chromium` (and OS dependencies if necessary), then run `npm run test:e2e`. The production `dist/` directory can be deployed as a static Vercel site; asset paths are relative so it can also be hosted under a subpath.

## Using the demo

Choose A–D in the command bar or search and toggle files in the inventory. The graph has filters for static, runtime and guardrail paths; select a node or spec to inspect its attribution and source. The graph shows a bounded sample of paths and a clickable cluster for remaining visible-path endpoints. Use the table filters or bitmap-word selector to follow individual bits. On compact screens, switch between the inventory, map and matrix using the panel navigation.

Scenario B's YAML/JSON runtime hits overlap mandatory masks, so masks are ORed, not summed. Scenario C's new migration has no baseline readers: directory-watching Prism guardrails select its linters. The root-scope refactor is a counterfactual for the nominated helper only; another changed root preload still forces the full suite. Selection latency is measured in the browser and can be below the clock's resolution.

## Scope and limitations

This first delivery is **a simulator, not a Ruby CLI integration**. Fixture source, AST landmarks, file accesses, durations and shadow observations are deterministic example data; the browser does not run Prism, intercept syscalls, execute specs, or verify a CI build. A recorded demo replay is not proof of a zero false-negative rate for a custom diff. The snapshot's normalized TypeScript model is not a claim about an existing Ruby emitter's JSON schema.

Importing actual `.cleave` artifacts and `bundle exec cleave ui` packaging are planned as separate deliveries once a real emitter, schema and Ruby CLI are available. See [the delivery ledger](docs/delivery.md) for acceptance criteria and example reconciliation.

## Ruby static-analysis slice

The first backend slice is a Ruby library, independent of the browser simulator. With Ruby 3.2+ and Bundler installed:

```sh
bundle install
bundle exec ruby -Ilib test/static_analysis_test.rb
```

```ruby
require "cleave"

files = Cleave::StaticAnalysis.scan("/path/to/repository")
files.each do |file|
  puts "#{file.path}: mandatory=#{file.mandatory?}"
  file.facts.each { |fact| p [fact.kind, fact.value, fact.node_type, fact.location.line, fact.location.column, fact.nesting] }
  file.require_edges.each { |edge| p [edge.source, edge.target] }
end
```

`scan` visits `.rb` files in sorted path order, skipping symlinks, `.git` and `node_modules`. Parse or I/O errors abort rather than returning an incomplete result. `analyze(source, path:, spec: nil)` handles a single file; by default only `spec/**/*_spec.rb` files are classified as specs, and callers can override `spec:` explicitly. Fact locations are one-based lines, zero-based **byte** columns, and byte lengths. Definitions and constant references are syntactic facts with lexical nesting, not resolved Ruby constants. Literal `require_relative` edges expose the path normalized relative to the source file without guessing an extension or requiring it to exist. Dynamic `require_relative`, `Dir.glob`, `Dir[]`, `Dir.entries`, `Dir.children`, `const_get`, eval variants and dynamic sends are conservatively recorded as hazards; hazards only make a file mandatory when it is classified as a spec.

This slice does **not** yet resolve the transitive constant graph, trace runtime opens, hash inventories, select or run tests, export artifacts, or prove absence of false negatives. Static facts alone cannot safely cover Ruby's dynamic behavior; do not use this slice by itself to skip tests. The UI remains a fixture-driven simulation.
