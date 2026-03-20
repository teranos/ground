import { build } from "esbuild";
import sveltePlugin from "esbuild-svelte";
import { typescript } from "svelte-preprocess-esbuild";
import { copyFileSync, mkdirSync } from "fs";

mkdirSync("dist", { recursive: true });

await build({
  entryPoints: ["src/main.ts"],
  bundle: true,
  outfile: "dist/main.js",
  format: "esm",
  minify: process.argv.includes("--minify"),
  plugins: [
    sveltePlugin({
      preprocess: [typescript()],
      compilerOptions: { css: "injected" },
    }),
  ],
  logLevel: "info",
});

copyFileSync("index.html", "dist/index.html");
copyFileSync("src/tower.css", "dist/tower.css");
