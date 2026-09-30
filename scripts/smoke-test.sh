#!/usr/bin/env bash
# Post-deploy smoke test for the web app and the API. Prints check names only: the host names are not secret,
# but the log is public and needs none of them. Response bodies are never printed.
# Usage: bash scripts/smoke-test.sh <web-url> <api-url>    (SMOKE_RETRIES, default 30, for cold starts)
set -euo pipefail
web=${1:?web url}; api=${2:?api url}
web=${web%/}; api=${api%/}
retries=${SMOKE_RETRIES:-30}
fail=0
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@" 2> /dev/null || true; }
# Scale-to-zero: the first request to each app can take a while. Retry a check until it succeeds.
wait_for() { local i; for i in $(seq 1 "$retries"); do "$@" && return 0; if (( i < retries )); then sleep 5; fi; done; return 1; }
api_up() { [[ "$(code "$api/api/health")" == 200 ]]; }
web_up() { [[ "$(code "$web/")" =~ ^(200|307|308)$ ]]; }
callback_location() { curl -s -o /dev/null -D - --max-time 30 "$web/auth/callback?error=smoke" 2> /dev/null | tr -d '\r' | grep -i '^location:' | cut -d' ' -f2- || true; }
has_location() { [[ -n "$(callback_location)" ]]; }

wait_for api_up || true
wait_for web_up || true
wait_for has_location || true

web_up && pass "web answers" || bad "web answers"

hdr=$(mktemp); trap 'rm -f "$hdr"' EXIT
health=$(curl -s -D "$hdr" --max-time 30 "$api/api/health" 2> /dev/null || true)
status=$(head -n 1 "$hdr" | tr -d '\r' | cut -d' ' -f2)
[[ "$status" == 200 && "$health" == *'"status":"ok"'* ]] && pass "API health" || bad "API health"
grep -qi '^strict-transport-security:' "$hdr" && pass "API sends HSTS" || bad "API sends HSTS"

acao() { curl -s -o /dev/null -D - --max-time 30 -X OPTIONS -H "Origin: $1" -H "Access-Control-Request-Method: GET" "$api/api/health" 2> /dev/null \
  | tr -d '\r' | grep -i '^access-control-allow-origin:' | cut -d' ' -f2- || true; }
[[ "$(acao "$web")" == "$web" ]] && pass "CORS allows the web origin" || bad "CORS allows the web origin"
[[ -z "$(acao "https://evil.example")" ]] && pass "CORS refuses a foreign origin" || bad "CORS refuses a foreign origin"

location=$(callback_location)
[[ "$location" == "$web"/* ]] && pass "auth redirect stays on the public web URL" || bad "auth redirect stays on the public web URL"

exit $fail
