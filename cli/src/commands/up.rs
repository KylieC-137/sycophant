use std::fs;

use serde_json::{Map, Value as Json};
use serde_yaml::Value;
use sha2::{Digest, Sha256};

use crate::commands::common::{step, warn};
use crate::commands::marker::{self, tenant_ns, MARKER_WRITER_VERBS, SYSTEM_NS, TENANT_NS_PREFIX};
use crate::commands::operator::{self, Operator};
use crate::runner::{run_output, run_silent};
use crate::scope::Scope;
use crate::values;

/// Per-tenant values scaffold, written only-if-absent by `tenant up` so edits
/// survive re-runs.
const SCAFFOLD_VALUES: &str = r#"# Sycophant tenant values.yaml
# Edit this file, then run: syco tenant up -f <tenant marker file>
# Each entry under workspaces, users, and toolsets is installed by its own
# lifecycle marker.
workspaces: {}
"#;

/// One per-slice provision marker: its kind and ConfigMap.
#[derive(Debug)]
struct Slice {
    kind: &'static str,
    marker: Json,
}

impl Slice {
    fn name(&self) -> &str {
        self.marker["metadata"]["name"].as_str().unwrap_or_default()
    }
}

/// `syco tenant up -f <file>`: apply the tenant marker file, then one marker per
/// workspace, user, and toolset in the tenant values file. Each marker's
/// installer runs `helm upgrade --install`, so re-running it upgrades the tenant
/// in place.
pub(crate) fn run(file: &str) -> Result<(), String> {
    let manifest = fs::read_to_string(file).map_err(|e| format!("failed to read {file}: {e}"))?;
    let (token, capacity) = tenant_fields(&manifest)?;
    let scope = Scope::for_tenant(&tenant_ns(&token))?;
    let values_file = scope.values_file();
    if !values_file.exists() {
        if let Some(parent) = values_file.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("failed to create {}: {e}", parent.display()))?;
        }
        fs::write(&values_file, SCAFFOLD_VALUES)
            .map_err(|e| format!("failed to write {}: {e}", values_file.display()))?;
        eprintln!("Scaffolded {}.", values_file.display());
    }
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

/// Apply the tenant marker, then every slice marker for the tenant in scope.
pub(crate) fn provision(
    scope: &Scope,
    op: &Operator,
    manifest: &str,
    capacity: &str,
) -> Result<(), String> {
    let ns = scope.release_name()?;
    let values = values::load(&scope.values_file())?;
    let slices = slices(&ns, &values)?;

    if run_silent("kubectl", &["get", "namespace", &ns]) {
        warn_capacity_unchanged(&ns, capacity);
    }

    step(&format!("Provisioning tenant {ns}"));
    marker::apply(op, "tenant", manifest)?;

    operator::grant_marker_writer(&ns, MARKER_WRITER_VERBS, &op.kubeconfig()?.identity)?;
    for s in &slices {
        step(&format!("Provisioning {}", s.name()));
        marker::apply(op, s.kind, &s.marker.to_string())?;
    }
    Ok(())
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

/// The 10-hex suffix a user marker is named with.
fn user_handle(user: &str) -> String {
    Sha256::digest(user.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>()[..10]
        .to_string()
}

/// Workspace, user, and toolset markers for the values file, in install order.
/// A workspace marker carries the values file narrowed to that one workspace;
/// toolsets and users are left to their own markers, and models to their
/// inference markers.
fn slices(ns: &str, values: &Value) -> Result<Vec<Slice>, String> {
    let yaml = |v: &Value| serde_yaml::to_string(v).map_err(|e| e.to_string());
    let mut out = Vec::new();

    let mut base = values.as_mapping().cloned().unwrap_or_default();
    for k in ["toolsets", "users", "workspaces", "model", "inference"] {
        base.remove(k);
    }
    for (name, ws) in mapping(values, "workspaces") {
        let name = key(name)?;
        let mut v = base.clone();
        v.insert("workspaces".into(), single(name, ws));
        let mut data = Map::new();
        data.insert("values".into(), yaml(&Value::Mapping(v))?.into());
        out.push(Slice {
            kind: "workspace",
            marker: marker::marker(&format!("provision-workspace-{name}"), ns, data),
        });
    }

    for user in values
        .get("users")
        .and_then(Value::as_sequence)
        .into_iter()
        .flatten()
    {
        let user = user.as_str().ok_or("users entries must be strings")?;
        let mut data = Map::new();
        data.insert("user".into(), user.into());
        out.push(Slice {
            kind: "user",
            marker: marker::marker(&format!("provision-user-{}", user_handle(user)), ns, data),
        });
    }

    for (name, ts) in mapping(values, "toolsets") {
        let name = key(name)?;
        let mut v = serde_yaml::Mapping::new();
        v.insert("toolsets".into(), single(name, ts));
        let mut data = Map::new();
        data.insert("values".into(), yaml(&Value::Mapping(v))?.into());
        out.push(Slice {
            kind: "toolset",
            marker: marker::marker(&format!("provision-toolset-{name}"), ns, data),
        });
    }
    Ok(out)
}

fn mapping<'a>(values: &'a Value, k: &str) -> impl Iterator<Item = (&'a Value, &'a Value)> {
    values
        .get(k)
        .and_then(Value::as_mapping)
        .into_iter()
        .flatten()
}

fn key(k: &Value) -> Result<&str, String> {
    k.as_str().ok_or_else(|| format!("non-string key {k:?}"))
}

fn single(name: &str, v: &Value) -> Value {
    let mut m = serde_yaml::Mapping::new();
    m.insert(name.into(), v.clone());
    Value::Mapping(m)
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALUES: &str = r#"
workspaceInit: { image: toolset-git }
model: { local: { format: openai } }
users: ["https://i.example#alice"]
toolsets:
  stdlib: { image: toolset:latest, keepalive: true }
workspaces:
  one: { toolsets: [stdlib] }
  two: {}
"#;

    fn plan() -> Vec<Slice> {
        slices("tenant-acme", &serde_yaml::from_str(VALUES).unwrap()).unwrap()
    }

    fn values_of(s: &Slice) -> Value {
        serde_yaml::from_str(s.marker["data"]["values"].as_str().unwrap()).unwrap()
    }

    #[test]
    fn scaffold_has_workspaces() {
        let v: Value = serde_yaml::from_str(SCAFFOLD_VALUES).unwrap();
        assert!(v.get("workspaces").is_some());
    }

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

    #[test]
    fn slices_in_install_order() {
        let kinds: Vec<_> = plan().iter().map(|s| s.kind).collect();
        assert_eq!(kinds, ["workspace", "workspace", "user", "toolset"]);
    }

    fn data_keys(s: &Slice) -> Vec<&str> {
        let mut keys: Vec<_> = s.marker["data"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort();
        keys
    }

    #[test]
    fn workspace_marker_is_named_for_its_workspace_and_carries_only_values() {
        let p = plan();
        let ws = &p[0];
        assert_eq!(ws.marker["metadata"]["name"], "provision-workspace-one");
        assert_eq!(ws.marker["metadata"]["namespace"], "tenant-acme");
        assert_eq!(data_keys(ws), ["values"]);
        let v = values_of(ws);
        let names: Vec<_> = v["workspaces"].as_mapping().unwrap().keys().collect();
        assert_eq!(names, [&Value::from("one")]);
        for k in ["toolsets", "users", "model"] {
            assert!(v.get(k).is_none(), "{k} must not reach a workspace marker");
        }
        assert_eq!(v["workspaceInit"]["image"], "toolset-git");
    }

    #[test]
    fn user_marker_is_named_for_its_subject_and_carries_only_user() {
        let p = plan();
        let u = &p[2];
        assert_eq!(u.marker["metadata"]["name"], "provision-user-8115163aab");
        assert_eq!(data_keys(u), ["user"]);
        assert_eq!(u.marker["data"]["user"], "https://i.example#alice");
    }

    #[test]
    fn toolset_marker_is_named_for_its_toolset_and_carries_only_values() {
        let p = plan();
        let t = &p[3];
        assert_eq!(t.marker["metadata"]["name"], "provision-toolset-stdlib");
        assert_eq!(data_keys(t), ["values"]);
        let v = values_of(t);
        assert_eq!(v["toolsets"]["stdlib"]["image"], "toolset:latest");
        assert!(v.get("workspaces").is_none());
    }

    #[test]
    fn empty_values_yield_no_slices() {
        let v: Value = serde_yaml::from_str(SCAFFOLD_VALUES).unwrap();
        assert!(slices("tenant-acme", &v).unwrap().is_empty());
    }
}
