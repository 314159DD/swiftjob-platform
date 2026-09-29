#!/usr/bin/env bash
# Fails when a tracked file contains a term from LEAK_BLOCKLIST (one term per line, case-insensitive).
# The blocklist names product internals (vendors, data sources, table names) and lives in a repository
# secret. Output names only file and line, never the term, because this repository's CI logs are public.
# Terms are matched literally: regex metacharacters are escaped and plain grep -i is used, because
# grep -F -i aborts on the grep 3.0 shipped with Git for Windows.
set -euo pipefail

if [[ -z "${LEAK_BLOCKLIST:-}" ]]; then
  echo "::error::LEAK_BLOCKLIST is not set"; exit 2
fi
patterns=$(mktemp); trap 'rm -f "$patterns"' EXIT
printf '%s\n' "$LEAK_BLOCKLIST" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sed 's/[][\.*^$]/\\&/g' > "$patterns" || true
if [[ ! -s "$patterns" ]]; then
  echo "::error::LEAK_BLOCKLIST contains no terms"; exit 2
fi

hits=0
while IFS= read -r -d '' file; do
  while IFS=: read -r line _; do
    echo "::error file=${file},line=${line}::blocked term found"
    hits=$((hits + 1))
  done < <(grep -n -i -I -f "$patterns" -- "$file" 2>/dev/null || true)
done < <(git ls-files -z)

if (( hits > 0 )); then
  echo "${hits} blocked term(s) found"; exit 1
fi
echo "leak check passed"
