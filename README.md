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

The static pass by itself does **not** resolve the transitive constant graph, trace runtime opens, select or run tests, or prove absence of false negatives. Static facts alone cannot safely cover Ruby's dynamic behavior; do not use this slice by itself to skip tests. The UI remains a fixture-driven simulation.

## Scoped Ruby access tracing

This slice adds an opt-in, process-local observation API; it is **not** yet wired to RSpec or safe execution. Reports can be fed to the incomplete artifact index below:

```ruby
require "cleave"
trace = Cleave::ScopedTrace.start(root: Dir.pwd)
begin
  # Load the test harness here: observations go to root scope "r".
  trace.with_spec("spec/services/payout_spec.rb") do
    # Execute this spec file here. Nested scopes are restored even on exceptions.
  end
ensure
  report = trace.stop
end
p report.to_h
```

The recorder observes Ruby-level `File.open`, `IO.read` / `IO.binread` (including inherited `File.read` / `File.binread`), `YAML.load_file`, and successful or cached `Kernel.require`. It records deduplicated `attempt` and `success` events, including failed read attempts, so an absent path is not silently discarded. Successful requires are resolved against loaded features and the load path; unresolved features produce a limitation instead of a fabricated path. Paths inside the chosen root are relative to it; outside paths are absolute. They are lexically normalized, not realpath-resolved, so symlink aliases are not collapsed. Opens for writing are conservatively included. Event scope is `r` or the supplied spec name.

Hooks are installed process-wide once and are dormant after `stop`. Only one session may be active per process. Scope stacks are **fiber-local**: new threads and fibers default to root until explicitly wrapped with `with_spec`. A fork receives a copy of the session; the parent does not receive child events automatically. Collect the child's `report.to_h` over IPC before it exits and retain it separately with the parent's report. The report includes its PID. Traces must be captured over the entire intended boot and test run; loading Cleave itself occurs before capture starts.

**Safety:** `complete` is always false. Ruby-level hooks cannot see native extensions, direct syscalls, subprocesses, all IO APIs, directory probes, or `require_relative` reliably. Unscoped concurrent work and uncollected children are also incomplete. A failed `require` is not recorded as a file dependency. A trace must never be used alone to skip tests. Later slices must define conservative fallback, process aggregation, schema and runner integration before any selection is safe.

## Inventory and bitmap artifacts

The Ruby library can capture repository content and persist a **versioned, incomplete** bitmap index. Capture only in a stable checkout and stop tracing before writing artifacts:

```ruby
require "cleave"

# Hash tracked and non-ignored untracked Git files; include ignored generated files explicitly.
inventory = Cleave::Inventory.capture_git(root: Dir.pwd, generated: ["generated/schema.json"])
# Alternatively: Cleave::Inventory.capture(root: Dir.pwd, paths: ["app/model.rb", "spec/model_spec.rb"])
index = Cleave::BitmapIndex.build(
  inventory: inventory, root: Dir.pwd,
  specs: ["spec/model_spec.rb"], reports: [report] # TraceReport(s) collected from this root
)
Cleave::Artifacts.write(".cleave", inventory: inventory, index: index)
loaded_inventory, loaded_index = Cleave::Artifacts.read(".cleave")
changes = loaded_inventory.diff(Cleave::Inventory.capture_git(root: Dir.pwd, generated: ["generated/schema.json"]))
```

`diff` returns sorted added, deleted, and content-modified paths; missing requested paths are omitted, making deletions observable. SHA-256 is streamed for regular files; symlinks, special files, `.git` paths, malformed paths, and files that change during hashing are rejected. Git capture requires `git` and includes non-ignored untracked files; generated files must be named explicitly. UTF-8 relative paths are required. The capture isn't a transactional filesystem snapshot and isn't hardened against a maliciously changing checkout.

Spec **paths** are identities; within each index they are sorted and assigned contiguous zero-based bit positions. Positions can change when specs are added or removed, so do not combine masks from different indexes. Trace observations for absent paths are retained, including failed reads; root-scope paths are stored separately. Unknown scopes and mismatched trace roots are rejected. External paths are omitted and noted as a limitation. Multiple explicitly collected reports can be supplied, but this does not prove all processes or tests were observed.

The two JSON files have explicit schemas and versions. Bitmap masks are canonical lowercase hexadecimal integers; the index binds to the inventory's content fingerprint. Reading validates fields, paths, duplicate JSON keys, IDs/ranges, and the fingerprint, and rejects unsupported versions or incomplete/mismatched pairs. Each file is replaced atomically, but the pair is **not** a single atomic transaction. A fingerprint detects a mixed pair when inventories differ; it is not an authenticity signature or a guarantee against concurrent writers. Both artifacts deliberately record `complete: false`. **Do not use this index to skip tests.** Safe selective execution, UI import, and CLI integration are later slices.

## Bitmap selection preview

```ruby
# `baseline` and `index` must be a validated pair; `current` is a new inventory.
# Independently discover every current spec first (including new and renamed specs).
result = Cleave::Selection.select(
  baseline: baseline, current: current, index: index, current_specs: all_current_spec_paths
)
p result.changes                # added / deleted / modified paths
p result.candidate_specs        # OBSERVED preview, not an execution list
p result.selected_specs         # all supplied current specs, because fallback is mandatory
p result.fallback_reasons       # includes "incomplete_index"
p result.union_nanoseconds      # monotonic time for bitmap OR only
```

The preview ORs each changed path's recorded bitmap, attributes its bits to changed files, and additionally includes changed or newly discovered specs. `observed_baseline_mask` uses baseline index positions; `candidate_mask` and `execution_mask` use the sorted **current** spec positions. Removed specs are not execution candidates. Each decision exposes its bitmap sources, changed/unindexed status and fallback reasons. Root-scope changes and unmapped changes are reported separately. Timings are actual measurements, not a guaranteed latency target.

**This API cannot authorize skipping or execute tests.** Every v1 index is incomplete, so `requires_full_suite?` is always true and `execution_ready?` is always false. `selected_specs` and `execution_mask` are full only over the caller-supplied current universe: independently discover the full suite; they cannot prove it contains every test. Omission of an indexed spec still present in the inventory is rejected, but unknown new/custom test paths cannot be inferred reliably. A future runner must invoke full-suite discovery when this fallback is set, never dispatch the preview or rely on the supplied list alone. Previous-failure and Prism guardrails, execution, static dependency resolution and shadow verification are not implemented by this slice.
