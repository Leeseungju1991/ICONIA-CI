#!/usr/bin/env bash
# ICONIA E2E Wide Stress Test — shell entry point.
#
# Usage:
#   ./scripts/run-stress.sh [pattern] [duration_s] [rps]
#
# Example:
#   ./scripts/run-stress.sh steady 300 100
#   ./scripts/run-stress.sh chaos 600 50
set -euo pipefail

PATTERN="${1:-steady}"
DURATION_S="${2:-300}"
RPS="${3:-100}"

if [ ! -f .env ]; then
  echo "❌ .env not found — cp .env.example .env"
  exit 1
fi

# Safety
if grep -qE "^STRESS_TARGET=production" .env; then
  echo "❌ STRESS_TARGET=production is FORBIDDEN. Use staging/local."
  exit 2
fi

export STRESS_PATTERN="$PATTERN"
export STRESS_DURATION_S="$DURATION_S"
export STRESS_RPS_TARGET="$RPS"

echo "[ICONIA Stress] pattern=$PATTERN duration=$DURATION_S RPS=$RPS"
python scripts/orchestrate-load.py
