# namespace-egress-baseline

The namespace-wide egress default-deny floor: one namespace-scoped
CiliumNetworkPolicy that selects every endpoint and grants no egress, so a pod
that no per-component allow policy selects is denied rather than open. The floor
is additive — it strips no existing policy and carries no shared allow.

- `floor-denies-live-egress` — live enforcement, not shape. It applies the floor
  alone, asserts Cilium accepts it (status Valid=True), then a probe pod carrying
  the workspace-init label attempts egress to an external IP and must be denied
  (pod exits 0 / phase Succeeded). This deliberately departs from the suite's
  shape-only convention: the shipped `egress: []` floor passed every shape check
  while being inert (Valid=False, enforcing nothing), so the behavioral claim is
  verified against a real pod. A Valid=True check alone cannot catch a floor with
  `enableDefaultDeny.egress: false`, which is valid yet denies nothing — only the
  live probe does.

Render-only checks (the floor's shape, the install-wait egress allow, no policy
selects workspace-init, headscale egress hosts — headscale is now in the tenant
chart) live in `tests/unit/tenant-chart/`.
