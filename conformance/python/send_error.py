# Conformance: официальный sentry-python должен доставить ошибку в Swatter,
# зная только DSN (ADR-0001). Запуск: SWATTER_DSN=... python send_error.py
import os
import sys

import sentry_sdk

dsn = os.environ.get("SWATTER_DSN")
if not dsn:
    print("SWATTER_DSN not set", file=sys.stderr)
    sys.exit(2)

sentry_sdk.init(
    dsn=dsn,
    release="conformance@0.0.1",
    environment="conformance",
    traces_sample_rate=0,
)

try:
    raise ValueError("conformance: hello from sentry-python")
except ValueError:
    sentry_sdk.capture_exception()

sentry_sdk.flush(timeout=5)
print("event sent")
