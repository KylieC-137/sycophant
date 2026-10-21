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

/// Render and write the `reap-<kind>-<name>` command into tenant `tenant` as the
/// operator and wait for the uninstall Job its uid names.
pub(crate) fn reap(op: &Operator, kind: &str, name: &str, tenant: &str) -> Result<(), String> {
    let manifest = render(
        &format!("{kind}-reap"),
        &[
            "--set-string",
            &format!("{kind}.name={name}"),
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
    let args = values.helm_args();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let manifest = render(&format!("{kind}-provision"), &args)?;
    let op = Operator::login(&Scope::global()?.oidc_dir())?;
    apply(&op, kind, &manifest)
}

/// `syco <kind> down <name> --tenant <t>`: write the reap command and wait for
/// its uninstall.
pub(crate) fn down(kind: &str, name: &str, tenant: &str) -> Result<(), String> {
    let op = Operator::login(&Scope::global()?.oidc_dir())?;
    reap(&op, kind, name, tenant)
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
    fn job_state_succeeded_is_done() {
        assert_eq!(job_state(&json!({"succeeded": 1})), Ok(true));
    }

    #[test]
    fn job_state_failed_condition_is_an_error() {
        assert!(job_state(&json!({
            "failed": 1,
            "conditions": [{"type": "Failed", "status": "True"}],
        }))
        .is_err());
    }

    #[test]
    fn job_state_running_is_pending() {
        assert_eq!(job_state(&json!({"active": 1})), Ok(false));
        assert_eq!(
            job_state(&json!({"conditions": [{"type": "Failed", "status": "False"}]})),
            Ok(false)
        );
        assert_eq!(job_state(&json!({})), Ok(false));
    }
}
