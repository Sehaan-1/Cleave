import { cpSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const dist = fileURLToPath(new URL("../dist/", import.meta.url));
const destination = fileURLToPath(new URL("../public/", import.meta.url));
rmSync(destination, { recursive: true, force: true });
cpSync(dist, destination, { recursive: true });
