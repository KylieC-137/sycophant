# Quickstart

From nothing to a working `syco chat` session.

## Prerequisites

- Docker (Docker Desktop or colima)
- k3d ≥ 5.x
- Go ≥ 1.22
- Rust toolchain (stable) with `aarch64-unknown-linux-musl` target
- jq, helm, kubectl
- Tailscale
- A GGUF model at `~/.cache/sycophant/weights/Qwen3.5-2B-Q4_K_M.gguf`

## 1. Build

    make sycoadm syco
    export PATH="$PWD/target:$PATH"

## 2. Create the cluster

    sycoadm setup

Prompts for an operator email and password. Idempotent.

## 3. Provision a tenant

    sycoadm tenant up -f examples/sycoadm/tenants/e2e-test.yaml

## 4. Install toolsets

Each toolset's image ref and tool list come from its built image:

    for name in stdlib workspace-ro ssh-credentials; do
      img="localhost:5555/toolset-${name}:latest"
      [ "$name" = "stdlib" ] && img="localhost:5555/toolset:latest"
      ref="$(docker inspect --format '{{index .RepoDigests 0}}' "$img")"
      printf '{"toolset": {"image": "%s", "tools": %s}}\n' \
        "${ref/localhost:5555/sycophant-registry:5000}" \
        "$(docker inspect --format '{{ index .Config.Labels "md.sycophant.tools" }}' "$img")" \
        > /tmp/${name}-image.yaml
      sycoadm toolset up \
        -f examples/sycoadm/toolsets/${name}/values.yaml \
        -f /tmp/${name}-image.yaml
    done

## 5. Create the demo SSH credential

    printf 'FAKE-ED25519-PRIVATE-KEY-DO-NOT-USE' \
      | sycoadm tenant secret set demo-ssh-key --ns tenant-e2e-test

## 6. Install inference

    sycoadm inference up -f examples/sycoadm/inference/local.yaml

## 7. Create a workspace

    sycoadm workspace up -f examples/sycoadm/workspaces/hello-world.yaml

Uploads the directory named by the values file's `instructions` key (`../instructions/simple`, the example AGENTS.md with model `local`) to the store, then installs the workspace. Rerun it after editing the files.

## 8. Install the app channel

    sycoadm channel up -f examples/sycoadm/channels/app.yaml

Mints the adapter's headscale auth key and installs the tailnet adapter.

## 9. Join the tailnet

    sycoadm connect --tenant e2e-test

Requires `sudo` for the Tailscale daemon. Run once per machine.

## 10. Login

    syco login --email e2e-operator@sycophant.local

## 11. Bind your identity

    sycoadm user up -f examples/sycoadm/users/alice.yaml \
      --set "user.subject=$(syco whoami --subject)"

## 12. Chat

    syco chat

## Tear down

To remove one workspace, which also deletes its instructions folder in the store:

    sycoadm workspace down hello-world --tenant e2e-test

To remove the whole cluster:

    sycoadm destroy
