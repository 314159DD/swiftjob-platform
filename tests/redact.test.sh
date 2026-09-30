#!/usr/bin/env bash
# Tests for scripts/redact.sh. Run: bash tests/redact.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/scripts/redact.sh"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }

check "$(printf 'id 11111111-2222-3333-4444-555555555555 end\n' | bash "$script")" "id <id> end" "GUID masked"
check "$(printf 'mail a.person@example.com end\n' | bash "$script")" "mail <email> end" "e-mail masked"
check "$(printf 'url https://x/y?sv=1&sig=abc%%2Bdef&se=2\n' | bash "$script")" "url https://x/y?sv=1&sig=<redacted>&se=2" "SAS signature masked"
check "$(printf 'PASSWORD=hunter2 other\n' | bash "$script")" "PASSWORD=<redacted> other" "assignment masked, case-insensitive"
check "$(printf 'plain text stays\n' | bash "$script")" "plain text stays" "plain text unchanged"
exit $fail
