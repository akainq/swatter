// Conformance (M4, ADR-0014): официальный @sentry/node с tracesSampleRate=1
// должен доставить транзакцию со спанами в Swatter, зная только DSN.
// Запуск: SWATTER_DSN=... node send_transaction.js
const Sentry = require("@sentry/node");

const dsn = process.env.SWATTER_DSN;
if (!dsn) {
  console.error("SWATTER_DSN is not set");
  process.exit(2);
}

Sentry.init({
  dsn,
  release: "conformance@0.0.1",
  environment: "conformance",
  tracesSampleRate: 1.0,
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

Sentry.startSpan({ name: "conformance-transaction", op: "test.run" }, async () => {
  await Sentry.startSpan({ name: "SELECT 1", op: "db.query" }, () => sleep(30));
  await Sentry.startSpan({ name: "render body", op: "template.render" }, () => sleep(10));
})
  .then(() => Sentry.flush(5000))
  .then((ok) => {
    if (!ok) {
      console.error("sentry flush timed out");
      process.exit(1);
    }
    console.log("transaction sent");
  });
