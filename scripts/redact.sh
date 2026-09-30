#!/usr/bin/env bash
# Masks identifiers and credentials in text bound for a public log: IPv4 addresses, GUIDs (subscription, tenant, principal IDs),
# e-mail addresses, and values of sig/token/key/password/secret assignments (SAS URLs, KEY=value lines).
set -euo pipefail
sed -E \
  -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<id>/g' \
  -e 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g' \
  -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
  -e 's/(sig|token|key|password|secret)=[^&[:space:]"]+/\1=<redacted>/Ig'
