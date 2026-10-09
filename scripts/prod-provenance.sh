#!/usr/bin/env bash
# Promotion gate for production, enforced at apply time (a private repository without a paid plan cannot require a check
# on its main branch). Usage: bash scripts/prod-provenance.sh <config-dir>
#
# Reads prod/images.auto.tfvars.json of the configuration checkout and requires:
#   - the api, db and aggregator digests each appear in the git history of staging/images.auto.tfvars.json on main
#     (they were deployed on staging first: proven there), and
#   - the web digest does NOT appear there (the production web image is its own build, with production URLs).
# History depth is whatever the checkout fetched (the workflow fetches 1000 commits of main): an older digest fails closed.
# Output: fixed messages only, never a digest or an image name. Env: PROV_REF (default origin/main, test hook).
set -euo pipefail
dir=${1:?usage: prod-provenance.sh <config-dir>}
ref=${PROV_REF:-origin/main}
file="$dir/prod/images.auto.tfvars.json"
if [[ ! -f "$file" ]]; then echo "::error::prod image file not found"; exit 1; fi

hist=$(mktemp); trap 'rm -f "$hist"' EXIT
if ! git -C "$dir" log -p --format= "$ref" -- staging/images.auto.tfvars.json > "$hist" 2> /dev/null; then
  echo "::error::could not read the staging image history"; exit 1
fi

rc=0
for name in api db aggregator web; do
  digest=$(python3 -I - "$file" "$name" <<'PY' 2> /dev/null || true
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["images"][sys.argv[2]]
m = re.search(r"@(sha256:[0-9a-f]{64})$", d)
print(m.group(1) if m else "")
PY
)
  if [[ -z "$digest" ]]; then echo "::error::${name} image is missing or not pinned by digest"; rc=1; continue; fi
  if grep -qF -- "$digest" "$hist"; then seen=1; else seen=0; fi
  if [[ "$name" == web ]]; then
    if (( seen )); then echo "::error::web digest was found on staging (a production build is required)"; rc=1
    else echo "web: production build"; fi
  else
    if (( seen )); then echo "${name}: proven on staging"
    else echo "::error::${name} digest never deployed on staging"; rc=1; fi
  fi
done
exit $rc
