//! Per-listener credential classes.
//!
//! Each external listener serves exactly one credential class: 9091 accepts
//! only person tokens, 9092 only channel-adapter ServiceAccount tokens, 9090
//! (internal) only harness SA tokens. A per-class interceptor stamps the
//! listener kind onto the request extensions so handlers branch on the
//! stamped class and never on the credential's shape.

use tonic::service::{Interceptor, InterceptorLayer};

/// The credential class a listener demands. `Copy` so the per-request layer
/// can stamp it cheaply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListenerClass {
    /// A person token (OIDC subject) on the app/terminal-client listener.
    PersonToken,
    /// An `adapter-<channel>` ServiceAccount token on the adapter listener.
    AdapterToken,
}

/// Layer stamping `class` on every request's extensions. It verifies
/// nothing — the credential class is a property of the socket, not of the
/// request.
#[allow(clippy::result_large_err)]
pub fn class_layer(class: ListenerClass) -> InterceptorLayer<impl Interceptor + Clone> {
    InterceptorLayer::new(move |mut req: tonic::Request<()>| {
        req.extensions_mut().insert(class);
        Ok::<_, tonic::Status>(req)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use http::Request;
    use tonic::body::Body;
    use tower::util::ServiceExt;
    use tower::{Layer, Service};

    #[tokio::test]
    async fn the_layer_stamps_the_class_on_the_extensions() {
        use http_body_util::{BodyExt, Full};

        // An inner service that echoes the extensions' class back.
        let inner = tower::service_fn(|req: Request<Body>| async move {
            let class: ListenerClass = *req
                .extensions()
                .get()
                .expect("the layer must stamp the class");
            let resp = http::Response::builder()
                .status(200)
                .body(Full::new(bytes::Bytes::from(format!("{class:?}"))))
                .unwrap();
            Ok::<_, std::convert::Infallible>(resp)
        });
        let mut svc = class_layer(ListenerClass::AdapterToken).layer(inner);
        let resp = svc
            .ready()
            .await
            .unwrap()
            .call(Request::new(Body::empty()))
            .await
            .unwrap();
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(&bytes[..], b"AdapterToken");
    }
}
