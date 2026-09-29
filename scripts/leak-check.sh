#!/usr/bin/env bash
# Fails when a tracked file contains a term from LEAK_BLOCKLIST (one term per line, case-insensitive).
# The blocklist names product internals (vendors, data sources, table names) and lives in a repository
# secret. Output names only file and line, never the term, because this repository's CI logs are public.
# Terms are matched literally: regex metacharacters are escaped and one grep -i is used, because
# grep -F -i and multi-pattern -i abort on the grep 3.0 shipped with Git for Windows.
set -euo pipefail

if [[ -z "${LEAK_BLOCKLIST:-}" ]]; then
  echo "::error::LEAK_BLOCKLIST is not set"; exit 2
fi
patterns=$(mktemp); trap 'rm -f "$patterns"' EXIT
printf '%s\n' "$LEAK_BLOCKLIST" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sed 's/[][\.*^$]/\\&/g' > "$patterns" || true
if [[ ! -s "$patterns" ]]; then
  echo "::error::LEAK_BLOCKLIST contains no terms"; exit 2
fi

# One BRE alternation instead of `grep -f`: grep 3.0 on Git for Windows aborts on -i with several patterns.
regex=$(sed ':a;N;$!ba;s/\n/\\|/g' "$patterns")

hits=0
errors=0
while IFS= read -r -d '' file; do
  rc=0
  out=$(LC_ALL=C grep -n -i -I -e "$regex" -- "$file" 2>/dev/null) || rc=$?
  if (( rc >= 2 )); then
    echo "::error::leak check could not scan ${file}"
    errors=$((errors + 1))
  elif (( rc == 0 )); then
    while IFS=: read -r line _; do
      echo "::error file=${file},line=${line}::blocked term found"
      hits=$((hits + 1))
    done <<< "$out"
  fi
done < <(git ls-files -z)

if (( errors > 0 )); then
  echo "${errors} file(s) could not be scanned"; exit 2
fi
if (( hits > 0 )); then
  echo "${hits} blocked term(s) found"; exit 1
fi
echo "leak check passed"
