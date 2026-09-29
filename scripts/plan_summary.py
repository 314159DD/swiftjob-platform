"""Summarise a Terraform JSON plan by resource type and action.

The summary goes into public pull request comments, so it contains resource types and counts only:
no resource names, addresses or attribute values.

Usage: terraform show -json plan.tfplan | python scripts/plan_summary.py
"""
import json
import sys
from collections import Counter

ACTIONS = ["create", "update", "replace", "delete", "other", "import"]


def classify(actions: list[str]) -> str | None:
    if actions in (["no-op"], ["read"]):
        return None
    if actions in (["create"], ["update"], ["delete"]):
        return actions[0]
    if sorted(actions) == ["create", "delete"]:
        return "replace"
    return "other"


def summarise(plan: dict) -> str:
    counts: Counter = Counter()
    for change in plan.get("resource_changes", []):
        kind = classify(change["change"]["actions"])
        if kind:
            counts[(change["type"], kind)] += 1
        if change["change"].get("importing"):
            counts[(change["type"], "import")] += 1
    if not counts:
        return "No changes."

    lines = ["| Resource type | " + " | ".join(ACTIONS) + " |", "|---|" + "---|" * len(ACTIONS)]
    for type_ in sorted({t for t, _ in counts}):
        cells = [str(counts[(type_, k)]) if counts[(type_, k)] else "" for k in ACTIONS]
        lines.append(f"| `{type_}` | " + " | ".join(cells) + " |")
    totals = {k: sum(n for (_, kk), n in counts.items() if kk == k) for k in ACTIONS}
    lines += ["", "Total: " + ", ".join(f"{totals[k]} to {k}" for k in ACTIONS if totals[k])]
    return "\n".join(lines)


if __name__ == "__main__":
    print(summarise(json.load(sys.stdin)))
