#!/usr/bin/env bash
# Maps the exit code of `terraform plan -detailed-exitcode` to a result. 2 (changes) and every error must
# turn the drift job red; only 0 is green.
set -euo pipefail
case "${1:?plan exit code}" in
  0) echo "no drift"; exit 0 ;;
  2) echo "::error::drift: Azure differs from the code"; exit 1 ;;
  *) echo "::error::error: terraform plan failed with exit code $1"; exit 1 ;;
esac
