import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  base: "./",
  publicDir: false,
  plugins: [react(), tailwindcss()],
  build: {
    rollupOptions: {
      output: {
        manualChunks: {
          "react-core": ["react", "react-dom/client"],
          "dependency-map": ["@xyflow/react", "@dagrejs/dagre"],
          "spec-matrix": ["@tanstack/react-table", "@tanstack/react-virtual"],
        },
      },
    },
  },
  server: { host: "0.0.0.0", allowedHosts: [".e2b.app"] },
  preview: { host: "0.0.0.0", allowedHosts: [".e2b.app"] },
});
