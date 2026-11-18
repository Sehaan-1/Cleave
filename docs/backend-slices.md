# Backend slices

The Ruby engine is built in independently reviewable slices. This sequence supplements the workbench delivery ledger; none of the later slices is implied by the static pass.

1. **Static Prism pass**: parse Ruby files without executing them; return located constant definitions/references, literal `require_relative` edges and hazard facts. Mark matching spec files mandatory. Fail closed on parse/I/O errors. Delivered.
2. **Scoped tracing**: define isolation and recording semantics, hook actual runtime reads/requires, preserve root/test attribution and handle parallelism and incomplete traces safely. This slice exposes process-local observations and explicit limitations; opt-in fork aggregation is best effort and remains incomplete. Serial RSpec example tracing is available as a separate opt-in run.
3. **Inventory and bitmap index**: content hashes, path-based test identities, versioned persisted artifacts and schema validation, covering additions/deletions and incomplete data. This slice produces incomplete indexes; it does not select tests.
4. **Selection**: compare inventories and OR bitmaps with explicit safety behavior and attribution. The preview measures its actual OR time, but v1 indexes require full-suite fallback; no execution adapter or latency guarantee is provided.
5a. **Guardrail planning**: apply Prism hazards, caller-supplied prior failures and root fallback to the diagnostic union; abort on stale or invalid spec source. v1 indexes still require the full suite and cannot authorize execution.
6. **RSpec execution**: run the configured suite serially by default or explicitly partition RSpec-discovered files into isolated parallel workers; persist observed outcomes and propagate failures. Full-suite fallback is mandatory, and configured-suite coverage is not verified.
7a. **Shadow verification**: compare a diagnostic guardrailed candidate with failures observed in one configured full-suite run; never authorize skipping.
7b. **Terminal telemetry**: report measured runner/worker-collection durations and observed example/spec counts, plus diagnostic shadow candidate/OR metrics when available.
7c. **Graph export**: standalone interactive HTML exploration of the observed artifact relationships, with explicit limitations. Verify against real projects before claiming any false-negative rate.
8a. **Artifact inspector**: locally import and validate the versioned inventory/index pair, without mixing it with the simulator.
8b. **Local CLI delivery**: package and serve a validated startup snapshot of the artifact pair from the Ruby CLI on loopback.
9a. **RSpec trace capture**: trace one configured full-suite RSpec process, persist incomplete root/example observations; do not skip tests.
9b. **Automated artifact generation**: opt in to build and persist incomplete inventories and indexes from the same serial traced run; Git-based before/after snapshots are not transactional, and test skipping remains disabled.
9d. **Best-effort fork observations**: opt-in collection of Ruby fork reports from one traced RSpec process, with inherited scope and explicit child-coverage limitations; no test skipping.
10a. **Diagnostic project plan**: expose current Git inventory, RSpec dry-run discovery and guardrailed candidates as versioned JSON; no selective execution.
9c. **Artifact publication provenance**: mark generation in progress/incomplete and bind both exact artifact byte streams to a local marker; do not infer authentication, freshness or coverage.
10d. **Approximate static dependency planning**: opt-in bounded current-inventory graph of relative requires and syntactic constant-name matches, with conservative uncertainty/deletion attribution and full-suite fallback.
10c. **Prior failure input**: opt in to use the latest internally consistent run record in the CLI diagnostic plan and workbench, with source digest and explicit unmatched paths; unsigned observations do not prove coverage and cannot authorize skipping.
10b. **Local plan viewer**: opt in to compute and display a validated diagnostic startup plan in the loopback workbench, separate from simulator and artifact inspector; no selective execution.

Exact boundaries and ordering may change as implementation constraints are discovered. A static AST is not evidence that a skipped test is safe.
