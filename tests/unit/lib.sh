# shellcheck shell=bash
# tests/unit/lib.sh — shared boilerplate for unit acceptance scripts.
# The caller must set HERE before sourcing.
# shellcheck disable=SC2154  # HERE is set by the caller.
# shellcheck disable=SC2034  # ROOT is used by the scripts that source this file.
ROOT="$(cd "$HERE/../../.." && pwd)"
readonly ROOT
WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n    %s\n' "$1" "$2"; }

summary() {
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}
