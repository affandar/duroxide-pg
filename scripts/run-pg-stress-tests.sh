#!/bin/bash
# Run PostgreSQL provider stress tests

set -e

DURATION=${1:-10}
DATABASE_URL=${DATABASE_URL:-$(grep '^DATABASE_URL=' .env 2>/dev/null | cut -d= -f2-)}

if [ -z "$DATABASE_URL" ]; then
    echo "Error: DATABASE_URL not set"
    echo "Usage: $0 [DURATION_SECS]"
    echo "Set DATABASE_URL environment variable or in .env file"
    exit 1
fi

echo "=== Running PostgreSQL Provider Stress Tests ==="
echo "Duration: ${DURATION}s per test"
echo "Database: $(echo $DATABASE_URL | sed 's/:.*@/:***@/')"
echo ""

cd pg-stress
cargo run --release --bin pg-stress -- --duration $DURATION

