# Stdlib toolset

A convention, not a built-in: a toolset entry pointing at the base toolset
image (`toolset`, image dir `images/toolset/`), bound explicitly like any
other. It bundles five built-in tools served directly by `toolset-runtime`
(no `/etc/toolset/dispatch` shell layer required):

| Tool     | Description                                                          |
|----------|----------------------------------------------------------------------|
| `Shell`  | Run a shell command, return stdout/stderr/exit-code                  |
| `Read`   | Read a text file as line-numbered `LINE\|CONTENT` (1 MiB cap)        |
| `Write`  | Write content to a file (parents auto-created, full overwrite)       |
| `Edit`   | Replace an exact unique substring in a file                          |
| `Search` | List files by basename or grep content (ripgrep-backed)              |

Tool names are PascalCase (the canonical LLM-facing identifier). The
K8s Job name the toolset builds for each call is kebab-cased
(`tool-read-<call_id_prefix>`) to satisfy RFC 1123.

A toolset provision command's `keepalive: "true"` keeps one toolset pod alive per workspace for the
workspace's lifetime — there is no per-call cold start.

## Extending the base image

The tool list is the image's `md.sycophant.tools` label, built from a flat
`tools.yaml` of string values. A derived image's label REPLACES the base's, so
to extend the stdlib toolset you author one `tools.yaml` holding all five stdlib
entries (copy `images/toolset/tools.yaml`) alongside your additions, convert it
to one-line JSON with a string-only check, and build with
`--label md.sycophant.tools="$label"` (see docs/toolset.md):

```dockerfile
FROM ghcr.io/calebfaruki/toolset:latest

# tool dispatcher for non-built-in tools
COPY dispatch /etc/toolset/dispatch
RUN chmod +x /etc/toolset/dispatch
```

The toolset-runtime entrypoint inherited from the base image routes
built-in tool names to its in-process implementation and falls through
to `/etc/toolset/dispatch <tool>` for anything else.
