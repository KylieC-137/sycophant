#!/usr/bin/env bash
# Offline acceptance suite for the apiserver auth-config render.
# Renders the sycophant-cluster chart with `helm template` only. No cluster.
#
#   bash tests/unit/oidc-identity-root/acceptance.sh
#
# Covers the per-identity trust model:
# the chart always renders AuthenticationConfiguration off the `idp` contract
# with no `authEngine` toggle, maps identity as the issuer-prefixed `sub` only,
# and guards the reserved `system:` prefix on the raw claim. Exits non-zero and
# prints every unmet expectation.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
source "$HERE/../lib.sh"
CHART="$ROOT/charts/sycophant-cluster"
readonly CHART
# shellcheck disable=SC2034  # SCHEMA reserved for future schema validation.
{
SCHEMA="$CHART/values.schema.json"
readonly SCHEMA
}

render() { helm template c "$CHART" -n sycophant --api-versions policies.kyverno.io/v1/ValidatingPolicy --show-only templates/apiserver-auth-config.yaml "$@" 2>&1; }

# The whole trust config the per-identity model needs: issuer + audience, no
# authEngine, no groups. Identity is the prefixed sub; no group claim is mapped
# or consulted.
cat > "$WORK/one.yaml" <<'YAML'
idp:
  issuer: https://idp-a.example.com
  audience: aud-a
YAML

# The chart renders AuthenticationConfiguration unconditionally from `idp`,
# with no authEngine selector.
t_always_renders_authconfig() {
  local out
  if ! out="$(render -f "$WORK/one.yaml")"; then
    bad always_renders_authconfig "chart failed to render with no authEngine set; the render must be unconditional off idp: $(tail -1 <<<"$out")"
  elif ! grep -q 'kind: AuthenticationConfiguration' <<<"$out"; then
    bad always_renders_authconfig "no 'kind: AuthenticationConfiguration' rendered; the auth config must render off idp with no authEngine gate"
  else
    ok always_renders_authconfig
  fi
}

# The schema rejects an authEngine key: the toggle is gone, not merely
# defaulted. Set on an otherwise-valid config, it must fail on authEngine
# itself (not on some other property).
t_schema_rejects_authengine() {
  local out
  if out="$(render -f "$WORK/one.yaml" --set authEngine=oidc)"; then
    bad schema_rejects_authengine "an authEngine key was accepted; the schema must reject it (authEngine is removed, not defaulted)"
  elif ! grep -qi 'authengine' <<<"$out"; then
    bad schema_rejects_authengine "render failed but not on authEngine; the rejection must name authEngine: $(tail -1 <<<"$out")"
  else
    ok schema_rejects_authengine
  fi
}

# The issuer block carries one claimValidationRules CEL rule rejecting the
# reserved system: prefix on the RAW sub, and no userValidationRules block.
# The guard runs before the prefix is applied.
t_system_claim_validation_rule() {
  local out
  if ! out="$(render -f "$WORK/one.yaml")"; then
    bad system_claim_validation_rule "single-issuer config failed to render: $(tail -1 <<<"$out")"
    return
  fi
  local guards; guards="$(grep -c '!claims.sub.startsWith("system:")' <<<"$out")"
  if ! grep -q 'claimValidationRules' <<<"$out"; then
    bad system_claim_validation_rule "no claimValidationRules block; the issuer must reject a system: sub on the raw claim"
  elif [ "$guards" != "1" ]; then
    bad system_claim_validation_rule "expected one '!claims.sub.startsWith(\"system:\")' guard, found $guards"
  elif grep -q 'userValidationRules' <<<"$out"; then
    bad system_claim_validation_rule "a userValidationRules block is present; the guard runs on the raw claim via claimValidationRules, never on the prefixed user"
  else
    ok system_claim_validation_rule
  fi
}

# Claim mapping is username/sub only: no groups, uid, or extra mapping.
t_no_groups_uid_extra_mapping() {
  local out
  if ! out="$(render -f "$WORK/one.yaml")"; then
    bad no_groups_uid_extra_mapping "single-issuer config failed to render: $(tail -1 <<<"$out")"
    return
  fi
  if ! grep -q 'claim: sub' <<<"$out"; then
    bad no_groups_uid_extra_mapping "identity is not mapped to the stable subject (sub); username must map sub"
  elif grep -qE '^[[:space:]]*groups:' <<<"$out"; then
    bad no_groups_uid_extra_mapping "a groups claim mapping is present; the model maps no groups"
  elif grep -qE '^[[:space:]]*uid:' <<<"$out"; then
    bad no_groups_uid_extra_mapping "a uid claim mapping is present; the model maps no uid"
  elif grep -qE '^[[:space:]]*extra:' <<<"$out"; then
    bad no_groups_uid_extra_mapping "an extra claim mapping is present; the model maps no extra"
  else
    ok no_groups_uid_extra_mapping
  fi
}

# The issuer block sets its audience and an issuer-derived username prefix
# (<issuer>#), so the subject namespace is the issuer's own.
t_audience_and_prefix() {
  local out
  if ! out="$(render -f "$WORK/one.yaml")"; then
    bad audience_and_prefix "single-issuer config failed to render: $(tail -1 <<<"$out")"
    return
  fi
  if ! grep -q '"aud-a"' <<<"$out"; then
    bad audience_and_prefix "the issuer must carry its audience; the aud is missing"
  elif ! grep -q 'prefix: "https://idp-a.example.com#"' <<<"$out"; then
    bad audience_and_prefix "the username prefix must be derived from the issuer URL (<issuer>#)"
  else
    ok audience_and_prefix
  fi
}

t_always_renders_authconfig
t_schema_rejects_authengine
t_system_claim_validation_rule
t_no_groups_uid_extra_mapping
t_audience_and_prefix

summary
