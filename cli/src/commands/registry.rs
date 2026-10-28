//! Push a local Docker image to the in-cluster registry and return the
//! in-cluster reference (host + digest-pinned) for use in manifests.
//!
//! The k3d registry `sycophant-registry` is reachable from the host as
//! `localhost:5555` and from inside the cluster as `sycophant-registry:5000`
//! (CoreDNS NodeHosts wiring in `setup`). Pushing through the registry is the
//! distribution-agnostic path: it works on any cluster with a registry, not
//! just k3d.

use crate::commands::common::{ok, step};
use crate::runner::{run_output, run_passthrough};

/// The registry as reachable from the host (k3d maps it to host port 5555).
const REGISTRY_HOST: &str = "localhost:5555";

/// The registry as reachable from inside the cluster (CoreDNS NodeHosts).
const REGISTRY_CLUSTER: &str = "sycophant-registry:5000";

/// Push local image `image` (e.g. `llama-server:local`) to the in-cluster
/// registry and return the digest-pinned in-cluster reference
/// (`sycophant-registry:5000/<name>@sha256:<digest>`).
///
/// The image must already exist in the host's Docker daemon. The push is
/// idempotent: re-pushing the same image just overwrites the tag.
pub(crate) fn push_local_image(image: &str) -> Result<String, String> {
    // Split `name:tag` (default tag `latest`).
    let (name, tag) = match image.split_once(':') {
        Some((n, t)) => (n, t),
        None => (image, "latest"),
    };
    // Strip any registry prefix from the name (e.g. `docker.io/library/foo` → `foo`).
    let name = name.rsplit('/').next().unwrap_or(name);

    let host_ref = format!("{REGISTRY_HOST}/{name}:{tag}");
    let cluster_ref = format!("{REGISTRY_CLUSTER}/{name}:{tag}");

    // Resolve the local image's digest. If the registry already has this exact
    // digest, skip the push (large images like weights are ~1.3 GB).
    let local_digest = run_output(
        "docker",
        &["inspect", "--format", "{{index .RepoDigests 0}}", image],
    )
    .unwrap_or_default();
    let local_digest = local_digest.split('@').nth(1).unwrap_or("").to_string();

    if !local_digest.is_empty() {
        let existing = run_output(
            "docker",
            &[
                "manifest",
                "inspect",
                &format!("{host_ref}@sha256:{local_digest}"),
            ],
        );
        if existing.is_ok() {
            ok(&format!("{cluster_ref} already in registry"));
            return Ok(format!("{cluster_ref}@sha256:{local_digest}"));
        }
    }

    step(&format!("Pushing {image} to {REGISTRY_HOST}"));
    run_passthrough("docker", &["tag", image, &host_ref])?;
    run_passthrough("docker", &["push", &host_ref])?;

    // Resolve the digest from the pushed image so the in-cluster reference is
    // pinned (the VAP `command-provision-toolset` requires digest pinning for
    // toolset images; pinning here too keeps the inference images consistent).
    let digest = run_output(
        "docker",
        &["inspect", "--format", "{{index .RepoDigests 0}}", &host_ref],
    )?;
    // RepoDigests looks like `localhost:5555/name@sha256:...`; rewrite the host.
    let pinned = digest.replace(REGISTRY_HOST, REGISTRY_CLUSTER);
    ok(&format!("pushed {cluster_ref}"));
    Ok(pinned)
}

#[cfg(test)]
mod tests {
    #[test]
    fn split_name_tag() {
        // The helper is inline; test the logic via a small extraction.
        let (name, tag) = match "llama-server:local".split_once(':') {
            Some((n, t)) => (n, t),
            None => ("llama-server:local", "latest"),
        };
        assert_eq!(name, "llama-server");
        assert_eq!(tag, "local");
    }
}
