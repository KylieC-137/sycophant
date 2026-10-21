# Examples

Values files for each provision command, rendered by `sycoadm <kind> up -f` with
[`charts/sycophant-commands`](../charts/sycophant-commands/). Each names tenant
`e2e-test`; point one elsewhere with `--set <kind>.tenant=<name>`. Later `-f`
files override earlier ones, and `--set` overrides both.

| Kind | Values |
|---|---|
| tenant | [`tenants/e2e-test.yaml`](tenants/e2e-test.yaml) |
| inference | [`inference/local.yaml`](inference/local.yaml), [`inference/deepseek-v4-flash.yaml`](inference/deepseek-v4-flash.yaml) |
| toolset | `toolsets/<name>/values.yaml`, beside each image's `tools.yaml` |
| workspace | [`workspaces/hello-world.yaml`](workspaces/hello-world.yaml) |
| user | [`users/alice.yaml`](users/alice.yaml) |
| channel | [`channels/app.yaml`](channels/app.yaml) |

[`instructions/simple/`](instructions/simple/) is an instructions tree for a
workspace.

## Order

Each `up` prompts for the operator password set during `sycoadm setup` and waits
for its installer. A workspace may name only models and toolsets already
installed.

```sh
sycoadm tenant up -f examples/tenants/e2e-test.yaml

printf '%s' "$OPENROUTER_API_KEY" | sycoadm tenant secret set sycophant-llm-openrouter --ns tenant-e2e-test
sycoadm inference up -f examples/inference/deepseek-v4-flash.yaml
sycoadm inference up -f examples/inference/local.yaml

# A toolset's image and tool list come from its built image, in a second file.
img=localhost:5555/toolset:latest
ref="$(docker inspect --format '{{index .RepoDigests 0}}' "$img")"
printf '{"toolset": {"image": "%s", "tools": %s}}\n' \
  "${ref/localhost:5555/sycophant-registry:5000}" \
  "$(docker inspect --format '{{ index .Config.Labels "md.sycophant.tools" }}' "$img")" \
  > stdlib-image.yaml
sycoadm toolset up -f examples/toolsets/stdlib/values.yaml -f stdlib-image.yaml
# ...the same for workspace-ro (toolset-git) and ssh-credentials (toolset-ssh-credentials)

printf 'FAKE-ED25519-PRIVATE-KEY-DO-NOT-USE' | sycoadm tenant secret set demo-ssh-key --ns tenant-e2e-test
sycoadm workspace up -f examples/workspaces/hello-world.yaml
sycoadm user up -f examples/users/alice.yaml --set "user.subject=<issuer>#<sub>"
sycoadm channel up -f examples/channels/app.yaml
```

Re-run any `up` after editing its values to upgrade that part in place. Remove
one with `sycoadm <kind> down <name> --tenant e2e-test`.

## Exercise and audit

Toolset pods spawn on the first tool call. From the Flutter client
([`docs/flutter-app.md`](../docs/flutter-app.md)), ask the agent to run
`echo hello` with its Shell tool, then to use the `test-cmd` tool, which prints
the mounted demo key. Then:

```sh
sycoadm tenant audit hello-world --ns tenant-e2e-test
kubectl logs -n tenant-e2e-test deployment/ws-hello-world -c harness | grep -c 'FAKE-ED25519-PRIVATE-KEY'   # 0
kubectl logs -n tenant-e2e-test deployment/ws-hello-world -c harness | grep -c '\[REDACTED:demo-ssh-key\]' # >= 1
```

The second count proves the tool read the key and the scrubber replaced it.
Tear down with `sycoadm tenant remove e2e-test` or `sycoadm destroy`.
