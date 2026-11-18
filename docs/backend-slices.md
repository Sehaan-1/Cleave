# Backend slices

The Ruby engine is built in independently reviewable slices. This sequence supplements the workbench delivery ledger; none of the later slices is implied by the static pass.

1. **Static Prism pass**: parse Ruby files without executing them; return located constant definitions/references, literal `require_relative` edges and hazard facts. Mark matching spec files mandatory. Fail closed on parse/I/O errors. Delivered.
2. **Scoped tracing**: define isolation and recording semantics, hook actual runtime reads/requires, preserve root/test attribution and handle parallelism and incomplete traces safely. This slice exposes process-local observations and explicit limitations; automatic child aggregation and runner integration are future work.
3. **Inventory and bitmap index**: content hashes, path-based test identities, versioned persisted artifacts and schema validation, covering additions/deletions and incomplete data. This slice produces incomplete indexes; it does not select tests.
4. **Selection**: compare inventories and OR bitmaps with explicit safety behavior and attribution. The preview measures its actual OR time, but v1 indexes require full-suite fallback; no execution adapter or latency guarantee is provided.
5. **Guardrails and execution**: carry forward failed tests, AST hazards, root fallback, safe worker dispatch and failure propagation.
6. **Audit/telemetry and graph**: real shadow verification, honest counts/timings, and an HTML export. Verify against a real Ruby project before claiming a false-negative rate.
7. **Workbench integration**: adapt the actual versioned artifacts to the UI and package local CLI assets once the emitter exists.

Exact boundaries and ordering may change as implementation constraints are discovered. A static AST is not evidence that a skipped test is safe.
