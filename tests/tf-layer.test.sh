#!/usr/bin/env bash
# Tests for scripts/tf-layer.sh. Run: bash tests/tf-layer.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/tf-layer.sh"
export PATH="$root/tests/fake-bin:$PATH"
export TF_STATE_RG=rg-state TF_STATE_SA=sastate
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export FAKE_TF_LOG="$tmp/args"

mkdir -p "$tmp/config/staging"
echo 'environment = "staging"' > "$tmp/config/staging/terraform.tfvars"

# platform plan: lock-free, no var files, redact mode shows stderr
: > "$FAKE_TF_LOG"; rc=0; out=$(FAKE_TF_EXIT=1 CONFIG_DIR="$tmp/config" bash "$script" plan platform 2>&1) || rc=$?
check "$(grep -c -- '-lock=false' "$FAKE_TF_LOG")" 1 "platform plan is lock-free"
check "$(grep -c -- 'plan -no-color' "$FAKE_TF_LOG")" 1 "no-color follows the subcommand"
check "$(grep -c -- '-var-file' "$FAKE_TF_LOG" || true)" 0 "platform plan has no var file"
check "$(grep -c 'bad value' <<< "$out" || true)" 1 "platform uses redact mode"

# staging plan: lock-free, private var file, suppress mode
: > "$FAKE_TF_LOG"; rc=0; out=$(FAKE_TF_EXIT=1 CONFIG_DIR="$tmp/config" bash "$script" plan staging 2>&1) || rc=$?
check "$(grep -c -- '-lock=false' "$FAKE_TF_LOG")" 1 "staging plan is lock-free"
check "$(grep -c -- "-var-file=$tmp/config/staging/terraform.tfvars" "$FAKE_TF_LOG")" 1 "staging plan uses the private var file"
check "$(grep -c 'bad value' <<< "$out" || true)" 0 "staging uses suppress mode"

# images file is added when present
echo '{"images":{}}' > "$tmp/config/staging/images.auto.tfvars.json"
: > "$FAKE_TF_LOG"; FAKE_TF_EXIT=0 CONFIG_DIR="$tmp/config" bash "$script" plan staging > /dev/null 2>&1 || true
check "$(grep -c -- 'images.auto.tfvars.json' "$FAKE_TF_LOG")" 1 "images var file is used when present"

# apply-plan takes the lock, plan exit 2 is success for plan and verify
: > "$FAKE_TF_LOG"; FAKE_TF_EXIT=0 CONFIG_DIR="$tmp/config" bash "$script" apply-plan staging > /dev/null 2>&1
check "$(grep -c -- '-lock-timeout=5m' "$FAKE_TF_LOG")" 1 "apply-plan takes the state lock"
rc=0; FAKE_TF_EXIT=2 CONFIG_DIR="$tmp/config" bash "$script" plan staging > /dev/null 2>&1 || rc=$?
check "$rc" 2 "plan returns 2 on changes"

# missing private configuration and unknown layer
rc=0; CONFIG_DIR="$tmp/none" bash "$script" plan staging > /dev/null 2>&1 || rc=$?
check "$rc" 2 "missing private configuration fails"
rc=0; bash "$script" plan nosuchlayer > /dev/null 2>&1 || rc=$?
check "$rc" 2 "unknown layer fails"
exit $fail
