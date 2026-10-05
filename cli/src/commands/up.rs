use serde_yaml::Value;

use crate::cli::Values;

use crate::commands::command::{self, tenant_ns, tenant_token, COMMAND_WRITER_VERBS};
use crate::commands::common::{step, warn};
use crate::commands::operator::{self, Operator};
use crate::runner::{run_output, run_silent};
use crate::scope::Scope;

/// `syco tenant up -f <values.yaml>`: render the tenant provision command from
/// the values and apply it. Its installer runs `helm upgrade --install`, so
/// re-running it upgrades the tenant in place.
pub(crate) fn run(values: &Values) -> Result<(), String> {
    let args = values.helm_args();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let manifest = command::render("tenant-provision", &args)?;
    let (token, capacity) = tenant_fields(&manifest)?;
    let scope = Scope::for_tenant(&tenant_ns(&token))?;
    let op = Operator::login(&scope.oidc_dir())?;
    provision(&scope, &op, &manifest, &capacity)
}

/// The `tenant` and `capacity` a rendered tenant provision command carries.
fn tenant_fields(manifest: &str) -> Result<(String, String), String> {
    let m: Value =
        serde_yaml::from_str(manifest).map_err(|e| format!("rendered command is not YAML: {e}"))?;
    let field = |k: &str| m["data"][k].as_str().unwrap_or_default().to_string();
    let token = field("tenant");
    if token.is_empty() {
        return Err("the tenant provision command carries no tenant; set tenant.name".into());
    }
    Ok((token, field("capacity")))
}

/// The tenant provision command for the tenant in scope, rendered from its name
/// and capacity.
pub(crate) fn tenant_manifest(scope: &Scope, capacity: &str) -> Result<String, String> {
    let ns = scope.release_name()?;
    command::render(
        "tenant-provision",
        &[
            "--set-string",
            &format!("tenant.name={}", tenant_token(&ns)?),
            "--set-string",
            &format!("tenant.capacity={capacity}"),
        ],
    )
}

/// Apply the tenant provision command for the tenant in scope, then let the
/// operator write commands in its namespace.
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
    command::apply(op, "tenant", manifest)?;

    operator::grant_command_writer(&ns, COMMAND_WRITER_VERBS, &op.kubeconfig()?.identity)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tenant_fields_read_from_the_rendered_command() {
        let f = "kind: ConfigMap\ndata: {tenant: acme, capacity: 2Gi}\n";
        assert_eq!(
            tenant_fields(f).unwrap(),
            ("acme".to_string(), "2Gi".to_string())
        );
        assert!(tenant_fields("kind: ConfigMap\ndata: {capacity: 2Gi}\n").is_err());
    }
}
