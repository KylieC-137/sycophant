//! A delivery containing an invalid relay-identity ConfigMap produces a
//! Warning Event naming the ConfigMap and the reason.
//!
//! ConfigMaps have no status subresource, so the Event is the only surface an
//! operator gets; `kubectl describe` shows `note`. The asserted seam is
//! `identity_watcher::publish_row_errors`.

use std::sync::{Arc, Mutex};

use http_body_util::BodyExt;
use k8s_openapi::api::core::v1::ConfigMap;
use kube::client::Body as KubeBody;

use relay_controller::identity::apply_delivery;
use relay_controller::identity_watcher::publish_row_errors;

mod common;
use common::NAMESPACE;

/// Captures the JSON body of every POST and echoes it back as a 201.
fn recording_kube_client(posted: Arc<Mutex<Vec<serde_json::Value>>>) -> kube::Client {
    let svc = tower::service_fn(move |req: http::Request<KubeBody>| {
        let posted = posted.clone();
        async move {
            let (parts, body) = req.into_parts();
            let bytes = body
                .collect()
                .await
                .expect("mock kube: request body must collect")
                .to_bytes();

            if parts.method == http::Method::POST {
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes) {
                    posted.lock().unwrap().push(v);
                }
            }

            let resp = http::Response::builder()
                .status(201)
                .header("content-type", "application/json")
                .body(KubeBody::from(bytes.to_vec()))
                .expect("mock kube: build response");
            Ok::<_, std::convert::Infallible>(resp)
        }
    });
    kube::Client::new(svc, NAMESPACE)
}

/// The shared identity ConfigMap, carrying a fixed uid.
fn identity_cm(name: &str, subject: Option<&str>) -> ConfigMap {
    let mut cm = common::identity_cm(name, subject, "alpha", &[]);
    cm.metadata.uid = Some("11111111-2222-3333-4444-555555555555".into());
    cm
}

fn note_of(event: &serde_json::Value) -> String {
    event
        .get("note")
        .and_then(|n| n.as_str())
        .unwrap_or_default()
        .to_string()
}

/// Each invalid ConfigMap raises its own Warning Event, hanging off and naming
/// it, not one aggregate; the valid one beside them is not implicated.
///
/// Emitting a generic note or a `type: Normal` Event, skipping publication, or
/// hanging every Event off one ConfigMap would leave the operator blind to
/// the exact identity rows the relay dropped.
#[tokio::test]
async fn an_invalid_configmap_raises_a_warning_event_naming_it_and_the_reason() {
    let mut blank_subject = identity_cm("user-blank", Some("   "));
    blank_subject.metadata.uid = Some("22222222-2222-3333-4444-555555555555".into());
    let cms = vec![
        identity_cm("user-badbadbad", None),
        blank_subject,
        identity_cm("user-0a1b2c3d4e", Some("https://issuer.example#alice")),
    ];
    let (_table, errors) = apply_delivery(&cms);
    assert_eq!(errors.len(), 2, "fixture: exactly two CMs are invalid");

    let posted: Arc<Mutex<Vec<serde_json::Value>>> = Arc::new(Mutex::new(Vec::new()));
    publish_row_errors(
        &recording_kube_client(posted.clone()),
        NAMESPACE,
        &cms,
        &errors,
    )
    .await
    .expect("publishing a row error must not fail against a healthy apiserver");

    let events = posted.lock().unwrap().clone();
    assert_eq!(events.len(), 2, "one Warning Event per rejected ConfigMap");
    for name in ["user-badbadbad", "user-blank"] {
        let event = events
            .iter()
            .find(|e| e.pointer("/regarding/name").and_then(|n| n.as_str()) == Some(name))
            .unwrap_or_else(|| panic!("no Event hangs off {name}; events were {events:?}"));

        assert_eq!(
            event.get("type").and_then(|t| t.as_str()),
            Some("Warning"),
            "a rejected identity row is a Warning, not a Normal event"
        );
        assert_eq!(
            event.pointer("/regarding/kind").and_then(|k| k.as_str()),
            Some("ConfigMap"),
            "the Event must hang off the identity ConfigMap so `kubectl describe` finds it"
        );

        let note = note_of(event);
        assert!(
            note.contains(name),
            "the note must name the offending ConfigMap; got: {note}"
        );
        assert!(
            !note.contains("user-0a1b2c3d4e"),
            "the valid ConfigMap must not be implicated; got: {note}"
        );
    }
}
