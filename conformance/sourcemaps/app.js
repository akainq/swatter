// Реальное приложение для conformance символикации (M2): собирается
// esbuild'ом в минифицированный бандл; @sentry/node ловит ошибку с
// минифицированным стеком и debug_meta (debug_id инжектит sentry-плагин).
import * as Sentry from "@sentry/node";

Sentry.init({
  dsn: process.env.SWATTER_DSN,
  release: "sourcemaps-conformance@1.0.0",
  environment: "conformance",
  tracesSampleRate: 0,
});

// имя функции будет вымангано минификацией — символикация обязана вернуть
// исходное crashDeepInside
function crashDeepInside() {
  throw new Error("conformance: symbolicated from esbuild bundle");
}

try {
  crashDeepInside();
} catch (err) {
  Sentry.captureException(err);
}

await Sentry.flush(5000);
console.log("event sent");
