use std::collections::BTreeMap;

use k8s_openapi::api::core::v1::Toleration;
use serde::Deserialize;

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SchedulingConfig {
    #[serde(default)]
    pub node_selector: BTreeMap<String, String>,
    #[serde(default)]
    pub tolerations: Vec<Toleration>,
}

impl SchedulingConfig {
    pub fn load(path: &str) -> Result<Self, String> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| format!("failed to read scheduling config {path}: {e}"))?;
        serde_yaml::from_str(&content).map_err(|e| format!("failed to parse scheduling YAML: {e}"))
    }

    pub fn load_or_default(path: &str, has_kube: bool) -> Result<Self, String> {
        if !has_kube {
            tracing::info!("no kube client, scheduling config skipped");
            return Ok(Self::default());
        }
        match Self::load(path) {
            Ok(s) => {
                tracing::info!(path, "loaded scheduling config");
                Ok(s)
            }
            Err(e) => Err(format!("scheduling config required in-cluster: {e}")),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.node_selector.is_empty() && self.tolerations.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_from_yaml() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(
            tmp.path(),
            r#"
node_selector:
  sycophant.md/workload: toolset
tolerations:
  - key: sycophant.md/workload
    operator: Equal
    value: toolset
    effect: NoSchedule
"#,
        )
        .unwrap();

        let config = SchedulingConfig::load(tmp.path().to_str().unwrap()).unwrap();
        assert!(!config.is_empty());
        assert_eq!(
            config.node_selector.get("sycophant.md/workload"),
            Some(&"toolset".to_string())
        );
        assert_eq!(config.tolerations.len(), 1);
        assert_eq!(
            config.tolerations[0].key.as_deref(),
            Some("sycophant.md/workload")
        );
        assert_eq!(config.tolerations[0].value.as_deref(), Some("toolset"));
        assert_eq!(config.tolerations[0].operator.as_deref(), Some("Equal"));
        assert_eq!(config.tolerations[0].effect.as_deref(), Some("NoSchedule"));
    }

    #[test]
    fn load_empty_yaml_gives_defaults() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(tmp.path(), "{}").unwrap();
        let config = SchedulingConfig::load(tmp.path().to_str().unwrap()).unwrap();
        assert!(config.is_empty());
    }

    #[test]
    fn load_or_default_skips_when_no_kube() {
        let config = SchedulingConfig::load_or_default("/nonexistent/path.yaml", false).unwrap();
        assert!(config.is_empty());
    }

    #[test]
    fn load_or_default_errors_in_cluster_when_missing() {
        let result = SchedulingConfig::load_or_default("/nonexistent/path.yaml", true);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("required in-cluster"));
    }

    #[test]
    fn is_empty_true_only_for_default() {
        let cases = [
            (SchedulingConfig::default(), true),
            (
                SchedulingConfig {
                    node_selector: BTreeMap::from([("k".into(), "v".into())]),
                    tolerations: vec![],
                },
                false,
            ),
            (
                SchedulingConfig {
                    node_selector: BTreeMap::new(),
                    tolerations: vec![Toleration::default()],
                },
                false,
            ),
        ];
        for (config, want) in cases {
            assert_eq!(config.is_empty(), want, "{config:?}");
        }
    }
}
