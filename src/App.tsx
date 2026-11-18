import { useState, useSyncExternalStore } from "react";
import { FolderTree, TableProperties, Waypoints } from "lucide-react";
import { BlastRadius } from "./components/BlastRadius";
import { ExecutionMatrix } from "./components/ExecutionMatrix";
import { CommandBar, Overview, StatusBar } from "./components/Header";
import { Inspector } from "./components/Inspector";
import { Inventory } from "./components/Inventory";
import { ArtifactInspector } from "./components/ArtifactInspector";

const media = window.matchMedia("(max-width: 800px)");
const subscribe = (f: () => void) => {
  media.addEventListener("change", f);
  return () => media.removeEventListener("change", f);
};
export default function App() {
  const compact = useSyncExternalStore(subscribe, () => media.matches);
  const [pane, setPane] = useState("map");
  const localMode = document.querySelector('meta[name="cleave-local-ui"]') !== null;
  const [artifacts, setArtifacts] = useState(localMode);
  if (artifacts) return <ArtifactInspector onBack={() => setArtifacts(false)} compact={compact} localMode={localMode} />;
  return (
    <div className="app-frame">
      <CommandBar onOpenArtifacts={() => setArtifacts(true)} />
      <Overview />
      {compact && (
        <nav className="mobile-nav" aria-label="Workbench panels">
          {(
            [
              ["files", "Inventory", FolderTree],
              ["map", "Blast radius", Waypoints],
              ["specs", "Matrix", TableProperties],
            ] as const
          ).map(([id, title, Icon]) => (
            <button
              key={id}
              aria-pressed={pane === id}
              onClick={() => setPane(id)}
            >
              <Icon size={14} />
              {title}
            </button>
          ))}
        </nav>
      )}
      <main className="workspace">
        {(!compact || pane === "files") && <Inventory />}
        {(!compact || pane === "map") && <BlastRadius compact={compact} />}
        {(!compact || pane === "specs") && <ExecutionMatrix />}
      </main>
      <StatusBar />
      <Inspector />
    </div>
  );
}
