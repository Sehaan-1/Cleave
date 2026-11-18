import { create } from "zustand";
import { createPayServerMini } from "../data/payServerMini";
import { buildIndex, selectTests } from "../engine/bitmapSelector";
import type { Selection } from "../engine/bitmapSelector";
import type { ScenarioId } from "../types/cleave";

export const snapshot = createPayServerMini();
export const index = buildIndex(snapshot);
export type InspectorTarget =
  | { type: "file" | "spec"; id: number }
  | { type: "group"; title: string; specIds: number[] }
  | { type: "audit" };
interface WorkbenchState {
  selection: Selection;
  lazyRoot: boolean;
  target: InspectorTarget | null;
  preset: (id: ScenarioId) => void;
  toggle: (id: number) => void;
  toggleLazy: () => void;
  clear: () => void;
  inspect: (target: InspectorTarget | null) => void;
}
export const useWorkbench = create<WorkbenchState>((set, get) => ({
  selection: selectTests(index, snapshot.scenarios[0].changedIds),
  lazyRoot: false,
  target: null,
  preset: (id) =>
    set({
      selection: selectTests(
        index,
        snapshot.scenarios.find((s) => s.id === id)!.changedIds,
      ),
      lazyRoot: false,
      target: null,
    }),
  toggle: (id) => {
    const { selection, lazyRoot } = get();
    const ids = new Set(selection.changed.map((file) => file.id));
    if (!ids.delete(id)) ids.add(id);
    const lazy = lazyRoot && ids.has(snapshot.lazyRootId);
    set({
      selection: selectTests(index, [...ids], lazy),
      lazyRoot: lazy,
      target: null,
    });
  },
  toggleLazy: () => {
    const { selection, lazyRoot } = get();
    const ids = selection.changed.map((file) => file.id);
    if (ids.includes(snapshot.lazyRootId))
      set({
        lazyRoot: !lazyRoot,
        selection: selectTests(index, ids, !lazyRoot),
        target: null,
      });
  },
  clear: () =>
    set({ selection: selectTests(index, []), lazyRoot: false, target: null }),
  inspect: (target) => set({ target }),
}));
