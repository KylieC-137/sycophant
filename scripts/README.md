# scripts/

Developer utilities for the sycophant codebase. **Not for consumers** —
hobbyists installing sycophant run `syco setup` (from the `cli/` crate).
These scripts are for maintainers running tests, debugging, and managing
local dev clusters.

The end-to-end test is now the `syco` CLI plus the example values — `syco setup`
→ `syco tenant up`/`chat` → `syco tenant audit` (see
`examples/README.md` and `docs/e2e-test.md`). The scripts below are
the legacy maintainer harness, retained until the CLI bring-up is verified live.

| Script | What it does |
|---|---|
| `e2e.sh` | **Legacy.** Full end-to-end over the app path — the client path the CLI doesn't yet cover. Reuses the k3d cluster (`--clean` rebuilds it and all images), deploys, drives the app path over the tailnet with `grpcurl` and the operator's Dex token, optionally compiles the Flutter client (`FLUTTER_TARGET=macos`), and runs the Step 6 security assertions. Long-running (~20+ min); unattended apart from one `sudo` prompt for the tailnet join. |
| `preflight.sh` | **Legacy.** Step-0 host-prereq check for `e2e.sh` (build toolchain + disk + Flutter tier). The build/disk tier is now in `syco setup`'s `check_prereqs`. |
| `quickstart-test.sh` | Chainsaw e2e against a fresh k3d cluster. Builds nothing — exercises `syco setup` (so the dev test hits the same code path consumers do), then runs the chainsaw integration tests + helm uninstall hygiene. ~10 min. |
| `mutation-removal.sh <mutation>` | Smoke-test that the chainsaw harness is non-performative: deletes a sycophant policy, runs the affected chainsaw tests (expects RED), restores. Names: `harness-vap`, `protect-security`, `tenant-tokenreview-crbs`, `runtimeclass-gvisor`. |
| `install-test-deps.sh` | Installs `chainsaw` + `kyverno` CLI binaries. Idempotent. Skips when binaries are already on PATH at the right version. |
| `kill-orphans.sh` | Kills orphan processes left behind by interrupted dev runs (rogue port-forwards, etc.). Run when ports refuse to bind. |

Required env vars for `e2e.sh`: `OPENROUTER_API_KEY`.

To run any of these you'll usually want `install-test-deps.sh` first.
