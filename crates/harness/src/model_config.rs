//! Model resolution for the harness.
//!
//! The harness owns model selection. It resolves the value an agent
//! definition's `model:` names to a `ModelConfig`, then dials the model
//! itself. A local model is a warm in-cluster Service the harness dials
//! directly; a remote model is reached through a per-call inference-runtime job
//! the harness creates. An absent name is refused, never defaulted.
//!
//! Each model is one `model-<key>` ConfigMap labelled `sycophant.md/type:
//! model`, its data the operator's flat provision command fields. The harness
//! watches the label set and rebuilds the table on every change, so a model
//! added, changed or removed takes effect on the next turn without a restart.

use std::collections::HashMap;

use k8s_openapi::api::core::v1::ConfigMap;

/// The one port every local model's `inference-<key>` Service serves on.
pub(crate) const LOCAL_INFERENCE_PORT: u16 = 8080;

/// One model the harness can dial, keyed in `ModelTable` by the value an
/// agent definition's `model:` names. `format` is the provider wire format and
/// `model` the provider-side model id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ModelConfig {
    /// A warm in-cluster model served by the `inference-<key>` ClusterIP
    /// Service on [`LOCAL_INFERENCE_PORT`]. The harness dials the Service
    /// directly; no per-call job is created.
    Local { format: String, model: String },
    /// A provider reached through a per-call inference-runtime job the harness
    /// creates. The job holds the provider credential and the external egress;
    /// the harness dials the job.
    Remote {
        format: String,
        model: String,
        base_url: String,
        /// The inference-runtime job image the harness stamps into the Job.
        image: String,
        /// Name of the Kubernetes Secret carrying the provider credential.
        /// Mounted by reference into the job; the value is never read here.
        /// Absent when the destination needs no credential.
        secret: Option<String>,
    },
}

impl ModelConfig {
    /// The provider wire format, common to both targets.
    pub(crate) fn format(&self) -> &str {
        match self {
            ModelConfig::Local { format, .. } | ModelConfig::Remote { format, .. } => format,
        }
    }

    /// The provider-side model id, common to both targets.
    pub(crate) fn model(&self) -> &str {
        match self {
            ModelConfig::Local { model, .. } | ModelConfig::Remote { model, .. } => model,
        }
    }

    /// Build one model from a ConfigMap's flat data. A `server.image` key makes
    /// it local, which carries no `baseUrl`.
    fn from_data(data: &std::collections::BTreeMap<String, String>) -> Result<Self, String> {
        let field = |k: &str| {
            data.get(k)
                .filter(|v| !v.is_empty())
                .cloned()
                .ok_or_else(|| format!("missing {k}"))
        };
        let format = field("format")?;
        let model = field("model")?;
        if data.contains_key("server.image") {
            return Ok(ModelConfig::Local { format, model });
        }
        Ok(ModelConfig::Remote {
            format,
            model,
            base_url: field("baseUrl")?,
            image: field("image")?,
            secret: data.get("secret").filter(|v| !v.is_empty()).cloned(),
        })
    }
}

/// The live model table, keyed by the `app.kubernetes.io/name` label of each
/// model ConfigMap. An absent key is refused, never defaulted.
#[derive(Clone, Debug, Default)]
pub(crate) struct ModelTable {
    models: HashMap<String, ModelConfig>,
}

impl ModelTable {
    /// Merge every model ConfigMap into one table. A ConfigMap that fails to
    /// parse is skipped and named in the returned errors.
    pub(crate) fn merge_configmaps<'a, I>(cms: I) -> (Self, Vec<String>)
    where
        I: IntoIterator<Item = &'a ConfigMap>,
    {
        let (models, errors) =
            shared::configmap_watcher::merge_labelled(cms, ModelConfig::from_data);
        (Self { models }, errors)
    }

    /// The model the agent-definition value names. Absent is refused, never
    /// defaulted: there is no fallback model.
    pub(crate) fn get(&self, name: &str) -> Option<&ModelConfig> {
        self.models.get(name)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::collections::BTreeMap;

    use k8s_openapi::api::core::v1::ConfigMap;
    use k8s_openapi::apimachinery::pkg::apis::meta::v1::ObjectMeta;

    use super::*;

    pub(crate) fn model_cm(key: &str, data: &[(&str, &str)]) -> ConfigMap {
        ConfigMap {
            metadata: ObjectMeta {
                name: Some(format!("model-{key}")),
                labels: Some(BTreeMap::from([
                    ("sycophant.md/type".to_string(), "model".to_string()),
                    ("app.kubernetes.io/name".to_string(), key.to_string()),
                ])),
                ..Default::default()
            },
            data: Some(
                data.iter()
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect(),
            ),
            ..Default::default()
        }
    }

    pub(crate) const REMOTE: &[(&str, &str)] = &[
        ("format", "openai"),
        ("model", "deepseek/deepseek-v4-flash"),
        ("baseUrl", "https://openrouter.ai/api/v1"),
        ("image", "inference-runtime:local"),
        ("secret", "llm-openrouter"),
    ];

    #[test]
    fn a_model_with_a_server_image_is_local_without_a_base_url() {
        let (table, errors) = ModelTable::merge_configmaps(&[model_cm(
            "local",
            &[
                ("format", "openai"),
                ("model", "liquid/lfm2.5-8b-a1b"),
                ("server.image", "llama-server:local"),
                ("server.weights", "ghcr.io/example/weights:1"),
                ("server.weightsPath", "/weights/model.gguf"),
                ("server.slots", "2"),
            ],
        )]);
        assert!(errors.is_empty(), "{errors:?}");
        assert_eq!(
            table.get("local"),
            Some(&ModelConfig::Local {
                format: "openai".to_string(),
                model: "liquid/lfm2.5-8b-a1b".to_string(),
            })
        );
    }

    #[test]
    fn a_model_without_a_server_image_is_remote_with_its_optional_secret() {
        let unauthenticated: Vec<_> = REMOTE
            .iter()
            .copied()
            .filter(|(k, _)| *k != "secret")
            .collect();
        let (table, errors) = ModelTable::merge_configmaps(&[
            model_cm("deepseek", REMOTE),
            model_cm("open", &unauthenticated),
        ]);
        assert!(errors.is_empty(), "{errors:?}");
        let remote = |secret: Option<&str>| ModelConfig::Remote {
            format: "openai".to_string(),
            model: "deepseek/deepseek-v4-flash".to_string(),
            base_url: "https://openrouter.ai/api/v1".to_string(),
            image: "inference-runtime:local".to_string(),
            secret: secret.map(str::to_string),
        };
        assert_eq!(table.get("deepseek"), Some(&remote(Some("llm-openrouter"))));
        assert_eq!(table.get("open"), Some(&remote(None)));
    }

    #[test]
    fn a_configmap_missing_format_is_skipped_and_named() {
        let unformatted: Vec<_> = REMOTE
            .iter()
            .copied()
            .filter(|(k, _)| *k != "format")
            .collect();
        let (table, errors) = ModelTable::merge_configmaps(&[
            model_cm("deepseek", REMOTE),
            model_cm("broken", &unformatted),
        ]);
        assert!(table.get("deepseek").is_some());
        assert_eq!(table.get("broken"), None);
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert!(errors[0].contains("model-broken"), "{errors:?}");
    }
}
