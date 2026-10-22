# Relay

[![made-with-rust](https://img.shields.io/badge/Made%20with-Rust-1f425f.svg)](https://www.rust-lang.org/)

Client gateway for agent workspaces. Relay is the single ingress: it authenticates every caller through the Kubernetes API, authorizes every request against the caller's live RBAC, relays user messages to the Harness, and relays the assistant reply and turn-state back to the client. It holds no LLM credentials, no conversation history, and no transport of its own. Each channel supplies its own transport through its own adapter Deployment.

## How It Works

One component, the **gateway controller**, one per tenant namespace. It:

- Serves three ports, one credential class each: the harness link (9090, SA tokens via TokenReview), the app port (9091, person tokens), and the adapter port (9092, `adapter-<channel>` SA tokens).
- Watches the `relay-identity` ConfigMaps — one per subject, carrying that person's workspace list and per-channel handle bindings — and reloads the identity table live.
- Authenticates person tokens by TokenReview and adapter tokens by an audience-pinned TokenReview; a thin per-listener layer stamps the credential class, and handlers branch on the stamped class, never on the credential's shape.
- Authorizes every request by a Kubernetes access review — one SubjectAccessReview carrying the resolved subject, submitted under the relay's own credential on every path — so the operator's live RBAC is the whole answer, checked per request.
- Relays inbound user messages → Harness, and outbound (assistant reply + turn-state) → client.

The gateway carries **no LLM credentials** and owns **no conversation log**. LLM dispatch is [Toolset](toolset.md); conversation history lives on the [Harness](harness.md). Relay is a relay across the trust boundary.

## Why Relay

The Harness and Toolset controller are in-cluster, trusted-network components. Something has to stand at the edge, authenticate external callers, and police what crosses in. That is Relay.

- **One authorization model, many transports** — every request is authorized by the same per-request Kubernetes review, whatever transport carried it.
- **Subject authorization** — a person reaches exactly the workspaces their RoleBindings grant, from any channel their tenant has enabled. Binding removal revokes within seconds, with no pod restart; token expiry bounds any stale credential.
- **Credential containment** — the gateway never holds LLM API keys; a compromised gateway cannot call providers. It holds no Secrets at all.

## Architecture

```
              adapter        gRPC :9091/:9092      gRPC :9090
   Client ───> Adapter ─────────────────> Gateway ───────> Harness
  (person or   (per-channel                (TokenReview,    (agent loop,
   platform     transport)                 SAR per         conversation
   token)                                   request)         history)

   Client <─── Adapter <───────────────── Gateway <─────── Harness
  (assistant reply +                     (relay outbound)  (DeliverOutbound:
   turn-state)                                              reply + turn-state)
```

Inbound: the caller presents a token, its channel's adapter delivers it, the gateway TokenReviews the token, resolves the caller to an OIDC subject (person) or through a handle binding (adapter), and authorizes the named workspace by a Kubernetes access review before forwarding user messages to the Harness. Outbound: the Harness originates the assistant reply and terminal turn-state and pushes them to the gateway (`DeliverOutbound`), which fans them out to the subscribed client.

## Identity

**The OIDC subject is the root of identity.** The apiserver's own OIDC authenticator resolves a person token to a username — the issuer-prefixed subject string. The relay requires `authenticated` and a non-empty username; it pins no audience of its own, because the apiserver enforces the issuer's audience at authentication time.

An operator grants a person reach by writing their workspace list once, with `sycoadm user up`: the user command renders one reach RoleBinding per listed workspace (subject kind `User`, the raw subject string, roleRef the workspace's `ws-<workspace>-reach` Role granting `get` on the workspace's harness Service) plus one identity ConfigMap. A listed workspace must already exist when the command is written, or the command fails and grants nothing. Each reach RoleBinding is owned by its workspace's reach Role, so reaping a workspace deletes every grant to it, and a workspace recreated under the same name reaches nobody until re-granted. Re-running the command with a shorter list revokes the excess workspaces on the next request; removing a handle binding stops the sender resolving on the next message.

**Adapter channel identity is structural.** The adapter port's TokenReview must yield `system:serviceaccount:<namespace>:adapter-<channel>`; the channel is the SA name minus `adapter-`. Adapter tokens are pinned to the `adapter.relay.sycophant.md` audience. The relay resolves the message's `sender` — the platform user ID — through the identity table's `handle.<channel>` bindings; a handle with no operator binding is refused before any review.

A handle claimed by two subjects resolves to neither and is reported as a row error, so the operator fixes the binding instead of one person silently receiving the other's messages.

**Revocation is binding removal plus token expiry.** The relay holds no denylist: a removed RoleBinding fails the very next SubjectAccessReview, and a removed handle binding fails the very next resolution, which runs on every message, so an already-open adapter channel is cut too. An open stream re-reviews its bearer token, the handle, and the subject's reach before every outbound item, so an expired token, a removed RoleBinding, or a removed handle ends it on its next item.

## The relay-identity ConfigMaps

One ConfigMap per subject, rendered by the user chart from the operator's command, named `user-<hash10>` and labelled `sycophant.md/type: relay-identity`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-0a1b2c3d4e
  labels:
    sycophant.md/type: relay-identity
data:
  subject: "https://issuer.example#alice"
  workspaces: "alpha,beta"
  handle.slack: "U0123ABCDEF"
  handle.telegram: "7133824091"
```

The operator (through the user command and its installer) is the only writer. A Kyverno rule matching the `sycophant.md/type: relay-identity` label denies CREATE, UPDATE, and DELETE from every ServiceAccount inside the tenant namespace, the relay included.

Validation is invalid-is-absent, per ConfigMap: a non-empty `subject`, a comma-separated `workspaces` list, and non-empty `handle.<channel>` values. A ConfigMap that does not parse does not exist, and it never suppresses the subjects beside it — a typo must not block a revocation made in the same edit. Rejected ConfigMaps are logged and raised as Warning Events naming the ConfigMap and the reason, so `kubectl describe configmap` shows the row the relay dropped.

## Conversation Lifecycle

The conversation log lives on the **Harness**, on a dedicated per-workspace PVC (LocalFs). Relay exposes the conversation-lifecycle RPCs to clients but does not own them — it relays each to the Harness, which mints IDs, assembles history, persists turns, and answers reads.

- `MintConversation` — returns a new opaque `conversation_id` (a UUID). Per-workspace Harness routing is the isolation boundary; there is no `<workspace>.` prefix.
- `ListConversations`, `DeleteConversation`, `SetConversationName`, `GetConversationHistory` — relayed to the Harness.

The S3 conversation backend was dropped; the Harness persists to LocalFs only.

## gRPC Protocol

Proto definitions at `crates/relay-proto/proto/relay/v1/relay.proto`.

**`relay.v1.RelayGateway`** — the token-authenticated, client-facing surface. Every workspace-scoped RPC names its workspace, and CancelTool resolves its workspace from the `call_id`; the relay authorizes that workspace per request:

| RPC | Description |
|-----|-------------|
| `ListWorkspaces` | The caller's whole granted list, straight from the watched identity ConfigMaps. One TokenReview authenticates; nothing is enumerated. |
| `ListGrants` | The named workspace's toolset grants, grouped by toolset, after the workspace is authorized. Names only, merged live from the per-workspace `ws-<workspace>-relay-grants` ConfigMaps; the gateway reads no Secret. |
| `MintConversation` / `ListConversations` / `DeleteConversation` / `SetConversationName` / `GetConversationHistory` | Conversation lifecycle; each names its workspace and is authorized before the relay to the Harness. |
| `GetTurnState` | Current turn-state for a conversation. |
| `ChannelIngest` | Inbound user message in; the channel_id's registered (subject, workspace) binding is re-checked for reach on every ingest. |
| `ChannelReceive` | Server-stream of outbound events (assistant reply + turn-state) to the client; names its workspace and (on the adapter path) its sender. |
| `WatchTools` / `DispatchTool` / `AwaitToolResult` | Tool surface, relayed to the Harness; each names its workspace. |
| `CancelTool` | Cancels an in-flight tool call. Names no workspace: the relay resolves it from the `call_id`'s server-side (subject, workspace) binding and re-runs the reach check. |
| `CancelTurn` | Cancels the conversation's in-flight turn; names its workspace. |

**`relay.v1.RelayInternal`** — the in-cluster surface the Harness calls back on:

| RPC | Description |
|-----|-------------|
| `Subscribe` | Harness subscribes to inbound user messages. |
| `SendServerNotification` / `SendServerRequestAndAwait` | Server-originated messages to the client. |
| `DeliverOutbound` | Harness pushes the assistant reply + terminal turn-state for fan-out to the client. |

## Channel adapters

The relay carries no transport. Each channel supplies its own, as a standing Deployment rendered by its channel provision command: one Deployment per channel, `replicas: 1`, `strategy: Recreate`, gVisor, its own ServiceAccount, its own fail-closed egress policy, and no workspace mount.

The app channel's adapter is the tailnet terminus. It is `sycophant.md/adapter-class: transport` — transport only, holding no signing identity and mounting no keypair volume — and forwards tailnet TCP :9090 to the relay's app port. Its tailnet node identity persists across restarts in the fixed `adapter-state` Secret (`TS_KUBE_SECRET`, one app channel per tenant). It is the stated exception to dial-out-only: it accepts inbound tailnet connections, so no ingress policy selects it. See [`docs/headscale-self-host-acme.md`](headscale-self-host-acme.md) for the self-hosted control plane.

Platform adapters (`sycophant.md/adapter-class: principal`) reach the relay on the adapter port with their `adapter-<channel>` ServiceAccount tokens. They are dial-out-only.

## RBAC

The gateway ServiceAccount can read ConfigMaps, raise Events, and create authorization reviews. It has **no Jobs, Deployments, or Pods RBAC**, no ConfigMap write verb, no Secrets RBAC at all, and no access to LLM credentials.

```yaml
rules:
  # The relay-identity ConfigMaps: read-only. RBAC is the first lock on
  # the identity table; the Kyverno rule is the second.
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
  # Warning Events naming rejected identity ConfigMaps.
  - apiGroups: ["events.k8s.io"]
    resources: ["events"]
    verbs: ["create", "patch"]
```

The app adapter carries a Role granting `get`/`update`/`patch` on the fixed `adapter-state` Secret (and `create` for first start), bound to the adapter's ServiceAccount, not the relay's.

TokenReview and SubjectAccessReview are cluster-scoped: the shared `cluster-relay-tokenreview` ClusterRole grants `create` on `tokenreviews` and `subjectaccessreviews`, bound to each tenant's `relay-controller` SA by the `tenant-rolebinding-generator` Kyverno policy.

## Security Model

- Every workspace-scoped request names its workspace (CancelTool resolves its workspace from the `call_id`) and is authorized by a Kubernetes access review carrying the relay's own namespace — never a caller-supplied one — so a workspace the caller cannot reach fails closed.
- The caller's token reaches the apiserver only in its TokenReview. Every access review is a SubjectAccessReview for the resolved subject under the relay's own credential: the subject's live RBAC is the whole answer, so removing a RoleBinding revokes on the very next request.
- The adapter path resolves senders only through operator-written handle bindings; an unbound handle is refused before any review or routing.
- Conversations bind to the OIDC subject that created them, not only to the workspace, so two subjects in one workspace cannot read each other's conversations.
- The gateway holds no signing keys, no device keys, and no Secrets at all: it authenticates by TokenReview and signs nothing. It cannot store a device credential because it has nowhere to put one.
- The gateway holds no LLM credentials and no Jobs RBAC — it cannot dispatch LLM calls or call providers.
- The gateway owns no conversation log — history lives on the Harness's PVC, so a compromised gateway cannot forge or rewrite history.
- All images are FROM scratch with musl static builds, signed with cosign (keyless, sigstore).

## Crate Structure

```
crates/
  relay-proto/        # gRPC proto definitions (relay.v1)
  relay-controller/   # gateway controller binary
```

## Installation

Container image is published to GHCR on each release:

```
ghcr.io/calebfaruki/relay-controller:latest
```

The tenant chart (`charts/sycophant-tenant/`) installs the gateway Deployment, once per tenant. The user command installs each person's reach RoleBindings and identity ConfigMap (`sycoadm user up`). The workspace chart (`charts/sycophant-workspace/`) installs each workspace's `ws-<workspace>-relay-grants` ConfigMap and reach Role. The channel chart (`charts/sycophant-channel/`), installed by `sycoadm channel up`, installs headscale and the channel's adapter Deployment. A caller's reach is the operator's RoleBinding grant; the identity ConfigMap is the operator's handle and workspace-list record. No custom kinds are on this path.
