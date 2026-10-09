#!/usr/bin/env bash
# Tests for scripts/prod-provenance.sh on a fixture git repository. Run: bash tests/prod-provenance.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/prod-provenance.sh"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
d() { printf 'sha256:%064d' "$1" | sed 's/ /0/g'; }
A=$(d 1); B=$(d 2); W=$(d 3); NEW=$(d 4); STAGEWEB=$(d 5)
cfg="$tmp/cfg"; mkdir -p "$cfg/staging" "$cfg/prod"
g() { git -C "$cfg" -c user.name=t -c user.email=t@example.com "$@"; }
g init -q -b main
img() { printf '{"images":{"api":"r/api@%s","db":"r/api@%s","aggregator":"r/agg@%s","web":"r/web@%s"}}\n' "$1" "$2" "$3" "$4"; }
# history: an old staging deploy (A, B), then a newer one that no longer holds A
img "$A" "$A" "$B" "$STAGEWEB" > "$cfg/staging/images.auto.tfvars.json"; g add -A; g commit -q -m one
img "$NEW" "$NEW" "$B" "$STAGEWEB" > "$cfg/staging/images.auto.tfvars.json"; g commit -q -am two
export PROV_REF=main
run() { rc=0; out=$(bash "$script" "$cfg" 2>&1) || rc=$?; }

img "$A" "$A" "$B" "$W" > "$cfg/prod/images.auto.tfvars.json"
run; check "$rc" 0 "digests proven in the staging history, own web build: passes"
check "$(grep -c 'api: proven on staging' <<< "$out")" 1 "api is reported proven"
check "$(grep -c 'sha256' <<< "$out" || true)" 0 "no digest is printed"

img "$(d 9)" "$A" "$B" "$W" > "$cfg/prod/images.auto.tfvars.json"
run; check "$rc" 1 "an api digest never on staging fails"
check "$(grep -c 'api digest never deployed on staging' <<< "$out")" 1 "the failing image is named"
img "$A" "$(d 9)" "$B" "$W" > "$cfg/prod/images.auto.tfvars.json"
run; check "$(grep -c 'db digest never deployed on staging' <<< "$out")" 1 "db is checked on its own"
img "$A" "$A" "$(d 9)" "$W" > "$cfg/prod/images.auto.tfvars.json"
run; check "$(grep -c 'aggregator digest never deployed on staging' <<< "$out")" 1 "aggregator is checked"
img "$A" "$A" "$B" "$STAGEWEB" > "$cfg/prod/images.auto.tfvars.json"
run; check "$rc" 1 "a web digest found on staging fails"
check "$(grep -c 'sha256' <<< "$out" || true)" 0 "no digest is printed on failure"
img "$A" "$A" "$B" "r/web:latest" > "$cfg/prod/images.auto.tfvars.json"
run; check "$rc" 1 "an image not pinned by digest fails"
rm "$cfg/prod/images.auto.tfvars.json"
run; check "$rc" 1 "a missing prod image file fails"
img "$A" "$A" "$B" "$W" > "$cfg/prod/images.auto.tfvars.json"
rc=0; out=$(PROV_REF=nosuchref bash "$script" "$cfg" 2>&1) || rc=$?
check "$rc" 1 "an unreadable history fails closed"
exit $fail
