import type {
  DependencyEdgeKind,
  RepoFileItem,
  SelectionReason,
  Snapshot,
  SpecFileItem,
} from "../types/cleave";

export const bit = (id: number) => 1n << BigInt(id);
export const maskOf = (ids: Iterable<number>) => {
  let result = 0n;
  for (const id of ids) result |= bit(id);
  return result;
};
export const wordAt = (mask: bigint, word: number) =>
  BigInt.asUintN(64, mask >> BigInt(64 * word));
export const hexWord = (mask: bigint, word: number) =>
  `0x${wordAt(mask, word).toString(16).padStart(16, "0").match(/.{4}/g)!.join("_")}`;
export const staticEdge = (kind: DependencyEdgeKind) =>
  kind === "PRISM_AST_CONSTANT" || kind === "PRISM_AST_REQUIRE";

export function buildIndex(snapshot: Snapshot) {
  const fileMasks = new Map(
    snapshot.files.map((file) => [file.id, maskOf(file.impactedTestIds)]),
  );
  const watched = new Map<string, bigint>();
  let alwaysMask = 0n,
    failedMask = 0n;
  for (const spec of snapshot.specs) {
    if (spec.failedInBaseline) failedMask |= bit(spec.id);
    if (!spec.hasPrismDynamicHazard) continue;
    if (spec.watchedGlob)
      watched.set(
        spec.watchedGlob,
        (watched.get(spec.watchedGlob) ?? 0n) | bit(spec.id),
      );
    else alwaysMask |= bit(spec.id);
  }
  // Only single-segment * globs are part of this fixture contract (never recurse across '/').
  const watchMasks = Array.from(watched, ([glob, mask]) => ({
    mask,
    pattern: new RegExp(
      "^" +
        glob
          .split("*")
          .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
          .join("[^/]*") +
        "$",
    ),
  }));
  return {
    snapshot,
    fileMasks,
    watchMasks,
    alwaysMask,
    failedMask,
    suiteMask: bit(snapshot.specs.length) - 1n,
    bits: snapshot.specs.map((s) => bit(s.id)),
    baselineMs: snapshot.specs.reduce((n, s) => n + s.avgDurationMs, 0),
  };
}
export type BitmapIndex = ReturnType<typeof buildIndex>;
export interface SpecDecision {
  spec: SpecFileItem;
  reason: SelectionReason;
  /** Actual bitmap hits, independent of the reason that took precedence. */
  hits: { file: RepoFileItem; kind: DependencyEdgeKind }[];
  guardFiles: RepoFileItem[];
}

export function selectTests(
  index: BitmapIndex,
  changedIds: readonly number[],
  lazyRoot = false,
) {
  const { snapshot } = index;
  const ids = new Set(changedIds);
  const changed = snapshot.files.filter((f) => ids.has(f.id));
  const roots = changed.filter(
    (f) => f.scope === "ROOT" && !(lazyRoot && f.id === snapshot.lazyRootId),
  );
  const filesById = new Map(changed.map((file) => [file.id, file]));

  // Time only assembling the masks, not building the index, describing rows, layout, or rendering.
  const watchedByFile = new Map<RepoFileItem, bigint>();
  const start = performance.now();
  let directMask = 0n,
    guardMask = index.alwaysMask;
  for (const file of changed) {
    directMask |= index.fileMasks.get(file.id)!;
    for (const { pattern, mask } of index.watchMasks) {
      if (!pattern.test(file.path)) continue;
      guardMask |= mask;
      watchedByFile.set(file, (watchedByFile.get(file) ?? 0n) | mask);
    }
  }
  const rootMask = roots.length ? index.suiteMask : 0n;
  const finalMask = directMask | guardMask | index.failedMask | rootMask;
  const unionUs = (performance.now() - start) * 1000;

  let selected = 0,
    direct = 0,
    guardrails = 0,
    failures = 0,
    rootCount = 0,
    selectedMs = 0;
  let dynamicOnly = 0,
    staticCovered = 0,
    bitmapHits = 0;
  const rows: SpecDecision[] = snapshot.specs.map((spec) => {
    const b = index.bits[spec.id];
    const hits: SpecDecision["hits"] = [];
    for (const fileId of spec.accessedFileIds) {
      const file = filesById.get(fileId);
      if (!file) continue;
      const recorded = file.edgeKindsByTestId[spec.id];
      hits.push({
        file,
        kind:
          recorded === "ROOT_SCOPE_PRELOAD" &&
          lazyRoot &&
          file.id === snapshot.lazyRootId
            ? "SYSCALL_FILE_OPEN"
            : recorded,
      });
    }
    let reason: SelectionReason = "SKIPPED";
    if (rootMask & b) {
      reason = "GUARDRAIL_ROOT_SCOPE";
      rootCount++;
    } else if (index.failedMask & b) {
      reason = "GUARDRAIL_PREV_FAILURE";
      failures++;
    } else if (guardMask & b) {
      reason = "GUARDRAIL_PRISM_GLOB";
      guardrails++;
    } else if (directMask & b) {
      reason = "BITMAP_DIRECT_HIT";
      direct++;
    }
    if (directMask & b) {
      bitmapHits++;
      if (hits.some(({ kind }) => staticEdge(kind))) staticCovered++;
      else if (hits.some(({ kind }) => kind === "SYSCALL_FILE_OPEN"))
        dynamicOnly++;
    }
    if (finalMask & b) {
      selected++;
      selectedMs += spec.avgDurationMs;
    }
    const guardFiles = spec.watchedGlob
      ? [...watchedByFile].filter(([, mask]) => mask & b).map(([file]) => file)
      : [];
    return { spec, reason, hits, guardFiles };
  });
  const scenario = snapshot.scenarios.find(
    (s) =>
      s.changedIds.length === changed.length &&
      s.changedIds.every((id) => ids.has(id)),
  );
  const shadow = snapshot.shadowRuns.find(
    (s) => s.scenario === scenario?.id && s.lazyRoot === lazyRoot,
  );
  const missed = shadow?.observedFailureIds.filter(
    (id) => !(finalMask & index.bits[id]),
  );
  return {
    rows,
    selected,
    direct,
    guardrails,
    failures,
    rootCount,
    selectedMs,
    bitmapHits,
    dynamicOnly,
    staticCovered,
    changed,
    roots,
    directMask,
    guardMask,
    failedMask: index.failedMask,
    rootMask,
    finalMask,
    unionUs,
    scenario,
    shadow,
    missed,
    mandatory: guardrails + failures + rootCount,
    skipped: snapshot.specs.length - selected,
  };
}
export type Selection = ReturnType<typeof selectTests>;
