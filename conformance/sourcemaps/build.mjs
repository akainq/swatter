// Сборка минифицированного бандла + sourcemap с инжектом Debug ID
// официальным @sentry/esbuild-plugin (без upload — authToken не задан,
// плагин только инжектит debug_id в бандл и .map).
import { build } from "esbuild";
import { sentryEsbuildPlugin } from "@sentry/esbuild-plugin";

await build({
  entryPoints: ["app.js"],
  outfile: "dist/bundle.js",
  bundle: true,
  minify: true,
  sourcemap: true,
  platform: "node",
  format: "esm",
  packages: "external",
  plugins: [
    sentryEsbuildPlugin({
      telemetry: false,
      // без authToken загрузка пропускается, инжект debug id остаётся
      sourcemaps: { assets: [] },
    }),
  ],
});

console.log("built");
