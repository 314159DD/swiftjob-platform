# shellcheck shell=bash
# Helpers for tests that prove Azure refuses something. Source this file.
# Output is one line per check. Raw Azure messages can name subscriptions, principals and resources and this
# output goes to public logs, so a message is only shown on failure, redacted and cut to 300 characters.
EXPECT_FAILURES=0
_EXPECT_REDACT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/redact.sh"

# Redact first, then cut, so a cut can never leave part of an identifier in the output.
_expect_excerpt() { tr '\n' ' ' <<< "$1" | bash "$_EXPECT_REDACT" | head -c 300; }

expect_refused() { # name extended-regex command...
  local name=$1 regex=$2 out rc=0 match
  shift 2
  out=$("$@" 2>&1) || rc=$?
  if (( rc != 0 )) && grep -Eq "$regex" <<< "$out"; then
    # EXPECT_LABEL replaces the matched text, for output that may carry an address or a principal name.
    match=${EXPECT_LABEL:-$(grep -Eo "$regex" <<< "$out")}
    echo "PASS: ${name} refused (${match%%$'\n'*})"
  elif (( rc == 0 )); then
    echo "FAIL: ${name} was allowed"
    EXPECT_FAILURES=$((EXPECT_FAILURES + 1)); return 1
  else
    echo "FAIL: ${name} failed for another reason: $(_expect_excerpt "$out")"
    EXPECT_FAILURES=$((EXPECT_FAILURES + 1)); return 1
  fi
}

expect_ok() { # name command...
  local name=$1 out rc=0
  shift
  out=$("$@" 2>&1) || rc=$?
  if (( rc == 0 )); then
    echo "PASS: ${name} works"
  else
    echo "FAIL: ${name} failed: $(_expect_excerpt "$out")"
    EXPECT_FAILURES=$((EXPECT_FAILURES + 1)); return 1
  fi
}

expect_summary() {
  if (( EXPECT_FAILURES > 0 )); then echo "${EXPECT_FAILURES} check(s) failed"; return 1; fi
  echo "all checks passed"
}
