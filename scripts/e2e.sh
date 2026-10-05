#!/usr/bin/env bash
# Single-command end-to-end test for sycophant.
#
# Deploys the Helm charts (in-cluster headscale plus the app-channel adapter),
# launches the Flutter client, and runs the Step 6 security assertions. Pauses
# for the operator at the Flutter UI step.
#
# By default reuses an existing k3d cluster and its loaded images, running only
# the phases that prove the cluster works. Pass --clean to delete+recreate the
# cluster and rebuild + load all images from scratch. With no cluster present,
# the first run bootstraps once regardless of --clean.
#
# The app channel's terminus is its own adapter Deployment, so the run
# stands up headscale, mints a pre-auth key into the adapter's authKey
# Secret, and asserts the adapter reaches Available under gVisor.
#
# Usage:
#   scripts/e2e.sh [--clean]   (--clean = fresh cluster + full image rebuild)
#
# Required env:
#   OPENROUTER_API_KEY
# Optional env:
#   CLUSTER_NAME (default sycophant),
#   ARCH (default aarch64), DOCKER_ARCH (default arm64), and the SYCO_* inputs
#   `syco setup` and the tenant commands read (see "syco inputs" below). syco's
#   config root is SYCO_CONFIG_DIR (default tmp/syco-config), never ~/.config.
#
# The bootstrap is `syco setup`, the main tenant is provisioned with `syco
# tenant up`, and the lifecycle proof drives `syco tenant up/down/remove`. A
# cluster without the Dex operator login needs one run with --clean.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CLUSTER_NAME="${CLUSTER_NAME:-sycophant}"
# The main tenant, as examples/tenants/e2e-test.yaml names it.
NAMESPACE="tenant-e2e-test"
ARCH="${ARCH:-aarch64}"
DOCKER_ARCH="${DOCKER_ARCH:-arm64}"
RUST_TARGET="${ARCH}-unknown-linux-musl"

# ---- flags ----
# --clean forces a fresh cluster + full image rebuild. Default reuses an
# existing cluster and its loaded images, running only the deploy + verify +
# security phases that prove the cluster works. With no cluster present, the
# first run bootstraps once regardless.
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    -h|--help)
      printf 'Usage: %s [--clean]\n  (default) reuse the existing cluster + images; run deploy/verify/security\n  --clean   delete+recreate the cluster and rebuild + load all images\n' "$(basename "$0")"
      exit 0 ;;
    *) printf 'unknown argument: %s (see --help)\n' "$arg" >&2; exit 1 ;;
  esac
done
# The operator invents the grant row's identity and hands it over out of
# band. The relay mints nothing, so this string is the whole proof.
# The producer is bounded, not the consumer: `tr </dev/urandom | head -c 16`
# hands `tr` a SIGPIPE the moment `head` has its 16 bytes, and under
# `pipefail` that aborts the script at line 1.
GRANT_CODE="e2e-$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | cut -c1-16)"
HEADSCALE_USER="e2e"
# The client reaches the relay through the app adapter's tailnet node, at the
# adapter's MagicDNS hostname. Nothing dials the relay's app port directly.
TAILNET_RELAY_ADDR="relay:9090"
ADAPTER_AUTHKEY_SECRET="relay-tsnet-authkey"
# Object-storage instructions delivery. The store lives in the system namespace
# and its operator credential never leaves it; the e2e host reaches it over
# `kubectl port-forward` and mints each harness a read-only, prefix-scoped one.
INSTRUCTIONS_BUCKET="sycophant-instructions"
INSTRUCTIONS_CREDENTIAL_NAME="instructions-reader"
INSTRUCTIONS_READ_ACCESS="e2e-instructions-reader"
INSTRUCTIONS_READ_SECRET="e2e-instructions-reader-secret"
S3_PF_PORT=9900
# SeaweedFS server image (Alpine, multi-arch), pinned by index digest to match
# the chart default. SEAWEEDFS_IMAGE is imported + installed by
# install_object_store. RCLONE_IMAGE (the harness sync client, a neutral S3
# client run against the SeaweedFS s3 gateway) is a tenant workload image loaded
# in step_1_build. Both are multi-arch indexes: export one arch to a tar to
# import.
SEAWEEDFS_IMAGE="chrislusf/seaweedfs@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882"
RCLONE_IMAGE="rclone/rclone:1.75.1"
# Marker the macOS tailnet join writes immediately before its sudo prompt and
# removes once the join returns. An external monitor watches this path to alert
# the operator that a password entry is imminent (the run is otherwise headless
# until Step 5).
SUDO_PENDING_SENTINEL="/tmp/sycophant-e2e-sudo-pending"
# The in-cluster inference model key, examples/inference/local.yaml. Its
# `server` block makes the chart render the llama.cpp Deployment, its Service and
# its ingress fence (CNP inference-<key>). Every local model serves on the fixed
# port 8080.
INFERENCE_PROFILE="local"
INFERENCE_PORT="8080"
# The remote model the hello-world workspace also lists, reached through a
# per-call inference job holding the vendor key:
# examples/inference/deepseek-v4-flash.yaml.
REMOTE_MODEL="deepseek-v4-flash"
# Client choice. Prompt when unset + interactive (the "confirm during install"
# step); honor the env var otherwise so CI/agents run non-interactively.
# none = backend-only: skip the local Flutter client and connect one remotely.
if [ -z "${FLUTTER_TARGET:-}" ]; then
  if [ -t 0 ]; then
    printf 'Install a Flutter client? [macos/none] (none = backend-only): ' >&2
    read -r FLUTTER_TARGET
    FLUTTER_TARGET="${FLUTTER_TARGET:-none}"
  else
    FLUTTER_TARGET="macos"
  fi
fi
case "$FLUTTER_TARGET" in
  macos)   CLIENT_NAME_DEFAULT="caleb-macbook" ;;
  none)    CLIENT_NAME_DEFAULT="remote-client" ;;
  *) printf 'unknown FLUTTER_TARGET: %s (expected macos|none)\n' "$FLUTTER_TARGET" >&2; exit 1 ;;
esac
CLIENT_NAME="${CLIENT_NAME:-$CLIENT_NAME_DEFAULT}"

: "${OPENROUTER_API_KEY:?must be set}"

# ---- ui helpers ----
step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m ⚠\033[0m %s\n' "$*" >&2; }
pause() {
  local marker="/tmp/sycophant-e2e-continue"
  rm -f "$marker"
  printf '\n\033[1;33m🛑 %s\033[0m\n' "$1"
  printf '   When done, run: \033[1mtouch %s\033[0m\n' "$marker"
  until [ -f "$marker" ]; do sleep 2; done
  rm -f "$marker"
}

# wait_for <description> <timeout-seconds> <shell-condition>
# Polls the condition every 2 s until it succeeds OR the timeout expires.
# Returns non-zero on timeout, with a `warn` log. Use this instead of an
# unbounded `until ... ; do sleep N; done` so hangs surface as failures.
wait_for() {
  local desc="$1"; local timeout="$2"; shift 2
  local deadline=$(( $(date +%s) + timeout ))
  while ! eval "$*"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      warn "timeout after ${timeout}s waiting for: ${desc}"
      return 1
    fi
    sleep 2
  done
}

# Release $1 has a deployed record in namespace $2. The provision command
# installers keep helm's release records in ConfigMaps labelled owner=helm,
# name, and status, so this reads the record without running helm against the
# tenant.
release_deployed() {
  local out
  out="$(kubectl get configmap -n "$2" -l "owner=helm,name=$1,status=deployed" -o name 2>/dev/null)" || true
  [ -n "$out" ]
}

# ---- background cleanup (port-forwards, flutter run) ----
declare -a CLEANUP_PIDS=()
# Set once the headscale forward is up. The cluster outlives the script but
# the forward does not, so a client still driving the app loses the tailnet
# the moment we exit — say how to get it back.
HEADSCALE_FORWARD_STARTED=""
cleanup() {
  local pid
  for pid in "${CLEANUP_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  if [ -n "$HEADSCALE_FORWARD_STARTED" ]; then
    printf '\nThe headscale port-forward stopped with this script. To keep using\n' >&2
    printf 'the app against the running cluster, restore it with:\n' >&2
    printf '  kubectl port-forward -n %s svc/headscale 8080:8080\n' "$NAMESPACE" >&2
  fi
}
trap cleanup EXIT

# Defensive: kill leftover sycophant processes from prior runs (leaked
# cargo test binaries, abandoned kubectl port-forwards, respawn loops).
"$REPO_ROOT/scripts/kill-orphans.sh"

# Generate the second, non-Dex JWT issuer the apiserver trusts beside the Dex
# issuer `syco setup` renders, so the lifecycle proof can admit a command written
# by an identity Dex never signed. Generates the issuer's self-signed TLS cert
# (the CA the apiserver trusts when it fetches the issuer's JWKS) and an RSA
# signing keypair (its public half the runtime fixture publishes, its private
# half mints the caller token offline), and writes the jwt: list entry `syco
# setup` appends to its rendered auth config before the node boots
# (SYCO_AUTH_CONFIG_APPEND). Its username prefix matches the Dex issuer's, so
# its tokens land in the trusted subject namespace.
gen_second_issuer_trust() {
  local d="$APISERVER_OIDC_DIR"
  rm -rf "$d"; mkdir -p "$d"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$d/oidc2-tls.key" -out "$d/oidc2-tls.crt" -days 90 \
    -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1
  openssl genrsa -out "$d/oidc2-sign.key" 2048 >/dev/null 2>&1
  openssl rsa -in "$d/oidc2-sign.key" -pubout -out "$d/oidc2-sign.pub" >/dev/null 2>&1

  {
    printf '  - issuer:\n'
    printf '      url: "%s"\n' "$APISERVER_OIDC2_ISSUER"
    printf '      audiences:\n'
    printf '        - "%s"\n' "$APISERVER_OIDC2_AUDIENCE"
    printf '      certificateAuthority: |\n'
    sed 's/^/        /' "$d/oidc2-tls.crt"
    printf '    claimMappings:\n'
    printf '      username:\n'
    printf '        claim: sub\n'
    printf '        prefix: "%s#"\n' "$APISERVER_OIDC_ISSUER"
    printf '    claimValidationRules:\n'
    printf "      - expression: '!claims.sub.startsWith(\"system:\")'\n"
    printf "        message: 'sub must not use the reserved system: prefix'\n"
  } > "$SYCO_AUTH_CONFIG_APPEND"
}

# ---- step 0: bootstrap ----
# `syco setup` does the operator's bootstrap: k3d cluster, gVisor, Cilium,
# CoreDNS registry wiring, Kyverno, the cluster chart, and Dex with the operator
# as its one password user. The SYCO_* inputs set above add e2e's audit policy,
# relay port, second issuer, Kyverno and reap tuning, and skip its image build
# (step 1 builds the full e2e set).
step_0_bootstrap() {
  step "Step 0: Bootstrap cluster (syco setup)"

  # The apiserver reads its OIDC trust config at process start, so the second
  # issuer is generated before the node boots.
  gen_second_issuer_trust

  k3d cluster delete "$CLUSTER_NAME" 2>/dev/null || true
  rm -f "$SYCO_PASSWORD_FILE"
  syco_credentials

  "$SYCO" setup
  ok "syco setup: cluster, gVisor, Cilium, Kyverno, cluster chart, Dex"
  assert_registry_dns
  smoke_gvisor
  install_object_store
}

# Tool job pods pull their toolset images from the in-cluster
# `sycophant-registry` container, which `syco setup` maps into CoreDNS
# NodeHosts. The Corefile reloads NodeHosts on its own (up to ~60s), so gate on
# the actual resolution from a workload pod, non-fatally: without it the
# hostname is NXDOMAIN and Step 6 can't run any toolset tool.
assert_registry_dns() {
  step "Step 0.2: CoreDNS resolves sycophant-registry"
  local registry_ip
  registry_ip="$(docker inspect sycophant-registry --format '{{ (index .NetworkSettings.Networks "k3d-'"$CLUSTER_NAME"'").IPAddress }}')"
  if [ -z "$registry_ip" ]; then
    warn "could not resolve sycophant-registry IP on k3d-${CLUSTER_NAME} network"
    return 1
  fi
  local dns_deadline=$((SECONDS + 120))
  while (( SECONDS < dns_deadline )); do
    if kubectl run "dns-probe-$$" --rm -i --restart=Never --image=busybox:1.36 \
         --quiet --timeout=10s -- nslookup sycophant-registry >/dev/null 2>&1; then
      ok "CoreDNS resolves sycophant-registry -> ${registry_ip}"
      return 0
    fi
    sleep 2
  done
  warn "sycophant-registry did not resolve from a workload pod within 120s (continuing; image pulls will retry)"
}

smoke_gvisor() {
  step "Step 0.5: gVisor smoke test"
  kubectl delete pod gvisor-smoke --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl run gvisor-smoke --restart=Never \
    --overrides='{"spec":{"runtimeClassName":"gvisor"}}' \
    --image=busybox:stable --command -- dmesg >/dev/null
  kubectl wait pod/gvisor-smoke --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s >/dev/null
  if wait_for "'Starting gVisor' in gvisor-smoke logs" 10 \
       "kubectl logs pod/gvisor-smoke 2>/dev/null | grep -q 'Starting gVisor'"; then
    ok "gVisor sandbox boots"
  else
    warn "gVisor first dmesg line did NOT match 'Starting gVisor'"
    kubectl logs pod/gvisor-smoke | head -3
    return 1
  fi
  kubectl delete pod gvisor-smoke --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
}

# Install the shared object store as a core cluster component (same tier as
# cilium/kyverno/gvisor): pull + import the SeaweedFS server image inline
# (multi-arch index, so export one arch to a tar), then `helm upgrade --install`
# the chart into the operator-owned system namespace.
# The chart generates the admin credential into that namespace and never copies
# it to a tenant. Must run after Cilium so the CiliumNetworkPolicy CRD exists
# and the store pod can get an IP.
install_object_store() {
  step "Step 0.8: Object store (shared SeaweedFS)"
  docker pull -q --platform "linux/${DOCKER_ARCH}" "$SEAWEEDFS_IMAGE" >/dev/null
  docker tag "$SEAWEEDFS_IMAGE" seaweedfs:local
  local tar; tar="$(mktemp -t seaweedfs.XXXXXX).tar"
  docker image save --platform "linux/${DOCKER_ARCH}" -o "$tar" seaweedfs:local
  k3d image import "$tar" --cluster "$CLUSTER_NAME" >/dev/null
  rm -f "$tar"
  # Create the PSA-restricted system namespace first (helm --create-namespace
  # would land it bare). Same manifest `syco setup` applies; idempotent.
  kubectl apply -f "$REPO_ROOT/charts/sycophant-cluster/system-ns.yaml" >/dev/null
  helm upgrade --install sycophant-objectstore "$REPO_ROOT/charts/sycophant-objectstore" \
    -n sycophant-system \
    --set-string image=seaweedfs:local \
    --set-string pullPolicy=Never \
    --wait >/dev/null
  ok "Object store ready"
}

# ---- step 1: build images ----
step_1_build() {
  step "Step 1: Build images"
  cd "$REPO_ROOT"

  cargo build --release --target "$RUST_TARGET" \
    -p inference-runtime \
    -p toolset-runtime \
    -p harness -p relay-controller

  local bin
  for bin in toolset-runtime relay-controller inference-runtime; do
    cp "target/$RUST_TARGET/release/$bin" "${bin}-linux-musl-${DOCKER_ARCH}"
    docker build -q -f build/Dockerfile \
      --build-arg "BINARY=$bin" --build-arg "TARGETARCH=$DOCKER_ARCH" \
      -t "${bin}:local" . >/dev/null
    rm "${bin}-linux-musl-${DOCKER_ARCH}"
  done

  # The one toolset base image: its entrypoint is the toolset runtime. Every
  # toolset image below builds FROM it.
  cp "target/$RUST_TARGET/release/toolset-runtime" "images/toolset-base/toolset-runtime-linux-${DOCKER_ARCH}"
  docker build -q --build-arg "TARGETARCH=$DOCKER_ARCH" -f images/toolset-base/Dockerfile images/toolset-base/ -t toolset-base:local >/dev/null
  rm "images/toolset-base/toolset-runtime-linux-${DOCKER_ARCH}"

  cp "target/$RUST_TARGET/release/harness" "harness-linux-musl-${DOCKER_ARCH}"
  docker build -q -f build/Dockerfile \
    --build-arg BINARY=harness --build-arg "TARGETARCH=$DOCKER_ARCH" \
    -t sycophant-harness:local . >/dev/null
  rm "harness-linux-musl-${DOCKER_ARCH}"

  # Each toolset image carries its tools.yaml, as one-line JSON, in the
  # md.sycophant.tools label; its toolset provision command is built from that
  # label. Every value must already be a string. A non-string aborts the build.
  local ctx tag label
  for ctx in images/toolset:toolset images/git:toolset-git examples/toolsets/ssh-credentials:toolset-ssh-credentials; do
    tag="${ctx#*:}"; ctx="${ctx%%:*}"
    label=$(python3 -c 'import json,sys,yaml; m=yaml.safe_load(open(sys.argv[1])); assert all(isinstance(v,str) for v in m.values()), "non-string value in "+sys.argv[1]; print(json.dumps(m,separators=(",",":")))' "$ctx/tools.yaml")
    docker build -q --build-arg "BASE_IMAGE=toolset-base:local" \
      --label "md.sycophant.tools=$label" \
      -f "$ctx/Dockerfile" "$ctx/" -t "$tag:local" >/dev/null
  done

  docker build -q --build-arg "TARGETARCH=$DOCKER_ARCH" images/kubectl/ -t sycophant-kubectl:local >/dev/null

  # provisioner bakes the tenant chart, so its build context is the repo root.
  docker build -q --build-arg "TARGETARCH=$DOCKER_ARCH" -f images/provisioner/Dockerfile "$REPO_ROOT" -t sycophant-provisioner:local >/dev/null

  # llama-server is a third-party engine: pulled by digest from trusted upstream,
  # never built here. --platform pins one arch so k3d import gets a single-arch
  # manifest, not a multi-arch index with absent per-platform blobs.
  # Operator places this GGUF here; source: https://huggingface.co/bartowski/MiniCPM5-2B-GGUF (MiniCPM5-2B-Q4_K_M.gguf)
  local GGUF_PATH="${GGUF_PATH:-${HOME}/.cache/sycophant/weights/MiniCPM5-2B-Q4_K_M.gguf}"
  # The inference container limit must clear the mmap'd model plus its KV cache
  # and runtime, or llama.cpp OOMKills mid-load (exit 137). The model default
  # lives here; the limit is server.memory in examples/inference/local.yaml.
  # The two must move together -- assert it now so a model bump that forgets the
  # limit fails at preflight, not fifteen minutes into the run.
  if [ ! -f "$GGUF_PATH" ]; then
    printf '\n\033[1;31m✗ inference model GGUF not found: %s\033[0m\n' "$GGUF_PATH" >&2
    exit 1
  fi
  local model_mib floor_mib memory_mib
  model_mib=$(( $(wc -c < "$GGUF_PATH") / 1024 / 1024 ))
  floor_mib=$(( model_mib * 14 / 10 ))
  memory_mib="$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["inference"]["server"]["memory"])' \
    "$REPO_ROOT/examples/inference/local.yaml")"
  memory_mib="${memory_mib%Mi}"
  if [ "$memory_mib" -lt "$floor_mib" ]; then
    printf '\n\033[1;31m✗ server.memory (%dMiB) is below the floor for %s (%dMiB on disk).\n   llama.cpp mmaps the model + KV + runtime; set server.memory >= %dMi (model x 1.4) in examples/inference/local.yaml.\033[0m\n' \
      "$memory_mib" "$(basename "$GGUF_PATH")" "$model_mib" "$floor_mib" >&2
    exit 1
  fi
  local LLAMA_SERVER_REF="${LLAMA_SERVER_REF:-ghcr.io/ggml-org/llama.cpp:server@sha256:9f84380be42d6285a827629c809387349c3541aa8986f7536547ca33cc8dd47a}"
  docker pull -q --platform "linux/${DOCKER_ARCH}" "$LLAMA_SERVER_REF" >/dev/null
  docker tag "$LLAMA_SERVER_REF" llama-server:local
  docker build -q -f build/weights.Dockerfile \
    --build-arg "GGUF=$(basename "$GGUF_PATH")" \
    --build-arg "WEIGHTS_PATH=/weights/model.gguf" \
    -t weights:local "$(dirname "$GGUF_PATH")" >/dev/null

  step "Loading images into k3d + pushing toolsets to registry"
  local img
  # toolset-git:local is the workspace-init image the chart defaults to
  # (pullPolicy Never), so it is imported rather than pulled.
  for img in inference-runtime:local \
             sycophant-harness:local relay-controller:local \
             sycophant-kubectl:local sycophant-provisioner:local \
             weights:local toolset-git:local; do
    k3d image import "$img" --cluster "$CLUSTER_NAME" >/dev/null
  done
  # llama-server is a multi-arch index under the containerd store; a plain import
  # saves manifests for absent platforms and fails. Export one arch to a tarball.
  local llama_tar; llama_tar="$(mktemp -t llama-server.XXXXXX).tar"
  docker image save --platform "linux/${DOCKER_ARCH}" -o "$llama_tar" llama-server:local
  k3d image import "$llama_tar" --cluster "$CLUSTER_NAME" >/dev/null
  rm -f "$llama_tar"

  # The harness instructions-sync init container's client (rclone, a neutral S3
  # client). A tenant-workload image pulled from Docker Hub, not a built artifact,
  # imported under the chart's default reference. Multi-arch index, so export one
  # arch to a tar (a plain import saves manifests for absent platforms and
  # fails). The SeaweedFS server image is handled separately by
  # install_object_store.
  docker pull -q --platform "linux/${DOCKER_ARCH}" "$RCLONE_IMAGE" >/dev/null
  local rclone_tar; rclone_tar="$(mktemp -t rclone.XXXXXX).tar"
  docker image save --platform "linux/${DOCKER_ARCH}" -o "$rclone_tar" "$RCLONE_IMAGE"
  k3d image import "$rclone_tar" --cluster "$CLUSTER_NAME" >/dev/null
  rm -f "$rclone_tar"

  # Toolset images go through the local registry (sycophant-registry:5000
  # in-cluster) so the tool job pods can pull them. The stdlib toolset rides
  # the same path.
  for img in toolset toolset-git toolset-ssh-credentials; do
    docker tag "${img}:local" "localhost:5555/${img}:latest"
    docker push -q "localhost:5555/${img}:latest" >/dev/null
  done
  ok "Images built + loaded"
}

# Upload one workspace's instructions tree to the shared store and mint its read-only,
# prefix-scoped sync credential: create the bucket, sync the tree with aws-cli,
# then add a read-only S3 identity scoped to the <ns>/<workspace> prefix through
# weed shell, and write the access/secret into the tenant's credentialName Secret.
# $1 = workspace name; $2 = target namespace (default $NAMESPACE). The tree is
# the simple example with `model:` pinned to the in-cluster inference profile.
provision_instructions_content() {
  local workspace="$1" target_ns="${2:-$NAMESPACE}"
  step "Uploading instructions + minting read-only sync credential (${workspace} -> ${target_ns})"

  local instructions_src; instructions_src="$(mktemp -d)"
  cp "$REPO_ROOT/examples/instructions/simple/AGENTS.md" "$instructions_src/AGENTS.md"
  cp -r "$REPO_ROOT/examples/instructions/simple/agents" "$instructions_src/agents"
  sed "s/^model:.*/model: ${INFERENCE_PROFILE}/" "$instructions_src/AGENTS.md" > "$instructions_src/AGENTS.md.tmp" \
    && mv "$instructions_src/AGENTS.md.tmp" "$instructions_src/AGENTS.md"

  # One reader identity per namespace: s3.configure -apply rewrites the named
  # identity's actions, so each namespace needs its own name or it clobbers another
  # tenant's prefix scope. Value is throwaway test creds, keyed by namespace.
  local read_access="${INSTRUCTIONS_READ_ACCESS}-${target_ns}"
  local read_secret="${INSTRUCTIONS_READ_SECRET}-${target_ns}"

  # Upload over a port-forward with the host's aws-cli; mint the reader with
  # `weed shell` inside the store pod (SeaweedFS ships no mc).

  # The admin credential lives only in the system namespace; read it from the
  # store's Secret rather than holding it in this script.
  local admin_access admin_secret
  admin_access="$(kubectl get secret seaweedfs-admin -n sycophant-system -o jsonpath='{.data.access-key}' | base64 -d)"
  admin_secret="$(kubectl get secret seaweedfs-admin -n sycophant-system -o jsonpath='{.data.secret-key}' | base64 -d)"

  kubectl port-forward -n sycophant-system "svc/seaweedfs" "${S3_PF_PORT}:8333" >/dev/null 2>&1 &
  local pf_pid=$!
  trap 'kill '"$pf_pid"' 2>/dev/null || true' RETURN

  local url="http://127.0.0.1:${S3_PF_PORT}"
  wait_for "store API reachable" 60 \
    "AWS_ACCESS_KEY_ID='$admin_access' AWS_SECRET_ACCESS_KEY='$admin_secret' aws s3 ls --endpoint-url '$url' >/dev/null 2>&1"

  local prefix="${target_ns}/${workspace}"
  AWS_ACCESS_KEY_ID="$admin_access" AWS_SECRET_ACCESS_KEY="$admin_secret" \
    aws s3 mb "s3://${INSTRUCTIONS_BUCKET}" --endpoint-url "$url" >/dev/null 2>&1 || true
  AWS_ACCESS_KEY_ID="$admin_access" AWS_SECRET_ACCESS_KEY="$admin_secret" \
    aws s3 sync "$instructions_src" "s3://${INSTRUCTIONS_BUCKET}/${prefix}" --endpoint-url "$url" --delete >/dev/null
  rm -rf "$instructions_src"

  # Mint the read-only, prefix-scoped reader with weed shell inside the store
  # pod: a static S3 identity scoped to this <ns>/<workspace> prefix. rclone sync
  # first stats the bare prefix key (a HeadObject on <prefix> with no trailing
  # slash), then lists, then downloads, so the reader needs List and Read that
  # cover the bare key too (SeaweedFS Read does not imply ListBucket). Both
  # actions end in a bare "*" (no slash): SeaweedFS 4.47 authorizes the stat with
  # target "Read:bucket/<prefix>", and a slash-star glob "bucket/<prefix>/*"
  # requires a literal "/" after the prefix, so it misses the bare key and the
  # stat 403s. The "*" glob crosses "/" and matches the empty suffix, so one
  # entry covers the bare key, the list (target "List:bucket/<prefix>/"), and
  # every child object. A non-wildcard entry is inert here: 4.47 compares it only
  # to "Verb:bucket" with the path discarded, so it cannot scope to a prefix. The
  # tradeoff of the bare "*" is that it also matches a sibling prefix sharing the
  # string; that is the only prefix-scoped form CanDo can express. The reader
  # Secret shape (access-key / secret-key) stays unchanged so the tenant Secret
  # contract is stable.
  kubectl exec -i -n sycophant-system deploy/seaweedfs -- weed shell >/dev/null <<EOF
s3.configure -user ${read_access} -access_key ${read_access} -secret_key ${read_secret} -actions Read:${INSTRUCTIONS_BUCKET}/${prefix}*,List:${INSTRUCTIONS_BUCKET}/${prefix}* -apply
EOF

  kubectl create secret generic "$INSTRUCTIONS_CREDENTIAL_NAME" -n "$target_ns" \
    --from-literal=access-key="$read_access" \
    --from-literal=secret-key="$read_secret" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "Instructions uploaded to ${INSTRUCTIONS_BUCKET}/${prefix}; read credential ${INSTRUCTIONS_CREDENTIAL_NAME} minted"
}

# Render the $1 template (for example workspace-provision) of the commands chart
# with the rest of the arguments, the same render `syco <kind> up` runs: `-f`
# files, then `--set` values as strings.
render_command() {
  local template="$1"; shift
  helm template c "$REPO_ROOT/charts/sycophant-commands" --show-only "templates/${template}.yaml" \
    "${@/#--set/--set-string}"
}

# Write the image override for toolset $1 from local image $2: `image` is the
# in-cluster registry digest and `tools` the image's md.sycophant.tools label.
# The host rewrite (localhost:5555 to sycophant-registry:5000) swaps the
# push-facing host for the name the CoreDNS NodeHosts entry `syco setup` adds
# resolves; the digest is identical either way.
write_toolset_image() {
  local image="localhost:5555/$2:latest" ref tools
  ref="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" | grep '^localhost:5555/')"
  tools="$(docker inspect --format '{{ index .Config.Labels "md.sycophant.tools" }}' "$image")"
  case "$tools" in
    "{"*) ;;
    *) warn "${image} carries no md.sycophant.tools label; rebuild with --clean"; exit 1 ;;
  esac
  mkdir -p "$VALUES_DIR"
  printf '{"toolset": {"image": "%s", "tools": %s}}\n' \
    "${ref/localhost:5555/sycophant-registry:5000}" "$tools" > "$VALUES_DIR/toolset-$1-image.yaml"
}

# Seed what the tenant reads but no provision command installs: the instructions
# tree and its read credential, the vendor model key, and the ssh-credentials
# fixtures.
seed_tenant() {
  # The harness init container syncs its <ns>/<workspace> instructions prefix
  # from the object store with a read-only credential.
  provision_instructions_content hello-world

  kubectl create secret generic sycophant-llm-openrouter -n "$NAMESPACE" \
    --from-literal=sycophant-llm-openrouter="$OPENROUTER_API_KEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl apply -f "$REPO_ROOT/examples/toolsets/ssh-credentials/fixtures/" -n "$NAMESPACE" >/dev/null
  ok "Instructions, secrets, toolset fixtures applied"
}

# ---- step 3: deploy ----
step_3_deploy() {
  step "Step 3: Deploy charts"

  # Create the PSA-restricted release namespace before helm installs into it
  # (helm --create-namespace would land it bare). Same manifest `syco setup` applies.
  kubectl apply -f "$REPO_ROOT/charts/sycophant-cluster/system-ns.yaml" >/dev/null

  # A killed prior run can leave this release wedged in a pending-*/failed state,
  # which blocks the next install with "another operation in progress". The
  # cluster chart holds no state worth preserving on a reuse run, so clear a
  # non-deployed release before reinstalling. (Mirror of the tenant block below.)
  if helm list -n sycophant-system --pending -q 2>/dev/null | grep -qx sycophant \
     || helm list -n sycophant-system --failed -q 2>/dev/null | grep -qx sycophant; then
    warn "cluster release 'sycophant' wedged (pending/failed) — uninstalling before reinstall"
    helm uninstall sycophant -n sycophant-system --wait --timeout=2m >/dev/null 2>&1 || true
  fi
  # `syco setup` installed the cluster chart on a fresh cluster; a reuse run
  # re-applies this checkout's chart with the same Dex trust (issuer, audience,
  # and the CA setup generated) and e2e reap tuning, so chart render and live
  # apiserver config agree.
  helm upgrade --install sycophant "$REPO_ROOT/charts/sycophant-cluster/" \
    -n sycophant-system \
    --set-string "idp.issuer=$APISERVER_OIDC_ISSUER" \
    --set-string "idp.audience=$APISERVER_OIDC_AUDIENCE" \
    --set-file "idp.certificateAuthority=$SYCO_DEX_CA" \
    -f "$SYCO_CLUSTER_VALUES" \
    --wait >/dev/null
  ok "Cluster chart installed"

  # A killed prior run (e.g. an apiserver timeout mid-install) can leave a tenant
  # release wedged in a pending-*/failed state, which blocks the next install
  # with "another operation in progress". An e2e tenant holds no state worth
  # preserving, so drop the non-deployed records the installers keep in
  # ConfigMaps; the next install proceeds from the last deployed one.
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    kubectl delete configmap -n "$NAMESPACE" \
      -l 'owner=helm,status in (pending-install,pending-upgrade,pending-rollback,failed)' \
      --ignore-not-found >/dev/null
  fi

  # The operator's path: `syco tenant up -f` applies the tenant provision
  # command under the operator's Dex login and waits on its installer Job. The
  # provision runs in the background while this step seeds the namespace the
  # reactor generates.
  "$SYCO" tenant up -f "$REPO_ROOT/examples/tenants/e2e-test.yaml" &
  local up_pid=$!
  CLEANUP_PIDS+=("$up_pid")

  wait_for "tenant namespace ${NAMESPACE} generated" 120 \
    "kubectl get namespace '$NAMESPACE' >/dev/null 2>&1"
  kubectl get namespace "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -qx sycophant-tenant \
    || { warn "generated namespace ${NAMESPACE} lacks the part-of=sycophant-tenant label"; exit 1; }
  seed_tenant

  # The part-of label the reactor stamps triggers the tenant-rolebinding-generator,
  # which mints the per-tenant TokenReview CRB and the pod VAP binding. Kyverno
  # generate is async, so wait for the wiring before the controllers need it.
  wait_for "${NAMESPACE}-relay-tokenreview CRB" 120 \
    "kubectl get clusterrolebinding ${NAMESPACE}-relay-tokenreview >/dev/null 2>&1"
  wait_for "${NAMESPACE}-sycophant-pod-binding VAP binding" 120 \
    "kubectl get validatingadmissionpolicybinding ${NAMESPACE}-sycophant-pod-binding >/dev/null 2>&1"
  ok "Kyverno minted TokenReview CRB + pod VAP binding (label-triggered)"

  # The pod VAP is now bound to this ns — assert it actually enforces. The
  # binding object existing does not mean the apiserver enforces it yet: there
  # is an eventual-consistency gap after Kyverno mints the binding, so poll the
  # probe until it is denied rather than asserting once. This pod is
  # PSA-restricted-compliant but sets automountServiceAccountToken: true, which
  # only the VAP forbids (PSA does not check it), so a denial citing the policy
  # proves the binding is live.
  local vap_probe_err vap_deadline
  vap_deadline=$((SECONDS + 30))
  while :; do
    vap_probe_err="$(kubectl apply -n "$NAMESPACE" -f - 2>&1 <<'POD' || true
apiVersion: v1
kind: Pod
metadata:
  name: vap-probe
  labels:
    app.kubernetes.io/part-of: sycophant
    app.kubernetes.io/component: relay-controller
spec:
  automountServiceAccountToken: true
  securityContext:
    runAsNonRoot: true
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: c
      image: registry.k8s.io/pause:3.9
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities: { drop: ["ALL"] }
POD
)"
    kubectl delete pod vap-probe -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    if printf '%s' "$vap_probe_err" | grep -qe 'cluster-gvisor-pod-policy' -e 'automountServiceAccountToken must be set to false'; then
      ok "pod VAP enforced (automountServiceAccountToken denied by cluster-gvisor-pod-policy)"
      break
    fi
    if [ "$SECONDS" -ge "$vap_deadline" ]; then
      warn "pod VAP did NOT deny the probe after 30s (binding not enforcing): ${vap_probe_err}"
      exit 1
    fi
    sleep 2
  done

  # Instructions delivery is object-storage-driven — no Instructions CR. The harness init
  # container syncs its <ns>/<workspace> prefix from the shared store in the
  # system namespace (seeded above) into an emptyDir it mounts read-only.

  wait "$up_pid" || { warn "syco tenant up failed"; exit 1; }
  ok "syco tenant up: tenant provision command admitted; its installer Job succeeded (install-wait passed)"
  wait_for "tenant release ${NAMESPACE} deployed" 120 \
    "release_deployed '$NAMESPACE' '$NAMESPACE'"
  ok "tenant release ${NAMESPACE} deployed"
  kubectl get configmap provision-tenant -n sycophant-system >/dev/null 2>&1 \
    && { warn "the tenant provision command survived a successful install"; exit 1; }
  ok "the tenant installer deleted its provision command"

  # Each model is its own provision command, applied once the tenant is up and
  # the vendor key is seeded. The harness watches the model ConfigMaps, so no
  # restart.
  local model
  for model in "$REMOTE_MODEL" "$INFERENCE_PROFILE"; do
    "$SYCO" inference up -f "$REPO_ROOT/examples/inference/${model}.yaml"
    kubectl get configmap "model-${model}" -n "$NAMESPACE" >/dev/null 2>&1 \
      || { warn "model ConfigMap model-${model} missing after its install"; exit 1; }
  done
  ok "syco inference up: ${REMOTE_MODEL} and ${INFERENCE_PROFILE} model provision commands installed"

  # Each toolset is its own provision command: its example values, then an
  # override carrying the image digest and the image's tool label. The harness
  # watches the toolset ConfigMaps, so no restart. The examples' keepalive keeps
  # the stdlib and grant-bearing pods alive for the later exec assertions.
  local ts name img
  for ts in stdlib:toolset workspace-ro:toolset-git ssh-credentials:toolset-ssh-credentials; do
    IFS=: read -r name img <<<"$ts"
    write_toolset_image "$name" "$img"
    "$SYCO" toolset up -f "$REPO_ROOT/examples/toolsets/${name}/values.yaml" \
      -f "$VALUES_DIR/toolset-${name}-image.yaml"
    [ -n "$(kubectl get configmap "toolset-${name}" -n "$NAMESPACE" \
      -o 'jsonpath={.data.image}' 2>/dev/null)" ] \
      || { warn "toolset ConfigMap toolset-${name} missing or has no image after its install"; exit 1; }
  done
  ok "syco toolset up: stdlib, workspace-ro and ssh-credentials toolset provision commands installed"

  # The workspace and its bound user are one provision command each.
  "$SYCO" workspace up -f "$REPO_ROOT/examples/workspaces/hello-world.yaml"
  kubectl get deploy hello-world -n "$NAMESPACE" >/dev/null 2>&1 \
    || { warn "hello-world harness Deployment missing after its install"; exit 1; }
  "$SYCO" user up -f "$REPO_ROOT/examples/users/alice.yaml" \
    --set "user.subject=${APISERVER_OIDC_ISSUER}#${TENANT_A_USER_SUB}"
  ok "syco workspace up and syco user up: hello-world and its bound user installed"

  # The app channel installs host-side after the base: its adapter needs a
  # pre-auth key minted from the tenant's own headscale.
  helm upgrade --install channel-app "$REPO_ROOT/charts/sycophant-tenant" -n "$NAMESPACE" \
    --set render=channel -f "$REPO_ROOT/docs/e2e/channel-values.yaml" >/dev/null
  ok "app channel slice installed"
  step_3_headscale_authkey

  # Grant rows are runtime data, not chart config: the operator writes them
  # into the chart-created `relay-access-grants` ConfigMap. The identity IS the
  # code, and the operator invents it — the relay mints nothing.
  kubectl patch configmap relay-access-grants -n "$NAMESPACE" --type=merge -p "$(
    cat <<EOF
{"data":{"${CLIENT_NAME}":"channel: app\nidentity: ${GRANT_CODE}\nworkspace: hello-world\n"}}
EOF
  )" >/dev/null
  ok "Grant row ${CLIENT_NAME} written (channel app, workspace hello-world)"

  # The grant code is one-time. A reused cluster keeps this client's prior device
  # registration in relay-registered-keys, which would leave the app "already
  # enrolled" against a now-spent code and suppress this run's fresh enrollment.
  # Clear the client's registration so THIS run's freshly written code is
  # redeemable and the device re-enrolls every run. No-op on a clean cluster
  # (secret or key absent).
  kubectl patch secret relay-registered-keys -n "$NAMESPACE" --type=json \
    -p "[{\"op\":\"remove\",\"path\":\"/data/${CLIENT_NAME}\"}]" >/dev/null 2>&1 || true
  ok "Cleared prior ${CLIENT_NAME} registration — this run mints a fresh enrollment"

  # The per-model egress CNP and the per-grant egress CNP are all chart-rendered
  # — the structural proof that egress authoring lives OUTSIDE the tenant.
  # `relay-ingress` is the ONE object carrying every relay ingress rule; its
  # whole-object absence is the only way the relay fails open, so the run
  # hard-fails on it.
  # inference-egress-<remote> is the vendor model's job egress hole;
  # inference-local is the in-cluster model pod's own ingress+DNS fence.
  for cnp in "inference-egress-${REMOTE_MODEL}" "inference-${INFERENCE_PROFILE}" relay-ingress; do
    if kubectl get ciliumnetworkpolicy "$cnp" -n "$NAMESPACE" >/dev/null 2>&1; then
      ok "CNP present: $cnp"
    else
      warn "expected CNP missing: $cnp"
      exit 1
    fi
  done

  # Every rendered workload pod must clear the pod VAP, the inference server's
  # weights-copy init container included. A VAP denial does not fail the helm
  # install: the Deployment object is created, but its ReplicaSet cannot create
  # the pod and emits a FailedCreate event citing the policy. So assert the
  # inference pod was admitted (a Pod object exists) and that no ReplicaSet in
  # the namespace reports an admission denial.
  wait_for "inference-${INFERENCE_PROFILE} pod admitted" 60 \
    "kubectl get pod -n '$NAMESPACE' -l app.kubernetes.io/component=inference,app.kubernetes.io/name=${INFERENCE_PROFILE} -o name 2>/dev/null | grep -q ." \
    || { warn "no pod for inference-${INFERENCE_PROFILE} — the ReplicaSet could not create one (admission?)"; \
         kubectl get events -n "$NAMESPACE" --field-selector reason=FailedCreate 2>/dev/null | tail -5 >&2; exit 1; }
  if kubectl get events -n "$NAMESPACE" --field-selector reason=FailedCreate 2>/dev/null \
       | grep -qiE 'denied|policy|automountServiceAccountToken'; then
    warn "a workload pod was denied admission by the pod VAP:"
    kubectl get events -n "$NAMESPACE" --field-selector reason=FailedCreate 2>/dev/null \
      | grep -iE 'denied|policy|automountServiceAccountToken' | sed 's/^/    /' >&2
    exit 1
  fi
  ok "All rendered workload pods admitted (inference copy-path init container included)"
}

# Stand the app adapter's tailnet identity up: create the headscale user,
# mint a pre-auth key, and hand it to the adapter through its authKey Secret.
# headscale 0.28+ requires a numeric user id for `-u`, hence the lookup.
step_3_headscale_authkey() {
  step "Minting a headscale pre-auth key for the app adapter"
  wait_for "headscale Available" 180 \
    "kubectl wait --for=condition=Available --timeout=5s -n '$NAMESPACE' deploy/headscale"

  kubectl exec -n "$NAMESPACE" deploy/headscale -- \
    headscale users create "$HEADSCALE_USER" >/dev/null 2>&1 || true
  local user_id
  user_id="$(kubectl exec -n "$NAMESPACE" deploy/headscale -- \
    headscale users list -o json | jq -r ".[] | select(.name==\"$HEADSCALE_USER\") | .id")"
  [ -n "$user_id" ] || { warn "headscale user $HEADSCALE_USER has no id"; return 1; }

  # The key never reaches a printf/echo: it goes straight from the mint
  # command into kubectl's stdin.
  kubectl exec -n "$NAMESPACE" deploy/headscale -- \
    headscale preauthkeys create -u "$user_id" -e 24h | tail -1 | tr -d '\r\n' \
    | kubectl create secret generic "$ADAPTER_AUTHKEY_SECRET" -n "$NAMESPACE" \
        --from-file=authkey=/dev/stdin --dry-run=client -o yaml \
    | kubectl apply -n "$NAMESPACE" -f - >/dev/null
  ok "Pre-auth key stored in Secret ${ADAPTER_AUTHKEY_SECRET}"

  wait_for "app adapter Available" 180 \
    "kubectl wait --for=condition=Available --timeout=5s -n '$NAMESPACE' deploy/adapter-app"
  ok "App adapter Available"
}

# ---- step 4: verify chart ----
step_4_verify() {
  step "Step 4: Verify chart"

  # Per-workspace harness Deployment rendered by the chart. Wait on
  # the Deployment becoming Available rather than a specific pod name,
  # since the pod name now carries a ReplicaSet suffix.
  kubectl wait -n "$NAMESPACE" --for=condition=Available --timeout=180s \
    deployment/hello-world >/dev/null
  ok "hello-world workspace Ready"

  # The in-cluster inference server must reach Available and stay healthy: the
  # server surviving is the non-racy guarantee this run owns. It is the slowest
  # workload — the copy init container writes the multi-gigabyte GGUF into the
  # emptyDir, then the server memory-maps it on CPU — so the timeout is generous.
  kubectl wait -n "$NAMESPACE" --for=condition=Available --timeout=600s \
    "deployment/inference-${INFERENCE_PROFILE}" >/dev/null
  ok "in-cluster inference server (${INFERENCE_PROFILE}) Available"

  # Workspace-init Job must COMPLETE: it binds the workspace PVC (first
  # consumer under WaitForFirstConsumer) and establishes the git baseline
  # for every workspace. helm --wait gates on PVC Bound, not Job completion,
  # so a failed git baseline would otherwise pass silently — assert it here.
  if kubectl wait -n "$NAMESPACE" --for=condition=complete --timeout=120s \
       job -l app.kubernetes.io/component=workspace-init,app.kubernetes.io/name=hello-world >/dev/null 2>&1; then
    ok "hello-world workspace-init Job complete (PVC bound + git baseline)"
  else
    warn "hello-world workspace-init Job did not complete"
    kubectl get job,pod -n "$NAMESPACE" -l app.kubernetes.io/component=workspace-init 2>&1 | sed 's/^/    /' >&2
    return 1
  fi
}

# ---- step 5: flutter ----
# Forwards headscale's HTTP API, so the operator can point the host's
# Tailscale at the in-cluster control plane and reach the app adapter over
# the tailnet. This is the only forward the run stands up: the relay's app
# port stays unreachable from the host, so a client can only arrive through
# the adapter, which is the path the assertions are meant to cover.
#
# Self-healing loop: kubectl port-forward binds to one pod's stream and dies
# on pod replacement (rollout, eviction, crash). The loop reconnects to the
# deployment's current pod automatically. Disable errexit inside the subshell
# so a non-zero kubectl exit doesn't kill the loop. The trap ensures the
# kubectl child dies with the subshell — without it the kubectl process would
# be orphaned and survive script teardown.
step_5_headscale_port_forward() {
  ( set +e
    kpid=""
    trap '[ -n "$kpid" ] && kill "$kpid" 2>/dev/null; exit' TERM INT EXIT
    while true; do
      kubectl port-forward -n "$NAMESPACE" svc/headscale 8080:8080 --address 0.0.0.0 \
        >/dev/null 2>&1 &
      kpid=$!
      wait "$kpid"
      sleep 2
    done ) &
  CLEANUP_PIDS+=($!)
  HEADSCALE_FORWARD_STARTED=1
}

# The code is read back from the row this script itself wrote this run. The
# deploy step clears any prior device registration for this client, so the fresh
# code is always redeemable and always surfaced — every run prints a live code.
step_5_grant_code() {
  kubectl get configmap relay-access-grants -n "$NAMESPACE" \
    -o jsonpath="{.data.${CLIENT_NAME}}" \
    | sed -n 's/^identity: //p' | tr -d '\n'
}

# Re-register the operator's Mac against THIS run's headscale. Every Step 0
# rebuilds the cluster, so headscale starts with an empty node DB while the Mac
# still holds the previous run's tailnet identity; `tailscale up` against the
# same login-server then silently keeps the now-unregistered node and the app's
# enrollment hangs against a relay it can't reach. Force-reauth fixes it every
# run so the join stops being a manual dance.
#
# The pre-auth key goes mint -> 0600 file -> `--auth-key=file:`, never a printf
# or argv, so it stays out of `ps` (same discipline as the adapter authkey).
# A sentinel is written immediately before the sudo prompt for the monitor.
tailnet_join_macos() {
  command -v tailscale >/dev/null 2>&1 \
    || { warn "tailscale CLI not found; join the tailnet manually before enrolling"; return 1; }

  kubectl exec -n "$NAMESPACE" deploy/headscale -- \
    headscale users create "$HEADSCALE_USER" >/dev/null 2>&1 || true
  local user_id
  user_id="$(kubectl exec -n "$NAMESPACE" deploy/headscale -- \
    headscale users list -o json | jq -r ".[] | select(.name==\"$HEADSCALE_USER\") | .id")"
  [ -n "$user_id" ] || { warn "headscale user $HEADSCALE_USER has no id"; return 1; }

  local keyfile
  keyfile="$(mktemp)"
  chmod 600 "$keyfile"
  kubectl exec -n "$NAMESPACE" deploy/headscale -- \
    headscale preauthkeys create -u "$user_id" -e 24h | tail -1 | tr -d '\r\n' > "$keyfile"

  # Sentinel first, then the banner, then the prompt — so the monitor fires
  # before sudo blocks on input.
  : > "$SUDO_PENDING_SENTINEL"
  printf '\n\033[1;33m🔑 SUDO INCOMING: the tailnet join needs your macOS password next.\033[0m\n' >&2
  sudo -v                                   # one prompt; caches for the two calls below
  sudo tailscale logout >/dev/null 2>&1 || true
  # --reset: prior runs may have left non-default prefs (e.g. --accept-routes);
  # `tailscale up` refuses to change settings otherwise. Reset to defaults and
  # apply only the flags below (peer-to-peer relay access needs no subnet routes).
  sudo tailscale up --reset --login-server=http://localhost:8080 \
    --auth-key="file:$keyfile" --force-reauth
  local rc=$?
  rm -f "$keyfile" "$SUDO_PENDING_SENTINEL"
  [ "$rc" -eq 0 ] || { warn "tailscale up failed (rc=$rc); join manually and retry"; return 1; }

  # Confirm the fresh headscale now sees this Mac online (relay + Mac = 2). `-w`
  # so 'offline' does not match 'online'.
  # shellcheck disable=SC2016 # single-quoted on purpose: wait_for evals it.
  wait_for "Mac joined the fresh tailnet" 60 \
    '[ "$(kubectl exec -n '"$NAMESPACE"' deploy/headscale -- headscale nodes list 2>/dev/null | grep -cw online)" -ge 2 ]'
  ok "Mac joined the tailnet (re-registered against this run'\''s headscale)"
}

step_5_flutter_macos() {
  local code="$1"
  step "Building Flutter macOS app"
  # CODE_SIGNING_ALLOWED=NO: build unsigned. arm64 applies a linker ad-hoc
  # signature so the app still launches locally; no Apple team or
  # provisioning profile needed. Never re-enable signing for the e2e.
  ( cd "$REPO_ROOT/client" && FLUTTER_XCODE_CODE_SIGNING_ALLOWED=NO flutter build macos --debug ) >/tmp/sycophant-flutter-build.log 2>&1 \
    || { warn "flutter build macos --debug failed; see /tmp/sycophant-flutter-build.log"; return 1; }
  local app_path="$REPO_ROOT/client/build/macos/Build/Products/Debug/sycophant.app"
  ok "macOS app built: $app_path"

  step "Launching macOS app"
  pkill -f "sycophant.app/Contents/MacOS/sycophant" 2>/dev/null || true
  sleep 1
  # `open -n` forces a new instance and bypasses the LaunchServices
  # "bring to front" path that returns -600 on stale state.
  if ! open -n "$app_path" 2>/dev/null; then
    warn "open -n failed, executing binary directly"
    "$app_path/Contents/MacOS/sycophant" >/dev/null 2>&1 &
  fi

  # The deploy step cleared any prior registration and wrote a fresh grant, so
  # the code is always live here — print the enrollment block unconditionally.
  printf '\n\033[1;35m========== Paste these into the app ==========\033[0m\n'
  printf '  Server:           %s\n' "$TAILNET_RELAY_ADDR"
  printf '  Workspace:        hello-world\n'
  printf '  Grant code:       %s\n' "$code"
  printf '  In-cluster model: %s  (a turn requesting this model routes to the inference-%s Service)\n' "$INFERENCE_PROFILE" "$INFERENCE_PROFILE"
  printf '\033[1;35m===============================================\033[0m\n'
  printf 'The tailnet was joined automatically for this run.\n'
  printf 'If the app opens at the chat screen with stale credentials, tap Sign Out first.\n'
}

# Backend-only (FLUTTER_TARGET=none): no local client to launch. Bring up the
# external listener, surface the connect details, and pause for the operator to
# attach a client from another machine (e.g. over Tailscale) and drive the
# Step 6 chat. Step 6 still runs afterward.
step_5_backend_only() {
  step "Step 5: Backend-only — connect a remote client"

  step_5_headscale_port_forward
  local code
  code="$(step_5_grant_code)"

  local addr="$TAILNET_RELAY_ADDR"

  printf '\n  Backend is up. Connect a client from another machine:\n' >&2
  printf '    Server:          %s\n' "$addr" >&2
  printf '    Workspace:       hello-world\n' >&2
  printf '    Namespace:       %s\n' "$NAMESPACE" >&2
  printf '    Client:          %s\n' "$CLIENT_NAME" >&2
  printf '    Grant code:      %s\n' "$code" >&2
  printf '    In-cluster model:%s  (routes to the inference-%s Service)\n' "$INFERENCE_PROFILE" "$INFERENCE_PROFILE" >&2

  pause "From the other machine, point the app at ${addr}, enroll with the code
   above. If the app was enrolled against a prior run, sign out first: this run
   rebuilt the cluster and minted a fresh code, so the app's stored device key
   no longer matches and signed calls fail until you re-enroll. Then send these
   two messages IN ORDER, ONE tool per message (the
   small in-cluster model calls a single tool reliably, not a chained sequence):
     1. (chip 'ssh-credentials: demo-key')  Use the test-cmd tool.
     2. (chip 'ssh-credentials: demo-key')  Use the Shell tool to run \`dmesg | head -1\`.
   The test-cmd reply's tool-result card shows the credential REDACTED. Step 6
   asserts on the toolset tool + the stdlib pod the Shell call triggers — same
   as the local-client path."
}

step_5_flutter() {
  if [ "$FLUTTER_TARGET" = "none" ]; then
    step_5_backend_only
    return
  fi

  step "Step 5: Flutter ${FLUTTER_TARGET} + chat"

  step_5_headscale_port_forward
  # Join the tailnet before the client launches, so enrollment reaches the relay
  # over the fresh tailnet instead of hanging on a stale node.
  tailnet_join_macos || return 1
  local code
  code="$(step_5_grant_code)"

  case "$FLUTTER_TARGET" in
    macos)   step_5_flutter_macos "$code" ;;
  esac

  pause "Tap Enroll, then drive the grant flow IN ORDER, ONE tool per message
   (the in-cluster model is small and calls a single tool reliably, not a
   chained sequence):
   1. Select the credential chip 'ssh-credentials: demo-key' above the
      input box, then send EXACTLY:
        Use the test-cmd tool.
      test-cmd runs under the demo-key grant (key delivered at its ssh
      path). The reply's tool-result card must show the key REDACTED, not
      raw — that card is the scrub proof, independent of the model's prose.
   2. Keep 'demo-key' selected and send EXACTLY:
        Use the Shell tool to run \`dmesg | head -1\`.
      Shell spawns the stdlib pod Step 6 asserts on for gVisor + egress +
      credential isolation and keepalive."
}

# ---- step 6: security assertions ----
step_6_security() {
  step "Step 6: Security assertions"

  # The harness creates the stdlib toolset pod on the first stdlib call; 90s
  # covers the ARM64 gVisor cold-start slow path.
  local toolset_selector="app.kubernetes.io/component=capability-job,sycophant.md/workspace=hello-world,sycophant.md/toolset=stdlib"
  local task_pod
  wait_for "stdlib toolset pod for hello-world" 90 \
    "kubectl get pod -n '$NAMESPACE' -l '$toolset_selector' -o name 2>/dev/null | grep -q ."
  task_pod="$(kubectl get pod -n "$NAMESPACE" \
                -l "$toolset_selector" \
                -o jsonpath='{.items[0].metadata.name}')"
  kubectl wait -n "$NAMESPACE" --for=condition=Ready --timeout=60s "pod/$task_pod" >/dev/null
  ok "stdlib toolset pod Ready ($task_pod)"

  local first_line
  first_line="$(kubectl exec -n "$NAMESPACE" "$task_pod" -- dmesg 2>/dev/null | head -1)"
  if echo "$first_line" | grep -q 'Starting gVisor'; then
    ok "gVisor kernel isolation"
  else
    warn "gVisor first dmesg line was: $first_line"
    return 1
  fi

  # Scan for real API-key prefixes in two sinks:
  #   1. harness stdout (kubectl logs)
  #   2. conversation log files on the harness's conversation-data PVC
  # Patterns match a prefix + length floor — `sk-ant-` + 50+ base64 chars
  # for Anthropic, `sk-` + 40+ for generic OpenAI-style. The length floor
  # avoids false positives on the bare strings "sk-" or "sk-ant-" appearing
  # in normal text.
  local key_regex='sk-ant-[A-Za-z0-9_-]{50,}|sk-[A-Za-z0-9_-]{40,}'

  local harness_hits
  harness_hits="$(kubectl logs -n "$NAMESPACE" deployment/hello-world -c harness --tail=10000 2>/dev/null \
                        | grep -cE "$key_regex" || true)"

  # The conversation log is on the harness's OWN RWO PVC
  # (conversation-data-<ws> at /var/lib/harness/conversations). A separate
  # pod can't mount an RWO PVC, and the harness image is FROM scratch (no
  # shell), so attach an ephemeral busybox to the harness pod sharing its
  # PID namespace and read the dir via /proc/1/root. (Fallback if a hardened
  # node blocks /proc/1/root via ptrace_scope: scale the harness to 0,
  # mount conversation-data-<ws> RO in a probe pod, grep, then scale back to 1.)
  local tb_pod scrub_c patch
  tb_pod="$(kubectl get pod -n "$NAMESPACE" \
    -l app.kubernetes.io/component=harness,sycophant.md/workspace=hello-world \
    -o jsonpath='{.items[0].metadata.name}')"
  scrub_c="syco-scrub-$$"
  patch='{"spec":{"ephemeralContainers":[{"name":"'"$scrub_c"'","image":"busybox:1.36","command":["sleep","180"],"targetContainerName":"harness","securityContext":{"runAsNonRoot":true,"runAsUser":1000,"readOnlyRootFilesystem":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}'
  kubectl patch pod "$tb_pod" -n "$NAMESPACE" \
    --subresource=ephemeralcontainers --type=strategic -p "$patch" >/dev/null
  local conv_hits=""
  for _ in $(seq 1 15); do
    conv_hits="$(kubectl exec -n "$NAMESPACE" "$tb_pod" -c "$scrub_c" -- \
      sh -c "grep -rcE '$key_regex' /proc/1/root/var/lib/harness/conversations 2>/dev/null | grep -v ':0\$' | wc -l" 2>/dev/null)" && break
    sleep 2
  done
  conv_hits="${conv_hits//[[:space:]]/}"
  conv_hits="${conv_hits:-0}"

  if [ "$harness_hits" -eq 0 ] && [ "$conv_hits" -eq 0 ]; then
    ok "Secret scrubbing (0 sk-ant-/sk- matches in harness + conv log)"
  else
    warn "Unscrubbed key prefixes detected: harness=$harness_hits conv_log=$conv_hits"
    return 1
  fi

  # The granted demo key: its raw bytes must never appear in the
  # conversation log, and the redaction marker must — together proving the
  # credential file was read end-to-end by the granted tool call and
  # scrubbed on the way out of the pod.
  local grant_raw grant_marker
  grant_raw="$(kubectl exec -n "$NAMESPACE" "$tb_pod" -c "$scrub_c" -- \
    sh -c "grep -rc 'FAKE-ED25519-PRIVATE-KEY' /proc/1/root/var/lib/harness/conversations 2>/dev/null | grep -v ':0\$' | wc -l" 2>/dev/null)"
  grant_marker="$(kubectl exec -n "$NAMESPACE" "$tb_pod" -c "$scrub_c" -- \
    sh -c "grep -rl 'REDACTED:demo-ssh-key' /proc/1/root/var/lib/harness/conversations 2>/dev/null | wc -l" 2>/dev/null)"
  grant_raw="${grant_raw//[[:space:]]/}"; grant_raw="${grant_raw:-1}"
  grant_marker="${grant_marker//[[:space:]]/}"; grant_marker="${grant_marker:-0}"
  if [ "$grant_raw" -eq 0 ] && [ "$grant_marker" -ge 1 ]; then
    ok "Grant credential read + scrubbed (marker present, raw bytes absent)"
  else
    warn "grant credential evidence wrong: raw_files=$grant_raw marker_files=$grant_marker"
    return 1
  fi

  # The harness persists tool execution to a single append-only
  # execution.json per conversation, under
  # /var/lib/harness/conversations/<ws>/<conv_id>/execution.json: one
  # ND-JSON record per ToolResultFrame (stdout / stderr / image, terminated by
  # one ToolComplete), each line carrying its call_id, with binary frames moved
  # to content-addressed blobs/sha256/<hex> in the same conversation dir. A tool
  # that ran to completion leaves a non-empty execution.json, so assert a
  # non-empty execution.json exists. Read it via the same ephemeral container
  # the conv-log scrub scan above used.
  local exec_ok=""
  for _ in $(seq 1 30); do
    exec_ok="$(kubectl exec -n "$NAMESPACE" "$tb_pod" -c "$scrub_c" -- \
      sh -c 'find /proc/1/root/var/lib/harness/conversations -type f -name "execution.json" -size +0c 2>/dev/null | head -1')" \
      && [ -n "$exec_ok" ] && break
    sleep 2
  done
  if [ -n "$exec_ok" ]; then
    ok "Tool execution (non-empty execution.json record persisted)"
  else
    warn "no execution.json record on harness PVC"
    return 1
  fi

  if kubectl exec -n "$NAMESPACE" "$task_pod" -- \
       wget -qO- --timeout=3 https://httpbin.org/ip >/dev/null 2>&1; then
    warn "stdlib toolset pod reached httpbin.org — NetworkPolicy egress NOT enforced"
    return 1
  else
    ok "NetworkPolicy blocks stdlib toolset egress"
  fi

  # L7 DNS allowlist holds: stdlib must NOT resolve arbitrary names (the DNS-tunnel
  # exfil guard — proves baseline + per-toolset CNP compose without L4-shadows-L7).
  # Best-effort: skip cleanly if the toolset image lacks nslookup.
  if kubectl exec -n "$NAMESPACE" "$task_pod" -- sh -c 'command -v nslookup' >/dev/null 2>&1; then
    if kubectl exec -n "$NAMESPACE" "$task_pod" -- nslookup example.com >/dev/null 2>&1; then
      warn "stdlib resolved example.com — L7 DNS allowlist NOT enforced"
      return 1
    else
      ok "L7 DNS allowlist blocks arbitrary name resolution"
    fi
  else
    warn "nslookup absent in toolset image — skipping L7 DNS probe (wget check still covers egress containment)"
  fi

  if kubectl exec -n "$NAMESPACE" "$task_pod" -- \
       cat /run/secrets/toolset/api-key >/dev/null 2>&1; then
    warn "/run/secrets/toolset/api-key exists inside stdlib toolset pod — credential leak"
    return 1
  else
    ok "Credential isolation (no LLM key in stdlib toolset pod)"
  fi

  # The stdlib toolset is bound bare, so this call resolved no grant. The
  # convention credential target must therefore be empty: a grant a call never
  # selected must not reach the pod.
  if kubectl exec -n "$NAMESPACE" "$task_pod" -- \
       cat /run/secrets/grant/credential >/dev/null 2>&1; then
    warn "/run/secrets/grant/credential exists inside a grantless toolset pod — credential leak"
    return 1
  else
    ok "Credential isolation (no grant credential in a grantless toolset pod)"
  fi

  # Every workspace-sa form the chart renders for the workspace must exist, not
  # just one of them.
  local workspace_sas sa
  workspace_sas="$(kubectl get serviceaccounts -n "$NAMESPACE" -l sycophant.md/type=workspace-sa -o name)"
  for sa in harness-hello-world unprivileged-hello-world hello-world-workspace-init; do
    if ! printf '%s\n' "$workspace_sas" | grep -qx "serviceaccount/${sa}"; then
      warn "${sa} ServiceAccount missing"
      return 1
    fi
  done
  ok "Workspace ServiceAccounts present"

  # Each substep is an independent security assertion sharing no state. Run
  # them all and fail at the end if any failed, so one failure never aborts the
  # rest and masks unrelated properties.
  local -a checks=(
    step_6_relay_sheds_tsnet
    step_6_adapter_isolation
    step_6_adapter_port_fence
    step_6_inference_fence
    step_6_grant_row_hot_reload
  )
  local failed=() c
  for c in "${checks[@]}"; do
    "$c" || failed+=("$c")
  done
  if [ "${#failed[@]}" -ne 0 ]; then
    warn "Step 6 substeps failed: ${failed[*]}"
    return 1
  fi
}

# The tailnet terminus lives on the app adapter, not the relay. A tailscale
# container back in the relay pod would widen the relay's per-pod egress and
# let loopback bypass both the tailnet and the CNP.
step_6_relay_sheds_tsnet() {
  local images
  images="$(kubectl get deploy relay-controller -n "$NAMESPACE" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{.name}={.image}{"\n"}{end}')"
  if printf '%s' "$images" | grep -qi 'tailscale\|tsnet'; then
    warn "relay pod carries a tailscale/tsnet container: $images"
    return 1
  fi
  ok "Relay pod carries no tailscale container"
}

# Every adapter runs under gVisor. It terminates a foreign protocol and
# parses whatever the outside world sends it.
step_6_adapter_isolation() {
  local rc
  rc="$(kubectl get pods -n "$NAMESPACE" \
    -l app.kubernetes.io/component=adapter \
    -o jsonpath='{.items[0].spec.runtimeClassName}')"
  if [ "$rc" != "gvisor" ]; then
    warn "app adapter pod runtimeClassName is '$rc', expected gvisor"
    return 1
  fi
  ok "App adapter runs under gVisor"
}

# An accept/deny pair. A deny-only probe passes on a fence that
# refuses everything, so both halves are required: the labelled pod must
# reach 9092 and the unlabelled one must not.
step_6_adapter_port_fence() {
  step "Adapter-port fence (9092)"
  local target="relay-controller.${NAMESPACE}.svc.cluster.local"

  adapter_probe() {
    local name="$1" class="$2"
    kubectl delete pod "$name" -n "$NAMESPACE" --ignore-not-found --wait=true >/dev/null 2>&1
    kubectl run "$name" -n "$NAMESPACE" --restart=Never --quiet \
      --image=busybox:1.36 \
      --labels="app.kubernetes.io/part-of=sycophant,app.kubernetes.io/component=adapter${class}" \
      --overrides='{"spec":{"automountServiceAccountToken":false,"runtimeClassName":"gvisor","containers":[{"name":"probe","image":"busybox:1.36","securityContext":{"runAsNonRoot":true,"runAsUser":65534,"readOnlyRootFilesystem":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}},"command":["sh","-c","nc -z -w 5 '"$target"' 9092"]}]}}' \
      >/dev/null 2>&1
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$name" \
      -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1
  }

  if adapter_probe adapter-probe-allow ",sycophant.md/adapter-class=principal"; then
    ok "principal-labelled pod reaches the adapter port"
  else
    warn "principal-labelled pod could NOT reach the adapter port — the fence admits nothing"
    kubectl logs adapter-probe-allow -n "$NAMESPACE" 2>&1 | tail -5 || true
    kubectl delete pod adapter-probe-allow adapter-probe-deny -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
    return 1
  fi

  if adapter_probe adapter-probe-deny ""; then
    warn "a pod without adapter-class=principal reached the adapter port — the fence is open"
    kubectl delete pod adapter-probe-allow adapter-probe-deny -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
    return 1
  else
    ok "pod without adapter-class=principal is refused on the adapter port"
  fi

  kubectl delete pod adapter-probe-allow adapter-probe-deny -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
}

# The in-cluster inference Service, fenced two ways.
#
# L3/L4: its ingress admits only pods carrying the profile's toolset label, so a
# labelled probe connects and an unlabelled one is refused. Both halves are
# required — a deny-only probe passes on a fence that admits nothing — so this is
# the same accept/deny pair as the adapter fence.
#
# L7: from a pod that DOES carry the label (L3/L4 already open), the Cilium HTTP
# allowlist answers /metrics and /slots with 403 and lets a completion through
# with 200. A denial here is a 403, not a drop, so the 403 is the positive signal
# the filter is engaged; a 200 on /metrics would mean a policy applied from
# outside the chart shadowed it, which the rendered-manifest checks cannot see.
# The completion 200 is the accept half and is itself the proof a turn reaches
# the in-cluster server rather than an external provider, since the probe dials
# the cluster Service by name. First-token latency, sustained tokens/sec and the
# pod's memory high-water mark are recorded from the server's own response
# timings and cgroup; they are informational and never fail the run.
step_6_inference_fence() {
  step "In-cluster inference fence (${INFERENCE_PROFILE})"
  local svc="inference-${INFERENCE_PROFILE}.${NAMESPACE}.svc.cluster.local"

  # --- L3/L4: reachable only by the harness, which dials the warm Service ---
  inference_l4_probe() {
    local name="$1" extra="$2"
    kubectl delete pod "$name" -n "$NAMESPACE" --ignore-not-found --wait=true >/dev/null 2>&1
    kubectl run "$name" -n "$NAMESPACE" --restart=Never --quiet \
      --image=busybox:1.36 \
      --labels="app.kubernetes.io/part-of=sycophant${extra}" \
      --overrides='{"spec":{"automountServiceAccountToken":false,"containers":[{"name":"probe","image":"busybox:1.36","resources":{"requests":{"cpu":"50m","memory":"64Mi"},"limits":{"cpu":"50m","memory":"64Mi"}},"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"readOnlyRootFilesystem":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}},"command":["sh","-c","nc -z -w 5 '"$svc"' '"$INFERENCE_PORT"'"]}]}}' \
      >/dev/null 2>&1
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$name" \
      -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1
  }

  if inference_l4_probe inference-probe-allow ",app.kubernetes.io/component=harness,sycophant.md/workspace=hello-world"; then
    ok "harness-labelled pod reaches the inference Service"
  else
    warn "harness-labelled pod could NOT reach the inference Service — the fence admits nothing"
    kubectl logs inference-probe-allow -n "$NAMESPACE" 2>&1 | tail -5 || true
    kubectl delete pod inference-probe-allow inference-probe-deny -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
    return 1
  fi

  if inference_l4_probe inference-probe-deny ""; then
    warn "a pod without the harness label reached the inference Service — the fence is open"
    kubectl delete pod inference-probe-allow inference-probe-deny -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
    return 1
  else
    ok "pod without the harness label is refused on the inference Service"
  fi
  kubectl delete pod inference-probe-allow inference-probe-deny -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1

  # --- L7: the HTTP allowlist closes every route but the two completions ---
  # One labelled pod probes /metrics, /slots and a completion, printing a status
  # line per route plus the server's response so the host can parse it. The pod
  # carries the harness label, so harness-egress grants it egress to the
  # inference endpoint and DNS for the Service FQDN.
  kubectl delete pod inference-l7-probe -n "$NAMESPACE" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl apply -n "$NAMESPACE" -f - >/dev/null <<POD
apiVersion: v1
kind: Pod
metadata:
  name: inference-l7-probe
  labels:
    app.kubernetes.io/part-of: sycophant
    app.kubernetes.io/component: harness
    sycophant.md/workspace: hello-world
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: probe
      image: busybox:1.36
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits: { cpu: 50m, memory: 64Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities: { drop: ["ALL"] }
      command: ["sh", "-c"]
      args:
        - |
          b=http://${svc}:${INFERENCE_PORT}
          code() { wget -S -q -O /dev/null "\$1" 2>&1 | grep -o 'HTTP/[0-9.]* [0-9][0-9][0-9]' | tail -1 | grep -o '[0-9][0-9][0-9]\$'; }
          echo "METRICS=\$(code \$b/metrics)"
          echo "SLOTS=\$(code \$b/slots)"
          r=\$(wget -S -q -O- --header 'Content-Type: application/json' --post-data '{"model":"${INFERENCE_PROFILE}","messages":[{"role":"user","content":"Reply with a short greeting."}],"stream":false,"max_tokens":32}' "\$b/v1/chat/completions" 2>&1 || true)
          echo "COMPLETION=\$(printf '%s' "\$r" | grep -o 'HTTP/[0-9.]* [0-9][0-9][0-9]' | tail -1 | grep -o '[0-9][0-9][0-9]\$')"
          printf '%s' "\$r" | tr ',{}' '\n' | grep -oE '"(completion_tokens|prompt_ms|predicted_ms|predicted_per_second)":[0-9.]+'
          t=\$(wget -S -q -O- --header 'Content-Type: application/json' --post-data '{"model":"${INFERENCE_PROFILE}","messages":[{"role":"user","content":"What is the weather in Paris right now? You must call the get_weather tool to answer."}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city.","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":"auto","stream":false}' "\$b/v1/chat/completions" 2>&1 || true)
          echo "TOOLCALL=\$(printf '%s' "\$t" | grep -o 'HTTP/[0-9.]* [0-9][0-9][0-9]' | tail -1 | grep -o '[0-9][0-9][0-9]\$')"
          if printf '%s' "\$t" | grep -qE '"tool_calls":[[:space:]]*\[[[:space:]]*\{'; then echo "TOOLCALLS=present"; else echo "TOOLCALLS=absent"; fi
POD
  if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/inference-l7-probe \
         -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1; then
    warn "inference L7 probe did not complete"
    kubectl logs inference-l7-probe -n "$NAMESPACE" 2>&1 | tail -10 || true
    kubectl delete pod inference-l7-probe -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
    return 1
  fi
  local out metrics_code slots_code completion_code toolcall_code toolcalls
  out="$(kubectl logs inference-l7-probe -n "$NAMESPACE" 2>/dev/null)"
  kubectl delete pod inference-l7-probe -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  metrics_code="$(printf '%s' "$out" | sed -n 's/^METRICS=//p')"
  slots_code="$(printf '%s' "$out" | sed -n 's/^SLOTS=//p')"
  completion_code="$(printf '%s' "$out" | sed -n 's/^COMPLETION=//p')"
  toolcall_code="$(printf '%s' "$out" | sed -n 's/^TOOLCALL=//p')"
  toolcalls="$(printf '%s' "$out" | sed -n 's/^TOOLCALLS=//p')"

  if [ "$metrics_code" = "403" ] && [ "$slots_code" = "403" ]; then
    ok "L7 allowlist denies /metrics and /slots with 403 (filter engaged)"
  else
    warn "L7 allowlist NOT engaged: /metrics=${metrics_code:-none} /slots=${slots_code:-none} — a 200 means a policy elsewhere shadowed the filter"
    return 1
  fi

  if [ "$completion_code" = "200" ]; then
    ok "In-cluster turn served: completion returned 200 from the inference pod (not an external provider)"
  else
    warn "completion did not return 200 from the inference Service: got ${completion_code:-none}"
    return 1
  fi

  # A tools request that must trigger a call. Both halves in one assertion: a
  # missing --chat-template-file file crashes the server (status != 200) and a
  # broken embedded template silently drops the tools array (tool_calls empty or
  # null → absent). A corrected template returns 200 with a non-empty tool_calls.
  if [ "$toolcall_code" = "200" ] && [ "$toolcalls" = "present" ]; then
    ok "Tool-call turn served: the model returned a non-empty tool_calls with 200 (the chat template renders the tools)"
  else
    warn "tool-call turn failed: status=${toolcall_code:-none} tool_calls=${toolcalls:-none} — a broken or dropped chat template drops the tools array (empty/null tool_calls); a missing template file crashes the server (status != 200)"
    return 1
  fi

  # Informational: the server reports its own timings in the response, so read
  # first-token (prefill) latency and sustained rate from there; read the memory
  # high-water from the pod's cgroup. None of these fail the run.
  local prompt_ms rate mem
  prompt_ms="$(printf '%s' "$out" | sed -n 's/.*"prompt_ms":\([0-9.]*\).*/\1/p' | head -1)"
  rate="$(printf '%s' "$out" | sed -n 's/.*"predicted_per_second":\([0-9.]*\).*/\1/p' | head -1)"
  mem="$(kubectl exec -n "$NAMESPACE" "deploy/inference-${INFERENCE_PROFILE}" -- \
    cat /sys/fs/cgroup/memory.peak 2>/dev/null | tr -d '[:space:]' || true)"
  printf '   inference metrics: first-token(prefill)=%sms  sustained=%s tok/s  mem-peak=%s bytes\n' \
    "${prompt_ms:-n/a}" "${rate:-n/a}" "${mem:-n/a}"
}

# Adding a row admits an identity and removing it revokes,
# both without a pod restart. The relay logs each delivery it applies with
# the resulting table size (rows=N), so a new delivery line whose rows count
# moved is direct evidence the live table changed. Line counts scope the
# wait to deliveries after each patch; the startup delivery can't match.
step_6_grant_row_hot_reload() {
  step "Grant row hot reload"
  local before after count0 rows0 count1

  grants_deliveries() {
    kubectl logs deploy/relay-controller -n "$NAMESPACE" 2>/dev/null \
      | grep -c '"message":"grants delivery applied"'
  }
  grants_last_rows() {
    kubectl logs deploy/relay-controller -n "$NAMESPACE" 2>/dev/null \
      | grep '"message":"grants delivery applied"' | tail -1 \
      | grep -o '"rows":[0-9]*' | cut -d: -f2
  }

  before="$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=relay-controller \
    -o jsonpath='{.items[0].metadata.name}')"
  count0="$(grants_deliveries)"
  rows0="$(grants_last_rows)"
  if [ -z "$rows0" ]; then
    warn "no grants delivery in relay logs before the probe — watcher never synced"
    return 1
  fi

  kubectl patch configmap relay-access-grants -n "$NAMESPACE" --type=merge \
    -p '{"data":{"e2e-probe-row":"channel: app\nidentity: e2e-probe-identity\nworkspace: hello-world\n"}}' \
    >/dev/null
  if wait_for "relay applies the added row (rows $rows0 -> $((rows0 + 1)))" 60 \
       "[ \"\$(grants_deliveries)\" -gt $count0 ] && [ \"\$(grants_last_rows)\" -eq $((rows0 + 1)) ]"; then
    ok "Added row applied without a restart (rows=$((rows0 + 1)))"
  else
    warn "relay never applied the added grant row"
    return 1
  fi

  count1="$(grants_deliveries)"
  kubectl patch configmap relay-access-grants -n "$NAMESPACE" --type=json \
    -p '[{"op":"remove","path":"/data/e2e-probe-row"}]' >/dev/null
  if wait_for "relay applies the removal (rows back to $rows0)" 60 \
       "[ \"\$(grants_deliveries)\" -gt $count1 ] && [ \"\$(grants_last_rows)\" -eq $rows0 ]"; then
    ok "Removed row left the live table (rows=$rows0)"
  else
    warn "relay never applied the row removal — revocation did not land"
    return 1
  fi

  after="$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=relay-controller \
    -o jsonpath='{.items[0].metadata.name}')"
  if [ "$before" != "$after" ]; then
    warn "relay pod restarted during the hot-reload probe ($before -> $after)"
    return 1
  fi
  ok "Hot reload completed with no relay restart"
}

# ---- step 7: syco upgrade via the CLI ----
# Exercises the operator upgrade path: it re-extracts the binary's charts and
# re-provisions the main tenant from its provision command, so this is the only
# coverage that `syco upgrade` actually delivers the binary's charts. Wiping the config-root charts first is the regression guard: an upgrade
# that skips the chart re-extract has nothing to apply and fails here.
step_7_upgrade_cli() {
  step "Step 7: syco upgrade (CLI chart delivery)"

  cargo build --release -p syco >/dev/null
  local syco="$REPO_ROOT/target/release/syco"

  rm -rf "${SYCO_CONFIG_DIR}/charts"

  if "$syco" upgrade; then
    ok "syco upgrade succeeded (re-extracted charts + applied cluster + tenant)"
  else
    warn "syco upgrade FAILED — CLI did not deliver its embedded charts"
    return 1
  fi

  if [ -f "${SYCO_CONFIG_DIR}/charts/sycophant-cluster/Chart.yaml" ]; then
    ok "config-root charts re-extracted from the binary"
  else
    warn "syco upgrade left the config-root charts missing"
    return 1
  fi
}

# ---- OIDC write-path proof ----
# A token from a generic (non-Dex) issuer fixture mints a store credential that
# writes, and the store reaches that issuer and nothing else.
#
# OIDC_WRITE_ROLE_ARN  the roles[] entry the fixture token assumes; the rendered
#                      -s3.iam.config roleMapping maps this issuer to it.
# The issuer carries :8080 so the iss claim, the discovery jwks_uri, the JWKS
# fetch, the fixture Service, and the egress port all resolve to one port.
OIDC_WRITE_ROLE_ARN="${OIDC_WRITE_ROLE_ARN:-arn:aws:iam::role/instructions-writer}"
OIDC_FIXTURE_AUDIENCE="${OIDC_FIXTURE_AUDIENCE:-sycophant-objectstore}"
OIDC_FIXTURE_SUBJECT="${OIDC_FIXTURE_SUBJECT:-e2e-writer}"
OIDC_FIXTURE_ISSUER="http://oidc-fixture.sycophant-system.svc.cluster.local:8080"

# Apiserver-trusted issuer for the per-identity cluster-identity proof: the
# bundled Dex. A separate trust root from the object-store issuer above: the
# apiserver only accepts an https issuer, and k3s runs kube-apiserver in the
# node netns with no CoreDNS, so Dex is published on a pinned NodePort the
# apiserver reaches at the node loopback. The self-signed serving cert and the
# rendered AuthenticationConfiguration are generated at boot into
# tmp/oidc-apiserver and mounted into the apiserver; the same cert is handed to
# Dex as its TLS listener, so both ends share one CA.
APISERVER_OIDC_NS="sycophant-system"
# Dex is published on this pinned NodePort so the apiserver reaches its
# discovery and JWKS at the node loopback.
APISERVER_OIDC_NODEPORT=30443
# Dex serves discovery and JWKS under the /dex path.
APISERVER_OIDC_ISSUER="https://127.0.0.1:${APISERVER_OIDC_NODEPORT}/dex"
APISERVER_OIDC_AUDIENCE="sycophant-cluster"
APISERVER_OIDC_DIR="$REPO_ROOT/tmp/oidc-apiserver"
# The identity sub each token carries; the apiserver prefixes it with the
# issuer to form the RoleBinding subject <issuer>#<sub>.
TENANT_A_USER_SUB="tenant-a-user"
TENANT_B_USER_SUB="tenant-b-user"
TENANT_B_NAMESPACE="${NAMESPACE}-b"

# Command contract. Command names and the label mirror the cluster
# chart's reactor policies. The reactor prefixes the bare tenant token with
# tenant-. The operator is authenticated by a second, non-Dex issuer (below).
LIFECYCLE_OPERATOR_SUB="operator-provisioner"
LIFECYCLE_TENANT_TOKEN="lifecycle-probe"
LIFECYCLE_TENANT_NS="tenant-${LIFECYCLE_TENANT_TOKEN}"
LIFECYCLE_WORKSPACE="hello-world"
LIFECYCLE_USER="${APISERVER_OIDC_ISSUER}#lifecycle-bound-user"
# Toolset names absent from the base install, so their ConfigMaps can only land
# via their provision commands.
LIFECYCLE_TOOLSET="lifecycle-tool"
LIFECYCLE_TOOLSET_2="lifecycle-tool-2"

# A second JWT issuer on its own loopback NodePort, trusted at boot
# (gen_second_issuer_trust) with the same username prefix as Dex, so the command
# contract is proven against an issuer the bundled Dex never signed.
APISERVER_OIDC2_NODEPORT=30444
APISERVER_OIDC2_ISSUER="https://127.0.0.1:${APISERVER_OIDC2_NODEPORT}"
APISERVER_OIDC2_AUDIENCE="sycophant-lifecycle"
APISERVER_OIDC2_KID="lifecycle-fixture-key"

# ---- syco inputs ----
# e2e drives the operator's real path through `syco`. Each SYCO_* input below
# defaults for e2e and may be overridden from the environment.
SYCO="$REPO_ROOT/target/release/syco"
# syco's config root for this run, so e2e never touches the operator's own
# ~/.config/sycophant. `syco setup` regenerates the Dex trust under it.
export SYCO_CONFIG_DIR="${SYCO_CONFIG_DIR:-$REPO_ROOT/tmp/syco-config}"
# Dex's operator login. The password persists for reuse runs against the same
# Dex and is regenerated with the cluster.
SYCO_PASSWORD_FILE="$REPO_ROOT/tmp/e2e-operator-password"
# The public Dex CA `syco setup` generated and the apiserver trusts.
SYCO_DEX_CA="$SYCO_CONFIG_DIR/oidc/ca.crt"
# The toolset image overrides e2e writes beside the example values.
VALUES_DIR="$SYCO_CONFIG_DIR/values"
export SYCO_EMAIL="${SYCO_EMAIL:-e2e-operator@sycophant.local}"
# Step 1 builds and loads the e2e image set itself.
export SYCO_SKIP_BUILD="${SYCO_SKIP_BUILD:-1}"
# The Cilium agent image comes from the host Docker cache, not a run-time pull.
export SYCO_CILIUM_PRELOAD="${SYCO_CILIUM_PRELOAD:-1}"
# Apiserver audit log and the relay's app port on the k3d load balancer.
export SYCO_K3D_ARGS="${SYCO_K3D_ARGS:---k3s-arg --kube-apiserver-arg=audit-policy-file=/etc/rancher/k3s/audit-policy.yaml@server:* --k3s-arg --kube-apiserver-arg=audit-log-path=/var/log/k3s-audit.log@server:* --k3s-arg --kube-apiserver-arg=audit-log-maxage=7@server:* -v $REPO_ROOT/docs/e2e/audit-policy.yaml:/etc/rancher/k3s/audit-policy.yaml@server:0 --port 9090:9090@loadbalancer}"
export SYCO_AUTH_CONFIG_APPEND="${SYCO_AUTH_CONFIG_APPEND:-$APISERVER_OIDC_DIR/second-issuer.yaml}"
export SYCO_KYVERNO_VALUES="${SYCO_KYVERNO_VALUES:-$REPO_ROOT/docs/e2e/kyverno-values.yaml}"
export SYCO_CLUSTER_VALUES="${SYCO_CLUSTER_VALUES:-$REPO_ROOT/docs/e2e/cluster-values.yaml}"

# Export SYCO_PASSWORD: the caller's, else the persisted one, else a new one.
syco_credentials() {
  if [ -z "${SYCO_PASSWORD:-}" ]; then
    if [ ! -s "$SYCO_PASSWORD_FILE" ]; then
      mkdir -p "$(dirname "$SYCO_PASSWORD_FILE")"
      ( umask 077; head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | cut -c1-24 > "$SYCO_PASSWORD_FILE" )
    fi
    SYCO_PASSWORD="$(cat "$SYCO_PASSWORD_FILE")"
  fi
  export SYCO_PASSWORD
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Write the JWKS ($4) and discovery document ($5) for issuer $3 whose RS256
# signing key is the PEM private key $1, published under kid $2.
write_issuer_docs() {
  local n
  n="$(openssl rsa -in "$1" -noout -modulus | sed 's/^Modulus=//' | xxd -r -p | b64url)"
  printf '{"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"%s","n":"%s","e":"AQAB"}]}\n' "$2" "$n" > "$4"
  printf '{"issuer":"%s","jwks_uri":"%s/.well-known/jwks.json"}\n' "$3" "$3" > "$5"
}

# Build a kubeconfig at $1 whose sole context (named $2) presents bearer token
# $3 to the current apiserver with its CA and no client cert. kubectl prefers a
# client cert over a token, so reusing the admin context would skip the OIDC path.
kubeconfig_with_token() {
  local kc="$1" name="$2" token="$3" server
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  kubectl config view --minify --raw \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
    | openssl base64 -d -A > "$kc.ca"
  [ -s "$kc.ca" ] || { warn "could not read the apiserver CA from the current kubeconfig"; exit 1; }
  KUBECONFIG="$kc" kubectl config set-cluster e2e \
    --server="$server" --certificate-authority="$kc.ca" --embed-certs=true >/dev/null
  KUBECONFIG="$kc" kubectl config set-credentials "$name" --token="$token" >/dev/null
  KUBECONFIG="$kc" kubectl config set-context "$name" --cluster=e2e --user="$name" >/dev/null
  KUBECONFIG="$kc" kubectl config use-context "$name" >/dev/null
}

# Mint a compact RS256 JWT: header (kid $1) + payload (iss $2, sub $3, aud $4,
# iat now, exp now+600s), signed by the PEM private key $5. Emits the token on
# stdout.
mint_rs256_jwt() {
  local kid="$1" iss="$2" sub="$3" aud="$4" keyfile="$5"
  local now exp header payload signing_input sig
  now="$(date +%s)"; exp="$(( now + 600 ))"
  header="$(printf '{"alg":"RS256","typ":"JWT","kid":"%s"}' "$kid" | b64url)"
  payload="$(printf '{"iss":"%s","sub":"%s","aud":"%s","iat":%s,"exp":%s}' \
    "$iss" "$sub" "$aud" "$now" "$exp" | b64url)"
  signing_input="${header}.${payload}"
  sig="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$keyfile" | b64url)"
  printf '%s.%s' "$signing_input" "$sig"
}

verify_oidc_write_path() {
  step "OIDC write-path proof"
  command -v python3 >/dev/null 2>&1 || { warn "python3 required for the OIDC proof"; exit 1; }

  local work; work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN

  # --- fixture keypair + discovery + JWKS ---
  openssl genrsa -out "$work/key.pem" 2048 >/dev/null 2>&1
  openssl rsa -in "$work/key.pem" -pubout -out "$work/pub.pem" >/dev/null 2>&1
  local kid="e2e-fixture-key"
  write_issuer_docs "$work/key.pem" "$kid" "$OIDC_FIXTURE_ISSUER" \
    "$work/jwks.json" "$work/openid-configuration.json"

  # Serve both documents from a ConfigMap through the pinned static-file server.
  kubectl create configmap oidc-fixture -n sycophant-system \
    --from-file=openid-configuration="$work/openid-configuration.json" \
    --from-file=jwks.json="$work/jwks.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # The fixture Deployment + Service (label app.kubernetes.io/name: oidc-fixture,
  # port 8080) serves the ConfigMap at /.well-known/. Reuse it if already applied;
  # otherwise this file is the contract for it.
  kubectl apply -n sycophant-system -f "$REPO_ROOT/scripts/fixtures/oidc-issuer.yaml" >/dev/null
  # Each run regenerates the keypair, so the served JWKS changes. Stamp a
  # checksum of the fixture ConfigMap onto the pod template: an unchanged content
  # is a no-op, a changed one rolls the fixture so it serves the new JWKS. This
  # replaces an unconditional rollout restart with a change-gated roll.
  local cfg_sum; cfg_sum="$(cat "$work/openid-configuration.json" "$work/jwks.json" | shasum -a 256 | cut -d' ' -f1)"
  kubectl patch deploy/oidc-fixture -n sycophant-system --type=merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"${cfg_sum}\"}}}}}" >/dev/null
  wait_for "oidc fixture ready" 120 \
    "kubectl get deploy oidc-fixture -n sycophant-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qx 1"

  # --- install the store pointed at the fixture, egress in-cluster ---
  local oidc_values; oidc_values="$(mktemp)"
  cat > "$oidc_values" <<EOF
oidc:
  issuer: ${OIDC_FIXTURE_ISSUER}
  clientId: ${OIDC_FIXTURE_AUDIENCE}
  egress:
    inCluster:
      endpointSelector:
        matchLabels:
          app.kubernetes.io/name: oidc-fixture
      port: 8080
EOF
  helm upgrade --install sycophant-objectstore "$REPO_ROOT/charts/sycophant-objectstore" \
    -n sycophant-system --set-string image=seaweedfs:local --set-string pullPolicy=Never \
    -f "$oidc_values" --wait >/dev/null
  kubectl rollout status deploy/seaweedfs -n sycophant-system --timeout=120s >/dev/null

  # --- mint an RS256 JWT signed by the fixture key ---
  local jwt
  jwt="$(mint_rs256_jwt "$kid" "$OIDC_FIXTURE_ISSUER" "$OIDC_FIXTURE_SUBJECT" \
    "$OIDC_FIXTURE_AUDIENCE" "$work/key.pem")"

  # --- reach the s3 gateway over the port-forward ---
  kubectl port-forward -n sycophant-system svc/seaweedfs "${S3_PF_PORT}:8333" >/dev/null 2>&1 &
  local pf_pid=$!
  trap 'kill '"$pf_pid"' 2>/dev/null || true; rm -rf "$work"' RETURN
  local endpoint="http://127.0.0.1:${S3_PF_PORT}"
  wait_for "s3 gateway reachable" 60 "curl -s -o /dev/null '${endpoint}'"

  # The token, presented to STS AssumeRoleWithWebIdentity, mints creds.
  local sts_out
  sts_out="$(aws sts assume-role-with-web-identity \
    --role-arn "$OIDC_WRITE_ROLE_ARN" \
    --role-session-name e2e-oidc-write \
    --web-identity-token "$jwt" \
    --endpoint-url "$endpoint" \
    --output json 2>"$work/sts.err")" || {
      warn "AssumeRoleWithWebIdentity did not return"; cat "$work/sts.err" >&2; exit 1; }
  local ak sk st
  ak="$(printf '%s' "$sts_out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])')"
  sk="$(printf '%s' "$sts_out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])')"
  st="$(printf '%s' "$sts_out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["Credentials"]["SessionToken"])')"
  [ -n "$ak" ] && [ -n "$sk" ] && [ -n "$st" ] || { warn "STS returned no temporary credentials"; exit 1; }
  ok "STS minted a short-lived credential from the fixture token"

  # The minted credential writes to the store.
  local obj; obj="$work/proof.txt"; echo "oidc-write-proof" > "$obj"
  AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" AWS_SESSION_TOKEN="$st" \
    aws s3 mb "s3://${INSTRUCTIONS_BUCKET}" --endpoint-url "$endpoint" >/dev/null 2>&1 || true
  AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" AWS_SESSION_TOKEN="$st" \
    aws s3 cp "$obj" "s3://${INSTRUCTIONS_BUCKET}/e2e/oidc-write-proof.txt" --endpoint-url "$endpoint" >/dev/null 2>"$work/put.err" || {
      warn "write with the minted credential was rejected"; cat "$work/put.err" >&2; exit 1; }
  ok "the minted credential wrote to ${INSTRUCTIONS_BUCKET}"

  # The store reaches the issuer and no other external destination.
  # Positive reach: the STS call above succeeded, which required the store to
  # fetch the fixture JWKS to verify the token — proof the issuer peer is open.
  # Negative control: exec in the REAL store container, not a kubectl-debug
  # ephemeral container — the debugger bypasses the pod's Cilium egress and gives
  # a false 'reachable'. DNS is allowed so example.org resolves; the egress lock
  # drops the TCP, so wget times out (non-zero exit).
  if kubectl exec -n sycophant-system deploy/seaweedfs -c seaweedfs -- \
    wget -T6 -t1 -qO- http://example.org >/dev/null 2>&1; then
    warn "store reached a non-issuer external host (example.org) — egress lock open"; exit 1
  fi
  ok "store egress to a non-issuer external host is denied"
  ok "OIDC write-path proof passed"
}

# Sign a JWT with Dex's active signing key so it validates against Dex's JWKS.
# Reads the private JWK from the openid-connect-keys SigningKey singleton Dex's
# storage created, and emits a compact token carrying Dex's issuer, the
# apiserver audience, and the given sub. Identity is the sub alone; no groups
# claim is set.
mint_dex_token() {
  local sub="$1"
  kubectl get signingkeies openid-connect-keys -n "$APISERVER_OIDC_NS" -o json \
    | ISS="$APISERVER_OIDC_ISSUER" AUD="$APISERVER_OIDC_AUDIENCE" SUB="$sub" python3 -c '
import json, os, sys, time
import jwt
from jwt.algorithms import RSAAlgorithm
sk = json.load(sys.stdin)["signingKey"]
key = RSAAlgorithm.from_jwk(json.dumps(sk))
now = int(time.time())
sys.stdout.write(jwt.encode(
    {"iss": os.environ["ISS"], "sub": os.environ["SUB"],
     "aud": os.environ["AUD"], "iat": now, "exp": now + 600},
    key, algorithm="RS256", headers={"kid": sk["kid"]}))
'
}

# ---- per-identity cluster-identity isolation proof ----
# Live proof that a user's issuer-prefixed identity can create a configmap in
# its own tenant namespace and cannot in another tenant's namespace, that a
# system:-prefixed sub is refused authentication, and that no per-identity
# binding is minted at login. Installs the bundled Dex on the node-reachable
# NodePort the apiserver already trusts (its TLS is the boot cert), mints two
# tokens signed with Dex's active signing key, and runs the checks.
verify_user_isolation() {
  step "Per-identity cluster-identity isolation proof"
  command -v python3 >/dev/null 2>&1 || { warn "python3 required for the identity proof"; exit 1; }

  [ -s "$SYCO_DEX_CA" ] \
    || { warn "apiserver OIDC trust material missing at ${SYCO_DEX_CA}; boot the cluster with --clean first"; exit 1; }

  local work; work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN

  # `syco setup` installed the bundled Dex on the pinned NodePort the apiserver
  # trusts, with its own TLS cert.
  wait_for "bundled Dex ready" 120 \
    "kubectl get deploy sycophant-dex -n $APISERVER_OIDC_NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qx 1"
  # Dex creates its signing key singleton on first serve; wait for it before
  # reading the key to sign tokens.
  wait_for "Dex signing key" 60 \
    "kubectl get signingkeies openid-connect-keys -n $APISERVER_OIDC_NS >/dev/null 2>&1"

  # A second tenant bound to a DIFFERENT identity, so the cross-tenant target
  # exists and carries its own per-identity binding. Both come from provision
  # commands, the same path as the main tenant. A bare namespace left by an
  # older run would block the provision, so it is cleared first.
  if kubectl get namespace "$TENANT_B_NAMESPACE" >/dev/null 2>&1 \
     && ! kubectl get namespace "$TENANT_B_NAMESPACE" \
       -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -qx sycophant-tenant; then
    kubectl delete namespace "$TENANT_B_NAMESPACE" --timeout=300s >/dev/null
  fi
  "$SYCO" tenant up -f "$REPO_ROOT/examples/tenants/e2e-test.yaml" \
    --set "tenant.name=${TENANT_B_NAMESPACE#tenant-}" --set tenant.capacity=512Mi
  "$SYCO" user up -f "$REPO_ROOT/examples/users/alice.yaml" --set "user.tenant=${TENANT_B_NAMESPACE#tenant-}" \
    --set "user.subject=${APISERVER_OIDC_ISSUER}#${TENANT_B_USER_SUB}"
  ok "tenant ${TENANT_B_NAMESPACE} provisioned and bound to ${TENANT_B_USER_SUB}"

  # Two Dex-signed tokens: a positive one whose sub is tenant A's bound
  # identity, and a negative one whose sub carries the reserved system: prefix.
  local token systoken
  token="$(mint_dex_token "$TENANT_A_USER_SUB")"
  systoken="$(mint_dex_token "system:masters")"

  local user_identity="${APISERVER_OIDC_ISSUER}#${TENANT_A_USER_SUB}"

  # The set of RoleBindings in the tenant namespace before any authentication.
  # Login must mint nothing, so this set must be unchanged after the checks.
  local rb_before
  rb_before="$(kubectl get rolebindings -n "$NAMESPACE" -o name 2>/dev/null | sort)"

  local ukube="$work/user.kubeconfig"
  kubeconfig_with_token "$ukube" user "$token"

  # Authn: the token must authenticate as the issuer-prefixed identity. The
  # apiserver's OIDC authenticator initializes lazily on first token use: it
  # needs the discovery/JWKS endpoint reachable, then a few seconds to finish,
  # and answers "authenticator not initialized" / 401 until it does. Poll
  # whoami until the identity appears, treating those transient answers as
  # retry, and fail only when the budget is spent.
  wait_for "user token OIDC authenticator initialized" 60 \
    "kubectl --kubeconfig='$ukube' auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null | grep -qFx '$user_identity'" \
    || { warn "user token did not authenticate as ${user_identity} within the init window (last: $(kubectl --kubeconfig="$ukube" auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || echo 401/none))"; exit 1; }
  ok "user token authenticated as ${user_identity}"

  # A member holds no control-plane verbs. It cannot create a configmap in
  # its own tenant namespace, so it cannot self-drop a command. Every
  # command is written by the operator that holds the cluster credential.
  local can_a
  can_a="$(kubectl --kubeconfig="$ukube" auth can-i create configmaps -n "$NAMESPACE" 2>/dev/null || true)"
  [ "$can_a" = "no" ] \
    || { warn "user could create configmaps in its own tenant namespace ${NAMESPACE} (got: ${can_a:-none}); a member must hold no control-plane verbs"; exit 1; }
  ok "user cannot create configmaps in its own tenant namespace"

  # Cross-tenant is denied the same way, so no member reaches another tenant.
  local can_b
  can_b="$(kubectl --kubeconfig="$ukube" auth can-i create configmaps -n "$TENANT_B_NAMESPACE" 2>/dev/null || true)"
  [ "$can_b" = "no" ] \
    || { warn "user could create configmaps in another tenant namespace ${TENANT_B_NAMESPACE} (got: ${can_b:-none}); isolation breached"; exit 1; }
  ok "user cannot create configmaps in another tenant namespace"

  # A system:-prefixed sub is refused at authentication: the issuer prefix bars
  # it structurally and the claimValidationRules guard rejects the raw claim.
  KUBECONFIG="$ukube" kubectl config set-credentials user --token="$systoken" >/dev/null
  local sysout
  if sysout="$(kubectl --kubeconfig="$ukube" auth whoami -o jsonpath='{.status.userInfo.username}' 2>&1)"; then
    warn "a system: token authenticated as ${sysout}; the reserved-prefix guard did not fire"; exit 1
  fi
  ok "a system: token is refused at authentication"

  # No login-time mint: authentication created no RoleBinding, and the only
  # binding naming the user identity is the user provision command's
  # provision-identity-<hash> binding.
  local rb_after
  rb_after="$(kubectl get rolebindings -n "$NAMESPACE" -o name 2>/dev/null | sort)"
  [ "$rb_before" = "$rb_after" ] \
    || { warn "a RoleBinding appeared in ${NAMESPACE} around authentication; login-time mint suspected"; exit 1; }
  local rb_naming
  rb_naming="$(kubectl get rolebindings -n "$NAMESPACE" -o json 2>/dev/null \
    | IDENT="$user_identity" python3 -c 'import json, os, sys
d = json.load(sys.stdin); ident = os.environ["IDENT"]
print("\n".join(rb["metadata"]["name"] for rb in d["items"]
      if any(s.get("kind") == "User" and s.get("name") == ident
             for s in rb.get("subjects") or [])))')"
  local user_rb; user_rb="provision-identity-$(handle_of "$user_identity")"
  [ "$rb_naming" = "$user_rb" ] \
    || { warn "user identity ${user_identity} is named by RoleBinding(s) other than ${user_rb}: ${rb_naming:-none}"; exit 1; }
  ok "no per-identity binding minted at login; the user provision command's ${user_rb} binding is the only grant"

  ok "per-identity cluster-identity isolation proof passed"
}

# Publish the second issuer's discovery + JWKS over HTTPS on its NodePort, using
# the boot-time TLS cert the apiserver trusts, so the apiserver can fetch and
# verify a token this issuer signed. Mirrors the object-store OIDC fixture's
# static-file serving (verify_oidc_write_path), on a TLS NodePort like the
# bundled Dex. The apiserver node netns has no CoreDNS, so the ClusterIP
# object-store fixture cannot serve here; this issuer is reached at the node
# loopback NodePort.
stand_up_second_issuer() {
  local work="$1" d="$APISERVER_OIDC_DIR"
  { [ -f "$d/oidc2-tls.crt" ] && [ -f "$d/oidc2-sign.key" ]; } \
    || { warn "second-issuer trust material missing under ${d}; boot the cluster with --clean first"; exit 1; }

  write_issuer_docs "$d/oidc2-sign.key" "$APISERVER_OIDC2_KID" "$APISERVER_OIDC2_ISSUER" \
    "$work/oidc2-jwks.json" "$work/oidc2-discovery.json"

  kubectl create configmap oidc2-fixture -n "$APISERVER_OIDC_NS" \
    --from-file=openid-configuration="$work/oidc2-discovery.json" \
    --from-file=jwks.json="$work/oidc2-jwks.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret tls oidc2-fixture-tls -n "$APISERVER_OIDC_NS" \
    --cert="$d/oidc2-tls.crt" --key="$d/oidc2-tls.key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  local jwks_sum; jwks_sum="$(shasum -a 256 "$work/oidc2-jwks.json" | cut -d' ' -f1)"
  kubectl apply -n "$APISERVER_OIDC_NS" -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oidc2-fixture
  labels: { app.kubernetes.io/name: oidc2-fixture }
spec:
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: oidc2-fixture }
  template:
    metadata:
      labels: { app.kubernetes.io/name: oidc2-fixture }
      annotations: { checksum/jwks: "${jwks_sum}" }
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: static-server
          # Same pinned static-web-server the object-store OIDC fixture uses,
          # here fronted with TLS so the apiserver fetches discovery over HTTPS.
          image: joseluisq/static-web-server@sha256:c6704bc8f1fe05378d91c3288495ce2e0131cf31cf8956f117cb1c7d83c49c31
          args:
            - --port=8443
            - --root=/public
            - --ignore-hidden-files=false
            - --disable-symlinks=false
            - --http2=true
            - --http2-tls-cert=/tls/tls.crt
            - --http2-tls-key=/tls/tls.key
          ports: [ { name: https, containerPort: 8443 } ]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          readinessProbe:
            httpGet: { path: /.well-known/openid-configuration, port: 8443, scheme: HTTPS }
            initialDelaySeconds: 1
            periodSeconds: 2
          volumeMounts:
            - { name: well-known, mountPath: /public/.well-known, readOnly: true }
            - { name: tls, mountPath: /tls, readOnly: true }
      volumes:
        - name: well-known
          configMap:
            name: oidc2-fixture
            items:
              - { key: openid-configuration, path: openid-configuration }
              - { key: jwks.json, path: jwks.json }
        - name: tls
          secret: { secretName: oidc2-fixture-tls }
---
apiVersion: v1
kind: Service
metadata:
  name: oidc2-fixture
  labels: { app.kubernetes.io/name: oidc2-fixture }
spec:
  type: NodePort
  selector: { app.kubernetes.io/name: oidc2-fixture }
  ports:
    - { name: https, port: 8443, targetPort: 8443, nodePort: ${APISERVER_OIDC2_NODEPORT} }
YAML
  wait_for "second issuer fixture ready" 120 \
    "kubectl get deploy oidc2-fixture -n $APISERVER_OIDC_NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qx 1"
}

# ---- tenant lifecycle command-contract proof ----
# Each command is admitted for an issuer-prefixed operator identity and refused
# for a standing ServiceAccount that holds the same RBAC, so the command VAP, not
# RBAC, is what tells them apart. Provision drives the tenant Namespace, quota,
# and base install; workspace, user, and toolset provision commands each drive
# one release; suspend scales the tenant down and stamps a reap TTL the reap
# policy acts on.

# The 10-hex handle of $1: a user provision command's name suffix, and the
# chart's per-user RoleBinding suffix.
handle_of() { printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-10; }

# Prove the identity gate on the kind $1 provision command rendered from the
# rest of the arguments (`syco <kind> up` values), sent with kubectl create: the
# standing SA ($sa_kube) is refused by command-provision-$1 on a real write, and
# the second issuer's identity ($op_kube), which Dex never signed, is admitted on
# a server dry-run so nothing is generated.
prove_gate() {
  local kind="$1" file="$work/${1}-command.yaml" err
  shift
  render_command "${kind}-provision" "$@" > "$file" || exit 1
  if err="$(kubectl --kubeconfig="$sa_kube" create -f "$file" 2>&1)"; then
    warn "a standing ServiceAccount wrote a ${kind} provision command; the ${kind} VAP failed open"; exit 1
  fi
  printf '%s' "$err" | grep -qi "command-provision-${kind}" \
    || { warn "SA ${kind} provision command was refused, but not by the ${kind} identity VAP: ${err}"; exit 1; }
  ok "a standing ServiceAccount credential cannot write a ${kind} provision command"
  kubectl --kubeconfig="$op_kube" create --dry-run=server -f "$file" >/dev/null \
    || { warn "the ${kind} VAP refused an IdP identity Dex never signed"; exit 1; }
  ok "${kind} provision command admitted for an IdP identity Dex never signed"
}

# The lifecycle workspace's harness pod name and Deployment generation, which a
# live toolset add must leave unchanged.
harness_identity() {
  printf '%s/%s' \
    "$(kubectl get pods -n "$LIFECYCLE_TENANT_NS" \
      -l "app.kubernetes.io/component=harness,sycophant.md/workspace=${LIFECYCLE_WORKSPACE}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" \
    "$(kubectl get deploy "$LIFECYCLE_WORKSPACE" -n "$LIFECYCLE_TENANT_NS" \
      -o jsonpath='{.metadata.generation}' 2>/dev/null)"
}

# The digest image the lifecycle toolset provision command for toolset $1
# carries. No tool is called, so nothing pulls it.
lifecycle_toolset_image() {
  printf 'registry.local/%s@sha256:%064d' "$1" 0
}

# Write the values for toolset $1 to $work.
toolset_values() {
  cat > "$work/toolset-$1.yaml" <<YAML
toolset:
  name: $1
  tenant: ${LIFECYCLE_TENANT_TOKEN}
  image: $(lifecycle_toolset_image "$1")
  tools:
    tool.$1-status.description: Report status.
YAML
}

verify_tenant_lifecycle() {
  step "Tenant lifecycle command-contract proof"
  command -v python3 >/dev/null 2>&1 || { warn "python3 required for the lifecycle proof"; exit 1; }

  # The user provision command and the chart's per-user RoleBinding are both
  # suffixed with the subject's handle.
  local user_handle
  user_handle="$(handle_of "$LIFECYCLE_USER")"

  local work; work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN

  # Start from nothing, so the proof covers a first provision. A prior run's
  # installer outlives its reap TTL.
  kubectl delete configmap provision-tenant -n sycophant-system --ignore-not-found >/dev/null
  kubectl delete namespace "$LIFECYCLE_TENANT_NS" --ignore-not-found --timeout=300s >/dev/null

  local operator_identity="${APISERVER_OIDC_ISSUER}#${LIFECYCLE_OPERATOR_SUB}"
  kubectl create role lifecycle-command-writer -n sycophant-system \
    --verb=create --resource=configmaps --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create serviceaccount lifecycle-standing-sa -n sycophant-system \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create rolebinding lifecycle-command-writer -n sycophant-system \
    --role=lifecycle-command-writer --user="$operator_identity" \
    --serviceaccount=sycophant-system:lifecycle-standing-sa \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  local sa_token sa_kube="$work/sa.kubeconfig"
  sa_token="$(kubectl create token lifecycle-standing-sa -n sycophant-system --duration=10m)"
  kubeconfig_with_token "$sa_kube" sa "$sa_token"

  stand_up_second_issuer "$work"
  local op_token op_kube="$work/operator.kubeconfig"
  op_token="$(mint_rs256_jwt "$APISERVER_OIDC2_KID" "$APISERVER_OIDC2_ISSUER" "$LIFECYCLE_OPERATOR_SUB" \
    "$APISERVER_OIDC2_AUDIENCE" "$APISERVER_OIDC_DIR/oidc2-sign.key")"
  kubeconfig_with_token "$op_kube" op "$op_token"
  # The apiserver OIDC authenticator initializes lazily.
  wait_for "operator token OIDC authenticator initialized" 60 \
    "kubectl --kubeconfig='$op_kube' auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null | grep -qFx '$operator_identity'" \
    || { warn "operator token did not authenticate as ${operator_identity}"; exit 1; }

  local tenant_values=(-f "$REPO_ROOT/examples/tenants/e2e-test.yaml"
    --set "tenant.name=$LIFECYCLE_TENANT_TOKEN" --set tenant.capacity=512Mi)
  prove_gate tenant "${tenant_values[@]}"

  # The operator's real path: syco writes the tenant provision command under its
  # Dex login and waits on its installer Job, failing loudly on a refused
  # command or a failed Job.
  syco_credentials
  "$SYCO" tenant up "${tenant_values[@]}"
  ok "syco tenant up: tenant provision command admitted for the operator's Dex identity; its installer Job succeeded"

  wait_for "tenant namespace generated" 120 \
    "kubectl get namespace '$LIFECYCLE_TENANT_NS' >/dev/null 2>&1"
  wait_for "tenant capacity quota generated" 120 \
    "kubectl get resourcequota '${LIFECYCLE_TENANT_NS}-capacity' -n '$LIFECYCLE_TENANT_NS' >/dev/null 2>&1"
  kubectl get namespace "$LIFECYCLE_TENANT_NS" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -qx sycophant-tenant \
    || { warn "generated namespace lacks the part-of=sycophant-tenant label"; exit 1; }
  ok "provision generated the tenant namespace and capacity quota"

  wait_for "tenant helm release deployed" 120 \
    "release_deployed '$LIFECYCLE_TENANT_NS' '$LIFECYCLE_TENANT_NS'"
  wait_for "relay-controller Deployment Available" 180 \
    "kubectl get deploy relay-controller -n '$LIFECYCLE_TENANT_NS' -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -qx 1"
  ok "tenant helm release deployed and relay-controller is Available"

  # The workspace harness reads the instructions-reader Secret, which the
  # provision path does not produce, so seed it the way the main tenant is
  # seeded.
  provision_instructions_content "$LIFECYCLE_WORKSPACE" "$LIFECYCLE_TENANT_NS"

  # One writer Role covers the workspace, user, and toolset provision commands.
  kubectl create role workspace-command-writer -n "$LIFECYCLE_TENANT_NS" \
    --verb=create,update,get --resource=configmaps --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create rolebinding workspace-command-writer -n "$LIFECYCLE_TENANT_NS" \
    --role=workspace-command-writer --user="$operator_identity" \
    --serviceaccount=sycophant-system:lifecycle-standing-sa \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # Each provision command is refused for the standing SA and admitted (dry-run)
  # for the second issuer's identity, then syco applies it under its Dex login.
  cat > "$work/workspace.yaml" <<YAML
workspace:
  name: ${LIFECYCLE_WORKSPACE}
  tenant: ${LIFECYCLE_TENANT_TOKEN}
  toolsets: [stdlib, workspace-ro]
YAML
  local user_values=(-f "$REPO_ROOT/examples/users/alice.yaml"
    --set "user.tenant=$LIFECYCLE_TENANT_TOKEN" --set "user.subject=$LIFECYCLE_USER")
  prove_gate workspace -f "$work/workspace.yaml"
  prove_gate user "${user_values[@]}"
  "$SYCO" workspace up -f "$work/workspace.yaml"
  "$SYCO" user up "${user_values[@]}"
  local m
  for m in "provision-workspace-${LIFECYCLE_WORKSPACE}" "provision-user-${user_handle}"; do
    kubectl get configmap "$m" -n "$LIFECYCLE_TENANT_NS" >/dev/null 2>&1 \
      && { warn "provision command ${m} survived a successful install"; exit 1; }
  done
  ok "the workspace and user installers deleted their provision commands"

  wait_for "workspace helm release deployed" 120 \
    "release_deployed 'workspace-${LIFECYCLE_WORKSPACE}' '$LIFECYCLE_TENANT_NS'"
  kubectl get deploy "$LIFECYCLE_WORKSPACE" -n "$LIFECYCLE_TENANT_NS" >/dev/null 2>&1 \
    || { warn "workspace harness Deployment was not created"; exit 1; }
  kubectl get configmap "relay-toolset-grants-${LIFECYCLE_WORKSPACE}" -n "$LIFECYCLE_TENANT_NS" \
    -o jsonpath='{.metadata.labels.sycophant\.md/type}' 2>/dev/null | grep -qx relay-toolset-grants \
    || { warn "per-workspace relay-toolset-grants ConfigMap missing or unlabeled"; exit 1; }
  ok "workspace release deployed; per-workspace object set installed in render=workspace mode"

  # The harness's one init container, instructions-sync, rclone-syncs the
  # instructions prefix; a clean exit proves the store sync end to end.
  wait_for "harness instructions-sync init container completed" 180 \
    "kubectl get pods -n '$LIFECYCLE_TENANT_NS' -l 'app.kubernetes.io/component=harness,sycophant.md/workspace=${LIFECYCLE_WORKSPACE}' -o jsonpath='{.items[0].status.initContainerStatuses[0].state.terminated.exitCode}' 2>/dev/null | grep -qx 0"
  kubectl get pods -n "$LIFECYCLE_TENANT_NS" \
    -l "app.kubernetes.io/component=harness,sycophant.md/workspace=${LIFECYCLE_WORKSPACE}" \
    -o jsonpath='{.items[0].status.initContainerStatuses[0].name}' 2>/dev/null | grep -qx instructions-sync \
    || { warn "the harness first init container is not instructions-sync; the exit-0 check inspected the wrong container"; exit 1; }
  ok "harness instructions-sync init container (rclone) synced and exited 0"

  # The base release's install-wait hook holds its installer Job until the
  # relay-controller is Available, so it is serving before the workspace
  # provision command and merges the new grants live.
  wait_for "relay-controller served the new workspace grants live" 60 \
    "kubectl logs -n '$LIFECYCLE_TENANT_NS' -l app.kubernetes.io/name=relay-controller --tail=80 2>/dev/null | grep -E 'toolset-grants delivery applied.*\"configmaps\":[1-9]' -q"
  ok "relay-controller merged the workspace grants without a pod roll"

  wait_for "user helm release deployed" 120 \
    "release_deployed 'user-${user_handle}' '$LIFECYCLE_TENANT_NS'"
  kubectl get rolebinding "provision-identity-${user_handle}" -n "$LIFECYCLE_TENANT_NS" \
    -o jsonpath='{.roleRef.kind}/{.roleRef.name}' 2>/dev/null | grep -qx ClusterRole/provision-identity \
    || { warn "per-user provision-identity RoleBinding missing or wrong roleRef"; exit 1; }
  kubectl get rolebinding "provision-identity-${user_handle}" -n "$LIFECYCLE_TENANT_NS" \
    -o jsonpath='{.subjects[0].kind}/{.subjects[0].name}' 2>/dev/null | grep -qFx "User/${LIFECYCLE_USER}" \
    || { warn "per-user provision-identity RoleBinding does not bind ${LIFECYCLE_USER}"; exit 1; }
  ok "user release deployed; per-user provision-identity RoleBinding binds the identity in render=user mode"

  # Two toolsets, one provision command each. The harness merges each per-toolset
  # ConfigMap by watch, so its pod and Deployment generation must not change.
  local harness_before ts n=0
  harness_before="$(harness_identity)"
  [ -n "${harness_before%/*}" ] || { warn "no lifecycle harness pod before the toolset add"; exit 1; }
  for ts in "$LIFECYCLE_TOOLSET" "$LIFECYCLE_TOOLSET_2"; do
    n=$((n + 1))
    toolset_values "$ts"
    prove_gate toolset -f "$work/toolset-${ts}.yaml"
    "$SYCO" toolset up -f "$work/toolset-${ts}.yaml"
    kubectl get configmap "provision-toolset-${ts}" -n "$LIFECYCLE_TENANT_NS" >/dev/null 2>&1 \
      && { warn "toolset provision command ${ts} survived a successful install"; exit 1; }

    wait_for "toolset ${ts} helm release deployed" 120 \
      "release_deployed 'toolset-${ts}' '$LIFECYCLE_TENANT_NS'"
    kubectl get configmap "toolset-${ts}" -n "$LIFECYCLE_TENANT_NS" \
      -o jsonpath='{.metadata.labels.sycophant\.md/type}' 2>/dev/null | grep -qx toolset \
      || { warn "per-toolset ConfigMap for ${ts} missing or not labelled sycophant.md/type=toolset"; exit 1; }
    kubectl get configmap "toolset-${ts}" -n "$LIFECYCLE_TENANT_NS" \
      -o "jsonpath={.data.image}" 2>/dev/null | grep -qFx "$(lifecycle_toolset_image "$ts")" \
      || { warn "per-toolset ConfigMap for ${ts} does not carry the provision command's data"; exit 1; }

    wait_for "harness merged toolset set=${n} by watch" 120 \
      "kubectl logs deploy/${LIFECYCLE_WORKSPACE} -n ${LIFECYCLE_TENANT_NS} -c harness --tail=200 2>/dev/null | grep -E 'toolset delivery applied.*\"configmaps\":${n},' -q"
    local harness_after; harness_after="$(harness_identity)"
    [ "$harness_before" = "$harness_after" ] \
      || { warn "harness pod or Deployment generation changed on toolset add (${harness_before} -> ${harness_after})"; exit 1; }
    ok "harness picked up toolset set=${n} live with no pod roll"
  done

  # --- suspend: scale tenant Deployments to zero, stamp the reap TTL.
  kubectl apply -n "$LIFECYCLE_TENANT_NS" -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lifecycle-workload
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lifecycle-workload
  template:
    metadata:
      labels:
        app: lifecycle-workload
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
YAML

  # `syco tenant down` suspends with no keepalive; `syco tenant remove`
  # re-writes the suspend command with keepalive 0.
  "$SYCO" tenant down "$LIFECYCLE_TENANT_TOKEN"
  wait_for "tenant deployments scaled to zero" 120 \
    "kubectl get deploy lifecycle-workload -n '$LIFECYCLE_TENANT_NS' -o jsonpath='{.spec.replicas}' 2>/dev/null | grep -qx 0" \
    || exit 1
  ok "syco tenant down scaled the tenant deployments to zero"
  "$SYCO" tenant remove "$LIFECYCLE_TENANT_TOKEN"
  wait_for "reap-after TTL stamped on the namespace" 120 \
    "kubectl get namespace '$LIFECYCLE_TENANT_NS' -o jsonpath='{.metadata.annotations.sycophant\.md/reap-after}' 2>/dev/null | grep -q ." \
    || exit 1
  ok "syco tenant remove stamped the reap TTL"

  # The e2e reap schedule is every minute (Kyverno's floor); allow a loaded node.
  wait_for "tenant namespace reaped" 720 \
    "! kubectl get namespace '$LIFECYCLE_TENANT_NS' >/dev/null 2>&1"
  ok "the zero-keepalive tenant namespace was reaped"

  ok "tenant lifecycle command-contract proof passed"
}

main() {
  # The operator path below runs through this checkout's syco.
  cargo build --release -p syco >/dev/null
  local cluster_exists=0
  if k3d cluster list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CLUSTER_NAME"; then
    cluster_exists=1
  fi

  if [ "$CLEAN" = "1" ]; then
    step "Clean run — fresh cluster + full image rebuild"
    CLEAN=1 "$REPO_ROOT/scripts/preflight.sh"
    step_0_bootstrap
    step_1_build
  elif [ "$cluster_exists" = "1" ]; then
    warn "Reusing cluster '$CLUSTER_NAME' + its loaded images (pass --clean to rebuild from scratch)"
    # Reuse still runs deploy, the proofs, and upgrade, so the runtime tools are
    # required; only the cross-build tier is not. Check them (CLEAN=0 skips musl).
    CLEAN=0 "$REPO_ROOT/scripts/preflight.sh"
    kubectl config use-context "k3d-$CLUSTER_NAME" >/dev/null 2>&1 \
      || { warn "could not switch kube-context to k3d-$CLUSTER_NAME — the k3d cluster exists but its kubeconfig context is missing; recreate with --clean"; exit 1; }
  else
    warn "No cluster '$CLUSTER_NAME' — bootstrapping once (later runs without --clean reuse it)"
    # First boot bootstraps and cross-compiles the images, so it needs the full
    # build tier even though the run was not invoked with --clean.
    CLEAN=1 "$REPO_ROOT/scripts/preflight.sh"
    step_0_bootstrap
    step_1_build
  fi

  syco_credentials
  step_3_deploy
  verify_user_isolation
  verify_tenant_lifecycle
  step_4_verify
  step_5_flutter
  step_6_security
  step_7_upgrade_cli
  verify_oidc_write_path
  printf '\n\033[1;32m==> e2e complete\033[0m\n'
  # Each helper installs a function-local `trap ... RETURN` to clean its temp
  # dir. Without functrace that trap stays installed after the helper returns
  # and would fire again on main's own return, when its `work` is out of scope
  # and set -u aborts. Clear it so main returns cleanly.
  trap - RETURN
}

main "$@"
