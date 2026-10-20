use crate::StreamEvent;
use futures::stream;
use serde_json::{Map, Value};

/// Map a list of clobbered managed-field names into a synthetic `StreamEvent`
/// stream. Each field becomes one `StreamEvent::Warning` carrying its own
/// `clobber_reason`. Concatenated by providers ahead of the live SSE stream
/// so the audit log sees the warnings before any response chunk.
pub fn warning_stream_for(
    clobbers: Vec<String>,
) -> impl futures::Stream<Item = Result<StreamEvent, String>> {
    stream::iter(clobbers.into_iter().map(|field| {
        let reason = clobber_reason(&field).to_string();
        Ok(StreamEvent::Warning { field, reason })
    }))
}

/// Static reason text for a managed field clobbered by principal-supplied
/// params. Generic for fields not in the table; the controller-side audit
/// log keys on `field`, so the reason is principal-facing UX.
pub fn clobber_reason(field: &str) -> &'static str {
    match field {
        "model" => "operator binds the model identifier to the API key via Model",
        "messages" | "contents" => "conversation history is owned by sycophant",
        "system" | "systemInstruction" => "system prompt is owned by sycophant",
        "tools" | "functionDeclarations" => "tool definitions are owned by sycophant",
        "stream" => "streaming is required for sycophant's audit log",
        _ => "operator-bound; principal override discarded",
    }
}

/// Clone `params` (or an empty Map if None) into a body Map, then return it
/// alongside the result of `detect_clobbers` against the same managed list.
/// The caller writes managed values into the returned body last, after using
/// the returned `Vec<String>` to emit warnings.
pub fn build_managed_body(
    params: Option<&Map<String, Value>>,
    managed: &[&str],
) -> (Map<String, Value>, Vec<String>) {
    let body = params.cloned().unwrap_or_default();
    let clobbers = detect_clobbers(&body, managed);
    (body, clobbers)
}

/// Return the subset of `managed` keys that are present in `body`, in the
/// order they appear in `managed`, with no duplicates.
pub fn detect_clobbers(body: &Map<String, Value>, managed: &[&str]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for key in managed {
        if body.contains_key(*key) && !out.iter().any(|existing| existing == *key) {
            out.push((*key).to_string());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn obj(v: Value) -> Map<String, Value> {
        match v {
            Value::Object(m) => m,
            _ => panic!("test fixture must be an object"),
        }
    }

    #[test]
    fn detect_no_duplicates_when_managed_repeats() {
        let body = obj(json!({"model": "x"}));
        assert_eq!(detect_clobbers(&body, &["model", "model"]), vec!["model"]);
    }

    #[test]
    fn build_with_none_params_returns_empty_body_and_no_clobbers() {
        let (body, clobbers) = build_managed_body(None, &["model"]);
        assert_eq!(body, Map::new());
        assert_eq!(clobbers, Vec::<String>::new());
    }

    #[test]
    fn build_clones_params_into_body() {
        let params = obj(json!({"temperature": 0.7}));
        let (body, clobbers) = build_managed_body(Some(&params), &["model"]);
        assert_eq!(body, obj(json!({"temperature": 0.7})));
        assert_eq!(clobbers, Vec::<String>::new());
    }

    #[test]
    fn build_detects_clobber_for_managed_key_in_params() {
        let params = obj(json!({"model": "x", "temperature": 0.7}));
        let (body, clobbers) = build_managed_body(Some(&params), &["model"]);
        assert_eq!(body, obj(json!({"model": "x", "temperature": 0.7})));
        assert_eq!(clobbers, vec!["model"]);
    }

    #[test]
    fn build_clobbers_in_managed_order() {
        let params = obj(json!({"stream": true, "model": "x"}));
        let (_body, clobbers) = build_managed_body(Some(&params), &["model", "stream"]);
        assert_eq!(clobbers, vec!["model", "stream"]);
    }

    #[test]
    fn clobber_reason_returns_distinct_text_per_managed_field() {
        let model = clobber_reason("model");
        let messages = clobber_reason("messages");
        let contents = clobber_reason("contents");
        let system = clobber_reason("system");
        let system_instr = clobber_reason("systemInstruction");
        let tools = clobber_reason("tools");
        let function_decls = clobber_reason("functionDeclarations");
        let stream = clobber_reason("stream");
        let unknown = clobber_reason("unknown");

        assert!(
            model.contains("operator binds the model identifier"),
            "model reason: {model}"
        );
        assert_eq!(messages, contents, "messages and contents share a reason");
        assert!(
            messages.contains("conversation history"),
            "messages reason: {messages}"
        );
        assert_eq!(system, system_instr);
        assert!(system.contains("system prompt"), "system reason: {system}");
        assert_eq!(tools, function_decls);
        assert!(tools.contains("tool definitions"), "tools reason: {tools}");
        assert!(stream.contains("streaming"), "stream reason: {stream}");
        assert!(
            unknown.contains("operator-bound"),
            "unknown reason: {unknown}"
        );

        // Each managed field has a distinct reason from the generic fallback.
        for r in [model, messages, system, tools, stream] {
            assert_ne!(r, unknown);
        }
    }
}
