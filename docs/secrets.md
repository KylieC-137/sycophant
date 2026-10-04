# Secrets: backend recipes

The sycophant chart consumes per-tenant LLM API keys via an inference marker's `secret`, and per-tenant tool credentials via a workspace's grants. Ephemeral Jobs mount the referenced K8s Secret by reference; no controller reads an API key, and the harness never reads one.

This doc shows minimal-working-example recipes for getting that Secret into the cluster. The chart imposes no preference among them — choose by ops cost vs. blast radius vs. existing tooling in your cluster.

## The contract

A `secrets[].secret` must resolve to an **Opaque K8s Secret in the release namespace**, holding the raw provider API token as bytes under **a data key equal to the Secret's own name**:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sycophant-llm-openrouter
  namespace: tenant-foo
type: Opaque
data:
  sycophant-llm-openrouter: <base64-encoded-token>
```

The data key is not configurable. `syco tenant secret set <name>` writes this shape; hand-rolled Secrets must match it.

Every credential reaches its pod as a file, never as an environment variable: env leaks through `/proc/<pid>/environ`, child process inheritance, and logs.

How that Secret arrives is out of framework scope. The recipes below are equivalent from the chart's perspective.

## Recipe 1: kubectl create secret

Simplest. Right for small private deployments and local development.

```sh
printf '%s' "$OPENROUTER_API_KEY" | syco tenant secret set sycophant-llm-openrouter --ns tenant-foo
```

The `kubectl` equivalent, if you are not using the CLI — note the data key repeats the Secret name:

```sh
kubectl create secret generic sycophant-llm-openrouter \
  --namespace tenant-foo \
  --from-literal=sycophant-llm-openrouter="$OPENROUTER_API_KEY"
```

Then in the model's inference marker, applied with `syco inference up -f`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: provision-inference-deepseek-v4-flash
  namespace: tenant-foo
  labels:
    sycophant.md/lifecycle-marker: "true"
    app.kubernetes.io/part-of: sycophant
data:
  format: openai
  model: deepseek/deepseek-v4-flash
  baseUrl: https://openrouter.ai/api/v1
  image: ghcr.io/calebfaruki/inference-runtime:latest
  secret: sycophant-llm-openrouter
```

A model marker names the Secret only. Kubelet mounts it read-only at
`/run/secrets/provider/credential`, the path the inference image reads, and no
component reads the value itself.

A tool job's credential comes from a workspace grant instead, which names the Secret the same way:

```yaml
workspaces:
  research:
    toolsets:
      - name: git-ops
        grants:
          deploy-key:
            secret: sycophant-ssh-key
            path: /home/agent/.ssh/id_ed25519
```

A toolset entry names no Secret at all. Keys under its `env` forward verbatim to the tool job as environment variables.

## Recipe 2: External Secrets Operator + AWS Secrets Manager

Right for cloud deployments where the operator already runs ESO and wants the API key managed alongside other cloud secrets.

Install ESO:

```sh
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
```

Configure a `ClusterSecretStore` for AWS Secrets Manager (IRSA-bound SA, region of your AWS account):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-central-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-irsa
            namespace: external-secrets
```

Create an `ExternalSecret` in the tenant namespace pointing at a value stored at `prod/tenant-foo/openrouter`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: sycophant-llm-openrouter
  namespace: tenant-foo
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: sycophant-llm-openrouter
    creationPolicy: Owner
  data:
    - secretKey: sycophant-llm-openrouter   # MUST equal target.name
      remoteRef:
        key: prod/tenant-foo/openrouter
```

**Key remapping gotcha**: ESO's `dataFrom` flows commonly produce secret keys matching the upstream JSON field name (`apiKey`, `OPENROUTER_API_KEY`, etc.). The consuming data key is not configurable, so remapping is mandatory: set `data[].secretKey` to the Secret name (as above). A `dataFrom` flow that copies the remote key through verbatim will not resolve.

Same chart values reference as Recipe 1.

Reference: <https://external-secrets.io/latest/api/externalsecret/>

## Recipe 3: Vault Agent Injector (HashiCorp Vault or OpenBao)

Right for operators with an existing Vault deployment who want runtime sidecar-based secret delivery (secrets stay in pod memory, never materialize as K8s Secret objects).

Vault Agent Injector is a mutating admission webhook that adds a sidecar container to annotated pods. The sidecar authenticates to Vault, fetches secrets, and writes them to an in-memory volume. To make this satisfy the sycophant contract, the sidecar must write to a K8s Secret in the tenant namespace (Vault Agent has a `secret` output mode for this, or use Vault Secrets Operator instead).

Cleaner pattern for the sycophant contract: use **Vault Secrets Operator** (VSO) which syncs Vault KV values directly into K8s Secrets. Install per upstream docs, then create a `VaultStaticSecret` resource:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: sycophant-llm-openrouter
  namespace: tenant-foo
spec:
  vaultAuthRef: default
  mount: secret
  type: kv-v2
  path: tenants/tenant-foo/openrouter
  destination:
    create: true
    name: sycophant-llm-openrouter
```

Same chart values reference as Recipe 1.

For OpenBao users: openbao-k8s is an MPL-2.0 fork of vault-k8s with identical APIs. Substitute `openbao.org/agent-inject` for `vault.hashicorp.com/agent-inject` annotations.

References:
- Vault Secrets Operator: <https://developer.hashicorp.com/vault/docs/platform/k8s/vso>
- OpenBao k8s: <https://github.com/openbao/openbao-k8s>

## What the chart does not do

- The chart does not install ESO, Vault, Vault Agent Injector, OpenBao, or any other secrets backend.
- The chart does not assume which backend produced the K8s Secret it consumes.
- The chart does not advise. Picking a backend is the operator's decision based on their existing infrastructure, compliance posture, and operational preference.

## Migrating between backends

Because the chart consumes only the resulting K8s Secret, migrating from one backend to another (e.g., `kubectl` to ESO+Vault) is an operator-side operation. The profile's or the grant's `secret` reference doesn't change. The chart doesn't need a release event. Migrate one tenant at a time if you want; the chart doesn't know the difference.
