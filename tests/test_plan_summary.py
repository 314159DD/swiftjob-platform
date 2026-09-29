import importlib.util
import pathlib

spec = importlib.util.spec_from_file_location(
    "plan_summary", pathlib.Path(__file__).parents[1] / "scripts" / "plan_summary.py"
)
plan_summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan_summary)


def rc(type_, name, actions, after=None):
    return {"type": type_, "name": name, "address": f"{type_}.{name}",
            "change": {"actions": actions, "after": after or {}}}


def test_no_changes():
    plan = {"resource_changes": [rc("azurerm_resource_group", "x", ["no-op"]),
                                 rc("azurerm_client_config", "y", ["read"])]}
    assert plan_summary.summarise(plan) == "No changes."


def test_missing_resource_changes_key():
    assert plan_summary.summarise({}) == "No changes."


def test_counts_per_type_and_action():
    plan = {"resource_changes": [
        rc("azurerm_management_group", "a", ["create"]),
        rc("azurerm_management_group", "b", ["create"]),
        rc("azurerm_policy_definition", "c", ["update"]),
        rc("azurerm_role_assignment", "d", ["delete", "create"]),
        rc("azurerm_role_assignment", "e", ["delete"]),
    ]}
    out = plan_summary.summarise(plan)
    assert "| `azurerm_management_group` | 2 |  |  |  |  |  |" in out
    assert "| `azurerm_policy_definition` |  | 1 |  |  |  |  |" in out
    assert "| `azurerm_role_assignment` |  |  | 1 | 1 |  |  |" in out
    assert "Total: 2 to create, 1 to update, 1 to replace, 1 to delete" in out


def test_names_and_values_never_appear():
    plan = {"resource_changes": [
        rc("azurerm_key_vault_secret", "vendor_api_key", ["create"],
           after={"name": "SECRET-VENDOR-KEY", "value": "hunter2"}),
    ]}
    out = plan_summary.summarise(plan)
    for leaked in ("vendor_api_key", "SECRET-VENDOR-KEY", "hunter2"):
        assert leaked not in out
    assert "`azurerm_key_vault_secret`" in out


def test_imports_are_counted():
    change = rc("azurerm_management_group", "root", ["no-op"])
    change["change"]["importing"] = {"id": "/providers/Microsoft.Management/managementGroups/secret-id"}
    out = plan_summary.summarise({"resource_changes": [change]})
    assert "| `azurerm_management_group` |  |  |  |  |  | 1 |" in out
    assert "1 to import" in out
    assert "secret-id" not in out
