import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

const directory = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  publicDir: "public",
  base: "./",
  build: {
    outDir: "dist",
    emptyOutDir: true,
    minify: false,
    sourcemap: true,
    target: "esnext",
    rolldownOptions: {
      input: resolve(directory, "src/main.ts"),
      external: ["premierepro", "uxp"],
      output: {
        format: "cjs",
        entryFileNames: "main.js"
      }
    }
  }
});
