# 2. Management group hierarchy

- Status: accepted
- Date: 2026-09-30

## Context

Policy and access are easiest to reason about when they are assigned once, high up, and inherited. The
subscription is a free trial and already holds one other project.
After the trial there should be one subscription per environment, so that a budget, a role assignment or a
mistake in one environment cannot reach another.

## Decision

The tree below `mg-swiftjob` is defined in `platform/management-groups.tf`:

```
mg-swiftjob
  mg-platform
  mg-workloads
    mg-prod
    mg-nonprod
  mg-sandbox
```

- `mg-swiftjob` carries all policy assignments. It is created by the bootstrap and imported into Terraform,
  which owns everything below it.
- `mg-platform` is for shared platform subscriptions and `mg-workloads` for application environments, split
  into production and non-production so that policy can differ between them later. `mg-sandbox` is for
  experiments and is excluded from the cost-guard policies (ADR 3). The location, tag and storage policies
  still apply to it.
- For now there is a single subscription. The owner moved it under `mg-workloads` with
  `scripts/move-subscription.sh`. `subscription_ids` on `mg-workloads` is in `ignore_changes`, so Terraform
  does not fight that move. A re-run of the apply after the move
  ([36648633515](https://github.com/314159DD/swiftjob-platform/actions/runs/36648633515)) reported no changes.
- After the move to pay-as-you-go (roadmap phase 7), each environment gets its own subscription under
  `mg-prod` or `mg-nonprod`.

## Consequences

- New subscriptions inherit every guardrail on arrival.
- `mg-platform`, `mg-prod` and `mg-nonprod` are empty until phase 7. Empty management groups cost nothing.
- Until then, production and non-production resources share a subscription and are separated by resource
  group and by the identities in ADR 1, without a subscription boundary between them.
- Azure makes the creator of a management group its Owner. The bootstrap removes such assignments from the
  pipeline identities, and the nightly Drift run fails if one reappears. This applies again whenever Terraform
  creates more management groups, for example with subscription vending.
