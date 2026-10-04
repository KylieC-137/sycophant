#!/usr/bin/env bash
# Offline: renders the tenant chart's slices and checks what each one emits.
# No cluster.
#
#   bash tests/unit/tenant-chart/acceptance.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CHART="$ROOT/charts/sycophant-tenant"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOCAL='{"format":"openai","model":"liquid/lfm2.5-8b-a1b","server.image":"llama-server:local","server.weights":"ghcr.io/example/weights:1","server.weightsPath":"/weights/model.gguf"}'
REMOTE='{"format":"openai","model":"deepseek/deepseek-v4-flash","baseUrl":"https://openrouter.ai/api/v1","image":"inference-runtime:local","secret":"llm-openrouter"}'
CHANNEL=(--set headscale.enabled=true --set headscale.serverUrl=http://localhost:8080
  --set-json 'channels={"app":{"kind":"app","loginServer":"http://headscale:8080"}}')

render() {
  local out="$1"; shift
  helm template t "$CHART" -n tenant-acme --set namespace.create=false "$@" \
    > "$WORK/$out.yaml" 2> "$WORK/$out.err"
  echo $? > "$WORK/$out.rc"
}
render base "${CHANNEL[@]}" --set render=base
render channel "${CHANNEL[@]}" --set render=channel
render bare --set render=base
render local --set render=inference --set name=local --set-json "marker=$LOCAL"
render remote --set render=inference --set name=deepseek --set-json "marker=$REMOTE"
render models --set render=workspace --set-json 'workspaces={"one":{"models":["a","b"]}}'
render wsbase --set render=base --set-json 'workspaces={"one":{}}'
render upgrade --set render=base --is-upgrade
render channel-off --set render=channel
render acme "${CHANNEL[@]}" --set render=channel \
  --set headscale.acme.enabled=true --set headscale.acme.email=op@example.com
render bogus --set render=channel \
  --set-json 'channels={"app":{"kind":"carrier-pigeon","loginServer":"http://headscale:8080"}}'
for m in override:'{"server.weightsPath":"/opt/m.gguf","server.contextBudget":"8192","server.slots":"1","server.outputCap":"512","server.threads":"2","server.memory":"4Gi","server.cpu":"2"}' \
         mount:'{"server.weightsDelivery":"mount"}' \
         tpl-copy:'{"server.chatTemplate":"TEMPLATE-BODY"}' \
         tpl-mount:'{"server.weightsDelivery":"mount","server.chatTemplate":"TEMPLATE-BODY"}' \
         single-true:'{"server.singleNodeException":"true"}' \
         single-false:'{"server.singleNodeException":"false"}'; do
  render "local-${m%%:*}" --set render=inference --set name=local --set-json "marker=$(printf '%s' "$LOCAL" | jq -c ". + ${m#*:}")"
done

python3 - "$WORK" "$REMOTE" <<'PY'
import json, sys, yaml

work, remote = sys.argv[1], json.loads(sys.argv[2])
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
    why = fn(docs)
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
        if d["kind"] == "ConfigMap" and d["metadata"]["name"] == f"model-{key}" \
                and labels.get("sycophant.md/type") == "model" and labels.get("app.kubernetes.io/name") == key:
            return d
    return None

check("base renders no adapter or headscale object", "base",
      lambda docs: channel_objects(docs))

def base_no_inference(docs):
    hits = [f"{d['kind']}/{d['metadata']['name']}" for d in docs
            if "inference" in ((d["metadata"].get("labels") or {}).get("app.kubernetes.io/component"),
                               (d.get("spec") or {}).get("template", {}).get("metadata", {}).get("labels", {}).get("app.kubernetes.io/component"),
                               ((d.get("spec") or {}).get("endpointSelector") or {}).get("matchLabels", {}).get("app.kubernetes.io/component"))
            or d["metadata"]["name"].startswith(("inference-", "model-"))]
    return hits
check("base renders no inference object", "base", base_no_inference)

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

check("a channel render with no channels renders no adapter", "channel-off",
      lambda docs: [f"{d['kind']}/{d['metadata']['name']}" for d in docs
                    for labels in ((d["metadata"].get("labels") or {}),
                                   (d.get("spec") or {}).get("template", {}).get("metadata", {}).get("labels") or {})
                    if labels.get("app.kubernetes.io/component") == "adapter"
                    or "sycophant.md/adapter-class" in labels])

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
wsbase, err1 = load("wsbase")
channel, err2 = load("channel")
check("every relay listener is published, admitted and dialed",
      (wsbase + channel, None) if wsbase is not None and channel is not None else (None, err1 or err2),
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
    every = [p for out in ("base", "channel", "bare", "wsbase") for p in load(out)[0]
             if p["kind"] in ("CiliumNetworkPolicy", "NetworkPolicy")]
    keyed = [p["metadata"]["name"] for p in every if "sycophant.md/channel" in json.dumps(p["spec"])]
    return keyed and f"policies keyed on the channel label: {keyed}"
check("app adapter is transport class and policies key on the class", "channel", adapter_class)

def unknown_kind(_):
    err = open(f"{work}/bogus.err").read()
    if load("bogus")[0] is not None or "kind" not in err:
        return f"want a failed render naming the kind, got {err!r}"
check("unknown channel kind fails the render", ([], None), unknown_kind)

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
    got = {o: hosts(o) for o in ("channel", "acme", "channel-off")}
    want = {"channel": ("headscale", [cp], [cp]),
            "acme": ("headscale", [acme, cp], [acme, cp]),
            "channel-off": None}
    return None if got == want else f"want {want}, got {got}"
check("headscale egress reaches only its control endpoints", ([], None), headscale)

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
    p = get(docs, "CiliumNetworkPolicy", "harness-egress-one")
    if p is None:
        return "harness-egress-one missing"
    eg = p["spec"].get("egress") or []
    warm = any(e.get("matchLabels") == {"app.kubernetes.io/component": "inference", "app.kubernetes.io/part-of": "sycophant"}
               for r in eg for e in r.get("toEndpoints") or [])
    dns = [n for r in eg for t in r.get("toPorts") or [] for n in (t.get("rules") or {}).get("dns") or []]
    want = {"matchPattern": "inference-*.tenant-acme.svc.cluster.local"}
    return None if warm and want in dns else f"warm={warm} dns={dns}"
check("harness egress reaches the inference pods and resolves their Services", "wsbase", harness_reaches_inference)

def local_server(docs):
    want = ["CiliumNetworkPolicy/inference-local", "ConfigMap/model-local", "Deployment/inference-local", "Service/inference-local"]
    if objects(docs) != want or not model_cm(docs, "local"):
        return f"want {want}, got {objects(docs)}"
    svc = get(docs, "Service", "inference-local")["spec"]
    labels = pod(get(docs, "Deployment", "inference-local"))["metadata"]["labels"]
    if svc.get("type") != "ClusterIP" or not selects(svc.get("selector"), labels):
        return f"Service {svc} does not select pod labels {labels}"
check("local marker renders the model server and its model ConfigMap, no provider egress", "local", local_server)

check("remote marker renders only its model ConfigMap and provider egress", "remote",
      lambda docs: None if objects(docs) == ["CiliumNetworkPolicy/inference-egress-deepseek", "ConfigMap/model-deepseek"]
      and (model_cm(docs, "deepseek") or {}).get("data") == remote
      else f"got {objects(docs)} {[d.get('data') for d in docs if d['kind'] == 'ConfigMap']}")

def models_env(docs):
    env = [e for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "one"
           for c in pod(d)["spec"]["containers"] for e in c.get("env") or [] if e["name"] == "MODELS"]
    return None if env and env[0].get("value") == "a,b" else f"MODELS env {env}"
check("workspace models reach its harness as MODELS", "models", models_env)

def engine_caps(docs):
    d = get(docs, "Deployment", "inference-local")
    av = argv(d)
    got = {f: pair(av, f) for f in ("-m", "-c", "-np", "-t", "-n", "--sse-ping-interval")}
    want = {"-m": "/opt/m.gguf", "-c": "8192", "-np": "1", "-t": "2", "-n": "512", "--sse-ping-interval": "30"}
    limits = next(c for c in pod(d)["spec"]["containers"] if c["name"] == "server")["resources"]["limits"]
    if got != want or (limits.get("memory"), str(limits.get("cpu"))) != ("4Gi", "2") or "--no-context-shift" not in av:
        return f"argv {av} limits {limits}"
check("engine caps follow the marker, context shift off and SSE ping pinned", "local-override", engine_caps)

FETCH = {"curl", "wget", "oras", "crane", "skopeo", "docker", "git",
         "-hf", "--hf-repo", "-mu", "--model-url", "-dr", "--docker-repo"}

def fetchers(spec):
    words = [w for c in spec.get("initContainers", []) + spec["containers"]
             for w in c.get("command", []) + c.get("args", [])]
    return [w for w in words if w.rsplit("/", 1)[-1] in FETCH]

def copy_delivery(docs):
    d = get(docs, "Deployment", "inference-local")
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
    spec = pod(get(docs, "Deployment", "inference-local"))["spec"]
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
    spec = pod(get(docs, "Deployment", "inference-local"))["spec"]
    server = next(c for c in spec["containers"] if c["name"] == "server")
    av = argv(get(docs, "Deployment", "inference-local"))
    return (
        ((get(docs, "ConfigMap", "inference-local-chat-template") or {}).get("data") or {}).get("template"),
        [v for v in spec["volumes"] if v["name"] == "chat-template"],
        [m for m in server["volumeMounts"] if m["name"] == "chat-template"],
        pair(av, "--chat-template-file"),
    )

def chat_template(_):
    want = (
        "TEMPLATE-BODY\n",
        [{"name": "chat-template", "configMap": {"name": "inference-local-chat-template"}}],
        [{"name": "chat-template", "mountPath": "/etc/sycophant/chat-template/template", "subPath": "template", "readOnly": True}],
        "/etc/sycophant/chat-template/template",
    )
    got = {o: plumbing(o) for o in ("local-tpl-copy", "local-tpl-mount", "local")}
    if got != {"local-tpl-copy": want, "local-tpl-mount": want, "local": (None, [], [], None)}:
        return f"want {want} on both deliveries and nothing unset, got {got}"
check("chat template renders all four parts on both deliveries, none when unset", ([], None), chat_template)

def placement(out):
    spec = pod(get(load(out)[0], "Deployment", "inference-local"))["spec"]
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

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
