//! Commands: the ConfigMaps the cluster's reactors act on, rendered from the
//! embedded `sycophant-commands` chart. Each is written under the operator's
//! IdP token. A provision command stamps a single-shot
//! `provision-<kind>-<uid10>` installer Job in sycophant-system, and a reap
//! command an `uninstall-<kind>-<uid10>` Job; each deletes its command once it
//! succeeds.

use serde_json::Value;

use crate::cli::Values;
use crate::commands::common::{ok, wait_for};
use crate::commands::operator::{self, Operator, OperatorKube};
use crate::runner::{run_output, run_stdin, run_stdin_bytes};
use crate::scope::Scope;

pub(crate) const SYSTEM_NS: &str = "sycophant-system";
pub(crate) const TENANT_NS_PREFIX: &str = "tenant-";
// A leftover command is deleted before its replacement is created.
pub(crate) const COMMAND_WRITER_VERBS: &str = "create,delete";

/// The namespace of tenant `name`.
pub(crate) fn tenant_ns(name: &str) -> String {
    format!("{TENANT_NS_PREFIX}{name}")
}

/// The first ten hex of a uid, which the reactor names a command's installer
/// objects with.
pub(crate) fn uid10(uid: &str) -> String {
    uid.replace('-', "").chars().take(10).collect()
}

/// The bare tenant token: the namespace minus the `tenant-` prefix the
/// provision reactor composes.
pub(crate) fn tenant_token(ns: &str) -> Result<&str, String> {
    ns.strip_prefix(TENANT_NS_PREFIX)
        .filter(|t| !t.is_empty())
        .ok_or_else(|| format!("tenant namespace must be {TENANT_NS_PREFIX}<name>, got {ns}"))
}

/// Render `templates/<template>.yaml` from the commands chart this binary embeds,
/// with `args` supplying the values (`-f <file>` and `--set-string`).
pub(crate) fn render(template: &str, args: &[&str]) -> Result<String, String> {
    let chart = crate::sync::extract_commands_chart(&Scope::global()?)?;
    let chart = chart.to_string_lossy();
    let show = format!("templates/{template}.yaml");
    let mut argv = vec!["template", "c", &chart, "--show-only", &show];
    argv.extend_from_slice(args);
    run_output("helm", &argv)
}

/// Write `manifest` as the operator, clearing any leftover command of the same
/// name first, and return the new command's uid. A rejection fails here.
fn write(kube: &OperatorKube, manifest: &str) -> Result<String, String> {
    let kc = kube.path();
    run_stdin(
        "kubectl",
        &[
            "--kubeconfig",
            &kc,
            "delete",
            "-f",
            "-",
            "--ignore-not-found",
        ],
        manifest,
    )?;
    let uid = run_stdin_bytes(
        "kubectl",
        &[
            "--kubeconfig",
            &kc,
            "create",
            "-f",
            "-",
            "-o",
            "jsonpath={.metadata.uid}",
        ],
        manifest,
    )?;
    Ok(String::from_utf8_lossy(&uid).trim().to_string())
}

/// Done, still running, or failed, from a Job's `.status`.
pub(crate) fn job_state(status: &Value) -> Result<bool, String> {
    let failed = status["conditions"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|c| c["type"] == "Failed" && c["status"] == "True");
    if failed {
        return Err("Job failed".into());
    }
    Ok(status["succeeded"].as_i64() == Some(1))
}

/// Apply a `kind` provision command manifest as the operator and wait for the installer
/// Job its uid names.
pub(crate) fn apply(op: &Operator, kind: &str, manifest: &str) -> Result<(), String> {
    let uid = write(&op.kubeconfig()?, manifest)?;
    wait_job(&format!("provision-{kind}-{}", uid10(&uid)), "provision")
}

/// Render and write the `reap-<kind>-…` command into tenant `tenant` as the
/// operator, and wait for the uninstall Job its uid names.
pub(crate) fn reap(
    op: &Operator,
    kind: &str,
    key: &str,
    value: &str,
    tenant: &str,
) -> Result<(), String> {
    let manifest = render(
        &format!("{kind}-reap"),
        &[
            "--set-string",
            &format!("{kind}.{key}={value}"),
            "--set-string",
            &format!("{kind}.tenant={tenant}"),
        ],
    )?;
    let uid = write(&op.kubeconfig()?, &manifest)?;
    wait_job(&format!("uninstall-{kind}-{}", uid10(&uid)), "reap")
}

/// Poll Job `job` in sycophant-system, run for a `verb` command, until it
/// succeeds or fails.
fn wait_job(job: &str, verb: &str) -> Result<(), String> {
    ok(&format!("{verb} command written; waiting on Job {job}"));
    let mut failure = None;
    wait_for(&format!("Job {job} finished"), 600, || {
        let status = run_output(
            "kubectl",
            &[
                "get",
                "job",
                job,
                "-n",
                SYSTEM_NS,
                "-o",
                "jsonpath={.status}",
            ],
        )
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null);
        match job_state(&status) {
            Ok(done) => done,
            Err(e) => {
                failure = Some(format!("{job}: {e}; the {verb} command was left in place"));
                true
            }
        }
    })?;
    failure.map_or(Ok(()), Err)
}

/// `syco <kind> up -f <values.yaml>`: render the kind's provision command from
/// the values, write it, and wait for its installer.
pub(crate) fn up(kind: &str, values: &Values) -> Result<(), String> {
    let mut args = values.helm_args();

    // Local images referenced in the values are pushed to the in-cluster
    // registry and rewritten to in-cluster references — the
    // distribution-agnostic path that works on any cluster with a registry,
    // not just k3d image import.
    let mut extra_files: Vec<(String, operator::TempFile)> = Vec::new();
    let overrides = match kind {
        "inference" => push_inference_images(values)?,
        "toolset" => {
            let (ov, f) = push_toolset_image(values)?;
            if let Some(f) = f {
                extra_files.push((f.path(), f));
            }
            ov
        }
        _ => Vec::new(),
    };
    for (key, val) in overrides {
        args.push("--set-string".to_string());
        args.push(format!("{key}={val}"));
    }
    for (path, _tmp) in &extra_files {
        args.push("-f".to_string());
        args.push(path.clone());
    }

    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let manifest = render(&format!("{kind}-provision"), &args)?;
    let op = Operator::login(&Scope::global()?.oidc_dir())?;

    // The channel needs a headscale pre-auth key to join the tailnet.
    // Mint it before the provisioner Job runs so the channel pod can start.
    if kind == "channel" {
        if let Some(ns) = manifest_namespace(&manifest) {
            mint_channel_authkey(&ns)?;
        }
    }

    apply(&op, kind, &manifest)
}

/// Read the values files, find `inference.server.image` and
/// `inference.server.weights`, push each to the in-cluster registry, and return
/// the `--set-string` overrides that rewrite them to the in-cluster references.
/// A remote model has no `server` block and nothing to push.
fn push_inference_images(values: &Values) -> Result<Vec<(String, String)>, String> {
    let merged = merge_values(values)?;

    let Some(server) = merged
        .get("inference")
        .and_then(|v| v.get("server"))
        .and_then(|v| v.as_mapping())
    else {
        return Ok(Vec::new());
    };

    let mut overrides = Vec::new();
    for field in ["image", "weights"] {
        let local = server
            .get(field)
            .and_then(|v| v.as_str())
            .ok_or_else(|| format!("inference.server.{field} not found in values"))?;
        // Only push local images (no registry prefix or digest).
        if local.contains('/') || local.contains('@') {
            continue; // already a registry reference
        }
        let pinned = crate::commands::registry::push_local_image(local)?;
        overrides.push((format!("inference.server.{field}"), pinned));
    }
    Ok(overrides)
}

/// `--set-string` overrides plus an optional extra values file for helm.
type HelmOverrides = (Vec<(String, String)>, Option<operator::TempFile>);

/// Read the values files, find `toolset.image`, push it to the in-cluster
/// registry, and return the `--set-string` override for the in-cluster
/// reference plus a temp values file carrying the image's
/// `md.sycophant.tools` label as `toolset.tools` (a YAML map, since the
/// values contain spaces/commas that break `--set-string`).
fn push_toolset_image(values: &Values) -> Result<HelmOverrides, String> {
    let merged = merge_values(values)?;

    let toolset = merged
        .get("toolset")
        .and_then(|v| v.as_mapping())
        .ok_or("toolset block not found in values")?;

    let local = toolset
        .get("image")
        .and_then(|v| v.as_str())
        .ok_or("toolset.image not found in values")?;

    // Already a registry reference — nothing to push.
    if local.contains('/') || local.contains('@') {
        return Ok((Vec::new(), None));
    }

    let pinned = crate::commands::registry::push_local_image(local)?;

    // Read the image's md.sycophant.tools label (one-line JSON) and write it
    // as a temp YAML values file under toolset.tools, since the helm template
    // ranges over .tools as a map and the values contain characters that
    // break --set-string.
    let tools_json = crate::runner::run_output(
        "docker",
        &[
            "inspect",
            "--format",
            "{{ index .Config.Labels \"md.sycophant.tools\" }}",
            local,
        ],
    )
    .unwrap_or_default();

    let overrides = vec![("toolset.image".to_string(), pinned)];
    if tools_json.is_empty() {
        return Ok((overrides, None));
    }

    let tools: std::collections::BTreeMap<String, String> = serde_json::from_str(&tools_json)
        .map_err(|e| format!("parse md.sycophant.tools label: {e}"))?;

    let mut doc = serde_yaml::Mapping::new();
    let mut toolset_map = serde_yaml::Mapping::new();
    let mut tools_map = serde_yaml::Mapping::new();
    for (k, v) in tools {
        tools_map.insert(serde_yaml::Value::String(k), serde_yaml::Value::String(v));
    }
    toolset_map.insert(
        serde_yaml::Value::String("tools".to_string()),
        serde_yaml::Value::Mapping(tools_map),
    );
    doc.insert(
        serde_yaml::Value::String("toolset".to_string()),
        serde_yaml::Value::Mapping(toolset_map),
    );
    let yaml = serde_yaml::to_string(&serde_yaml::Value::Mapping(doc))
        .map_err(|e| format!("serialize tools values: {e}"))?;

    let tmp = operator::TempFile::new("yaml", &yaml)?;
    Ok((overrides, Some(tmp)))
}

/// Merge all values files (later files override earlier, matching helm) into a
/// single top-level mapping.
fn merge_values(
    values: &Values,
) -> Result<std::collections::BTreeMap<String, serde_yaml::Value>, String> {
    use std::collections::BTreeMap;
    use std::fs;

    let mut merged: BTreeMap<String, serde_yaml::Value> = BTreeMap::new();
    for file in &values.files {
        let text = fs::read_to_string(file).map_err(|e| format!("cannot read {file}: {e}"))?;
        let doc: serde_yaml::Value =
            serde_yaml::from_str(&text).map_err(|e| format!("{file} is not YAML: {e}"))?;
        if let Some(map) = doc.as_mapping() {
            for (k, v) in map {
                if let Some(key) = k.as_str() {
                    merged.insert(key.to_string(), v.clone());
                }
            }
        }
    }
    Ok(merged)
}

/// `syco <kind> down <name> --tenant <t>`: write the reap command and wait for
/// its uninstall.
pub(crate) fn down(kind: &str, name: &str, tenant: &str) -> Result<(), String> {
    let op = Operator::login(&Scope::global()?.oidc_dir())?;
    reap(&op, kind, "name", name, tenant)
}

/// `sycoadm user down <subject> --tenant <t>`: write the user's reap command
/// and wait for its uninstall.
pub(crate) fn user_down(subject: &str, tenant: &str) -> Result<(), String> {
    let op = Operator::login(&Scope::global()?.oidc_dir())?;
    reap(&op, "user", "subject", subject, tenant)
}

/// Write the suspend command into tenant namespace `ns`. Without a keepalive the
/// tenant scales to zero and stays; with one the reap deletes it that many days on.
pub(crate) fn suspend(op: &Operator, ns: &str, keepalive: Option<&str>) -> Result<(), String> {
    let name = format!("tenant.name={}", tenant_token(ns)?);
    let keep = keepalive.map(|k| format!("tenant.keepalive={k}"));
    let mut args = vec!["--set-string", &name];
    if let Some(k) = &keep {
        args.extend(["--set-string", k]);
    }
    let manifest = render("tenant-suspend", &args)?;
    let kube = op.kubeconfig()?;
    operator::grant_command_writer(ns, COMMAND_WRITER_VERBS, &kube.identity)?;
    write(&kube, &manifest)?;
    ok(&format!("suspend-tenant command written in {ns}"));
    Ok(())
}

/// Extract the target namespace from a rendered provision command manifest.
pub(crate) fn manifest_namespace(manifest: &str) -> Option<String> {
    let doc: serde_yaml::Value = serde_yaml::from_str(manifest).ok()?;
    doc["metadata"]["namespace"].as_str().map(|s| s.to_string())
}

/// Mint a headscale pre-auth key for the channel and store it as a Secret.
fn mint_channel_authkey(ns: &str) -> Result<(), String> {
    use crate::runner::run_passthrough;
    run_passthrough("sh", &["-c", &format!(
        "kubectl exec -n {ns} deploy/headscale -- headscale users create channel 2>/dev/null; \
         uid=$(kubectl exec -n {ns} deploy/headscale -- headscale users list -o json | jq -r '.[] | select(.name == \"channel\") | .id'); \
         kubectl exec -n {ns} deploy/headscale -- headscale preauthkeys create -u \"$uid\" -e 8760h \
           | tr -d '\\n' \
           | kubectl create secret generic relay-tsnet-authkey -n {ns} --from-file=authkey=/dev/stdin --dry-run=client -o yaml \
           | kubectl apply -n {ns} -f - >/dev/null"
    )]).map_err(|e| format!("failed to mint channel authkey: {e}"))?;
    ok("channel pre-auth key minted");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn tenant_token_strips_prefix() {
        assert_eq!(tenant_token("tenant-acme").unwrap(), "acme");
        assert!(tenant_token("acme").is_err());
        assert!(tenant_token("tenant-").is_err());
    }

    #[test]
    fn uid10_strips_dashes_before_truncating() {
        assert_eq!(uid10("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"), "0a1b2c3d4e");
    }

    #[test]
    fn job_state_is_done_on_success_err_on_failure_else_pending() {
        // done
        assert_eq!(job_state(&json!({"succeeded": 1})), Ok(true));
        // failed
        assert!(job_state(&json!({
            "failed": 1,
            "conditions": [{"type": "Failed", "status": "True"}],
        }))
        .is_err());
        // pending
        assert_eq!(job_state(&json!({"active": 1})), Ok(false));
        assert_eq!(
            job_state(&json!({"conditions": [{"type": "Failed", "status": "False"}]})),
            Ok(false)
        );
        assert_eq!(job_state(&json!({})), Ok(false));
    }
}
