// Conformance: официальный @sentry/bun должен доставить ошибку в Swatter,
// зная только DSN (ADR-0001). Запуск: SWATTER_DSN=... bun run send_error.ts
import * as Sentry from "@sentry/bun";

const dsn = process.env.SWATTER_DSN;
if (!dsn) {
  console.error("SWATTER_DSN is not set");
  process.exit(2);
}

Sentry.init({
  dsn,
  release: "conformance@0.0.1",
  environment: "conformance",
  tracesSampleRate: 0,
});

Sentry.captureException(new Error("conformance: hello from @sentry/bun"));

const flushed = await Sentry.flush(5000);
if (!flushed) {
  console.error("sentry flush timed out");
  process.exit(1);
}
console.log("event sent");
