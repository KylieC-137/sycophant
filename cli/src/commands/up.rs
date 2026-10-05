use std::fs;

use serde_json::{Map, Value as Json};
use serde_yaml::Value;

use crate::commands::common::{step, warn};
use crate::commands::marker::{self, tenant_ns, MARKER_WRITER_VERBS, SYSTEM_NS, TENANT_NS_PREFIX};
use crate::commands::operator::{self, Operator};
use crate::runner::{run_output, run_silent};
use crate::scope::Scope;

/// `syco tenant up -f <file>`: apply the tenant marker file. Its installer runs
/// `helm upgrade --install`, so re-running it upgrades the tenant in place.
pub(crate) fn run(file: &str) -> Result<(), String> {
    let manifest = fs::read_to_string(file).map_err(|e| format!("failed to read {file}: {e}"))?;
    let (token, capacity) = tenant_fields(&manifest)?;
    let scope = Scope::for_tenant(&tenant_ns(&token))?;
    let op = Operator::login(&scope.oidc_dir())?;
    provision(&scope, &op, &manifest, &capacity)
}

/// The `tenant` and `capacity` a tenant marker file carries.
fn tenant_fields(manifest: &str) -> Result<(String, String), String> {
    let m: Value =
        serde_yaml::from_str(manifest).map_err(|e| format!("marker file is not YAML: {e}"))?;
    let field = |k: &str| m["data"][k].as_str().unwrap_or_default().to_string();
    let token = field("tenant");
    if token.is_empty() {
        return Err("the tenant marker file carries no data.tenant".into());
    }
    Ok((token, field("capacity")))
}

/// The tenant marker for the tenant in scope.
pub(crate) fn tenant_manifest(scope: &Scope, capacity: &str) -> Result<String, String> {
    let ns = scope.release_name()?;
    Ok(tenant_marker(tenant_token(&ns)?, capacity).to_string())
}

/// Apply the tenant marker for the tenant in scope, then let the operator write
/// markers in its namespace.
pub(crate) fn provision(
    scope: &Scope,
    op: &Operator,
    manifest: &str,
    capacity: &str,
) -> Result<(), String> {
    let ns = scope.release_name()?;

    if run_silent("kubectl", &["get", "namespace", &ns]) {
        warn_capacity_unchanged(&ns, capacity);
    }

    step(&format!("Provisioning tenant {ns}"));
    marker::apply(op, "tenant", manifest)?;

    operator::grant_marker_writer(&ns, MARKER_WRITER_VERBS, &op.kubeconfig()?.identity)
}

/// The capacity ResourceQuota is generated once with the namespace; a
/// re-provision does not resize it.
fn warn_capacity_unchanged(ns: &str, capacity: &str) {
    let current = run_output(
        "kubectl",
        &[
            "get",
            "resourcequota",
            &format!("{ns}-capacity"),
            "-n",
            ns,
            "-o",
            "jsonpath={.spec.hard.limits\\.memory}",
        ],
    )
    .unwrap_or_default();
    if !current.is_empty() && !capacity.is_empty() && current != capacity {
        warn(&format!(
            "{ns}: capacity stays {current}; re-provisioning does not resize the quota (asked for {capacity})"
        ));
    }
}

/// The bare tenant token: the namespace minus the `tenant-` prefix the
/// provision reactor composes.
fn tenant_token(ns: &str) -> Result<&str, String> {
    ns.strip_prefix(TENANT_NS_PREFIX)
        .filter(|t| !t.is_empty())
        .ok_or_else(|| format!("tenant namespace must be {TENANT_NS_PREFIX}<name>, got {ns}"))
}

fn tenant_marker(token: &str, capacity: &str) -> Json {
    let mut data = Map::new();
    data.insert("tenant".into(), token.into());
    data.insert("capacity".into(), capacity.into());
    marker::marker("provision-tenant", SYSTEM_NS, data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tenant_token_strips_prefix() {
        assert_eq!(tenant_token("tenant-acme").unwrap(), "acme");
        assert!(tenant_token("acme").is_err());
        assert!(tenant_token("tenant-").is_err());
    }

    #[test]
    fn tenant_fields_read_from_the_marker_file() {
        let f = "kind: ConfigMap\ndata: {tenant: acme, capacity: 2Gi}\n";
        assert_eq!(
            tenant_fields(f).unwrap(),
            ("acme".to_string(), "2Gi".to_string())
        );
        assert!(tenant_fields("kind: ConfigMap\ndata: {capacity: 2Gi}\n").is_err());
    }
}
