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

The workbench can also inspect real version 1 inventory and bitmap artifacts locally in a separate mode. `bundle exec cleave ui` packaging remains a separate delivery. See [the delivery ledger](docs/delivery.md) for acceptance criteria and example reconciliation.

## Import real artifacts

In the browser workbench choose **Import artifacts**, select a matching `.cleave/inventory.json` and `.cleave/bitmap_index.json` pair, then select **Load artifacts**. The files are read locally and never uploaded. Each file is limited to 10 MiB and must be valid UTF-8 JSON. The inspector validates v1 schemas, duplicate keys, path ordering, SHA-256 values and inventory fingerprint, index binding, spec references and bitmap ranges before showing data. Matching fingerprints detect incompatible pairs but do not authenticate them. Only the pair emitted by the current Ruby backend is supported; there is no `index.json` emitter yet.

Browse or search recorded and inventoried paths, inspect baseline hashes and root scope, and page through recorded spec associations. An observed path can be absent from the baseline inventory, for example after a failed file read. The bitmap does not retain operation type or attempt/success status. Source, AST, timing, current changes and audit results are unavailable in these artifacts; the inspector does not substitute demo values. Switching back to the simulator displays only its separate fixture. The imported index is always incomplete and **cannot authorize skipping tests**. The inspector is not yet wired to a current inventory, selection, runner, or local CLI server.

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

The two JSON files have explicit schemas and versions. Bitmap masks are canonical lowercase hexadecimal integers; the index binds to the inventory's content fingerprint. Reading validates fields, paths, duplicate JSON keys, IDs/ranges, and the fingerprint, and rejects unsupported versions or incomplete/mismatched pairs. Each file is replaced atomically, but the pair is **not** a single atomic transaction. A fingerprint detects a mixed pair when inventories differ; it is not an authenticity signature or a guarantee against concurrent writers. Both artifacts deliberately record `complete: false`. **Do not use this index to skip tests.** Safe selective execution and local CLI workbench integration are later slices.

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

**This API cannot authorize skipping or execute tests.** Every v1 index is incomplete, so `requires_full_suite?` is always true and `execution_ready?` is always false. `selected_specs` and `execution_mask` are full only over the caller-supplied current universe: independently discover the full suite; they cannot prove it contains every test. Omission of an indexed spec still present in the inventory is rejected, but unknown new/custom test paths cannot be inferred reliably. A future runner must invoke full-suite discovery when this fallback is set, never dispatch the preview or rely on the supplied list alone. Prism and prior-failure guardrails are planned separately below. Static dependency resolution remains unimplemented; the runner below never executes this preview.

## Guardrail planning

`Cleave::Guardrails.plan` combines the selection preview with Prism hazards and caller-supplied previous failures. It re-reads every supplied current Ruby spec, verifies its SHA-256 against the current inventory, and parses those exact bytes. A stale, missing, symlinked, non-Ruby, unreadable or invalid spec aborts the plan rather than being treated as hazard-free.

```ruby
plan = Cleave::Guardrails.plan(
  root: Dir.pwd, baseline: baseline, current: current, index: index,
  current_specs: all_current_spec_paths,
  previous_failures: previous_failed_spec_paths # nil means unavailable, [] means known empty
)
p plan.mandatory_mask                  # Prism hazard bits, current spec positions
p plan.previous_failure_mask           # previous failure bits, current spec positions
p plan.root_mask                       # full supplied suite if a recorded root path changed
p plan.guardrailed_candidate_specs      # preview only; masks are ORed, not summed
p plan.fallback_reasons
```

The plan preserves overlapping reasons, hazard locations and unmatched previous-failure paths. The supplied previous-failure list is not independently verified or persisted by this API; missing or unmatched results are explicitly flagged. Root changes select the whole supplied universe in the preview. As before, the universe must be independently discovered, v1 indexes are incomplete, and the plan **always requires a full-suite fallback and is not execution-ready**. Neither the guardrailed preview nor the supplied list is authorization to skip tests. The configured-suite runner below persists observed outcomes and propagates failures; it does not yet feed them back into this plan.

## Run the configured RSpec suite

Add `cleave-ste` and `rspec` to your project's Gemfile and install its bundle. From the project root:

```sh
bundle exec cleave                    # one RSpec process (default)
bundle exec cleave run --workers 4    # opt in to parallel file workers
```

This runner **never executes the selective preview**. The default runs `bundle exec rspec` with an additional JSON formatter, so the project's RSpec configuration determines its suite. With more than one worker, Cleave asks RSpec for its configured file list in a dry run, partitions that list without shell interpolation, and starts up to the requested number of processes. Dry-run discovery loads spec files and can therefore have top-level side effects. Parallel workers have separate Ruby processes: suite hooks, shared state, global ordering, randomization and plugins may behave differently from a single RSpec run. Worker invocations override RSpec's pattern with `**/*` to prevent RSpec from expanding the entire configured directory alongside explicit file paths; the dry-run file list remains authoritative. Parallel mode rejects filenames containing RSpec selector characters (`[`, `]`, or `:`); use serial mode for those files. Use parallel mode only for suites designed for process isolation; run serially if that is not true. RSpec configuration or filters may intentionally exclude examples; this runner cannot prove coverage of every test in a repository.

The exit status is zero only when the launched reports are consistent and report no failures; failing examples, discovery errors, crashed workers, and zero examples produce a nonzero exit. Worker output is displayed after each worker completes. Interrupting the runner terminates its worker process groups and records an incomplete run. Results are written atomically to `.cleave/last_run.json` under a process lock. A `running` record is written before launch so an interrupted/crashed run does not silently reuse an old success. The versioned record includes observed failed spec paths, example counts and errors. `reports_complete` only means the launched RSpec reports were readable and internally consistent; `suite_coverage_verified` is always false. These records are observations, not proof of full test coverage, a shadow audit, or authorization to skip tests. The file does not yet automatically feed guardrail planning.


## Full-suite shadow verification

`bundle exec cleave run --verify` compares a guardrailed **diagnostic candidate** against failures observed in a single configured full-suite RSpec run. First create a baseline `.cleave/inventory.json` and `.cleave/bitmap_index.json` as described above, with all baseline spec paths. Run from a Git project root after changing the project. The command uses RSpec dry-run discovery, captures tracked and non-ignored files plus baseline and discovered paths, builds the candidate before execution, then runs the configured suite serially. It checks the project inventory again afterward. The regular `.cleave/last_run.json` includes a `verification` object; its status is `observed_misses`, `no_observed_misses`, or `incomplete`.

An observed miss is a **failing spec file** reported by the full suite that was not in the candidate. It is evidence of a candidate miss for that run, not a diagnosis of why the test failed. No observed misses is **not** a zero false-negative rate: passing tests, flaky tests, filtered examples, unobserved files and other execution contexts are not verified. The result does not prove configured-suite completeness or authorize skipping tests. The candidate applies static hazard and root guardrails, but previous failures are unavailable and explicitly flagged; the runner's previous record is not implicitly trusted. Incomplete or stale artifacts, discovery failures, inconsistent reports, or inventory changes produce an incomplete verification and nonzero exit. If planning fails, the runner still attempts the normal full suite. Failures retain a nonzero exit regardless of verification.

Verification currently requires one worker; `--workers` greater than one is rejected. Discovery loads spec files in a separate dry-run process and can have side effects or differ from the subsequent real run. Git capture is not a transactional snapshot and cannot detect ignored new files, external dependencies, changes reverted during the run, or tests excluded by RSpec configuration. Explicitly inventory ignored generated dependencies in the baseline. A consistent report is not evidence of complete coverage. Trace/index incompleteness and mandatory full-suite fallback remain unchanged. No selective execution or automated shadow replay is performed.


## Terminal telemetry

Every completed CLI run prints a plain-text telemetry summary and records the underlying integer measurements in `.cleave/last_run.json` under `telemetry` (version 1). `runner_elapsed_ns` is monotonic wall time from the start of locked execution through processing and cleanup, excluding lock acquisition and the final status write. `worker_collection_elapsed_ns` covers launching workers, waiting for them, streaming their output and parsing their reports; parallel time is wall time, not the sum of worker runtimes. It is unavailable if collection aborts. Interrupted runs persist elapsed runner time but do not print the final summary.

Example outcome counts and spec-file counts are derived from successfully parsed RSpec reports. A partial report label means those counts may omit workers or examples and must not be interpreted as suite totals. A file counts once if at least one of its examples appears in a successfully parsed report. Discovery counts are unavailable for a normal serial run, which deliberately does not perform dry-run discovery. With `--verify`, the summary also shows the guardrailed diagnostic candidate count, the measured bitmap OR time (only the OR loop, not planning), and observed missed failing files; if planning fails, the candidate is unavailable. These are observations, not a measurement of tests skipped, runtime saved, or a false-negative rate. Actual execution remains the configured full suite and suite coverage is unverified.

## Export an observed dependency graph

From the project root, with an existing validated `.cleave/inventory.json` and `.cleave/bitmap_index.json` pair:

```sh
bundle exec cleave graph --output .cleave/graph.html
```

Open the generated HTML file locally in a modern browser. It is self-contained and uses no network requests. Search and page through observed paths or indexed specs, follow associations in either direction, and inspect recorded root-scope paths and index limitations. Long lists are paginated without dropping associations. An existing regular output file is replaced atomically; symlink output targets are rejected, and the output directory must already exist. Artifact paths and limitations are escaped before embedding; nevertheless, only open exports and artifacts from sources you trust.

The graph reflects **baseline artifact observations**, not the current diff or a live trace. A bitmap associates an observed path with a spec; it does not retain operation types, distinguish attempts from successful reads, identify precise lines, or prove that an edge is exhaustive. Root-scope observations are shown separately, not fabricated as per-spec edges. An observed path absent from the inventory may represent a missing-file attempt. External paths were omitted by the indexer. The index is incomplete and configured-suite coverage is not verified: **never use this graph to decide which tests to skip**. Static graph resolution and `cleave ui` remain separate work.
