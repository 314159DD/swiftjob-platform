#!/usr/bin/env python3
"""Delete guard for the production layer (plan 05, ADR 12).

Reads `terraform show -json tfplan` on stdin and exits 1 when the plan deletes or replaces the PostgreSQL server,
the storage account, a storage container, a user-assigned identity or the Key Vault (a replace carries both delete and create). Exits 2 when the input is not a
plan, so a broken pipe can never look like "nothing is deleted". Prints only the resource type and the action,
never an address, name or ID: the log of this repository is public.
"""
import json
import sys

GUARDED = (
    "azurerm_postgresql_flexible_server",
    "azurerm_storage_account",
    "azurerm_key_vault",
    "azurerm_storage_container",  # losing the CV container deletes the CVs
    "azurerm_user_assigned_identity",  # replacing the PostgreSQL Entra admin identity orphans the database roles
)


def main() -> int:
    try:
        plan = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        print("::error::prod guard: input is not JSON")
        return 2
    if not isinstance(plan, dict) or "resource_changes" not in plan and "format_version" not in plan:
        print("::error::prod guard: input is not a Terraform plan")
        return 2
    hits = []
    for change in plan.get("resource_changes") or []:
        rtype = change.get("type")
        actions = (change.get("change") or {}).get("actions") or []
        if rtype in GUARDED and "delete" in actions:
            hits.append((rtype, "replace" if "create" in actions else "delete"))
    for rtype, action in sorted(hits):
        print(f"::error::prod guard: the plan would {action} a {rtype}")
    if hits:
        print("Refusing to apply. Data resources are never deleted by the pipeline; see docs/prod-bootstrap.md.")
        return 1
    print("prod guard: no guarded guarded resource is deleted or replaced")
    return 0


if __name__ == "__main__":
    sys.exit(main())
