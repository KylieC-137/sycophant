# Examples

Values files for each provision command, rendered by `sycoadm <kind> up -f` with
[`charts/sycophant-commands`](../../charts/sycophant-commands/). Each names tenant
`hello-world`; point one elsewhere with `--set <kind>.tenant=<name>`. Later `-f`
files override earlier ones, and `--set` overrides both.

The hello world is five pieces, each from one values file:

| Kind | Values |
|---|---|
| tenant | [`tenants/hello-world.yaml`](tenants/hello-world.yaml) |
| inference | [`inference/qwen3-5-2b.yaml`](inference/qwen3-5-2b.yaml) |
| toolset | [`toolsets/hello-world/values.yaml`](toolsets/hello-world/values.yaml), beside the image's `tools.yaml` |
| workspace | [`workspaces/hello-world.yaml`](workspaces/hello-world.yaml) |
| channel | [`channels/tailnet.yaml`](channels/tailnet.yaml) |

[`users/alice.yaml`](users/alice.yaml) binds a person to the workspace, and
[`instructions/hello-world/`](instructions/hello-world/) is the workspace's
instructions tree.

The [README quickstart](../../README.md#quickstart) installs them in order.
