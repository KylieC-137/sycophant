#!/usr/bin/env bash
# Offline acceptance suite for `sycoadm workspace up` and `workspace down`
# instructions delivery. Runs the built sycoadm binary as a black box with
# fakes on PATH: kubectl (records every argv and plays the built-in store's
# filer HTTP API behind `kubectl exec deploy/seaweedfs -- curl`, plus command
# writes), helm (`get values` only; renders run the real helm), and the host
# curl (the operator's IdP login). No cluster.
#
#   bash tests/unit/workspace-cli/acceptance.sh
#
# Builds sycoadm (debug) first unless SYCOADM names a binary.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
source "$HERE/../lib.sh"

if [ -z "${SYCOADM:-}" ]; then
  if ! (cd "$ROOT" && env CARGO_BUILD_JOBS=3 cargo build -q -p sycoadm >&2); then
    echo "cargo build -p sycoadm failed" >&2
    exit 1
  fi
  SYCOADM="$ROOT/target/debug/sycoadm"
fi
# run_cli runs the binary from each case's own directory, so a relative
# SYCOADM is resolved here, against the directory the suite was started from.
case "$SYCOADM" in
  /*) ;;
  *) SYCOADM="$PWD/$SYCOADM" ;;
esac
readonly SYCOADM
if [ ! -f "$SYCOADM" ] || [ ! -x "$SYCOADM" ]; then
  echo "SYCOADM=$SYCOADM is not an executable file" >&2
  exit 1
fi
REAL_HELM="$(command -v helm)"
readonly REAL_HELM
readonly IDENTITY="https://127.0.0.1:30443/dex#operator"
readonly BUCKET_PATH="buckets/sycophant-instructions"

SHIMS="$WORK/shims"
readonly SHIMS
mkdir -p "$SHIMS"
cp "$HERE/fake-kubectl" "$SHIMS/kubectl"
cp "$HERE/fake-helm" "$SHIMS/helm"
cp "$HERE/fake-curl" "$SHIMS/curl"
chmod +x "$SHIMS/kubectl" "$SHIMS/helm" "$SHIMS/curl"

# ---- helpers ----

# run_cli <state> <cwd> <sycoadm args...>: run sycoadm from <cwd> against the
# fakes, whose store and logs live under <state>. The store persists across
# runs in one <state>; the logs and written commands are per run. Exit status
# lands in <state>/rc (124 on a 120 s timeout), output in <state>/out.
run_cli() {
  local state="$1" cwd="$2"
  shift 2
  mkdir -p "$state/store" "$state/tmp" "$state/config"
  rm -rf "$state/commands"
  : > "$state/kubectl.log"
  : > "$state/events"
  local rc=0
  (
    cd "$cwd" || exit 1
    env PATH="$SHIMS:$PATH" FAKE_STATE="$state" FAKE_IDENTITY="$IDENTITY" \
      FAKE_CLUSTER_VALUES="$HERE/fixtures/cluster-values.json" REAL_HELM="$REAL_HELM" \
      SYCO_CONFIG_DIR="$state/config" TMPDIR="$state/tmp" \
      SYCO_EMAIL=op@example.com SYCO_PASSWORD=pw \
      python3 -c 'import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, timeout=120).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)' "$SYCOADM" "$@"
  ) > "$state/out" 2>&1 || rc=$?
  echo "$rc" > "$state/rc"
}

rc_of() { cat "$1/rc"; }

# The token subject and the store folder of workspace $3 in tenant $2.
sub_of() { printf 'system:serviceaccount:tenant-%s:ws-%s' "$1" "$2"; }
folder_of() { printf '%s/store/%s/%s' "$1" "$BUCKET_PATH" "$(sub_of "$2" "$3")"; }

# Sorted "sha256  relpath" lines for the regular files under $1 (empty when
# $1 is absent). Symlinks and other non-regular entries are skipped.
manifest() {
  python3 -c '
import hashlib, os, sys
root, out = sys.argv[1], []
if os.path.isdir(root):
    for d, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(d, f)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            out.append(hashlib.sha256(open(p, "rb").read()).hexdigest() + "  " + os.path.relpath(p, root))
print("\n".join(sorted(out)))' "$1"
}

# The number of `kubectl exec` calls into the store pod in the last run.
store_execs() {
  jq -s '[.[] | select((index("exec") != null) and (map(test("seaweedfs")) | any))] | length' "$1/kubectl.log"
}

# The value of data key $3 in the command the last run wrote as $2
# (<namespace>_<name>), or empty.
command_data() {
  python3 -c '
import os, sys, yaml
p = os.path.join(sys.argv[1], "commands", sys.argv[2] + ".yaml")
d = yaml.safe_load(open(p)) if os.path.exists(p) else {}
print(((d or {}).get("data") or {}).get(sys.argv[3], ""))' "$1" "$2" "$3"
}

# A nested instructions tree: AGENTS.md at the root, a file in a
# subdirectory, and a file whose bytes are not text and end without a newline.
make_tree() {
  mkdir -p "$1/agents"
  printf -- '---\nmodel: local\n---\n\nYou are the probe.\n' > "$1/AGENTS.md"
  printf 'Write a poem.\n' > "$1/agents/poet.md"
  printf 'bin\000\377end' > "$1/agents/raw.bin"
}

# A file left in workspace $3's store folder by an earlier upload.
seed_folder() {
  mkdir -p "$(folder_of "$1" "$2" "$3")/old"
  printf 'stale\n' > "$(folder_of "$1" "$2" "$3")/old/stale.md"
}

# A case: <dir>/vals holds probe.yaml and its tree; the store holds a stale
# file for probe and an unrelated sibling folder (probe2, acme).
new_case() {
  local dir="$1"
  mkdir -p "$dir/vals" "$dir/state" "$dir/elsewhere"
  cp "$HERE/fixtures/probe.yaml" "$HERE/fixtures/probe-nokey.yaml" "$dir/vals/"
  make_tree "$dir/vals/tree"
  seed_folder "$dir/state" acme probe
  seed_folder "$dir/state" acme probe2
}

# Every argv in the last run's kubectl log, checked for the admin-reach
# markers: no admin-key or IAM Secret, no port-forward. Prints offenders.
admin_reach() {
  jq -r 'select(map(test("seaweedfs-admin|seaweedfs-iam|port-forward")) | any) | join(" ")' "$1/kubectl.log"
}

# The last run's events must be: DELETE <folder>?recursive, a GET of the
# folder answering 404, then only PUTs into the folder, then the one command
# CREATE $3. $2 is the store folder path as the filer sees it.
order_problem() {
  python3 -c '
import sys
events = [l.split() for l in open(sys.argv[1] + "/events").read().splitlines()]
folder, create = "/" + sys.argv[2] + "/", sys.argv[3]
if not events or events[0][:2] != ["DELETE", folder]:
    print(f"first event must delete {folder}; got {events[:1]}"); sys.exit()
if len(events) < 2 or events[1] != ["GET", folder, "404"]:
    print(f"the delete must be followed by a GET of {folder} answering 404; got {events[1:2]}"); sys.exit()
mid = events[2:-1]
if any(e[0] != "PUT" or not e[1].startswith(folder) for e in mid):
    print(f"after the 404 check only uploads into {folder} may run; got {mid}"); sys.exit()
if events[-1] != ["CREATE", create]:
    print(f"the last event must be the command write {create}; got {events[-1]}")
' "$1" "$2" "$3"
}

# ---- tests ----

# A first `workspace up` replaces the probe folder with exactly the local
# tree, leaves the sibling folder alone, runs delete -> 404 -> uploads ->
# provision, and never reaches the admin key, the IAM Secret or a port-forward.
t_up_uploads_exact_tree() {
  local name="workspace up leaves the store folder holding exactly the local tree"
  local dir="$WORK/upload"
  new_case "$dir"
  local sibling; sibling="$(manifest "$(folder_of "$dir/state" acme probe2)")"
  run_cli "$dir/state" "$dir/vals" workspace up -f probe.yaml
  local got want order reach
  got="$(manifest "$(folder_of "$dir/state" acme probe)")"
  want="$(manifest "$dir/vals/tree")"
  order="$(order_problem "$dir/state" "$BUCKET_PATH/$(sub_of acme probe)" tenant-acme/provision-workspace-probe)"
  reach="$(admin_reach "$dir/state")"
  if [ "$(rc_of "$dir/state")" != 0 ]; then
    bad "$name" "exit $(rc_of "$dir/state"): $(tail -3 "$dir/state/out")"
  elif [ "$got" != "$want" ]; then
    bad "$name" "store folder $(sub_of acme probe)/ holds [${got//$'\n'/; }], want [${want//$'\n'/; }]"
  elif [ "$(manifest "$(folder_of "$dir/state" acme probe2)")" != "$sibling" ]; then
    bad "$name" "the sibling folder $(sub_of acme probe2)/ changed"
  elif [ -n "$order" ]; then
    bad "$name" "$order"
  elif [ -n "$reach" ]; then
    bad "$name" "reached the store admin key, its IAM Secret or a port-forward: $reach"
  else
    ok "$name"
  fi
}

# The provision command carries a 64-hex instructions-hash; the same files in
# another directory with other mtimes give the same hash, a changed byte
# another.
t_up_hash_rides_command() {
  local name="workspace up stamps an instructions-hash that tracks only file content and paths"
  local dir="$WORK/hash"
  new_case "$dir"
  mkdir -p "$dir/copy"
  cp "$dir/vals/probe.yaml" "$dir/copy/"
  cp -R "$dir/vals/tree" "$dir/copy/tree"
  touch -t 202001010000 "$dir/copy/tree/AGENTS.md" "$dir/copy/tree/agents/poet.md"
  local cmd=tenant-acme_provision-workspace-probe h1 h2 h3
  run_cli "$dir/state" "$dir/vals" workspace up -f probe.yaml
  h1="$(command_data "$dir/state" "$cmd" instructions-hash)"
  run_cli "$dir/state" "$dir/copy" workspace up -f probe.yaml
  h2="$(command_data "$dir/state" "$cmd" instructions-hash)"
  printf 'Write two poems.\n' > "$dir/copy/tree/agents/poet.md"
  run_cli "$dir/state" "$dir/copy" workspace up -f probe.yaml
  h3="$(command_data "$dir/state" "$cmd" instructions-hash)"
  if ! [[ "$h1" =~ ^[a-f0-9]{64}$ ]]; then
    bad "$name" "the provision command carries no 64-hex instructions-hash (got '${h1}'); exit $(rc_of "$dir/state")"
  elif [ "$h2" != "$h1" ]; then
    bad "$name" "unchanged files in another directory with other mtimes changed the hash ($h1 -> $h2)"
  elif [ "$h3" = "$h1" ] || [ -z "$h3" ]; then
    bad "$name" "a changed byte left the hash at $h1"
  else
    ok "$name"
  fi
}

# With no instructions key the seeded folder ends up empty.
t_up_without_key_empties_folder() {
  local name="workspace up with no instructions key leaves the store folder empty"
  local dir="$WORK/nokey"
  new_case "$dir"
  run_cli "$dir/state" "$dir/vals" workspace up -f probe-nokey.yaml
  local got; got="$(manifest "$(folder_of "$dir/state" acme probe)")"
  if [ "$(rc_of "$dir/state")" != 0 ]; then
    bad "$name" "exit $(rc_of "$dir/state"): $(tail -3 "$dir/state/out")"
  elif [ -n "$got" ]; then
    bad "$name" "store folder still holds [${got//$'\n'/; }]"
  else
    ok "$name"
  fi
}

# A relative instructions path resolves against the values file's
# directory, not the working directory (which holds a decoy tree).
t_up_relative_path_resolves_against_values_dir() {
  local name="a relative instructions path resolves against the values file's directory"
  local dir="$WORK/relative"
  new_case "$dir"
  mkdir -p "$dir/elsewhere/tree"
  printf 'decoy\n' > "$dir/elsewhere/tree/AGENTS.md"
  run_cli "$dir/state" "$dir/elsewhere" workspace up -f "$dir/vals/probe.yaml"
  local got want
  got="$(manifest "$(folder_of "$dir/state" acme probe)")"
  want="$(manifest "$dir/vals/tree")"
  if [ "$(rc_of "$dir/state")" != 0 ]; then
    bad "$name" "exit $(rc_of "$dir/state"): $(tail -1 "$dir/state/out")"
  elif [ "$got" != "$want" ]; then
    bad "$name" "store folder holds [${got//$'\n'/; }], want [${want//$'\n'/; }]"
  else
    ok "$name"
  fi
}

# --set workspace.name moves the upload to the rendered target's folder; the
# values file's own folder is unchanged.
t_up_set_moves_target() {
  local name="--set workspace.name uploads to the rendered target's folder only"
  local dir="$WORK/override"
  new_case "$dir"
  local before got want
  want="$(manifest "$dir/vals/tree")"
  before="$(manifest "$(folder_of "$dir/state" acme probe)")"
  run_cli "$dir/state" "$dir/vals" workspace up -f probe.yaml --set workspace.name=other
  got="$(manifest "$(folder_of "$dir/state" acme other)")"
  if [ "$(rc_of "$dir/state")" != 0 ]; then
    bad "$name" "exit $(rc_of "$dir/state"): $(tail -1 "$dir/state/out")"
  elif [ "$got" != "$want" ]; then
    bad "$name" "$(sub_of acme other)/ holds [${got//$'\n'/; }], want [${want//$'\n'/; }]"
  elif [ "$(manifest "$(folder_of "$dir/state" acme probe)")" != "$before" ]; then
    bad "$name" "the values file's own folder $(sub_of acme probe)/ changed"
  else
    ok "$name"
  fi
}

# expect_refused <label> <state> <cwd> <sycoadm args...>: the run must exit
# non-zero (not by timeout), make no store call, and leave the store as it
# was. Appends to the caller's `problems`.
expect_refused() {
  local label="$1" state="$2" cwd="$3"
  shift 3
  local before after rc
  before="$(manifest "$state/store")"
  run_cli "$state" "$cwd" "$@"
  after="$(manifest "$state/store")"
  rc="$(rc_of "$state")"
  if [ "$rc" = 0 ]; then
    problems+=("$label: exited 0")
  elif [ "$rc" = 124 ]; then
    problems+=("$label: hung (timed out)")
  elif [ "$(store_execs "$state")" != 0 ]; then
    problems+=("$label: made $(store_execs "$state") store call(s) before refusing")
  elif [ "$before" != "$after" ]; then
    problems+=("$label: the store changed")
  fi
}

# Each refusal runs with one defect present and must stop before any store
# call: a symlink in the tree, an unsafe entry name, two -f, a bad workspace
# name or tenant on up, a name the reap refuses on down.
t_refusals_touch_no_store() {
  local name="refused runs make no store call"
  local problems=() dir
  dir="$WORK/ref-symlink"; new_case "$dir"
  ln -s AGENTS.md "$dir/vals/tree/link.md"
  expect_refused "symlink" "$dir/state" "$dir/vals" workspace up -f probe.yaml
  dir="$WORK/ref-unsafe"; new_case "$dir"
  printf 'x\n' > "$dir/vals/tree/agents/a?b"
  expect_refused "unsafe name a?b" "$dir/state" "$dir/vals" workspace up -f probe.yaml
  dir="$WORK/ref-names"; new_case "$dir"
  expect_refused "two -f" "$dir/state" "$dir/vals" workspace up -f probe.yaml -f probe.yaml
  expect_refused "name a/../.." "$dir/state" "$dir/vals" workspace up -f probe.yaml --set 'workspace.name=a/../..'
  expect_refused "tenant a/../.." "$dir/state" "$dir/vals" workspace up -f probe.yaml --set 'workspace.tenant=a/../..'
  expect_refused "down a/../.." "$dir/state" "$dir/vals" workspace down 'a/../..' --tenant acme
  if [ "${#problems[@]}" -eq 0 ]; then ok "$name"; else bad "$name" "${problems[*]}"; fi
}

# `workspace down` writes the reap first, then deletes the folder and proves
# it gone; the folder is absent afterwards.
t_down_reaps_then_deletes_folder() {
  local name="workspace down reaps, then deletes the store folder"
  local dir="$WORK/down"
  new_case "$dir"
  run_cli "$dir/state" "$dir/vals" workspace down probe --tenant acme
  local folder events
  folder="/$BUCKET_PATH/$(sub_of acme probe)/"
  events="$(tr '\n' ';' < "$dir/state/events")"
  if [ "$(rc_of "$dir/state")" != 0 ]; then
    bad "$name" "exit $(rc_of "$dir/state"): $(tail -3 "$dir/state/out")"
  elif [ -e "$(folder_of "$dir/state" acme probe)" ]; then
    bad "$name" "store folder $(sub_of acme probe)/ still exists; events: $events"
  elif [ "$events" != "CREATE tenant-acme/reap-workspace-probe;DELETE ${folder} 204;GET ${folder} 404;" ]; then
    bad "$name" "want reap write, then DELETE and a 404 GET of ${folder}; got: $events"
  else
    ok "$name"
  fi
}

# A refused upload (PUT 500) fails `workspace up` without writing the provision
# command. A store that is down, or a folder still present after the delete,
# fails `workspace down`.
t_store_down_fails_the_run() {
  local name="a refused upload fails workspace up (no command), a down store or surviving folder fails workspace down"
  local problems=() dir
  dir="$WORK/storedown-up"; new_case "$dir"
  FAKE_PUT_STATUS=500 run_cli "$dir/state" "$dir/vals" workspace up -f probe.yaml
  if [ "$(rc_of "$dir/state")" = 0 ]; then
    problems+=("up: exited 0")
  elif grep -q '^CREATE ' "$dir/state/events"; then
    problems+=("up: wrote a command")
  fi
  dir="$WORK/storedown-down"; new_case "$dir"
  FAKE_STORE_DOWN=1 run_cli "$dir/state" "$dir/vals" workspace down probe --tenant acme
  if [ "$(rc_of "$dir/state")" = 0 ]; then
    problems+=("down: exited 0")
  fi
  dir="$WORK/storedown-gone"; new_case "$dir"
  FAKE_GET_STATUS=200 run_cli "$dir/state" "$dir/vals" workspace down probe --tenant acme
  if [ "$(rc_of "$dir/state")" = 0 ]; then
    problems+=("down: exited 0 with the folder still present")
  fi
  if [ "${#problems[@]}" -eq 0 ]; then ok "$name"; else bad "$name" "${problems[*]}"; fi
}

t_up_uploads_exact_tree
t_up_hash_rides_command
t_up_without_key_empties_folder
t_up_relative_path_resolves_against_values_dir
t_up_set_moves_target
t_refusals_touch_no_store
t_down_reaps_then_deletes_folder
t_store_down_fails_the_run

summary
