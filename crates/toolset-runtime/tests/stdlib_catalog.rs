use std::collections::HashMap;

use tokio_util::sync::CancellationToken;
use toolset_runtime::stdlib::{dispatch_builtin, BUILTIN_NAMES, DEFAULT_MAX_OUTPUT_CHARS};

#[tokio::test]
async fn every_builtin_name_dispatches_to_an_implementation() {
    assert!(!BUILTIN_NAMES.is_empty());
    for name in BUILTIN_NAMES {
        let result = dispatch_builtin(
            name,
            &HashMap::new(),
            "/nonexistent",
            DEFAULT_MAX_OUTPUT_CHARS,
            &CancellationToken::new(),
        )
        .await;
        assert!(
            result.stderr.starts_with("missing required parameter"),
            "{name}: {}",
            result.stderr
        );
    }
}
