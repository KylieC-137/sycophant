//! Lifecycle markers: the fixed-name ConfigMaps the cluster's reactors act on.
//! Each is written under the operator's IdP token. A provision marker stamps a
//! single-shot `provision-<kind>-<handle>` installer Job in sycophant-system.

use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

use crate::commands::common::{ok, wait_for};
use crate::commands::operator::{self, Operator, OperatorKube};
use crate::runner::{run_output, run_silent, run_stdin};

pub(crate) const SYSTEM_NS: &str = "sycophant-system";
pub(crate) const TENANT_NS_PREFIX: &str = "tenant-";
// Fixed-name markers in a tenant namespace are re-written, so get and update too.
pub(crate) const TENANT_MARKER_VERBS: &str = "create,update,get";

fn sha256_hex(s: &str) -> String {
    Sha256::digest(s.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The 10-hex handle the reactor names a marker's installer objects with.
pub(crate) fn handle_of(s: &str) -> String {
    sha256_hex(s)[..10].to_string()
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

/// Write `m` as the operator: create it, or replace the fixed-name marker a
/// prior write left.
fn write(kube: &OperatorKube, m: &Value) -> Result<(), String> {
    let name = m["metadata"]["name"].as_str().unwrap_or_default();
    let ns = m["metadata"]["namespace"].as_str().unwrap_or_default();
    let kc = kube.path();
    let exists = run_silent(
        "kubectl",
        &["--kubeconfig", &kc, "get", "configmap", name, "-n", ns],
    );
    let verb = if exists { "replace" } else { "create" };
    run_stdin(
        "kubectl",
        &["--kubeconfig", &kc, verb, "-f", "-"],
        &m.to_string(),
    )?;
    ok(&format!("{name} marker written in {ns}"));
    Ok(())
}

/// Write a provision marker for tenant namespace `ns` and wait for its
/// installer Job. The marker's installer objects from a prior run are cleared
/// first: Kyverno skips a downstream object a different trigger generated and
/// only updates one this trigger did, so a finished Job would never re-run and
/// a stale RoleBinding could be reaped mid-install.
pub(crate) fn provision(
    op: &Operator,
    kind: &str,
    handle: &str,
    ns: &str,
    m: &Value,
) -> Result<(), String> {
    let job = format!("provision-{kind}-{handle}");
    for args in clear_installer_args(&job, ns) {
        run_output(
            "kubectl",
            &args.iter().map(String::as_str).collect::<Vec<_>>(),
        )?;
    }
    write(&op.kubeconfig()?, m)?;
    wait_for(&format!("installer Job {job} succeeded"), 600, || {
        run_output(
            "kubectl",
            &[
                "get",
                "job",
                &job,
                "-n",
                SYSTEM_NS,
                "-o",
                "jsonpath={.status.succeeded}",
            ],
        )
        .is_ok_and(|s| s == "1")
    })
}

fn clear_installer_args(job: &str, ns: &str) -> [Vec<String>; 2] {
    let v = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    [
        v(&[
            "delete",
            "job,serviceaccount",
            job,
            "-n",
            SYSTEM_NS,
            "--ignore-not-found",
        ]),
        v(&["delete", "rolebinding", job, "-n", ns, "--ignore-not-found"]),
    ]
}

/// Write the suspend marker into tenant namespace `ns`. Without a keepalive the
/// tenant scales to zero and stays; with one the reap deletes it that many days on.
pub(crate) fn suspend(op: &Operator, ns: &str, keepalive: Option<&str>) -> Result<(), String> {
    let kube = op.kubeconfig()?;
    operator::grant_marker_writer(ns, TENANT_MARKER_VERBS, &kube.identity)?;
    let mut data = Map::new();
    if let Some(k) = keepalive {
        data.insert("keepalive".into(), k.into());
    }
    write(&kube, &marker("suspend-tenant", ns, data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handle_is_first_ten_hex_of_sha256() {
        assert_eq!(handle_of("acme"), "822b33ad87");
    }

    #[test]
    fn clears_installer_job_sa_and_grant() {
        let [system, tenant] =
            clear_installer_args("provision-workspace-822b33ad87", "tenant-acme");
        assert_eq!(
            system,
            [
                "delete",
                "job,serviceaccount",
                "provision-workspace-822b33ad87",
                "-n",
                SYSTEM_NS,
                "--ignore-not-found"
            ]
        );
        assert_eq!(
            tenant,
            [
                "delete",
                "rolebinding",
                "provision-workspace-822b33ad87",
                "-n",
                "tenant-acme",
                "--ignore-not-found"
            ]
        );
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
