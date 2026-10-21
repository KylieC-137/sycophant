//! Watch the `relay-identity` ConfigMaps and keep the relay's live identity
//! table in sync.
//!
//! Revocation cannot wait for a pod roll, so this is a hot reload: every
//! delivery replaces the table wholesale, via the shared
//! [`shared::configmap_watcher::watch_configmaps`].
//!
//! ConfigMaps that fail validation are reported twice: in the log, and as a
//! Warning Event naming the ConfigMap. ConfigMaps have no status subresource,
//! so `kubectl describe` is the operator's only surface.

use std::sync::Arc;

use k8s_openapi::api::core::v1::ConfigMap;
use kube::runtime::events::{Event, EventType, Recorder, Reporter};
use kube::{Client as KubeClient, Resource};
use tokio::sync::RwLock;

use crate::identity::{apply_delivery, IdentityTable, RowError};

/// `reportingController` on every Event this module publishes.
const REPORTING_CONTROLLER: &str = "relay-controller";

/// The label every relay-identity ConfigMap carries.
const IDENTITY_LABEL: &str = "sycophant.md/type=relay-identity";

/// Watch the relay-identity ConfigMaps in `namespace`, swapping `table` on
/// every delivery. `ready_tx` fires once the initial sync has landed. Each
/// delivery's rejected ConfigMaps are published as Warning Events off the
/// watch loop, since the shared watcher's merge step is synchronous.
pub async fn watch_identities(
    client: KubeClient,
    namespace: &str,
    table: Arc<RwLock<IdentityTable>>,
    ready_tx: tokio::sync::watch::Sender<bool>,
) -> Result<(), String> {
    let events_client = client.clone();
    let events_namespace = namespace.to_string();
    shared::configmap_watcher::watch_configmaps(
        client,
        namespace,
        IDENTITY_LABEL,
        "identity",
        table,
        ready_tx,
        move |current| {
            let cms: Vec<ConfigMap> = current.values().cloned().collect();
            let (parsed, errors) = apply_delivery(&cms);
            let reasons = errors
                .iter()
                .map(|e| format!("{}: {}", e.key, e.reason))
                .collect();
            let client = events_client.clone();
            let namespace = events_namespace.clone();
            tokio::spawn(async move {
                if let Err(e) = publish_row_errors(&client, &namespace, &cms, &errors).await {
                    tracing::warn!(error = %e, "failed to publish identity row Warning Events");
                }
            });
            (parsed, reasons)
        },
    )
    .await
}

/// Raise one Warning Event per rejected ConfigMap, each naming the ConfigMap
/// and why it was rejected. A clean delivery publishes nothing.
pub async fn publish_row_errors(
    client: &KubeClient,
    namespace: &str,
    cms: &[ConfigMap],
    errors: &[RowError],
) -> Result<(), String> {
    if errors.is_empty() {
        return Ok(());
    }

    let recorder = Recorder::new(
        client.clone(),
        Reporter {
            controller: REPORTING_CONTROLLER.into(),
            instance: None,
        },
    );

    for err in errors {
        // The Event hangs off the offending ConfigMap so `kubectl describe`
        // finds it; a conflict error names no single ConfigMap, so it hangs
        // off the first delivery member instead.
        let regarding = cms
            .iter()
            .find(|cm| cm.metadata.name.as_deref() == Some(err.key.as_str()))
            .or_else(|| cms.first());
        let mut reference = regarding.map(|cm| cm.object_ref(&())).unwrap_or_default();
        if reference.namespace.is_none() {
            reference.namespace = Some(namespace.to_string());
        }
        recorder
            .publish(
                &Event {
                    type_: EventType::Warning,
                    reason: "InvalidIdentityRow".into(),
                    // Per-row so each rejected ConfigMap stays separately
                    // addressable rather than collapsing into one series.
                    action: format!("ValidateRow:{}", err.key),
                    note: Some(format!(
                        "identity row \"{}\" rejected and treated as absent: {}",
                        err.key, err.reason
                    )),
                    secondary: None,
                },
                &reference,
            )
            .await
            .map_err(|e| format!("publishing Warning Event for row {}: {e}", err.key))?;
    }

    Ok(())
}
