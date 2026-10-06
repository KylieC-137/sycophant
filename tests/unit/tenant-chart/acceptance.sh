#!/usr/bin/env bash
# Offline: renders the tenant charts and checks what each one emits.
# No cluster.
#
#   bash tests/unit/tenant-chart/acceptance.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOCAL='{"format":"openai","model":"liquid/lfm2.5-8b-a1b","server.image":"llama-server:local","server.weights":"ghcr.io/example/weights:1","server.weightsPath":"/weights/model.gguf"}'
REMOTE='{"format":"openai","model":"deepseek/deepseek-v4-flash","baseUrl":"https://openrouter.ai/api/v1","image":"inference-runtime:local","secret":"llm-openrouter"}'
TOOLSET='{"image":"ghcr.io/sycophant-md/git@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","keepalive":"false","tool.git-status.description":"Show the working tree status.","tool.git-commit.description":"Commit staged changes.","tool.git-commit.arg.message.type":"string","tool.git-commit.arg.message.required":"true","tool.git-commit.arg.message.env":"MESSAGE"}'
WORKSPACE='{"toolsets":"git,ssh","models":"a,b","storage":"5Gi","grant.ssh.demo.secret":"demo-key","grant.ssh.demo.path":"/home/agent/.ssh/id","grant.ssh.demo.egress":"github.com"}'
CHANNEL='{"kind":"app","loginServer":"http://headscale:8080","headscale.enabled":"true","headscale.serverUrl":"http://localhost:8080"}'

render() {
  local out="$1" chart="$2"; shift 2
  helm template t "$ROOT/charts/sycophant-$chart" -n tenant-acme "$@" \
    > "$WORK/$out.yaml" 2> "$WORK/$out.err"
  echo $? > "$WORK/$out.rc"
}
render bare tenant --set namespace.create=false
render upgrade tenant --set namespace.create=false --is-upgrade
render channel channel --set name=app --set-json "command=$CHANNEL"
render headscale-off channel --set name=app --set-json 'command={"kind":"app","loginServer":"https://hs.example.test"}'
render acme channel --set name=app --set-json "command=$(printf '%s' "$CHANNEL" \
  | jq -c '. + {"headscale.acme.enabled":"true","headscale.acme.email":"op@example.com"}')"
render no-magic channel --set name=app --set-json "command=$(printf '%s' "$CHANNEL" \
  | jq -c '. + {"headscale.magicDns":"false"}')"
render local inference --set name=local --set-json "command=$LOCAL"
render remote inference --set name=deepseek --set-json "command=$REMOTE"
render toolset toolset --set name=git --set-json "command=$TOOLSET"
render workspace workspace --set name=one --set-json "command=$WORKSPACE"
render wsbase workspace --set name=one --set-json 'command={}'
render user user --set-json 'users=["https://issuer.example#alice"]'
for m in override:'{"server.weightsPath":"/opt/m.gguf","server.contextBudget":"8192","server.slots":"1","server.outputCap":"512","server.threads":"2","server.memory":"4Gi","server.cpu":"2"}' \
         mount:'{"server.weightsDelivery":"mount"}' \
         tpl-copy:'{"server.chatTemplate":"TEMPLATE-BODY"}' \
         tpl-mount:'{"server.weightsDelivery":"mount","server.chatTemplate":"TEMPLATE-BODY"}' \
         single-true:'{"server.singleNodeException":"true"}' \
         single-false:'{"server.singleNodeException":"false"}'; do
  render "local-${m%%:*}" inference --set name=local --set-json "command=$(printf '%s' "$LOCAL" | jq -c ". + ${m#*:}")"
done

python3 - "$WORK" "$REMOTE" "$TOOLSET" "$WORKSPACE" <<'PY'
import hashlib, json, sys, yaml

work, remote, toolset, workspace = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3]), json.loads(sys.argv[4])
passed = failed = 0

def ok(name):
    global passed
    passed += 1
    print(f"ok   {name}")

def bad(name, why):
    global failed
    failed += 1
    print(f"FAIL {name}\n    {why}")

def load(out):
    if int(open(f"{work}/{out}.rc").read()) != 0:
        return None, open(f"{work}/{out}.err").read().strip().splitlines()[-1:]
    return [d for d in yaml.safe_load_all(open(f"{work}/{out}.yaml")) if d], None

def check(name, out, fn):
    docs, err = load(out) if isinstance(out, str) else out
    if docs is None:
        bad(name, err)
        return
    try:
        why = fn(docs)
    except Exception as e:
        why = f"{type(e).__name__}: {e}"
    if why:
        bad(name, why)
    else:
        ok(name)

def objects(docs):
    return sorted(f"{d['kind']}/{d['metadata']['name']}" for d in docs)

def get(docs, kind, name):
    return next((d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name), None)

def pod(d):
    return d["spec"]["template"]

def selects(match, labels):
    return bool(match) and all(labels.get(k) == v for k, v in match.items())

def ports(rule):
    return {int(p["port"]) for t in rule.get("toPorts") or [] for p in t.get("ports") or []}

def cnps(docs):
    return [d for d in docs if d["kind"] == "CiliumNetworkPolicy"]

def argv(d):
    c = next(c for c in pod(d)["spec"]["containers"] if c["name"] == "server")
    return c.get("command", []) + c.get("args", [])

def pair(av, flag):
    return av[av.index(flag) + 1] if flag in av else None

def channel_objects(docs):
    return sorted(
        f"{d['kind']}/{d['metadata']['name']}" for d in docs
        if (d["metadata"].get("labels") or {}).get("app.kubernetes.io/component") in ("adapter", "headscale")
        or d["metadata"]["name"].startswith(("adapter-", "headscale"))
    )

def model_cm(docs, key):
    for d in docs:
        labels = d["metadata"].get("labels") or {}
        if d["kind"] == "ConfigMap" and d["metadata"]["name"] == f"inf-{key}" \
                and labels.get("sycophant.md/type") == "model" and labels.get("app.kubernetes.io/name") == key:
            return d
    return None

BASE = ["CiliumNetworkPolicy/default-deny-egress", "CiliumNetworkPolicy/install-wait-egress",
        "CiliumNetworkPolicy/relay-egress", "CiliumNetworkPolicy/relay-ingress",
        "ConfigMap/relay-access-grants", "ConfigMap/toolset-scheduling",
        "Deployment/relay-controller", "Job/install-wait",
        "Role/install-wait", "Role/relay-controller",
        "RoleBinding/install-wait", "RoleBinding/relay-controller",
        "Service/relay-controller", "ServiceAccount/install-wait", "ServiceAccount/relay-controller"]
check("base chart renders only the tenant's shared objects", "bare",
      lambda docs: None if objects(docs) == BASE else f"want {BASE}, got {objects(docs)}")

def user_binding(docs):
    subject = "https://issuer.example#alice"
    name = f"RoleBinding/user-{hashlib.sha256(subject.encode()).hexdigest()[:10]}"
    if objects(docs) != [name]:
        return f"want only {name}, got {objects(docs)}"
    rb = docs[0]
    got = ([(s["kind"], s["name"]) for s in rb.get("subjects") or []], rb["roleRef"]["kind"], rb["roleRef"]["name"])
    return got != ([("User", subject)], "ClusterRole", "provision-identity") and f"binding {got}"
check("user chart binds each identity to provision-identity in its own RoleBinding", "user", user_binding)

check("channel renders the adapter and headscale", "channel",
      lambda docs: None if all(get(docs, k, n) for k, n in [
          ("Deployment", "adapter-app"),
          ("Deployment", "headscale"),
          ("Role", "adapter-app-state"),
          ("CiliumNetworkPolicy", "adapter-transport-egress"),
          ("CiliumNetworkPolicy", "adapter-principal-egress"),
          ("CiliumNetworkPolicy", "headscale-egress")]) else channel_objects(docs))

transport = {
    "app.kubernetes.io/component": "adapter",
    "sycophant.md/adapter-class": "transport",
    "app.kubernetes.io/part-of": "sycophant",
}

def relay_rules(docs):
    d = get(docs, "CiliumNetworkPolicy", "relay-ingress")
    return (d or {}).get("spec", {}).get("ingress") or []

def admits_transport(docs):
    rules = relay_rules(docs)
    if any([e.get("matchLabels") for e in r.get("fromEndpoints") or []] == [transport]
           and [p for t in r.get("toPorts") or [] for p in t.get("ports") or []]
               == [{"port": "9091", "protocol": "TCP"}]
           for r in rules):
        return None
    return f"no 9091 transport rule in relay-ingress {rules}"
check("base with no channels admits the transport adapter on 9091", "bare", admits_transport)

def relay_fence(docs):
    relay = pod(get(docs, "Deployment", "relay-controller"))["metadata"]["labels"]
    fences = [d["metadata"]["name"] for d in cnps(docs)
              if d["spec"].get("ingress") and selects(d["spec"]["endpointSelector"].get("matchLabels"), relay)]
    if fences != ["relay-ingress"]:
        return f"want only relay-ingress fencing the relay, got {fences}"
    key = lambda r: json.dumps(r, sort_keys=True)
    got = sorted(key(([e.get("matchLabels") for e in r.get("fromEndpoints") or []], sorted(ports(r))))
                 for r in relay_rules(docs) if ports(r) != {9091})
    want = sorted(key(r) for r in [
        ([{"app.kubernetes.io/component": "harness", "app.kubernetes.io/part-of": "sycophant"}], [9090]),
        ([{"app.kubernetes.io/component": "adapter", "sycophant.md/adapter-class": "principal",
           "app.kubernetes.io/part-of": "sycophant"}], [9092]),
    ])
    return None if got == want else f"want {want}, got {got}"
check("relay-ingress alone fences the relay: harness on 9090, principal adapters on 9092", "bare", relay_fence)

def listeners(docs):
    relay = get(docs, "Deployment", "relay-controller")
    labels = pod(relay)["metadata"]["labels"]
    named = {p["name"]: p["containerPort"] for c in pod(relay)["spec"]["containers"] for p in c.get("ports") or []}
    svc = get(docs, "Service", "relay-controller") or {}
    published = {named.get(p["targetPort"], p["targetPort"]) for p in svc.get("spec", {}).get("ports") or []}
    admit = {p for d in cnps(docs) if selects(d["spec"]["endpointSelector"].get("matchLabels"), labels)
             for r in d["spec"].get("ingress") or [] for p in ports(r)}
    dial = {p for d in cnps(docs) for r in d["spec"].get("egress") or []
            if any(selects(e.get("matchLabels"), labels) for e in r.get("toEndpoints") or [])
            for p in ports(r)}
    gaps = {p: [k for k, s in (("service", published), ("ingress", admit), ("egress", dial)) if p not in s]
            for p in sorted(named.values())}
    gaps = {p: g for p, g in gaps.items() if g}
    return None if named and not gaps else f"listeners {sorted(named.values())} missing {gaps}"
parts = [load(o) for o in ("bare", "wsbase", "channel")]
check("every relay listener is published, admitted and dialed",
      (sum((d for d, _ in parts), []), None) if all(d is not None for d, _ in parts)
      else (None, next(e for d, e in parts if d is None)),
      listeners)

def adapter_shape(docs):
    deps = [d for d in docs if d["kind"] == "Deployment"
            and pod(d)["metadata"]["labels"].get("app.kubernetes.io/component") == "adapter"]
    if len(deps) != 1:
        return f"want one adapter Deployment, got {objects(deps)}"
    d = deps[0]
    spec = pod(d)["spec"]
    env = {e["name"]: e.get("value") for c in spec["containers"] for e in c.get("env") or []}
    problems = [
        (d["spec"].get("replicas"), d["spec"].get("strategy", {}).get("type")) != (1, "Recreate") and "replicas/strategy",
        spec.get("runtimeClassName") != "gvisor" and "runtimeClassName",
        spec.get("automountServiceAccountToken") is not False and "automountServiceAccountToken",
        (spec.get("securityContext") or {}).get("seccompProfile", {}).get("type") != "RuntimeDefault" and "seccompProfile",
        env.get("TS_USERSPACE") != "true" and "TS_USERSPACE",
        any(((c.get("securityContext") or {}).get("capabilities") or {}).get("add") for c in spec["containers"]) and "capabilities.add",
        any("persistentVolumeClaim" in v for v in spec.get("volumes") or []) and "persistentVolumeClaim",
    ]
    return [p for p in problems if p] or None
check("app adapter pod is a hardened singleton", "channel", adapter_shape)

def adapter_class(docs):
    d = get(docs, "Deployment", "adapter-app")
    labels = pod(d)["metadata"]["labels"]
    if (labels.get("sycophant.md/adapter-class"), labels.get("sycophant.md/channel")) != ("transport", "app"):
        return f"adapter labels {labels}"
    pols = [p for p in cnps(docs) if selects(p["spec"]["endpointSelector"].get("matchLabels"), labels)]
    if not pols or any(not p["spec"].get("egress") or p["spec"].get("ingress")
                       or "all" in json.dumps([r.get("toEntities") for r in p["spec"]["egress"]]) for p in pols):
        return f"want only fail-closed egress policies selecting the adapter, got {[p['spec'] for p in pols]}"
    every = [p for out in ("channel", "bare", "wsbase") for p in load(out)[0]
             if p["kind"] in ("CiliumNetworkPolicy", "NetworkPolicy")]
    keyed = [p["metadata"]["name"] for p in every if "sycophant.md/channel" in json.dumps(p["spec"])]
    return keyed and f"policies keyed on the channel label: {keyed}"
check("app adapter is transport class and policies key on the class", "channel", adapter_class)

def headscale(_):
    def hosts(out):
        p = get(load(out)[0], "CiliumNetworkPolicy", "headscale-egress")
        if p is None:
            return None
        eg = p["spec"]["egress"]
        dns = sorted(n.get("matchName") or "pattern" for r in eg for t in r.get("toPorts") or []
                     for n in (t.get("rules") or {}).get("dns") or [])
        fqdn = sorted(n.get("matchName") or "pattern" for r in eg for n in r.get("toFQDNs") or [])
        return p["spec"]["endpointSelector"]["matchLabels"].get("app.kubernetes.io/component"), dns, fqdn
    cp, acme = "controlplane.tailscale.com", "acme-v02.api.letsencrypt.org"
    got = {o: hosts(o) for o in ("channel", "acme", "headscale-off")}
    want = {"channel": ("headscale", [cp], [cp]),
            "acme": ("headscale", [acme, cp], [acme, cp]),
            "headscale-off": None}
    return None if got == want else f"want {want}, got {got}"
check("headscale egress reaches only its control endpoints", ([], None), headscale)

def magic_dns(_):
    def value(out):
        cm = get(load(out)[0] or [], "ConfigMap", "headscale-config")
        return cm and yaml.safe_load(cm["data"]["config.yaml"])["dns"]["magic_dns"]
    got = {o: value(o) for o in ("channel", "no-magic")}
    return None if got == {"channel": True, "no-magic": False} else f"magic_dns {got}"
check("headscale magic_dns defaults on and turns off with \"false\"", ([], None), magic_dns)

def workspace_init_unselected(docs):
    sel = [d["metadata"]["name"] for d in docs
           if (d["kind"] == "CiliumNetworkPolicy" and (d["spec"].get("endpointSelector") or {}).get("matchLabels", {}).get("app.kubernetes.io/component") == "workspace-init")
           or (d["kind"] == "NetworkPolicy" and (d["spec"].get("podSelector") or {}).get("matchLabels", {}).get("app.kubernetes.io/component") == "workspace-init")]
    return sel and f"policies select workspace-init: {sel}"
check("no policy selects the workspace-init pod", "wsbase", workspace_init_unselected)

def grants_install_only(_):
    cm = get(load("bare")[0], "ConfigMap", "relay-access-grants")
    meta = (cm or {}).get("metadata", {})
    if (meta.get("annotations") or {}).get("helm.sh/resource-policy") != "keep" \
            or (meta.get("labels") or {}).get("sycophant.md/type") != "relay-access-grants":
        return f"install must render relay-access-grants with keep and its type label, got {meta}"
    docs, err = load("upgrade")
    if docs is None:
        return err
    if not get(docs, "ConfigMap", "toolset-scheduling"):
        return "upgrade render is empty"
    found = [d["metadata"]["name"] for d in docs if d["kind"] == "ConfigMap"
             and "relay-access-grants" in (d["metadata"]["name"], (d["metadata"].get("labels") or {}).get("sycophant.md/type"))]
    return found and f"upgrade renders {found}"
check("relay-access-grants renders on install only, kept", ([], None), grants_install_only)

def harness_reaches_inference(docs):
    p = get(docs, "CiliumNetworkPolicy", "ws-one-egress")
    if p is None:
        return "ws-one-egress missing"
    eg = p["spec"].get("egress") or []
    warm = any(e.get("matchLabels") == {"app.kubernetes.io/component": "inference", "app.kubernetes.io/part-of": "sycophant"}
               for r in eg for e in r.get("toEndpoints") or [])
    dns = [n for r in eg for t in r.get("toPorts") or [] for n in (t.get("rules") or {}).get("dns") or []]
    want = [{"matchPattern": "inf-*.tenant-acme.svc.cluster.local"},
            {"matchPattern": "*.ws-one-capability.tenant-acme.svc.cluster.local"}]
    return None if warm and all(w in dns for w in want) else f"warm={warm} dns={dns}"
check("harness egress reaches the inference pods and resolves their Services", "wsbase", harness_reaches_inference)

def harness_dials_tool_pods(docs):
    p = get(docs, "CiliumNetworkPolicy", "ws-one-egress")
    if p is None:
        return "ws-one-egress missing"
    ingress = [r for r in p["spec"].get("ingress") or [] if 9090 in ports(r)]
    dials = any(9090 in ports(r) and any((e.get("matchLabels") or {}).get("app.kubernetes.io/component") == "capability-job"
                                         for e in r.get("toEndpoints") or [])
                for r in p["spec"].get("egress") or [])
    return None if not ingress and dials else f"ingress on 9090 {ingress}, egress to capability-job on 9090 {dials}"
check("harness admits no ingress on 9090 and dials capability-job pods on 9090", "wsbase", harness_dials_tool_pods)

def local_server(docs):
    want = ["CiliumNetworkPolicy/inf-local", "ConfigMap/inf-local", "Deployment/inf-local", "Service/inf-local"]
    if objects(docs) != want or not model_cm(docs, "local"):
        return f"want {want}, got {objects(docs)}"
    svc = get(docs, "Service", "inf-local")["spec"]
    labels = pod(get(docs, "Deployment", "inf-local"))["metadata"]["labels"]
    if svc.get("type") != "ClusterIP" or not selects(svc.get("selector"), labels):
        return f"Service {svc} does not select pod labels {labels}"
check("local command renders the model server and its model ConfigMap, no provider egress", "local", local_server)

check("remote command renders only its model ConfigMap and provider egress", "remote",
      lambda docs: None if objects(docs) == ["CiliumNetworkPolicy/inf-deepseek", "ConfigMap/inf-deepseek"]
      and (model_cm(docs, "deepseek") or {}).get("data") == remote
      else f"got {objects(docs)} {[d.get('data') for d in docs if d['kind'] == 'ConfigMap']}")

def toolset_cm(docs):
    if objects(docs) != ["ConfigMap/ts-git"]:
        return f"want only ConfigMap/ts-git, got {objects(docs)}"
    d = docs[0]
    labels = d["metadata"].get("labels") or {}
    if (labels.get("sycophant.md/type"), labels.get("app.kubernetes.io/name")) != ("toolset", "git"):
        return f"labels {labels}"
    return None if d.get("data") == toolset else f"data {d.get('data')}"
check("toolset command renders only its toolset ConfigMap carrying the command data", "toolset", toolset_cm)

def harness_env(docs):
    return {e["name"]: e.get("value") for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "ws-one"
            for c in pod(d)["spec"]["containers"] if c["name"] == "harness" for e in c.get("env") or []}

def command_env(docs):
    env = harness_env(docs)
    grants = json.loads(env.get("GRANTS") or "null")
    want = {k: v for k, v in workspace.items() if k.startswith("grant.")}
    got = (env.get("TOOLSETS"), env.get("MODELS"), grants)
    return None if got == ("git,ssh", "a,b", want) else f"TOOLSETS, MODELS, GRANTS {got}"
check("workspace command toolsets, models and grants reach its harness env", "workspace", command_env)

def no_stdlib_default(docs):
    env = harness_env(docs)
    cm = get(docs, "ConfigMap", "ws-one-capability-grants")
    if not get(docs, "Deployment", "ws-one") or env.get("TOOLSETS", "") != "" or cm is None or cm.get("data"):
        return f"TOOLSETS {env.get('TOOLSETS')!r}, ws-one-capability-grants {cm and cm.get('data')}"
check("a workspace command naming no toolsets lists none and approves no Secret", "wsbase", no_stdlib_default)

def command_grant_objects(docs):
    cm = get(docs, "ConfigMap", "ws-one-capability-grants") or {"metadata": {}}
    if (cm.get("data"), (cm["metadata"].get("labels") or {}).get("sycophant.md/type")) != ({"demo-key": "ssh"}, "capability-grants"):
        return f"ws-one-capability-grants {cm}"
    sel = {"sycophant.md/workspace": "one", "sycophant.md/toolset": "ssh", "sycophant.md/grant": "demo"}
    fqdns = [(p["metadata"]["name"], n.get("matchName")) for p in cnps(docs)
             if selects(sel, (p["spec"].get("endpointSelector") or {}).get("matchLabels") or {})
             for r in p["spec"].get("egress") or [] for n in r.get("toFQDNs") or []]
    if fqdns != [("ws-one-grant-ssh-demo", "github.com")]:
        return f"grant egress toFQDNs {fqdns}"
    relay = get(docs, "ConfigMap", "ws-one-relay-grants")
    names = yaml.safe_load(((relay or {}).get("data") or {}).get("grants.yaml") or "null")
    want = {"one": ["git", {"name": "ssh", "grants": {"demo": {}}}]}
    return None if names == want else f"ws-one-relay-grants {names}"
check("a workspace command grant renders its Secret approval, its egress and its relay grant name", "workspace", command_grant_objects)

def command_harness_storage(docs):
    d = get(docs, "Deployment", "ws-one")
    if d is None:
        return "Deployment/ws-one missing"
    sync = " ".join(a for c in pod(d)["spec"].get("initContainers") or [] if c["name"] == "instructions-sync"
                    for a in c.get("args") or [])
    pvc = get(docs, "PersistentVolumeClaim", "ws-one-data")
    size = (pvc or {}).get("spec", {}).get("resources", {}).get("requests", {}).get("storage")
    if "/tenant-acme/one\"" not in sync or size != "5Gi":
        return f"sync {sync!r}, ws-one-data {size}"
check("a workspace command syncs instructions from <namespace>/<workspace> and sizes its storage", "workspace", command_harness_storage)

WORKSPACE_OBJECTS = sorted([
    "CiliumNetworkPolicy/ws-one-egress", "CiliumNetworkPolicy/ws-one-grant-ssh-demo", "CiliumNetworkPolicy/ws-one-job-ingress",
    "ConfigMap/ws-one-capability-grants", "ConfigMap/ws-one-relay-grants", "Deployment/ws-one", "Job/ws-one-init",
    "PersistentVolumeClaim/ws-one-conversation", "PersistentVolumeClaim/ws-one-data", "Role/ws-one", "RoleBinding/ws-one",
    "Service/ws-one", "Service/ws-one-capability",
    "ServiceAccount/ws-one", "ServiceAccount/ws-one-init", "ServiceAccount/ws-one-unprivileged"])

def workspace_references(docs):
    if objects(docs) != WORKSPACE_OBJECTS:
        return f"want {WORKSPACE_OBJECTS}, got {objects(docs)}"
    harness, init = pod(get(docs, "Deployment", "ws-one"))["spec"], pod(get(docs, "Job", "ws-one-init"))["spec"]
    rb = get(docs, "RoleBinding", "ws-one")
    got = (harness.get("serviceAccountName"), init.get("serviceAccountName"),
           sorted(v["persistentVolumeClaim"]["claimName"] for s in (harness, init) for v in s.get("volumes") or [] if "persistentVolumeClaim" in v),
           rb["roleRef"]["name"], [s["name"] for s in rb.get("subjects") or []],
           {e["name"]: e.get("value") for c in harness["containers"] for e in c.get("env") or []}.get("CAPABILITY_SERVICE_NAME"))
    want = ("ws-one", "ws-one-init", ["ws-one-conversation", "ws-one-data"], "ws-one", ["ws-one"], "ws-one-capability")
    return None if got == want else f"want {want}, got {got}"
check("a workspace renders every object under its release name and references them by those names", "workspace", workspace_references)

def engine_caps(docs):
    d = get(docs, "Deployment", "inf-local")
    av = argv(d)
    got = {f: pair(av, f) for f in ("-m", "-c", "-np", "-t", "-n", "--sse-ping-interval")}
    want = {"-m": "/opt/m.gguf", "-c": "8192", "-np": "1", "-t": "2", "-n": "512", "--sse-ping-interval": "30"}
    limits = next(c for c in pod(d)["spec"]["containers"] if c["name"] == "server")["resources"]["limits"]
    if got != want or (limits.get("memory"), str(limits.get("cpu"))) != ("4Gi", "2") or "--no-context-shift" not in av:
        return f"argv {av} limits {limits}"
check("engine caps follow the command, context shift off and SSE ping pinned", "local-override", engine_caps)

FETCH = {"curl", "wget", "oras", "crane", "skopeo", "docker", "git",
         "-hf", "--hf-repo", "-mu", "--model-url", "-dr", "--docker-repo"}

def fetchers(spec):
    words = [w for c in spec.get("initContainers", []) + spec["containers"]
             for w in c.get("command", []) + c.get("args", [])]
    return [w for w in words if w.rsplit("/", 1)[-1] in FETCH]

def copy_delivery(docs):
    d = get(docs, "Deployment", "inf-local")
    spec = pod(d)["spec"]
    inits = spec.get("initContainers") or []
    server = next(c for c in spec["containers"] if c["name"] == "server")
    vols = {v["name"]: v for v in spec["volumes"]}
    if len(inits) != 1 or inits[0]["image"] != "ghcr.io/example/weights:1" or server["image"] != "llama-server:local":
        return f"want one copy step from the weight image beside the runtime image, got {inits} {server['image']}"
    cmd = inits[0]["command"]
    if cmd[0].rsplit("/", 1)[-1] in ("sh", "bash", "ash") or "-c" in cmd or "/weights/model.gguf" not in cmd:
        return f"copy step must be exec form reading the weights path, got {cmd}"
    scratch = [v for v in vols.values() if "emptyDir" in v]
    if not scratch or any(not v["emptyDir"].get("sizeLimit") or v["emptyDir"].get("medium") == "Memory" for v in scratch):
        return f"copy target must be a size-limited disk emptyDir, got {scratch}"
    if any("image" in v for v in vols.values()):
        return "copy delivery carries an image volume"
    if not all(m.get("readOnly") for m in server["volumeMounts"] if m["name"] == scratch[0]["name"]):
        return "server mounts the weight copy writable"
    return fetchers(spec) and f"fetches {fetchers(spec)}"
check("copy is the default weight delivery", "local", copy_delivery)

def mount_delivery(docs):
    spec = pod(get(docs, "Deployment", "inf-local"))["spec"]
    images = [v for v in spec["volumes"] if "image" in v]
    server = next(c for c in spec["containers"] if c["name"] == "server")
    if [v["image"]["reference"] for v in images] != ["ghcr.io/example/weights:1"]:
        return f"want one image volume of the weight image, got {images}"
    if spec.get("initContainers") or not any(m["name"] == images[0]["name"] for m in server["volumeMounts"]):
        return f"want the server mounting the image volume and no copy step, got {spec.get('initContainers')} {server['volumeMounts']}"
    return fetchers(spec) and f"fetches {fetchers(spec)}"
check("mount delivery uses an image volume and no copy step", "local-mount", mount_delivery)

def plumbing(out):
    docs = load(out)[0]
    spec = pod(get(docs, "Deployment", "inf-local"))["spec"]
    server = next(c for c in spec["containers"] if c["name"] == "server")
    av = argv(get(docs, "Deployment", "inf-local"))
    return (
        ((get(docs, "ConfigMap", "inf-local-chat-template") or {}).get("data") or {}).get("template"),
        [v for v in spec["volumes"] if v["name"] == "chat-template"],
        [m for m in server["volumeMounts"] if m["name"] == "chat-template"],
        pair(av, "--chat-template-file"),
    )

def chat_template(_):
    want = (
        "TEMPLATE-BODY\n",
        [{"name": "chat-template", "configMap": {"name": "inf-local-chat-template"}}],
        [{"name": "chat-template", "mountPath": "/etc/sycophant/chat-template/template", "subPath": "template", "readOnly": True}],
        "/etc/sycophant/chat-template/template",
    )
    got = {o: plumbing(o) for o in ("local-tpl-copy", "local-tpl-mount", "local")}
    if got != {"local-tpl-copy": want, "local-tpl-mount": want, "local": (None, [], [], None)}:
        return f"want {want} on both deliveries and nothing unset, got {got}"
check("chat template renders all four parts on both deliveries, none when unset", ([], None), chat_template)

def placement(out):
    spec = pod(get(load(out)[0], "Deployment", "inf-local"))["spec"]
    return spec.get("nodeSelector"), spec.get("tolerations")

def node_separation(_):
    default = placement("local")
    if default[0] != {"sycophant.md/workload": "inference"} \
            or placement("local-single-false") != default or placement("local-single-true") != (None, None):
        return f"default {default}, false {placement('local-single-false')}, true {placement('local-single-true')}"
    sched = yaml.safe_load(get(load("bare")[0], "ConfigMap", "toolset-scheduling")["data"]["scheduling.yaml"])
    values = [t.get("value") for t in sched["tolerations"]]
    return values != ["toolset"] and f"toolset pods tolerate {values}"
check("inference and toolset pods stay on separate nodes unless the exception is declared", ([], None), node_separation)

def headless_service(docs):
    for d in docs:
        spec = d.get("spec") or {}
        sel = spec.get("selector") or {}
        if d["kind"] == "Service" and spec.get("clusterIP") == "None" \
                and sel.get("app.kubernetes.io/component") == "capability-job" \
                and sel.get("sycophant.md/workspace") == "one" \
                and any(str(p.get("port")) == "9090" for p in spec.get("ports") or []):
            return None
    return "no headless Service selects workspace one's capability-job pods on 9090"
check("a headless Service addresses each workspace's capability-job pods on 9090", "wsbase", headless_service)

def tool_pod_ingress(docs):
    harness = {"app.kubernetes.io/component": "harness", "sycophant.md/workspace": "one"}
    for c in cnps(docs):
        sel = (c["spec"].get("endpointSelector") or {}).get("matchLabels") or {}
        if (sel.get("app.kubernetes.io/component"), sel.get("sycophant.md/workspace")) != ("capability-job", "one"):
            continue
        for rule in c["spec"].get("ingress") or []:
            if 9090 in ports(rule) and any(selects(harness, e.get("matchLabels") or {}) for e in rule.get("fromEndpoints") or []):
                return None
    return "no policy admits workspace one's harness to its capability-job pods on 9090"
check("capability-job pods admit their own workspace's harness on 9090", "wsbase", tool_pod_ingress)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
