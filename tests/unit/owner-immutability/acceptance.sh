#!/usr/bin/env bash
# Offline: renders the tenant-namespace PSA-required VAP and checks that the
# sycophant.md/owner annotation and label are immutable on UPDATE.
# No cluster.
#
#   bash tests/unit/owner-immutability/acceptance.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

rendered="$(helm template c "$ROOT/charts/sycophant-cluster" \
  --api-versions policies.kyverno.io/v1/ValidatingPolicy \
  --show-only templates/tenant-ns-psa-required-vap.yaml 2>&1)" || {
  printf 'FAIL render tenant-ns-psa-required-vap.yaml\n    %s\n' "$rendered"
  exit 1
}

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n    %s\n' "$1" "$2"; }

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
