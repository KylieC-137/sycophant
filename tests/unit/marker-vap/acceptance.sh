#!/usr/bin/env bash
# Offline: renders the marker VAPs from the cluster chart and runs each case
# directory through `kyverno test`, then checks that every rejection names its
# field. No cluster.
#
#   bash tests/unit/marker-vap/acceptance.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$HERE/." "$WORK/"

helm template c "$ROOT/charts/sycophant-cluster" -n kyverno \
  --api-versions policies.kyverno.io/v1/ValidatingPolicy \
  --show-only templates/marker-vap.yaml > "$WORK/policy.yaml" || exit 1

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n    %s\n' "$1" "$2"; }

results() {
  [ -f "$WORK/$1.json" ] || kyverno test "$WORK/$1" -o json --detailed-results --remove-color 2>/dev/null \
    | sed -n '/^\[/,/^\]/p' | jq -s 'add // []' > "$WORK/$1.json"
  cat "$WORK/$1.json"
}

expect() {
  local dir="$1" resource="$2" token="$3" out row
  out="$(results "$dir")"
  row="$(jq -c --arg r "$resource" '[.[] | select(.RESOURCE | endswith("/" + $r))][0] // empty' <<<"$out")"
  if [ -z "$row" ]; then
    bad "$dir/$resource" "no result reported"
  elif [ "$(jq -r .RESULT <<<"$row")" != "Pass" ]; then
    bad "$dir/$resource" "$(jq -r '.REASON + ": " + (.Message // "")' <<<"$row")"
  elif [ -n "$token" ] && ! jq -e --arg t "$token" '(.Message // "") | contains($t)' <<<"$row" >/dev/null; then
    bad "$dir/$resource" "rejection does not name '$token': $(jq -r '.Message // ""' <<<"$row")"
  else
    ok "$dir/$resource"
  fi
}

expect tenant-unknown-key provision-tenant bogus
expect tenant-bad-capacity provision-tenant capacity
expect tenant-from-serviceaccount provision-tenant issuer-prefixed
expect tenant-token-at-cap provision-tenant ""
expect tenant-token-over-cap provision-tenant "at most 46"
expect tenant-missing-capacity provision-tenant capacity
expect tenant-values-key provision-tenant "'values'"
expect inference-markers provision-inference-deepseek ""
expect inference-markers provision-inference-local ""
expect inference-markers provision-inference-format format
expect inference-markers provision-inference-baseurl "'baseUrl' must be an http or https URL whose host is a dotted name"
expect inference-markers provision-inference-bool server.singleNodeException
expect inference-markers provision-inference-localbaseurl "must not carry a 'baseUrl'"
expect inference-markers provision-inference-singlelabel "'baseUrl' must be an http or https URL whose host is a dotted name"
expect inference-markers provision-inference-emptyimage "non-empty 'server.image'"
expect inference-markers reap-inference-deepseek ""
expect inference-markers reap-inference-local ""
expect suspend-bad-keepalive suspend-tenant "0, 30, 60, 90"
expect slice-markers-validate-data "provision-workspace-$(printf 'a%.0s' {1..43})" ""
expect slice-markers-validate-data "provision-workspace-$(printf 'a%.0s' {1..44})" "at most 43"
expect slice-markers-validate-data "provision-toolset-$(printf 'a%.0s' {1..45})" ""
expect slice-markers-validate-data "provision-toolset-$(printf 'a%.0s' {1..46})" "at most 45"
expect slice-markers-validate-data provision-user-0f1e2d3c4 handle
expect slice-markers-validate-data provision-user-1f1e2d3c4b quote
expect slice-markers-validate-data provision-user-2f1e2d3c4b quote
expect slice-markers-validate-data provision-user-3f1e2d3c4b quote
expect slice-markers-validate-data provision-user-0123456789 ""
expect slice-markers-validate-data provision-workspace-two bogus
expect slice-markers-validate-data suspend-tenant ""

open="$(python3 - "$WORK/policy.yaml" <<'PY'
import sys, yaml
vaps = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "ValidatingAdmissionPolicy"]
print(" ".join(d["metadata"]["name"] for d in vaps if d["spec"].get("failurePolicy") != "Fail") if vaps else "none rendered")
PY
)"
if [ -z "$open" ]; then ok "every marker VAP fails closed"; else bad "every marker VAP fails closed" "$open"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
