# gvisor-scope

Pins the gVisor runtime scope to **toolsets only** (`capability-job`).

- `capability-job-in-gvisor-scope` — every `capability-job` pod is
  gVisor-sandboxed and volume-bounded no matter which workspace's harness
  built the Job. Proves toolsets stay sandboxed.
- The companion `harness-pod-shape/compliant-pod-admits` test proves the
  inverse: a harness pod admits on the kubelet-default runtime (no
  `runtimeClassName`), since the mutate no longer stamps it and the VAP no
  longer requires it for non-toolset components.

The harness/channel components run on runc; their containment is
the universal VAP envelope (drop-ALL caps, ROFS, automountSA=false, seccomp,
runAsNonRoot) plus per-component Cilium egress allowlists.
