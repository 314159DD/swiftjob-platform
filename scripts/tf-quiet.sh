#!/usr/bin/env bash
# Runs terraform for a public log. Standard output (plan and apply text) is always discarded.
#   redact:   on failure, standard error is printed through scripts/redact.sh
#   suppress: on failure, only "terraform <cmd> failed with exit code N" is printed. Used for layers whose inputs
#             are private: an error message can quote a variable value or a resource address from the private config.
# TF_QUIET_OK_CODES lists exit codes that count as success (default "0"; plan -detailed-exitcode uses "0 2").
set -euo pipefail
mode=${1:-}
case "$mode" in
  redact|suppress) shift ;;
  *) echo "usage: tf-quiet.sh <redact|suppress> <terraform arguments>" >&2; exit 64 ;;
esac
sub=""
for a in "$@"; do if [[ "$a" != -* ]]; then sub=$a; break; fi; done
err=$(mktemp); trap 'rm -f "$err"' EXIT
rc=0
terraform "$@" > /dev/null 2> "$err" || rc=$?
if [[ " ${TF_QUIET_OK_CODES:-0} " != *" $rc "* ]]; then
  if [[ "$mode" == redact ]]; then
    # A failing redaction must never change the exit code, and raw stderr is never printed.
    bash "${TF_QUIET_REDACT:-$(dirname "$0")/redact.sh}" < "$err" >&2 || echo "::error::redaction failed, error output withheld" >&2
  else
    echo "::error::terraform ${sub:-command} failed with exit code ${rc}. Its error output is withheld because this layer has private inputs; run the Diagnose workflow in the configuration repository for the full text." >&2
  fi
fi
exit "$rc"
