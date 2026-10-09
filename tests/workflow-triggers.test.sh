#!/usr/bin/env bash
# Proves a merge cannot change production: the production workflows are dispatch-only, no other workflow triggers on
# production paths, and only the production workflows (plus the manual, gated rights test) use the production environment.
# Run: bash tests/workflow-triggers.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
# The text of the top-level `on:` block.
on_block() { awk '/^on:/{f=1; next} f && /^[A-Za-z_-]+:/{exit} f' "$1"; }

for f in apply-prod identity-prod; do
  block=$(on_block "$wf/$f.yml")
  if grep -q '^  workflow_dispatch:' <<< "$block"; then ok "$f is dispatchable"; else bad "$f is dispatchable"; fi
  if grep -Eq '^  (push|pull_request|pull_request_target|schedule|workflow_run|repository_dispatch|release|workflow_call)' <<< "$block"; then
    bad "$f has a trigger other than workflow_dispatch"
  else ok "$f is dispatch-only"; fi
  if grep -q '^    environment: production' "$wf/$f.yml"; then ok "$f runs in the production environment"; else bad "$f runs in the production environment"; fi
done

for f in "$wf"/*.yml; do
  name=$(basename "$f" .yml)
  case "$name" in apply-prod|identity-prod) continue ;; esac
  block=$(on_block "$f")
  if grep -Eq 'environments/(prod|identity-prod)|config/prod' <<< "$block"; then bad "$name triggers on production paths"; else ok "$name does not trigger on production paths"; fi
  if grep -q 'environment: production' "$f" && [[ "$name" != rights-test ]]; then bad "$name uses the production environment"; fi
done

# The rights test uses the production environment only in a job that needs a manual dispatch and PROD_READY.
if grep -B3 'environment: production' "$wf/rights-test.yml" | grep -q "workflow_dispatch' && vars.PROD_READY == 'true'"; then
  ok "the rights test prod job is manual and gated"
else bad "the rights test prod job is manual and gated"; fi
# Apply staging never runs a production layer.
if grep -q 'prod' <(grep 'tf-layer.sh' "$wf/apply-staging.yml"); then bad "apply-staging calls a prod layer"; else ok "apply-staging calls staging only"; fi
exit $fail
