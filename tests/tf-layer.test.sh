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

# nettest may be fed from private inputs later: suppress mode too
: > "$FAKE_TF_LOG"; rc=0; out=$(FAKE_TF_EXIT=1 bash "$script" plan nettest 2>&1) || rc=$?
check "$(grep -c 'bad value' <<< "$out" || true)" 0 "nettest uses suppress mode"

# images file is added when present
echo '{"images":{}}' > "$tmp/config/staging/images.auto.tfvars.json"
: > "$FAKE_TF_LOG"; FAKE_TF_EXIT=0 CONFIG_DIR="$tmp/config" bash "$script" plan staging > /dev/null 2>&1 || true
check "$(grep -c -- 'images.auto.tfvars.json' "$FAKE_TF_LOG")" 1 "images var file is used when present"

# apply-plan takes the lock, plan exit 2 is success for plan and verify
: > "$FAKE_TF_LOG"; FAKE_TF_EXIT=0 CONFIG_DIR="$tmp/config" bash "$script" apply-plan staging > /dev/null 2>&1
check "$(grep -c -- '-lock-timeout=5m' "$FAKE_TF_LOG")" 1 "apply-plan takes the state lock"
rc=0; FAKE_TF_EXIT=2 CONFIG_DIR="$tmp/config" bash "$script" plan staging > /dev/null 2>&1 || rc=$?
check "$rc" 2 "plan returns 2 on changes"

# identity-staging: its own var file, no images file, suppress mode
echo 'web_base_url = "https://x.example.test"' > "$tmp/config/staging/identity.auto.tfvars"
: > "$FAKE_TF_LOG"; rc=0; out=$(FAKE_TF_EXIT=1 CONFIG_DIR="$tmp/config" bash "$script" plan identity-staging 2>&1) || rc=$?
check "$(grep -c -- "-var-file=$tmp/config/staging/identity.auto.tfvars" "$FAKE_TF_LOG")" 1 "identity plan uses the identity var file"
check "$(grep -c -- 'images.auto.tfvars.json' "$FAKE_TF_LOG" || true)" 0 "identity plan has no images file"
check "$(grep -c 'bad value' <<< "$out" || true)" 0 "identity uses suppress mode"
rm "$tmp/config/staging/identity.auto.tfvars"
rc=0; CONFIG_DIR="$tmp/config" bash "$script" plan identity-staging > /dev/null 2>&1 || rc=$?
check "$rc" 2 "missing identity configuration fails"

# migrate-first: a targeted plan of the db-migrate job into its own plan file, then an apply of exactly that file
: > "$FAKE_TF_LOG"; FAKE_TF_EXIT=0 CONFIG_DIR="$tmp/config" bash "$script" migrate-plan staging > /dev/null 2>&1
check "$(grep -c -- '-target=module.workload.azurerm_container_app_job.this\["db-migrate"\]' "$FAKE_TF_LOG")" 1 "migrate-plan targets the db-migrate job only"
check "$(grep -c -- '-out=tfplan-db' "$FAKE_TF_LOG")" 1 "migrate-plan writes its own plan file"
check "$(grep -c -- '-lock-timeout=5m' "$FAKE_TF_LOG")" 1 "migrate-plan takes the state lock"
check "$(grep -c -- "-var-file=$tmp/config/staging/terraform.tfvars" "$FAKE_TF_LOG")" 1 "migrate-plan uses the private var file"
: > "$FAKE_TF_LOG"; FAKE_TF_EXIT=0 CONFIG_DIR="$tmp/config" bash "$script" migrate-apply staging > /dev/null 2>&1
check "$(grep -c -- 'apply .* tfplan-db' "$FAKE_TF_LOG")" 1 "migrate-apply applies tfplan-db"
rc=0; out=$(FAKE_TF_EXIT=1 CONFIG_DIR="$tmp/config" bash "$script" migrate-plan staging 2>&1) || rc=$?
check "$(grep -c 'bad value' <<< "$out" || true)" 0 "migrate-plan stays in suppress mode"

# migrate-check: the address must be in the targeted plan or in the state, otherwise the run fails
mkdir "$tmp/tfbin"
cat > "$tmp/tfbin/terraform" <<'STUB'
#!/usr/bin/env bash
# CHK_PLAN: json for "show -json"; CHK_STATE: lines for "state list"
for a in "$@"; do
  case "$a" in
    show) echo "$CHK_PLAN"; exit 0 ;;
    state) echo "$CHK_STATE"; exit 0 ;;
  esac
done
exit 0
STUB
chmod +x "$tmp/tfbin/terraform"
good='{"resource_changes":[{"address":"module.workload.azurerm_container_app_job.this[\"db-migrate\"]"}]}'
wrong='{"resource_changes":[{"address":"module.workload.azurerm_container_app_job.this[\"db\"]"}]}'
chk() { PATH="$tmp/tfbin:$PATH" CONFIG_DIR="$tmp/config" bash "$script" migrate-check staging; }
rc=0; CHK_PLAN="$good" CHK_STATE="" chk > /dev/null 2>&1 || rc=$?
check "$rc" 0 "migrate-check passes when the plan holds the job"
rc=0; CHK_PLAN='{"resource_changes":[]}' CHK_STATE='module.workload.azurerm_container_app_job.this["db-migrate"]' chk > /dev/null 2>&1 || rc=$?
check "$rc" 0 "migrate-check passes when the state holds the job"
rc=0; out=$(CHK_PLAN="$wrong" CHK_STATE='something.else' chk 2>&1) || rc=$?
check "$rc" 1 "migrate-check fails when the address matches nothing (wrong target)"
check "$(grep -c 'something.else' <<< "$out" || true)" 0 "migrate-check prints nothing from the state"

# missing private configuration and unknown layer
rc=0; CONFIG_DIR="$tmp/none" bash "$script" plan staging > /dev/null 2>&1 || rc=$?
check "$rc" 2 "missing private configuration fails"
rc=0; bash "$script" plan nosuchlayer > /dev/null 2>&1 || rc=$?
check "$rc" 2 "unknown layer fails"
exit $fail
