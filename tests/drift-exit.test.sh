#!/usr/bin/env bash
# Tests for scripts/drift-exit.sh. Run: bash tests/drift-exit.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/scripts/drift-exit.sh"
fail=0
expect() { # plan-exit expected-exit expected-text
  local out rc=0
  out=$(bash "$script" "$1" 2>&1) || rc=$?
  if [[ "$rc" == "$2" && "$out" == *"$3"* ]]; then echo "ok   plan exit $1"; else echo "FAIL plan exit $1 -> $rc '$out'"; fail=1; fi
}
expect 0 0 "no drift"
expect 2 1 "drift"
expect 1 1 "error"
expect 137 1 "error"
exit $fail
