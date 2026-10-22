#!/usr/bin/env bash
# Offline: renders the tenant-namespace PSA-required VAP and checks that the
# sycophant.md/owner annotation and label are immutable on UPDATE.
# No cluster.
#
#   bash tests/unit/owner-immutability/acceptance.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
source "$HERE/../lib.sh"

rendered="$(helm template c "$ROOT/charts/sycophant-cluster" \
  --api-versions policies.kyverno.io/v1/ValidatingPolicy \
  --show-only templates/tenant-ns-psa-required-vap.yaml 2>&1)" || {
  printf 'FAIL render tenant-ns-psa-required-vap.yaml\n    %s\n' "$rendered"
  exit 1
}
readonly rendered

# AC4a: the rendered VAP must deny UPDATE that changes the sycophant.md/owner annotation.
if printf '%s' "$rendered" | grep -q "sycophant.md/owner.*annotation.*immutable"; then
  ok "owner annotation immutability expression present"
else
  bad "owner annotation immutability expression present" \
      "the rendered tenant-ns-psa-required VAP does not contain an immutability validation for the sycophant.md/owner annotation"
fi

# AC4b: the rendered VAP must deny UPDATE that changes the sycophant.md/owner label.
if printf '%s' "$rendered" | grep -q "sycophant.md/owner.*label.*immutable"; then
  ok "owner label immutability expression present"
else
  bad "owner label immutability expression present" \
      "the rendered tenant-ns-psa-required VAP does not contain an immutability validation for the sycophant.md/owner label"
fi

summary
