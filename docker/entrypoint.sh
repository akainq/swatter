#!/bin/sh
# Автомиграции на старте (ADR-0004): PG + ClickHouse, additive-only.
set -e

echo "swatter: running migrations..."
/app/bin/swatter eval "Swatter.Release.migrate()"

echo "swatter: starting..."
exec /app/bin/swatter start
