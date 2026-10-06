#!/usr/bin/env bash
# Offline: renders the command VAPs from the cluster chart and runs each case
# directory through `kyverno test`, then checks that every rejection names its
# field and that every template in the commands chart, rendered with the test
# values, is admitted. No cluster.
#
#   bash tests/unit/command-vap/acceptance.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$HERE/." "$WORK/"

helm template c "$ROOT/charts/sycophant-cluster" -n kyverno \
  --api-versions policies.kyverno.io/v1/ValidatingPolicy \
  --show-only templates/command-vap.yaml > "$WORK/policy.yaml" || exit 1

python3 - "$WORK" "$HERE" "$ROOT/charts/sycophant-commands" <<'PY'
import os, subprocess, sys, yaml
work, here, chart = sys.argv[1:4]
case = os.path.join(work, "commands")
os.makedirs(case)
checks = []
def check(name, good, detail=""):
    checks.append(f"{'ok' if good else 'bad'}\t{name}\t{detail}\n")

tdir = os.path.join(chart, "templates")
templates = sorted(f[:-len(".yaml")] for f in os.listdir(tdir) if f.endswith(".yaml")) if os.path.isdir(tdir) else []

renders = [(t, "command-values.yaml", t) for t in templates]
renders.append(("inference-provision", "command-values-remote.yaml", "inference-provision-remote"))
rendered = {}
for template, values, out in renders:
    p = subprocess.run(["helm", "template", "c", chart, "-f", os.path.join(here, values),
                        "--show-only", f"templates/{template}.yaml"], capture_output=True, text=True)
    if p.returncode != 0:
        check(f"render {out}", False, p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "")
        continue
    docs = [d for d in yaml.safe_load_all(p.stdout) if d]
    if len(docs) != 1 or docs[0].get("kind") != "ConfigMap":
        check(f"render {out}", False, f"{len(docs)} objects, not one ConfigMap")
        continue
    rendered[out] = docs[0]
    yaml.safe_dump(docs[0], open(os.path.join(case, out + ".yaml"), "w"))

def summary(out):
    d = rendered.get(out)
    return d and (d["metadata"]["name"], d["metadata"]["namespace"], d.get("data") or {})

want = ("provision-workspace-hello-world", "tenant-acme", {
    "toolsets": "stdlib,ssh-credentials",
    "models": "deepseek,local",
    "storage": "5Gi",
    "grant.ssh-credentials.demo-key.secret": "demo-ssh-key",
    "grant.ssh-credentials.demo-key.path": "/home/agent/.ssh/id_ed25519",
    "grant.ssh-credentials.demo-key.egress": "git.example.com",
})
check("workspace values flatten to command data", summary("workspace-provision") == want,
      f"got: {summary('workspace-provision')}")

want = ("provision-tenant", "sycophant-system", {"tenant": "acme", "capacity": "2Gi"})
check("tenant values flatten to command data", summary("tenant-provision") == want,
      f"got: {summary('tenant-provision')}")

want = ("provision-toolset-git", "tenant-acme", {
    "image": "ghcr.io/sycophant-md/git@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "keepalive": "true",
    "deadlineSeconds": "300",
    "env.GIT_TERMINAL_PROMPT": "0",
    "tool.git-status.description": "Show the working tree status in the workspace.",
    "tool.git-clone.description": "Clone a git repository.",
    "tool.git-clone.arg.url.type": "string",
    "tool.git-clone.arg.url.required": "true",
    "tool.git-clone.arg.url.env": "URL",
    "tool.git-clone.arg.url.description": "Repository URL.",
})
check("toolset values flatten to command data", summary("toolset-provision") == want,
      f"got: {summary('toolset-provision')}")

want = ("provision-user-b212e3ad41", "tenant-acme", {"user": "https://dex.example.com/dex#alice"})
check("user command named by the subject's sha256 handle", summary("user-provision") == want,
      f"got: {summary('user-provision')}")

want = ("provision-channel-app", "tenant-acme", {
    "storageClass": "local-path",
    "kind": "app",
    "image": "tailscale/tailscale",
    "tag": "v1.80.0",
    "pullPolicy": "Always",
    "loginServer": "http://headscale:8080",
    "hostname": "relay",
    "authKeySecret": "relay-tsnet-authkey",
    "headscale.enabled": "true",
    "headscale.image": "headscale/headscale",
    "headscale.tag": "0.28.0",
    "headscale.pullPolicy": "Always",
    "headscale.serverUrl": "http://localhost:8080",
    "headscale.magicDns": "true",
    "headscale.baseDomain": "ts.local",
    "headscale.acme.enabled": "false",
    "headscale.acme.email": "ops@example.com",
})
check("channel values flatten to command data", summary("channel-provision") == want,
      f"got: {summary('channel-provision')}")

results, names = [], []
for out, d in sorted(rendered.items()):
    kind, verb = out.split("-")[:2]
    m = d["metadata"]
    names.append(m["name"])
    results.append({"policy": f"command-{verb}-{kind}", "isValidatingAdmissionPolicy": True,
                    "kind": "ConfigMap", "result": "pass",
                    "resources": [f"{m['namespace']}/{m['name']}"]})
open(os.path.join(work, "admitted"), "w").write("".join(n + "\n" for n in names))
open(os.path.join(work, "checks"), "w").write("".join(checks))
yaml.safe_dump({"apiVersion": "cli.kyverno.io/v1alpha1", "kind": "Test",
                "metadata": {"name": "command-vap-commands"}, "policies": ["../policy.yaml"],
                "resources": [o + ".yaml" for o in sorted(rendered)], "userinfo": "../operator.yaml",
                "variables": "../values.yaml", "results": results},
               open(os.path.join(case, "kyverno-test.yaml"), "w"))
PY

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
expect inference-commands provision-inference-deepseek ""
expect inference-commands provision-inference-format format
expect inference-commands provision-inference-baseurl "'baseUrl' must be an http or https URL whose host is a dotted name"
expect inference-commands provision-inference-bool server.singleNodeException
expect inference-commands provision-inference-localbaseurl "must not carry a 'baseUrl'"
expect inference-commands provision-inference-singlelabel "'baseUrl' must be an http or https URL whose host is a dotted name"
expect inference-commands provision-inference-emptyimage "non-empty 'server.image'"
expect inference-commands reap-inference-data ""
expect toolset-commands provision-toolset-tagimage "'image' must"
expect toolset-commands provision-toolset-bogus "unknown key 'tool.git-status.bogus'"
expect toolset-commands provision-toolset-badtype "'tool.git-clone.arg.url.type' must"
expect toolset-commands provision-toolset-deadline "'deadlineSeconds' must"
expect toolset-commands provision-toolset-noenv "'tool.git-clone.arg.url.env'"
expect toolset-commands provision-toolset-dotted "unknown key 'tool.git.status.description'"
expect toolset-commands provision-toolset-notype "'tool.git-clone.arg.url.type'"
expect toolset-commands provision-toolset-dottedarg "unknown key 'tool.git-clone.arg.u.rl."
expect toolset-commands provision-toolset-required "'tool.git-clone.arg.url.required' must"
expect toolset-commands reap-toolset-data "'image'"
expect workspace-commands provision-workspace-unlisted "'grant.ssh-credentials.demo-key.secret' grants a toolset not in 'toolsets'"
expect workspace-commands provision-workspace-nosecret "'grant.ssh-credentials.demo-key.path' has no '.secret' beside it"
expect workspace-commands provision-workspace-harnesscpu "unknown key 'harness.cpu'"
expect workspace-commands provision-workspace-undottedegress "'grant.ssh-credentials.demo-key.egress' must be a dotted hostname"
expect workspace-commands provision-workspace-relativepath "'grant.ssh-credentials.demo-key.path' must be an absolute path"
expect workspace-commands provision-workspace-badsecret "a workspace grant's 'secret' must be a Secret name"
expect suspend-bad-keepalive suspend-tenant "0, 30, 60, 90"
expect slice-commands-validate-data "provision-workspace-$(printf 'a%.0s' {1..49})" ""
expect slice-commands-validate-data "provision-workspace-$(printf 'a%.0s' {1..50})" "at most 49"
expect slice-commands-validate-data "provision-toolset-$(printf 'a%.0s' {1..50})" ""
expect slice-commands-validate-data "provision-toolset-$(printf 'a%.0s' {1..51})" "at most 50"
expect slice-commands-validate-data "provision-inference-$(printf 'a%.0s' {1..49})" ""
expect slice-commands-validate-data "provision-inference-$(printf 'a%.0s' {1..50})" "at most 49"
expect slice-commands-validate-data "provision-channel-$(printf 'a%.0s' {1..50})" ""
expect slice-commands-validate-data "provision-channel-$(printf 'a%.0s' {1..51})" "at most 50"
expect slice-commands-validate-data provision-channel-yes "'headscale.enabled' must be \"true\" or \"false\""
expect slice-commands-validate-data provision-channel-magicdns "'headscale.magicDns' must be \"true\" or \"false\""
expect slice-commands-validate-data provision-channel-kind "'kind' app"
expect slice-commands-validate-data provision-channel-nologin "non-empty 'loginServer'"
expect slice-commands-validate-data provision-channel-emptylogin "non-empty 'loginServer'"
expect slice-commands-validate-data provision-channel-noserverurl "non-empty 'headscale.serverUrl'"
expect slice-commands-validate-data provision-channel-noacmeemail "non-empty 'headscale.acme.email'"
expect slice-commands-validate-data provision-user-0f1e2d3c4 handle
expect slice-commands-validate-data provision-user-1f1e2d3c4b quote
expect slice-commands-validate-data provision-user-2f1e2d3c4b quote
expect slice-commands-validate-data provision-user-3f1e2d3c4b quote
while IFS=$'\t' read -r res name detail; do
  if [ "$res" = ok ]; then ok "$name"; else bad "$name" "$detail"; fi
done < "$WORK/checks"
while read -r name; do expect commands "$name" ""; done < "$WORK/admitted"

open="$(python3 - "$WORK/policy.yaml" <<'PY'
import sys, yaml
vaps = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "ValidatingAdmissionPolicy"]
print(" ".join(d["metadata"]["name"] for d in vaps if d["spec"].get("failurePolicy") != "Fail") if vaps else "none rendered")
PY
)"
if [ -z "$open" ]; then ok "every command VAP fails closed"; else bad "every command VAP fails closed" "$open"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
