#!/usr/bin/env bash
# Step-0 preflight for the sycophant from-scratch build + e2e. Checks the host
# prerequisites that otherwise fail cryptically deep into the build, plus free
# disk, and prints one exact fix line per missing item (macOS + Linux). Exits
# nonzero if anything required is missing, so scripts/e2e.sh aborts before doing
# any expensive work. Safe to run standalone:  scripts/preflight.sh
#
# Tiers:
#   - always:      runtime + deploy toolchain, native build tools, free disk
#   - cross-build: musl cross-compile chain, only when CLEAN=1 (a reuse run
#                  keeps the loaded images and never cross-compiles)
#
# Env (shared with scripts/e2e.sh):
#   ARCH            target arch for the musl build (default aarch64)
#   CLEAN           1 on a from-scratch build (checks the cross-build tier)

set -uo pipefail

ARCH="${ARCH:-aarch64}"
readonly ARCH
RUST_TARGET="${ARCH}-unknown-linux-musl"
readonly RUST_TARGET
CROSS_LINKER="${ARCH}-linux-musl-gcc"
readonly CROSS_LINKER
CLEAN="${CLEAN:-0}"
readonly CLEAN

# Disk thresholds (GB).
VM_DISK_FAIL=8
readonly VM_DISK_FAIL
VM_DISK_WARN=15
readonly VM_DISK_WARN
HOST_DISK_WARN=20
readonly HOST_DISK_WARN

OS="$(uname -s)"   # Darwin | Linux
readonly OS
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

red()  { printf '\033[1;31m%s\033[0m' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m' "$*"; }
ylw()  { printf '\033[1;33m%s\033[0m' "$*"; }

MISSING=0

# need <label> <probe-cmd> <macos-fix> <linux-fix>
# Records a failure (with the OS-appropriate fix) when the probe fails.
need() {
  local label="$1" probe="$2" macfix="$3" linfix="$4"
  if eval "$probe" >/dev/null 2>&1; then
    printf '  %s %s\n' "$(grn '✓')" "$label"
  else
    local fix; [ "$OS" = "Darwin" ] && fix="$macfix" || fix="$linfix"
    printf '  %s %s\n      fix: %s\n' "$(red '✗')" "$label" "$fix"
    MISSING=$((MISSING + 1))
  fi
}

echo "==> sycophant preflight  (arch=${ARCH}, os=${OS})"

# ---- always: cluster + build tooling on PATH ----
echo "-- toolchain --"
need "docker (running)" "docker info" \
  "open Docker Desktop (or: brew install --cask docker)" \
  "install Docker Engine + start it: https://docs.docker.com/engine/install/"
need "k3d"     "command -v k3d"     "brew install k3d"      "curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
need "helm"    "command -v helm"    "brew install helm"     "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
need "kubectl" "command -v kubectl" "brew install kubectl"  "https://kubernetes.io/docs/tasks/tools/#kubectl"
need "cargo"   "command -v cargo"   "https://rustup.rs"     "https://rustup.rs"
need "protoc"  "command -v protoc"  "brew install protobuf" "apt-get install -y protobuf-compiler  (or: dnf install protobuf-compiler)"
need "cmake"   "command -v cmake"   "brew install cmake"    "apt-get install -y cmake  (or: dnf install cmake)"
need "jq"      "command -v jq"           "brew install jq"      "apt-get install -y jq  (or: dnf install jq)"
need "openssl" "command -v openssl"      "brew install openssl" "apt-get install -y openssl"
need "PyJWT"   "python3 -c 'import jwt'" "pip3 install pyjwt"   "pip3 install pyjwt  (or: apt-get install -y python3-jwt)"
# Step 5 drives the app path with grpcurl over the run's tailnet.
need "grpcurl"   "command -v grpcurl"   "brew install grpcurl"   "https://github.com/fullstorydev/grpcurl/releases"
need "tailscale" "command -v tailscale" "brew install tailscale" "curl -fsSL https://tailscale.com/install.sh | sh"

# ---- always: C toolchain (native link step) ----
if [ "$OS" = "Darwin" ]; then
  need "Xcode command-line tools" "xcode-select -p" \
    "xcode-select --install" "n/a"
else
  need "C compiler (cc)" "command -v cc" \
    "n/a" "apt-get install -y build-essential  (or: dnf groupinstall 'Development Tools')"
fi

# ---- cross-build: musl chain for ${RUST_TARGET}, only on a from-scratch build ----
# A reuse run keeps the images loaded in the cluster and never cross-compiles, so
# the musl chain is not a prerequisite there. Checking it would falsely fail a
# reuse run on a host that can still run every non-build step.
if [ "$CLEAN" = "1" ]; then
  echo "-- musl cross-build (${RUST_TARGET}) --"
  need "rustup target ${RUST_TARGET}" \
    "rustup target list --installed | grep -qx ${RUST_TARGET}" \
    "rustup target add ${RUST_TARGET}" \
    "rustup target add ${RUST_TARGET}"
  need "cross-linker ${CROSS_LINKER}" \
    "command -v ${CROSS_LINKER}" \
    "brew install messense/macos-cross-toolchains/${ARCH}-unknown-linux-musl" \
    "install a ${ARCH}-linux-musl cross toolchain (e.g. musl-cross) providing ${CROSS_LINKER}"
  # The target + compiler are useless to cargo without the linker wired in
  # ~/.cargo/config.toml; the build links against the host cc otherwise and fails.
  need "$HOME/.cargo/config.toml linker for ${RUST_TARGET}" \
    "grep -q 'target.${RUST_TARGET}' \"\${CARGO_HOME:-\$HOME/.cargo}/config.toml\"" \
    "add to $HOME/.cargo/config.toml:  [target.${RUST_TARGET}]\\n             linker = \"${CROSS_LINKER}\"" \
    "add to $HOME/.cargo/config.toml:  [target.${RUST_TARGET}]\\n             linker = \"${CROSS_LINKER}\""
else
  echo "-- musl cross-build: skipped (reuse run — images already loaded) --"
fi

# ---- disk ----
echo "-- disk --"
host_free_kb="$(df -Pk "$REPO_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${host_free_kb:-}" ]; then
  host_free_gb=$((host_free_kb / 1024 / 1024))
  if [ "$host_free_gb" -lt "$HOST_DISK_WARN" ]; then
    printf '  %s host free disk: %dGB (< %dGB; the ./target build is multi-GB)\n' "$(ylw '⚠')" "$host_free_gb" "$HOST_DISK_WARN"
  else
    printf '  %s host free disk: %dGB\n' "$(grn '✓')" "$host_free_gb"
  fi
fi
if docker info >/dev/null 2>&1; then
  vm_free_kb="$(docker run --rm busybox df -Pk / 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "${vm_free_kb:-}" ]; then
    vm_free_gb=$((vm_free_kb / 1024 / 1024))
    if [ "$vm_free_gb" -lt "$VM_DISK_FAIL" ]; then
      printf '  %s Docker VM free disk: %dGB (< %dGB — kubelet will evict; reclaim with `docker system prune -af`)\n' "$(red '✗')" "$vm_free_gb" "$VM_DISK_FAIL"
      MISSING=$((MISSING + 1))
    elif [ "$vm_free_gb" -lt "$VM_DISK_WARN" ]; then
      printf '  %s Docker VM free disk: %dGB (< %dGB; consider `docker system prune -af`)\n' "$(ylw '⚠')" "$vm_free_gb" "$VM_DISK_WARN"
    else
      printf '  %s Docker VM free disk: %dGB\n' "$(grn '✓')" "$vm_free_gb"
    fi
  fi
fi

echo
if [ "$MISSING" -gt 0 ]; then
  printf '%s %d required prerequisite(s) missing — fix the ✗ items above and re-run.\n' "$(red 'preflight failed:')" "$MISSING"
  exit 1
fi
printf '%s all required prerequisites present.\n' "$(grn 'preflight ok:')"
