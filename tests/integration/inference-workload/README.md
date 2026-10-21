# inference-workload

Applied shape of the in-cluster inference workload: one always-on server per
local inference provision command, fenced to its tenant. Each case renders
the `sycophant-inference` chart from the local provision command fixture
`fixtures/model-inference-local.json`, merged with the case's `server.*` keys.
Render-only checks live in `tests/unit/tenant-chart/`.

- `pod-shape` — hardened floor on every container including the init
  container, no SA token, node selector and toleration, and the absence set
  (no runtimeClassName, host namespace, hostPath, or hostPort).
- `netpol-shape` — ingress fenced to the harness on one port with a closed L7
  route allowlist, and egress DNS-only.
