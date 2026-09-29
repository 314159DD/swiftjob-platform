#!/usr/bin/env bash
# Tests for scripts/leak-check.sh. Run: bash tests/leak-check.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/scripts/leak-check.sh"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected $2, got $1)"; fail=1; fi; }

repo=$(mktemp -d); trap 'rm -rf "$repo"' EXIT
cd "$repo"; git init -q
printf 'clean line\n' > clean.md
printf 'first line\nuses SecretVendor here\n' > leaky.md
git add -A

# test_clean_repo_passes
rc=0; LEAK_BLOCKLIST=$'unrelated\nother' bash "$script" >/dev/null 2>&1 || rc=$?
check "$rc" 0 "clean repo passes"

# test_hit_fails_with_file_and_line
rc=0; out=$(LEAK_BLOCKLIST=$'secretvendor' bash "$script" 2>&1) || rc=$?
check "$rc" 1 "hit fails"
check "$(grep -c 'file=leaky.md,line=2' <<< "$out")" 1 "hit reports file and line"

# test_output_never_contains_term
check "$(grep -ci 'secretvendor' <<< "$out" || true)" 0 "output never contains the term"

# test_empty_blocklist_is_an_error
rc=0; LEAK_BLOCKLIST=$'\n  \n' bash "$script" >/dev/null 2>&1 || rc=$?
check "$rc" 2 "empty blocklist is an error"
rc=0; env -u LEAK_BLOCKLIST bash "$script" >/dev/null 2>&1 || rc=$?
check "$rc" 2 "missing blocklist is an error"

# test_crlf_terms_are_trimmed (secrets pasted on Windows end in \r)
rc=0; LEAK_BLOCKLIST=$'secretvendor\r' bash "$script" >/dev/null 2>&1 || rc=$?
check "$rc" 1 "CRLF term still matches"

# test_untracked_files_are_ignored
printf 'SecretVendor\n' > untracked.md
git rm -q --cached leaky.md
rc=0; LEAK_BLOCKLIST=$'secretvendor' bash "$script" >/dev/null 2>&1 || rc=$?
check "$rc" 0 "untracked files are ignored"

exit $fail
