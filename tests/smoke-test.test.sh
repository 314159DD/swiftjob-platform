#!/usr/bin/env bash
# Tests for scripts/smoke-test.sh against a local fake. Run: bash tests/smoke-test.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
port=18080
url="http://127.0.0.1:${port}"
run_mode() { # mode -> exit code of the smoke test
  WEB="$url" MODE="$1" python3 "$root/tests/fake-app.py" "$port" & pid=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "$url/" && break; sleep 0.1; done
  rc=0; SMOKE_RETRIES=1 bash "$root/scripts/smoke-test.sh" "$url" "$url" > "$tmp/out.txt" 2>&1 || rc=$?
  kill "$pid"; wait "$pid" 2>/dev/null || true
  echo "$rc"
}
check "$(run_mode good)" 0 "healthy apps pass"
check "$(grep -c '127.0.0.1' "$tmp/out.txt" || true)" 0 "output names checks, not URLs"
check "$(run_mode foreign-cors)" 1 "foreign origin fails the smoke test"
check "$(grep -c '^FAIL: CORS refuses a foreign origin' "$tmp/out.txt" || true)" 1 "the CORS check is the one that failed"
check "$(run_mode internal-redirect)" 1 "internal redirect fails the smoke test"
check "$(grep -c '^FAIL: auth redirect' "$tmp/out.txt" || true)" 1 "the redirect check is the one that failed"
exit $fail
