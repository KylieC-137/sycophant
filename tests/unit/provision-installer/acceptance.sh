#!/usr/bin/env bash
# Offline: renders the install policies from the cluster chart, generates each
# kind's install objects from a marker with `kyverno apply`, then runs the
# generated Job script against stub helm and kubectl. No cluster.
#
#   bash tests/unit/provision-installer/acceptance.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CHART="$ROOT/charts/sycophant-cluster"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() { helm template c "$CHART" -n kyverno --api-versions policies.kyverno.io/v1/ValidatingPolicy "$@"; }

generate() {
  mkdir -p "$WORK/$2-out"
  kyverno apply "$WORK/$1-policy.yaml" --resource "$HERE/$2.yaml" \
    -f "$HERE/values.yaml" -o "$WORK/$2-out" --remove-color >/dev/null 2>&1
}
for kind in tenant workspace user toolset inference; do
  render --show-only "templates/$kind-kpol.yaml" > "$WORK/$kind-policy.yaml"
  generate "$kind" "$kind"
done
generate inference reap-inference

mkdir -p "$WORK/bin"
cat > "$WORK/bin/kubectl" <<'SH'
#!/bin/sh
printf 'kubectl %s\n' "$*" >> "$CALLS"
case "$*" in
  *"get configmap"*) printf '%s' "${GET_CM:-{\}}" ;;
esac
exit 0
SH
cat > "$WORK/bin/helm" <<'SH'
#!/bin/sh
printf 'helm %s\n' "$*" >> "$CALLS"
exit "${HELM_EXIT:-0}"
SH
chmod +x "$WORK/bin/kubectl" "$WORK/bin/helm"

python3 - "$WORK" "$HERE" <<'PY'
import json, os, re, subprocess, sys, yaml

work = sys.argv[1]
uid10 = "0a1b2c3d4e"
cases = {
    "tenant": {"marker": "provision-tenant", "marker_ns": "sycophant-system", "release": None},
    "workspace": {"marker": "provision-workspace-one", "marker_ns": "tenant-acme", "release": "workspace-one"},
    "user": {"marker": "provision-user-0123456789", "marker_ns": "tenant-acme", "release": "user-0123456789"},
    "toolset": {"marker": "provision-toolset-one", "marker_ns": "tenant-acme", "release": "toolset-one"},
    "inference": {"marker": "provision-inference-local", "marker_ns": "tenant-acme", "release": "inference-local"},
}
passed = failed = 0

def ok(name):
    global passed
    passed += 1
    print(f"ok   {name}")

def bad(name, why):
    global failed
    failed += 1
    print(f"FAIL {name}\n    {why}")

def generated(kind):
    out = os.path.join(work, f"{kind}-out")
    docs = []
    for f in sorted(os.listdir(out)) if os.path.isdir(out) else []:
        with open(os.path.join(out, f)) as fh:
            docs += [d for d in yaml.safe_load_all(fh) if d]
    return docs

def find(docs, kind, name, ns):
    for d in docs:
        m = d.get("metadata", {})
        if d.get("kind") == kind and m.get("name") == name and m.get("namespace") == ns:
            return d
    return None

def run_job(job, helm_exit, get_cm="{}"):
    c = job["spec"]["template"]["spec"]["containers"][0]
    script = c["args"][0].replace("/tmp/", work + "/scratch/")
    os.makedirs(work + "/scratch", exist_ok=True)
    calls = os.path.join(work, "calls")
    open(calls, "w").close()
    env = {e["name"]: e.get("value", "") for e in c.get("env", [])}
    env.update(PATH=f"{work}/bin:/usr/bin:/bin", CALLS=calls, HELM_EXIT=str(helm_exit), HOME=work, GET_CM=get_cm)
    rc = subprocess.run(["sh", "-c", script], env=env, capture_output=True).returncode
    with open(calls) as fh:
        return rc, [l.split() for l in fh.read().splitlines()]

def selects(selector, labels):
    if any(labels.get(k) != v for k, v in (selector.get("matchLabels") or {}).items()):
        return False
    return all(e["operator"] == "In" and labels.get(e["key"]) in e["values"]
               for e in selector.get("matchExpressions") or [])

def reap_policy(kind):
    return next((d for d in yaml.safe_load_all(open(os.path.join(work, f"{kind}-policy.yaml"))) or []
                 if d and d.get("kind") == "DeletingPolicy" and d["metadata"]["name"] == f"reap-{kind}"), None)

def reaps(policy, docs):
    selector = policy["spec"]["matchConstraints"]["objectSelector"]
    expr = next(v["expression"] for v in policy["spec"]["variables"] if v["name"] == "reapAfter")
    annotation = re.search(r'annotations\["([^"]+)"\]', expr).group(1)
    return [f"{d['kind']}/{d['metadata']['name']}" for d in docs
            if not selects(selector, d["metadata"].get("labels") or {})
            or not (d["metadata"].get("annotations") or {}).get(annotation)]

def deletes_marker(argv, marker, ns):
    if argv[0] != "kubectl" or "delete" not in argv or marker not in argv:
        return False
    if not any(a in ("configmap", "configmaps", "cm") for a in argv):
        return False
    return any(argv[i] in ("-n", "--namespace") and argv[i + 1] == ns for i in range(len(argv) - 1)) \
        or f"--namespace={ns}" in argv

for kind, c in cases.items():
    docs = generated(kind)
    name = f"provision-{kind}-{uid10}"
    sa = find(docs, "ServiceAccount", name, "sycophant-system")
    job = find(docs, "Job", name, "sycophant-system")
    rb = find(docs, "RoleBinding", name, "tenant-acme")
    if not (sa and job and rb and job["spec"]["template"]["spec"].get("serviceAccountName") == name
            and [s.get("name") for s in rb.get("subjects", [])] == [name]):
        bad(f"{kind}: install identity named from the marker uid",
            f"want ServiceAccount and Job {name} in sycophant-system and RoleBinding {name} in tenant-acme using it; generated {[(d['kind'], d['metadata'].get('name')) for d in docs]}")
        continue
    ok(f"{kind}: install identity named from the marker uid")

    if rb["roleRef"] == {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "provision-write"}:
        ok(f"{kind}: install RoleBinding binds ClusterRole provision-write")
    else:
        bad(f"{kind}: install RoleBinding binds ClusterRole provision-write", f"roleRef {rb['roleRef']}")

    if kind != "tenant":
        reap = reap_policy(kind)
        miss = reaps(reap, (sa, rb)) if reap else ["no DeletingPolicy"]
        if miss:
            bad(f"reap-{kind} selects this install SA and RoleBinding", f"not reaped: {miss}")
        else:
            ok(f"reap-{kind} selects this install SA and RoleBinding")

    rc, calls = run_job(job, 0)
    helm_at = [i for i, a in enumerate(calls) if a[0] == "helm" and "upgrade" in a]
    del_at = [i for i, a in enumerate(calls) if deletes_marker(a, c["marker"], c["marker_ns"])]
    if rc == 0 and helm_at and del_at and min(del_at) > max(helm_at):
        ok(f"{kind}: successful install deletes its marker after helm")
    else:
        bad(f"{kind}: successful install deletes its marker after helm",
            f"rc={rc}, calls={[' '.join(a) for a in calls]}")

    if c["release"]:
        if helm_at and c["release"] in calls[helm_at[0]]:
            ok(f"{kind}: release named from the marker name suffix")
        else:
            bad(f"{kind}: release named from the marker name suffix",
                f"want {c['release']} in {[' '.join(calls[i]) for i in helm_at]}")

    rc, calls = run_job(job, 1)
    if rc != 0 and not any(deletes_marker(a, c["marker"], c["marker_ns"]) for a in calls):
        ok(f"{kind}: failed install leaves its marker")
    else:
        bad(f"{kind}: failed install leaves its marker", f"rc={rc}, calls={[' '.join(a) for a in calls]}")

docs = generated("tenant")
name = f"provision-tenant-{uid10}"
rb = find(docs, "RoleBinding", name, "sycophant-system")
if rb and rb["roleRef"] == {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "provision-tenant-marker"} \
        and [(s.get("kind"), s.get("name"), s.get("namespace")) for s in rb.get("subjects", [])] == [("ServiceAccount", name, "sycophant-system")]:
    ok("tenant: install ServiceAccount bound to the marker-delete Role")
else:
    bad("tenant: install ServiceAccount bound to the marker-delete Role", f"got {rb}")

reap_t = next((d for d in yaml.safe_load_all(open(os.path.join(work, "tenant-policy.yaml"))) or []
               if d and d.get("kind") == "DeletingPolicy" and d["metadata"]["name"] == "reap-tenant"), None)
t_sa = find(docs, "ServiceAccount", f"provision-tenant-{uid10}", "sycophant-system")
name = "tenant: the scheduled sweep selects the install ServiceAccount and RoleBinding"
if not (reap_t and t_sa):
    bad(name, "missing reap-tenant DeletingPolicy or install ServiceAccount")
else:
    cond = next(c["expression"] for c in reap_t["spec"]["conditions"] if c["name"] == "selector-matches-by-kind")
    kinds = {r for rule in reap_t["spec"]["matchConstraints"]["resourceRules"] for r in rule["resources"]}
    if f'"{t_sa["metadata"]["labels"]["app.kubernetes.io/component"]}"' in cond \
            and {"namespaces", "serviceaccounts", "rolebindings"} <= kinds:
        ok(name)
    else:
        bad(name, f"component label not in selector or kinds {kinds}")

def install_call(kind, get_cm="{}"):
    job = find(generated(kind), "Job", f"provision-{kind}-{uid10}", "sycophant-system")
    if not job:
        return None
    _, calls = run_job(job, 0, get_cm)
    return next((a for a in calls if a[0] == "helm" and "upgrade" in a), None)

job = find(generated("tenant"), "Job", f"provision-tenant-{uid10}", "sycophant-system")
argv = install_call("tenant") or []
env = [e["name"] for e in job["spec"]["template"]["spec"]["containers"][0].get("env", [])] if job else []
name = "tenant: install passes no values to helm"
if job and argv and not {"-f", "--values"} & set(argv) and "VALUES" not in env:
    ok(name)
else:
    bad(name, f"argv={' '.join(argv)}, env={env}")

taking = [k for k in ("workspace", "user", "toolset", "inference")
          if (install_call(k) or ["--take-ownership"]).count("--take-ownership")]
if taking:
    bad("capability installs never take ownership of another release's objects", f"--take-ownership on {taking}")
else:
    ok("capability installs never take ownership of another release's objects")

marker_data = yaml.safe_load(open(os.path.join(sys.argv[2], "inference.yaml")))["data"]
argv = install_call("inference", json.dumps(marker_data))
name = "inference: install hands the marker data and name to the chart"
if not argv:
    bad(name, "no helm upgrade call")
else:
    files = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] in ("-f", "--values")]
    loaded = [yaml.safe_load(open(f)) for f in files if os.path.exists(f)]
    sets = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] in ("--set", "--set-string")]
    if any((v or {}).get("marker") == marker_data for v in loaded) and "render=inference" in sets and "name=local" in sets:
        ok(name)
    else:
        bad(name, f"argv={' '.join(argv)}, values={loaded}")

docs = generated("reap-inference")
name = f"uninstall-inference-{uid10}"
sa = find(docs, "ServiceAccount", name, "sycophant-system")
job = find(docs, "Job", name, "sycophant-system")
rb = find(docs, "RoleBinding", name, "tenant-acme")
if sa and job and rb and job["spec"]["template"]["spec"].get("serviceAccountName") == name \
        and rb["roleRef"] == {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "provision-write"} \
        and [(s.get("kind"), s.get("name"), s.get("namespace")) for s in rb.get("subjects", [])] == [("ServiceAccount", name, "sycophant-system")]:
    ok("inference: reap marker generates a uid-named uninstall identity bound to provision-write")
else:
    bad("inference: reap marker generates a uid-named uninstall identity bound to provision-write",
        f"generated {[(d['kind'], d['metadata'].get('name'), d['metadata'].get('namespace')) for d in docs]}")

if job:
    rc, calls = run_job(job, 0)
    un_at = [i for i, a in enumerate(calls) if a[:2] == ["helm", "uninstall"] and "inference-deepseek" in a
             and any(a[j] in ("-n", "--namespace") and a[j + 1] == "tenant-acme" for j in range(len(a) - 1))]
    del_at = [i for i, a in enumerate(calls) if deletes_marker(a, "reap-inference-deepseek", "tenant-acme")]
    if rc == 0 and un_at and del_at and min(del_at) > max(un_at) and not any(a[0] == "helm" and "upgrade" in a for a in calls):
        ok("inference: uninstall removes the release, then deletes its reap marker")
    else:
        bad("inference: uninstall removes the release, then deletes its reap marker", f"rc={rc}, calls={[' '.join(a) for a in calls]}")
    rc, calls = run_job(job, 1)
    if rc != 0 and not any(deletes_marker(a, "reap-inference-deepseek", "tenant-acme") for a in calls):
        ok("inference: failed uninstall leaves its reap marker")
    else:
        bad("inference: failed uninstall leaves its reap marker", f"rc={rc}, calls={[' '.join(a) for a in calls]}")
else:
    bad("inference: uninstall removes the release, then deletes its reap marker", "no uninstall Job")
    bad("inference: failed uninstall leaves its reap marker", "no uninstall Job")

reap = reap_policy("inference")
name = "inference: the scheduled sweep selects the uninstall identity"
if not (reap and sa and rb):
    bad(name, "missing reap-inference DeletingPolicy or uninstall identity")
else:
    miss = [f"{d['kind']}/{d['metadata']['name']}" for d in (sa, rb)
            if (d["metadata"].get("labels") or {}).get("app.kubernetes.io/component") != "uninstall-inference"]
    miss += reaps(reap, (sa, rb))
    if miss:
        bad(name, f"{miss} not labelled uninstall-inference or not reaped")
    else:
        ok(name)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
