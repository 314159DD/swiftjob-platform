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

# test_terms_match_literally_and_case_insensitively
lit=$(mktemp -d); cd "$lit"; git init -q
printf 'abc\n' > a.md; git add -A
rc=0; LEAK_BLOCKLIST='a.c' bash "$script" >/dev/null 2>&1 || rc=$?
check "$rc" 0 "dot is literal, a.c does not match abc"
printf 'foo[1]\n' > b.md; git add -A
rc=0; LEAK_BLOCKLIST='Foo[1]' bash "$script" >/dev/null 2>&1 || rc=$?
check "$rc" 1 "Foo[1] matches foo[1]"
git rm -q -f --cached b.md; rm b.md; printf 'axxb\n' > c.md; git add -A
rc=0; LEAK_BLOCKLIST='a*b' bash "$script" >/dev/null 2>&1 || rc=$?
check "$rc" 0 "star is literal, a*b does not match axxb"
printf 'a*b\n' > c.md
rc=0; LEAK_BLOCKLIST='a*b' bash "$script" >/dev/null 2>&1 || rc=$?
check "$rc" 1 "a*b matches literal a*b"

# test_any_term_of_several_matches
printf 'uses Other
' > d.md; git add -A
rc=0; LEAK_BLOCKLIST=$'unrelated
other
z.z' bash "$script" >/dev/null 2>&1 || rc=$?
check "$rc" 1 "second of several terms matches"

# test_grep_error_fails_closed (tracked file removed from disk cannot be opened)
err=$(mktemp -d); cd "$err"; git init -q
printf 'gone\n' > gone.md; git add -A; rm gone.md
rc=0; out=$(LEAK_BLOCKLIST='secretvendor' bash "$script" 2>&1) || rc=$?
check "$rc" 2 "unreadable tracked file exits 2"
check "$(grep -ci 'secretvendor' <<< "$out" || true)" 0 "error output never contains the term"

exit $fail
