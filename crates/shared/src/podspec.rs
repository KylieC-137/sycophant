//! Shared PodSpec fragments. Centralizes the security-load-bearing pieces
//! every sycophant capability-job pod needs so the controllers that spawn them
//! can't drift.

use k8s_openapi::api::core::v1::{
    ProjectedVolumeSource, ServiceAccountTokenProjection, Volume, VolumeMount, VolumeProjection,
};

/// Build the projected single-audience SA-token `Volume` + read-only
/// `VolumeMount` pair a capability-job pod mounts at the kubelet default path. The
/// token carries exactly `audience`; paired with
/// `automountServiceAccountToken=false` on the PodSpec (kept at the call
/// site) it replaces the kubelet default token. The path, expiration, and
/// read-only mount are fixed here so the spawners can't diverge on the
/// trust boundary.
pub fn sa_token_volume(volume_name: &str, audience: &str) -> (Volume, VolumeMount) {
    let volume = Volume {
        name: volume_name.to_string(),
        projected: Some(ProjectedVolumeSource {
            default_mode: None,
            sources: Some(vec![VolumeProjection {
                service_account_token: Some(ServiceAccountTokenProjection {
                    path: "token".to_string(),
                    audience: Some(audience.to_string()),
                    expiration_seconds: Some(3600),
                }),
                ..Default::default()
            }]),
        }),
        ..Default::default()
    };
    let mount = VolumeMount {
        name: volume_name.to_string(),
        mount_path: "/var/run/secrets/kubernetes.io/serviceaccount".to_string(),
        read_only: Some(true),
        ..Default::default()
    };
    (volume, mount)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pull the single projected SA-token projection out of the Volume so
    /// the audience/expiration assertions read the value the pod actually
    /// mounts, not a fixture echo.
    fn token_projection(volume: &Volume) -> &ServiceAccountTokenProjection {
        volume
            .projected
            .as_ref()
            .expect("projected source")
            .sources
            .as_ref()
            .expect("sources")
            .first()
            .expect("one projection")
            .service_account_token
            .as_ref()
            .expect("sa-token projection")
    }

    /// The projected token must carry exactly the requested single audience
    /// and the fixed 3600s expiration. The mount must reference the Volume by
    /// name, sit at the kubelet default path clients read from, and be
    /// read-only.
    #[test]
    fn sa_token_volume_projects_audience_and_expiry_read_only_at_kubelet_path() {
        let (volume, mount) = sa_token_volume("relay-sa-token", "relay.internal");
        let projection = token_projection(&volume);
        assert_eq!(projection.audience.as_deref(), Some("relay.internal"));
        assert_eq!(projection.expiration_seconds, Some(3600));
        assert_eq!(mount.name, "relay-sa-token");
        assert_eq!(mount.name, volume.name);
        assert_eq!(
            mount.mount_path,
            "/var/run/secrets/kubernetes.io/serviceaccount"
        );
        assert_eq!(mount.read_only, Some(true));
    }
}
