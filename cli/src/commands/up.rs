use std::fs;

use serde_json::{Map, Value as Json};
use serde_yaml::Value;

use crate::commands::common::{ok, step, wait_for, warn};
use crate::commands::marker::{self, handle_of, SYSTEM_NS, TENANT_MARKER_VERBS, TENANT_NS_PREFIX};
use crate::commands::operator::{self, Operator};
use crate::runner::{run_output, run_silent};
use crate::scope::Scope;
use crate::values;

/// Per-tenant values scaffold, written only-if-absent by `tenant up` so edits
/// survive re-runs.
const SCAFFOLD_VALUES: &str = r#"# Sycophant tenant values.yaml
# Edit this file, then run: syco tenant up --ns <name> --capacity <quantity>
# Each entry under workspaces, users, and toolsets is installed by its own
# lifecycle marker; every other key configures the tenant's base release.
workspaces: {}
"#;

/// One per-slice provision marker: its kind, handle, and ConfigMap.
#[derive(Debug)]
struct Slice {
    kind: &'static str,
    handle: String,
    marker: Json,
}

impl Slice {
    /// The release its installer names: `<kind>-<name>`, or `user-<handle>`.
    fn release(&self) -> String {
        let data = &self.marker["data"];
        match self.kind {
            "user" => format!("user-{}", self.handle),
            kind => format!("{kind}-{}", data[kind].as_str().unwrap_or_default()),
        }
    }
}

/// `syco tenant up --ns tenant-<token> --capacity <q>` — provision or
/// re-provision a tenant through the lifecycle markers: the tenant marker
/// carrying the base values, then one marker per workspace, user, and toolset
/// in the values file. Each marker's installer runs `helm upgrade --install`, so
/// re-running it upgrades the tenant in place.
pub(crate) fn run(scope: &Scope, capacity: &str) -> Result<(), String> {
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
    provision(scope, &op, capacity, &mut || Ok(()))
}

/// Write every marker for the tenant in scope. `after_base` runs once the base
/// installer Job has succeeded and the relay is serving, before any slice.
pub(crate) fn provision(
    scope: &Scope,
    op: &Operator,
    capacity: &str,
    after_base: &mut dyn FnMut() -> Result<(), String>,
) -> Result<(), String> {
    let ns = scope.release_name()?;
    let token = tenant_token(&ns)?;
    let values = values::load(&scope.values_file())?;
    let base = base_values(&values)?;
    let slices = slices(token, &ns, &values)?;

    let existing = run_silent("kubectl", &["get", "namespace", &ns]);
    let legacy = existing && is_legacy(&ns)?;
    if existing {
        warn_capacity_unchanged(&ns, capacity);
    }

    step(&format!("Provisioning tenant {ns}"));
    if legacy {
        // A tenant installed as one host-side helm release keeps its release
        // record in Secrets. The marker installers keep theirs in ConfigMaps and
        // adopt the live objects, so the old record is dropped, not the objects.
        run_output(
            "kubectl",
            &[
                "delete",
                "secret",
                "-n",
                &ns,
                "-l",
                "owner=helm",
                "--ignore-not-found",
            ],
        )?;
        ok(&format!(
            "{ns}: dropped the single-release helm record; markers adopt its objects"
        ));
    }
    // The tenant marker name is shared by every tenant; clear a prior one.
    run_output(
        "kubectl",
        &[
            "delete",
            "configmap",
            "provision-tenant",
            "-n",
            SYSTEM_NS,
            "--ignore-not-found",
        ],
    )?;
    let handle = handle_of(token);
    marker::provision(
        op,
        "tenant",
        &handle,
        &ns,
        &tenant_marker(token, &handle, capacity, &base),
    )?;
    // The base relay-controller must be serving before the first workspace's
    // grants land, so it merges them live rather than at boot.
    wait_for("base relay-controller Available", 300, || {
        run_output(
            "kubectl",
            &[
                "get",
                "deploy",
                "relay-controller",
                "-n",
                &ns,
                "-o",
                "jsonpath={.status.availableReplicas}",
            ],
        )
        .is_ok_and(|r| r.parse::<u32>().is_ok_and(|n| n >= 1))
    })?;
    after_base()?;

    operator::grant_marker_writer(&ns, TENANT_MARKER_VERBS, &op.kubeconfig()?.identity)?;
    for s in &slices {
        step(&format!("Provisioning {} {}", s.kind, s.handle));
        marker::provision(op, s.kind, &s.handle, &ns, &s.marker)?;
    }
    if legacy {
        // The single release bound its users in one `provision-identity`
        // RoleBinding; the user markers now bind each one separately.
        run_output(
            "kubectl",
            &[
                "delete",
                "rolebinding",
                "provision-identity",
                "-n",
                &ns,
                "--ignore-not-found",
            ],
        )?;
    }
    for release in orphan_releases(&deployed_releases(&ns)?, &ns, &slices) {
        warn(&format!(
            "{ns}: release {release} has no entry in the values file and is left installed; no marker removes a slice"
        ));
    }
    Ok(())
}

/// True when the tenant still carries a host-side helm release record (the
/// Secrets storage driver) from before the marker split.
fn is_legacy(ns: &str) -> Result<bool, String> {
    let out = run_output(
        "kubectl",
        &["get", "secret", "-n", ns, "-l", "owner=helm", "-o", "name"],
    )?;
    Ok(!out.trim().is_empty())
}

/// Release names with a deployed record in the tenant's ConfigMap storage.
fn deployed_releases(ns: &str) -> Result<Vec<String>, String> {
    let out = run_output(
        "kubectl",
        &[
            "get",
            "configmap",
            "-n",
            ns,
            "-l",
            "owner=helm,status=deployed",
            "-o",
            "jsonpath={range .items[*]}{.metadata.labels.name}{\" \"}{end}",
        ],
    )?;
    Ok(out.split_whitespace().map(str::to_string).collect())
}

/// Deployed slice releases the values file no longer names.
fn orphan_releases(deployed: &[String], ns: &str, slices: &[Slice]) -> Vec<String> {
    let wanted: Vec<String> = slices.iter().map(Slice::release).collect();
    let mut out: Vec<String> = deployed
        .iter()
        .filter(|r| r.as_str() != ns && !wanted.contains(r))
        .cloned()
        .collect();
    out.sort();
    out.dedup();
    out
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
    if !current.is_empty() && current != capacity {
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

fn tenant_marker(token: &str, handle: &str, capacity: &str, values: &str) -> Json {
    let mut data = Map::new();
    data.insert("tenant".into(), token.into());
    data.insert("handle".into(), handle.into());
    data.insert("capacity".into(), capacity.into());
    data.insert("values".into(), values.into());
    // The provision reactors match only a policy keepalive value.
    data.insert("keepalive".into(), "0".into());
    marker::marker("provision-tenant", SYSTEM_NS, data)
}

/// The base release's values: everything but the keys the per-slice markers own.
fn base_values(values: &Value) -> Result<String, String> {
    let mut base = values.as_mapping().cloned().unwrap_or_default();
    for k in ["workspaces", "users", "toolsets"] {
        base.remove(k);
    }
    serde_yaml::to_string(&Value::Mapping(base)).map_err(|e| e.to_string())
}

/// Workspace, user, and toolset markers for the values file, in install order.
/// A workspace marker carries the values file narrowed to that one workspace;
/// toolsets and users are left to their own markers.
fn slices(token: &str, ns: &str, values: &Value) -> Result<Vec<Slice>, String> {
    let yaml = |v: &Value| serde_yaml::to_string(v).map_err(|e| e.to_string());
    let mut out = Vec::new();

    let mut base = values.as_mapping().cloned().unwrap_or_default();
    base.remove("toolsets");
    base.remove("users");
    base.remove("workspaces");
    for (name, ws) in mapping(values, "workspaces") {
        let name = key(name)?;
        let mut v = base.clone();
        v.insert("workspaces".into(), single(name, ws));
        let handle = handle_of(&format!("{token}/{name}"));
        let mut data = Map::new();
        data.insert("workspace".into(), name.into());
        data.insert("handle".into(), handle.clone().into());
        data.insert("values".into(), yaml(&Value::Mapping(v))?.into());
        out.push(Slice {
            kind: "workspace",
            marker: marker::marker("provision-workspace", ns, data),
            handle,
        });
    }

    for user in values
        .get("users")
        .and_then(Value::as_sequence)
        .into_iter()
        .flatten()
    {
        let user = user.as_str().ok_or("users entries must be strings")?;
        let handle = handle_of(&format!("{token}/{user}"));
        let mut data = Map::new();
        data.insert("user".into(), user.into());
        data.insert("handle".into(), handle.clone().into());
        out.push(Slice {
            kind: "user",
            marker: marker::marker("provision-user", ns, data),
            handle,
        });
    }

    for (name, ts) in mapping(values, "toolsets") {
        let name = key(name)?;
        let mut v = serde_yaml::Mapping::new();
        v.insert("toolsets".into(), single(name, ts));
        let handle = handle_of(&format!("{token}/{name}"));
        let mut data = Map::new();
        data.insert("toolset".into(), name.into());
        data.insert("handle".into(), handle.clone().into());
        data.insert("values".into(), yaml(&Value::Mapping(v))?.into());
        out.push(Slice {
            kind: "toolset",
            marker: marker::marker("provision-toolset", ns, data),
            handle,
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
users: ["https://i.example#alice"]
toolsets:
  stdlib: { image: toolset:latest, keepalive: true }
workspaces:
  one: { toolsets: [stdlib] }
  two: {}
"#;

    fn plan() -> Vec<Slice> {
        slices(
            "acme",
            "tenant-acme",
            &serde_yaml::from_str(VALUES).unwrap(),
        )
        .unwrap()
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
    fn tenant_marker_shape() {
        let m = tenant_marker("acme", "822b33ad87", "2Gi", "storageClass: fast\n");
        assert_eq!(m["metadata"]["name"], "provision-tenant");
        assert_eq!(m["metadata"]["namespace"], SYSTEM_NS);
        assert_eq!(m["data"]["tenant"], "acme");
        assert_eq!(m["data"]["handle"], "822b33ad87");
        assert_eq!(m["data"]["capacity"], "2Gi");
        assert_eq!(m["data"]["keepalive"], "0");
        assert_eq!(m["data"]["values"], "storageClass: fast\n");
    }

    #[test]
    fn base_values_drop_slice_keys() {
        let v: Value =
            serde_yaml::from_str(&base_values(&serde_yaml::from_str(VALUES).unwrap()).unwrap())
                .unwrap();
        assert_eq!(v["workspaceInit"]["image"], "toolset-git");
        for k in ["workspaces", "users", "toolsets"] {
            assert!(v.get(k).is_none(), "{k} must not reach the base release");
        }
        assert_eq!(
            base_values(&serde_yaml::from_str(SCAFFOLD_VALUES).unwrap()).unwrap(),
            "{}\n"
        );
    }

    #[test]
    fn slices_in_install_order() {
        let kinds: Vec<_> = plan().iter().map(|s| s.kind).collect();
        assert_eq!(kinds, ["workspace", "workspace", "user", "toolset"]);
    }

    #[test]
    fn workspace_marker_narrows_to_one_workspace() {
        let p = plan();
        let ws = &p[0];
        assert_eq!(ws.marker["metadata"]["name"], "provision-workspace");
        assert_eq!(ws.marker["metadata"]["namespace"], "tenant-acme");
        assert_eq!(ws.marker["data"]["workspace"], "one");
        assert_eq!(ws.handle, handle_of("acme/one"));
        assert_eq!(ws.marker["data"]["handle"], ws.handle.as_str());
        let v = values_of(ws);
        let names: Vec<_> = v["workspaces"].as_mapping().unwrap().keys().collect();
        assert_eq!(names, [&Value::from("one")]);
        assert!(v.get("toolsets").is_none());
        assert!(v.get("users").is_none());
        assert_eq!(v["workspaceInit"]["image"], "toolset-git");
    }

    #[test]
    fn user_marker_carries_subject() {
        let p = plan();
        let u = &p[2];
        assert_eq!(u.marker["metadata"]["name"], "provision-user");
        assert_eq!(u.marker["data"]["user"], "https://i.example#alice");
        assert_eq!(u.handle, handle_of("acme/https://i.example#alice"));
    }

    #[test]
    fn toolset_marker_carries_only_its_toolset() {
        let p = plan();
        let t = &p[3];
        assert_eq!(t.marker["metadata"]["name"], "provision-toolset");
        assert_eq!(t.marker["data"]["toolset"], "stdlib");
        assert_eq!(t.handle, handle_of("acme/stdlib"));
        let v = values_of(t);
        assert_eq!(v["toolsets"]["stdlib"]["image"], "toolset:latest");
        assert!(v.get("workspaces").is_none());
    }

    #[test]
    fn slice_releases_match_the_installer_names() {
        let names: Vec<_> = plan().iter().map(Slice::release).collect();
        assert_eq!(
            names,
            [
                "workspace-one".to_string(),
                "workspace-two".to_string(),
                format!("user-{}", handle_of("acme/https://i.example#alice")),
                "toolset-stdlib".to_string(),
            ]
        );
    }

    #[test]
    fn orphans_are_deployed_slices_the_values_no_longer_name() {
        let deployed: Vec<String> = [
            "tenant-acme",
            "workspace-one",
            "workspace-gone",
            "toolset-old",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        assert_eq!(
            orphan_releases(&deployed, "tenant-acme", &plan()),
            ["toolset-old", "workspace-gone"]
        );
    }

    #[test]
    fn empty_values_yield_no_slices() {
        let v: Value = serde_yaml::from_str(SCAFFOLD_VALUES).unwrap();
        assert!(slices("acme", "tenant-acme", &v).unwrap().is_empty());
    }
}
