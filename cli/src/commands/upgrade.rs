//! `syco upgrade [--check]` — operator command: validate the cluster and every
//! tenant, then apply new chart versions (cluster first, then each tenant).
//!
//! `--check` runs validation and reports, then stops without applying. Either
//! way, any failed check exits non-zero with nothing applied. Host/toolchain
//! prereqs live in `syco setup`, not here.

use crate::cli::UpgradeCmd;
use crate::commands::common::{ok, step};
use crate::runner::{run_output, run_passthrough, run_silent};
use crate::scope::Scope;

// Every Kyverno policy the cluster chart renders, paired with the resource that
// resolves it. A policy missing from this list is one the gate would let a
// broken cluster carry through an upgrade, so it tracks the chart's policy set
// exactly. Resources are spelled in full: the CEL policy types are split across
// four kinds and no one short name covers them.
const KYVERNO_POLICIES: &[(&str, &str)] = &[
    (
        "validatingpolicies.policies.kyverno.io",
        "cluster-capability-job-gate",
    ),
    (
        "validatingpolicies.policies.kyverno.io",
        "cluster-protect-security",
    ),
    (
        "mutatingpolicies.policies.kyverno.io",
        "cluster-capability-job-gate-envelope",
    ),
    (
        "mutatingpolicies.policies.kyverno.io",
        "cluster-runtime-class",
    ),
    (
        "mutatingpolicies.policies.kyverno.io",
        "tenant-suspend-reactor",
    ),
    (
        "mutatingpolicies.policies.kyverno.io",
        "tenant-suspend-reap-ttl",
    ),
    (
        "generatingpolicies.policies.kyverno.io",
        "tenant-provision-reactor",
    ),
    (
        "generatingpolicies.policies.kyverno.io",
        "tenant-rolebinding-generator",
    ),
];

// The reap policy is checked for presence, not readiness. The cleanup
// controller never writes `conditionStatus.ready` on a DeletingPolicy — it
// records only `lastExecutionTime` — so a readiness check would fail forever.
// Presence is still worth asserting: the policy is compiled by the admission
// webhook when it is applied, so an object that exists is an object that built.
const KYVERNO_SCHEDULED_POLICIES: &[(&str, &str)] =
    &[("deletingpolicies.policies.kyverno.io", "tenant-reap")];

pub(crate) fn run(cmd: UpgradeCmd) -> Result<(), String> {
    let scope = Scope::global()?;

    // Phase 1 — validate cluster + every tenant. Read-only; collect every
    // failure before deciding whether to apply.
    step("Cluster upgrade safety checks");
    let mut cluster_fails = Vec::new();
    require(
        &mut cluster_fails,
        "cluster helm release `sycophant`",
        run_silent("helm", &["status", "sycophant", "-n", "sycophant-system"]),
        "no cluster release \u{2014} run `syco setup`",
    );
    require(
        &mut cluster_fails,
        "Kyverno policies ready",
        KYVERNO_POLICIES
            .iter()
            .all(|(resource, name)| policy_ready(resource, name)),
        "Kyverno policies not Ready \u{2014} check `kubectl get vpol,mpol,gpol`",
    );
    require(
        &mut cluster_fails,
        "Kyverno scheduled policies present",
        KYVERNO_SCHEDULED_POLICIES
            .iter()
            .all(|(resource, name)| policy_present(resource, name)),
        "reap policy missing \u{2014} check `kubectl get dpol`",
    );
    // No-downgrade guard: `syco upgrade` applies the charts bundled in THIS
    // binary, so a syco older than the cluster would roll the platform back.
    // (The release-present check above covers a missing release, so skew is only
    // checked when a version is readable.) Compares via version_gte, not full
    // semver precedence — pre-release ordering isn't worth a crate for `x.y.z` tags.
    if let Some(cluster_ver) = cluster_app_version() {
        let cli_ver = env!("CARGO_PKG_VERSION");
        require(
            &mut cluster_fails,
            "syco not older than the cluster",
            version_gte(cli_ver, &cluster_ver),
            &format!(
                "cluster is v{cluster_ver} but this syco is v{cli_ver} \u{2014} `syco upgrade` \
                 would downgrade the platform; update syco instead"
            ),
        );
    }

    let tenants = tenant_namespaces(&kubectl_tenant_namespaces()?);
    let mut tenant_failures: Vec<(String, Vec<String>)> = Vec::new();
    for ns in &tenants {
        step(&format!("Tenant `{ns}` upgrade safety checks"));
        let mut fails = Vec::new();
        require(
            &mut fails,
            "tenant helm release",
            run_silent("helm", &["status", ns, "-n", ns]),
            "no tenant release \u{2014} run `syco tenant up --ns <ns>`",
        );
        require(
            &mut fails,
            "data PVCs present",
            !pvc_names(ns).is_empty(),
            "no data PVCs \u{2014} tenant storage missing/half-removed",
        );
        if fails.is_empty() {
            ok(&format!("tenant `{ns}` checks passed"));
        } else {
            tenant_failures.push((ns.clone(), fails));
        }
    }

    if let Some(msg) = summarize_failures(&cluster_fails, &tenant_failures) {
        return Err(msg);
    }
    if cmd.check {
        ok(&format!(
            "all checks passed: cluster + {} tenant namespace(s)",
            tenants.len()
        ));
        return Ok(());
    }

    // Phase 2 — apply. Cluster first: the upgrade ordering is enforced by this
    // sequence, not by any runtime version guard.
    //
    // Deliver THIS binary's charts, not the stale ones a prior `setup`/`up` left in
    // the config root. A new top-level `required` chart value needs a `values.yaml`
    // default, else the `--reuse-values` render below fails.
    crate::sync::extract_assets(&scope)?;
    step("Upgrading cluster");
    let dir = scope.cluster_chart_dir();
    let cluster_chart = dir.to_string_lossy().into_owned();
    // `--reuse-values` carries the operator's setup-time overrides forward; a
    // bare upgrade re-renders from chart values.yaml and drops the `idp` values
    // the schema marks `required`.
    run_passthrough(
        "helm",
        &[
            "upgrade",
            "--install",
            "sycophant",
            &cluster_chart,
            "-n",
            "sycophant-system",
            "--reuse-values",
            "--wait",
            "--timeout=5m",
        ],
    )?;
    ok("cluster upgraded");

    // `--reuse-values` is mandatory: a bare `helm upgrade` resets values to
    // chart defaults, wiping each tenant's config. Tenant data lives in PVCs,
    // untouched by helm regardless.
    let tenant_chart = scope.tenant_chart_dir().to_string_lossy().into_owned();
    for ns in &tenants {
        step(&format!("Upgrading tenant `{ns}`"));
        run_passthrough(
            "helm",
            &[
                "upgrade",
                "--install",
                ns,
                &tenant_chart,
                "-n",
                ns,
                "--reuse-values",
            ],
        )?;
        ok(&format!("tenant `{ns}` upgraded"));
    }
    Ok(())
}

// Local copy of setup::require; unify only if a 3rd caller appears.
fn require(fails: &mut Vec<String>, label: &str, present: bool, detail: &str) {
    if present {
        ok(label);
    } else {
        fails.push(format!("  \u{2717} {label}\n      {detail}"));
    }
}

// -- pure helpers (unit-tested; the shell wrappers below are covered live) --

/// Namespace names from a whitespace/newline-separated `kubectl get ns` list.
fn tenant_namespaces(kubectl_out: &str) -> Vec<String> {
    kubectl_out.split_whitespace().map(str::to_string).collect()
}

/// Combine cluster + per-tenant validation failures into one message, or `None`
/// when everything passed.
fn summarize_failures(cluster: &[String], tenants: &[(String, Vec<String>)]) -> Option<String> {
    if cluster.is_empty() && tenants.is_empty() {
        return None;
    }
    let mut sections = Vec::new();
    if !cluster.is_empty() {
        sections.push(format!("cluster:\n{}", cluster.join("\n")));
    }
    for (ns, fails) in tenants {
        sections.push(format!("tenant `{ns}`:\n{}", fails.join("\n")));
    }
    let names: Vec<&str> = tenants.iter().map(|(ns, _)| ns.as_str()).collect();
    Some(format!(
        "aborting: upgrade validation failed ({} cluster check(s), {} tenant namespace(s): {}); nothing applied:\n{}",
        cluster.len(),
        tenants.len(),
        names.join(", "),
        sections.join("\n"),
    ))
}

// -- shell wrappers (read-only) --

fn kubectl_tenant_namespaces() -> Result<String, String> {
    run_output(
        "kubectl",
        &[
            "get",
            "ns",
            "-l",
            "app.kubernetes.io/part-of=sycophant-tenant",
            "-o",
            "jsonpath={range .items[*]}{.metadata.name}{\" \"}{end}",
        ],
    )
    .map_err(|e| format!("aborting: cannot list tenant namespaces ({e}); nothing applied"))
}

/// Readiness of one Kyverno policy, reported as a boolean at
/// `.status.conditionStatus.ready` by every kind that reports it at all.
fn policy_ready(resource: &str, name: &str) -> bool {
    run_output(
        "kubectl",
        &[
            "get",
            resource,
            name,
            "-o",
            "jsonpath={.status.conditionStatus.ready}",
        ],
    )
    .map(|s| parse_ready(&s))
    .unwrap_or(false)
}

/// True when the readiness field reads exactly `true` (whitespace trimmed).
fn parse_ready(s: &str) -> bool {
    s.trim() == "true"
}

/// Whether one Kyverno policy exists, for the kinds that report no readiness.
fn policy_present(resource: &str, name: &str) -> bool {
    run_output(
        "kubectl",
        &["get", resource, name, "-o", "jsonpath={.metadata.name}"],
    )
    .map(|s| parse_present(&s, name))
    .unwrap_or(false)
}

/// True when the returned resource name (whitespace trimmed) matches the query.
fn parse_present(s: &str, name: &str) -> bool {
    s.trim() == name
}

/// The `sycophant` cluster release's appVersion from helm metadata, or `None`
/// if the release is absent/unreadable (the release-present check covers that).
fn cluster_app_version() -> Option<String> {
    let out = run_output("helm", &["list", "-n", "sycophant-system", "-o", "json"]).ok()?;
    let releases: serde_json::Value = serde_json::from_str(&out).ok()?;
    releases
        .as_array()?
        .iter()
        .find(|r| r.get("name").and_then(serde_json::Value::as_str) == Some("sycophant"))
        .and_then(|r| r.get("app_version").and_then(serde_json::Value::as_str))
        .map(str::to_string)
}

/// True when semver `a` >= `b`, comparing numeric MAJOR.MINOR.PATCH (so 0.10 > 0.9).
/// Missing/non-numeric parts count as 0.
fn version_gte(a: &str, b: &str) -> bool {
    fn parts(v: &str) -> (u64, u64, u64) {
        let mut it = v
            .split(['.', '-', '+'])
            .filter_map(|p| p.parse::<u64>().ok());
        (
            it.next().unwrap_or(0),
            it.next().unwrap_or(0),
            it.next().unwrap_or(0),
        )
    }
    parts(a) >= parts(b)
}

fn pvc_names(ns: &str) -> String {
    run_output(
        "kubectl",
        &[
            "get",
            "pvc",
            "-n",
            ns,
            "-o",
            "jsonpath={range .items[*]}{.metadata.name}{\" \"}{end}",
        ],
    )
    .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_gte_orders_numerically_not_lexically() {
        assert!(version_gte("0.1.0", "0.1.0"), "equal is allowed");
        assert!(version_gte("0.2.0", "0.1.0"), "newer syco is allowed");
        // Mutant using string compare would pass this (downgrade slips through).
        assert!(!version_gte("0.1.0", "0.2.0"), "older syco must be blocked");
        assert!(
            version_gte("0.10.0", "0.9.0"),
            "numeric, not lexical (0.10 > 0.9)"
        );
        assert!(version_gte("1.0.0", "0.9.9"));
    }

    #[test]
    fn tenant_namespaces_splits_names_and_empty_yields_none() {
        assert_eq!(
            tenant_namespaces("alpha beta\ngamma  "),
            vec!["alpha", "beta", "gamma"]
        );
        // Mutant returning [] unconditionally would silently upgrade nothing.
        assert!(tenant_namespaces("   \n").is_empty());
    }

    #[test]
    fn parse_ready_true_only_for_trimmed_true() {
        assert!(parse_ready("true"));
        assert!(parse_ready("  true\n"));
        assert!(!parse_ready("false"));
        assert!(!parse_ready(""));
        assert!(!parse_ready("True"));
    }

    #[test]
    fn parse_present_true_only_on_trimmed_name_match() {
        assert!(parse_present("tenant-reap", "tenant-reap"));
        assert!(parse_present("  tenant-reap\n", "tenant-reap"));
        assert!(!parse_present("", "tenant-reap"));
        assert!(!parse_present("other-policy", "tenant-reap"));
    }

    #[test]
    fn summarize_failures_none_when_all_pass() {
        // Mutant returning Some(..) unconditionally would abort a healthy platform.
        assert_eq!(summarize_failures(&[], &[]), None);
    }

    #[test]
    fn summarize_failures_reports_cluster_issues_alone() {
        // Mutant ignoring cluster fails would apply onto a broken cluster.
        let msg = summarize_failures(&["  \u{2717} CRDs present".to_string()], &[])
            .expect("must abort when the cluster fails");
        assert!(msg.contains("cluster"), "missing cluster section: {msg}");
    }

    #[test]
    fn summarize_failures_names_every_failing_namespace() {
        let tenants = vec![
            (
                "alpha".to_string(),
                vec!["  \u{2717} tenant helm release".to_string()],
            ),
            (
                "beta".to_string(),
                vec!["  \u{2717} data PVCs present".to_string()],
            ),
        ];
        let msg = summarize_failures(&[], &tenants).expect("must abort when any ns fails");
        // Report ALL failing namespaces, not just the first. A mutant using
        // `.first()`/`[0]`/`take(1)` drops beta.
        assert!(msg.contains("alpha"), "missing alpha: {msg}");
        assert!(msg.contains("beta"), "missing beta: {msg}");
        assert!(
            msg.contains('2'),
            "count should reflect both failures: {msg}"
        );
    }
}
