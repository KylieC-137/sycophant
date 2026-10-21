//! Generate `BUILTIN_NAMES` from the stdlib toolset's flat tool declarations
//! (`images/toolset/tools.yaml`) so the runtime's builtin set and the image's
//! tool label cannot drift. The generated slice is `include!`d by `stdlib.rs`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let tools_yaml = manifest_dir.join("../../images/toolset/tools.yaml");

    println!("cargo:rerun-if-changed={}", tools_yaml.display());

    let raw = std::fs::read_to_string(&tools_yaml)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", tools_yaml.display()));
    let flat: BTreeMap<String, String> =
        serde_yaml::from_str(&raw).expect("stdlib tools.yaml is not a flat map of strings");

    let names: BTreeSet<&str> = flat
        .keys()
        .filter_map(|k| k.strip_prefix("tool."))
        .filter_map(|rest| rest.split_once('.').map(|(name, _)| name))
        .collect();
    assert!(!names.is_empty(), "stdlib tools.yaml names no tools");

    let entries: String = names.iter().map(|n| format!("    {n:?},\n")).collect();
    let generated = format!(
        "/// The stdlib builtins, generated at build from images/toolset/tools.yaml.\n\
         pub const BUILTIN_NAMES: &[&str] = &[\n{entries}];\n"
    );

    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("builtin_names.rs");
    std::fs::write(&out, generated).expect("write builtin_names.rs");
}
