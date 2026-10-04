//! Lifecycle markers: the ConfigMaps the cluster's reactors act on. Each is
//! written under the operator's IdP token. A provision marker stamps a
//! single-shot `provision-<kind>-<uid10>` installer Job in sycophant-system,
//! and a reap marker an `uninstall-<kind>-<uid10>` Job; each deletes its marker
//! once it succeeds.

use serde_json::{json, Map, Value};

use crate::commands::common::{ok, wait_for};
use crate::commands::operator::{self, Operator, OperatorKube};
use crate::runner::{run_output, run_stdin, run_stdin_bytes};

pub(crate) const SYSTEM_NS: &str = "sycophant-system";
pub(crate) const TENANT_NS_PREFIX: &str = "tenant-";
// A leftover marker is deleted before its replacement is created.
pub(crate) const MARKER_WRITER_VERBS: &str = "create,delete";

/// The namespace of tenant `name`.
pub(crate) fn tenant_ns(name: &str) -> String {
    format!("{TENANT_NS_PREFIX}{name}")
}

/// The first ten hex of a uid, which the reactor names a marker's installer
/// objects with.
pub(crate) fn uid10(uid: &str) -> String {
    uid.replace('-', "").chars().take(10).collect()
}

/// A marker ConfigMap named `name` in `ns` carrying `data`.
pub(crate) fn marker(name: &str, ns: &str, data: Map<String, Value>) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": name,
            "namespace": ns,
            "labels": {
                "sycophant.md/lifecycle-marker": "true",
                "app.kubernetes.io/part-of": "sycophant",
            },
        },
        "data": data,
    })
}

/// Write `manifest` as the operator, clearing any leftover marker of the same
/// name first, and return the new marker's uid. A rejection fails here.
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
        return Err("Job failed; the marker was left in place".into());
    }
    Ok(status["succeeded"].as_i64() == Some(1))
}

/// Apply a `kind` marker manifest as the operator and wait for the installer
/// Job its uid names.
pub(crate) fn apply(op: &Operator, kind: &str, manifest: &str) -> Result<(), String> {
    let uid = write(&op.kubeconfig()?, manifest)?;
    wait_job(&format!("provision-{kind}-{}", uid10(&uid)))
}

/// Write the empty `reap-<kind>-<name>` marker into tenant `tenant` as the
/// operator and wait for the uninstall Job its uid names.
pub(crate) fn reap(op: &Operator, kind: &str, name: &str, tenant: &str) -> Result<(), String> {
    let ns = tenant_ns(tenant);
    let kube = op.kubeconfig()?;
    let manifest = marker(&format!("reap-{kind}-{name}"), &ns, Map::new()).to_string();
    let uid = write(&kube, &manifest)?;
    wait_job(&format!("uninstall-{kind}-{}", uid10(&uid)))
}

/// Poll Job `job` in sycophant-system until it succeeds or fails.
fn wait_job(job: &str) -> Result<(), String> {
    ok(&format!("marker written; waiting on Job {job}"));
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
                failure = Some(format!("{job}: {e}"));
                true
            }
        }
    })?;
    failure.map_or(Ok(()), Err)
}

/// `syco <kind> up -f <file>`: apply a marker file and wait for its installer.
pub(crate) fn up(kind: &str, file: &str) -> Result<(), String> {
    let manifest =
        std::fs::read_to_string(file).map_err(|e| format!("failed to read {file}: {e}"))?;
    let op = Operator::login(&crate::scope::Scope::global()?.oidc_dir())?;
    apply(&op, kind, &manifest)
}

/// `syco <kind> down <name> --tenant <t>`: write the reap marker and wait for
/// its uninstall.
pub(crate) fn down(kind: &str, name: &str, tenant: &str) -> Result<(), String> {
    let op = Operator::login(&crate::scope::Scope::global()?.oidc_dir())?;
    reap(&op, kind, name, tenant)
}

/// Write the suspend marker into tenant namespace `ns`. Without a keepalive the
/// tenant scales to zero and stays; with one the reap deletes it that many days on.
pub(crate) fn suspend(op: &Operator, ns: &str, keepalive: Option<&str>) -> Result<(), String> {
    let kube = op.kubeconfig()?;
    operator::grant_marker_writer(ns, MARKER_WRITER_VERBS, &kube.identity)?;
    let mut data = Map::new();
    if let Some(k) = keepalive {
        data.insert("keepalive".into(), k.into());
    }
    write(&kube, &marker("suspend-tenant", ns, data).to_string())?;
    ok(&format!("suspend-tenant marker written in {ns}"));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uid10_strips_dashes_before_truncating() {
        assert_eq!(uid10("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"), "0a1b2c3d4e");
    }

    #[test]
    fn job_state_succeeded_is_done() {
        assert_eq!(job_state(&json!({"succeeded": 1})), Ok(true));
    }

    #[test]
    fn job_state_failed_condition_is_an_error_naming_the_marker() {
        let err = job_state(&json!({
            "failed": 1,
            "conditions": [{"type": "Failed", "status": "True"}],
        }))
        .unwrap_err();
        assert!(err.contains("marker"), "{err}");
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

    #[test]
    fn marker_carries_contract_labels() {
        let m = marker("suspend-tenant", "tenant-acme", Map::new());
        assert_eq!(m["metadata"]["name"], "suspend-tenant");
        assert_eq!(m["metadata"]["namespace"], "tenant-acme");
        assert_eq!(
            m["metadata"]["labels"]["sycophant.md/lifecycle-marker"],
            "true"
        );
        assert_eq!(
            m["metadata"]["labels"]["app.kubernetes.io/part-of"],
            "sycophant"
        );
    }
}
