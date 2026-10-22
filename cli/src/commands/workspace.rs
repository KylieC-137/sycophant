//! `sycoadm workspace up` and `down`, which also deliver the workspace's
//! instructions to the built-in store.
//!
//! Each workspace has one folder in the store's instructions bucket, keyed by
//! its service account's token subject. `up` replaces that folder with the
//! files of the directory the values file names under `workspace.instructions`,
//! then provisions the workspace; `down` reaps the workspace, then deletes the
//! folder. Every store call is one `kubectl exec` of curl against the filer
//! inside the store pod, with plain arguments and no shell.

use std::fs::{self, File};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::cli::Values;
use crate::commands::command::{self, tenant_ns, tenant_token, SYSTEM_NS};
use crate::commands::operator::Operator;
use crate::runner::{run_output, run_passthrough, run_passthrough_from};
use crate::scope::Scope;

pub(crate) const BUCKET: &str = "sycophant-instructions";
const STORE: &str = "deploy/seaweedfs";
const PROVISION_PREFIX: &str = "provision-workspace-";

/// The filer URL of the instructions bucket, inside the store pod.
pub(crate) fn bucket_url() -> String {
    format!("http://localhost:8888/buckets/{BUCKET}/")
}

/// The filer URL of workspace `name`'s folder in namespace `ns`.
fn folder_url(ns: &str, name: &str) -> String {
    format!("{}system:serviceaccount:{ns}:ws-{name}/", bucket_url())
}

/// One regular file to upload: its path under the instructions directory
/// (`/`-separated) and on disk.
struct Entry {
    rel: String,
    path: PathBuf,
}

/// `sycoadm workspace up -f <values.yaml>`: upload the instructions, then
/// write the provision command and wait for its installer.
pub(crate) fn up(values: &Values) -> Result<(), String> {
    let [file] = values.files.as_slice() else {
        return Err("workspace up takes exactly one -f".into());
    };
    let entries = match instructions_dir(Path::new(file))? {
        Some(dir) => walk(&dir)?,
        None => Vec::new(),
    };
    let hash = hash(&entries)?;

    let mut args = values.helm_args();
    args.extend([
        "--set-string".to_string(),
        format!("workspace.instructionsHash={hash}"),
    ]);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let manifest = command::render("workspace-provision", &args)?;
    let (ns, name) = target(&manifest)?;

    let op = Operator::login(&Scope::global()?.oidc_dir())?;
    let folder = folder_url(&ns, &name);
    clear(&folder)?;
    for e in &entries {
        upload(&folder, e)?;
    }
    command::apply(&op, "workspace", &manifest)
}

/// `sycoadm workspace down <name> --tenant <t>`: reap the workspace, then
/// delete its instructions folder. The store is touched only after the reap
/// succeeds, so a name or tenant the reap refuses never reaches it.
pub(crate) fn down(name: &str, tenant: &str) -> Result<(), String> {
    let op = Operator::login(&Scope::global()?.oidc_dir())?;
    command::reap(&op, "workspace", name, tenant)?;
    clear(&folder_url(&tenant_ns(tenant), name))
}

/// The instructions directory the values file names, if any. A relative path
/// resolves against the values file's directory.
fn instructions_dir(file: &Path) -> Result<Option<PathBuf>, String> {
    let text =
        fs::read_to_string(file).map_err(|e| format!("cannot read {}: {e}", file.display()))?;
    let doc: serde_yaml::Value =
        serde_yaml::from_str(&text).map_err(|e| format!("{} is not YAML: {e}", file.display()))?;
    let dir = match &doc["workspace"]["instructions"] {
        serde_yaml::Value::Null => return Ok(None),
        serde_yaml::Value::String(s) if !s.is_empty() => Path::new(s),
        _ => return Err("workspace.instructions must be a directory path".into()),
    };
    let base = match file.parent() {
        Some(p) if !p.as_os_str().is_empty() => p,
        _ => Path::new("."),
    };
    Ok(Some(base.join(dir)))
}

/// Every regular file under `root`, sorted by relative path. Entries are read
/// with lstat, so a symlink inside the tree is never followed. Anything but a
/// regular file or a directory, or a name outside letters, digits, `.`, `_`
/// and `-` (or starting with `-`), is refused before any content is read.
fn walk(root: &Path) -> Result<Vec<Entry>, String> {
    let meta = fs::metadata(root).map_err(|e| format!("instructions {}: {e}", root.display()))?;
    if !meta.is_dir() {
        return Err(format!(
            "instructions {} is not a directory",
            root.display()
        ));
    }
    let mut entries = Vec::new();
    walk_dir(root, "", &mut entries)?;
    entries.sort_by(|a, b| a.rel.as_bytes().cmp(b.rel.as_bytes()));
    Ok(entries)
}

fn walk_dir(dir: &Path, prefix: &str, out: &mut Vec<Entry>) -> Result<(), String> {
    let read = fs::read_dir(dir).map_err(|e| format!("cannot read {}: {e}", dir.display()))?;
    for item in read {
        let item = item.map_err(|e| format!("cannot read {}: {e}", dir.display()))?;
        let path = item.path();
        let name = item
            .file_name()
            .into_string()
            .ok()
            .filter(|n| safe_name(n))
            .ok_or_else(|| {
                format!(
                    "instructions entry {} has an unsafe name: use letters, digits, '.', '_' and '-', not starting with '-'",
                    path.display()
                )
            })?;
        let rel = format!("{prefix}{name}");
        let kind = fs::symlink_metadata(&path)
            .map_err(|e| format!("cannot stat {}: {e}", path.display()))?
            .file_type();
        if kind.is_dir() {
            walk_dir(&path, &format!("{rel}/"), out)?;
        } else if kind.is_file() {
            out.push(Entry { rel, path });
        } else {
            return Err(format!(
                "instructions entry {} is not a regular file or directory",
                path.display()
            ));
        }
    }
    Ok(())
}

fn safe_name(n: &str) -> bool {
    !n.is_empty()
        && !n.starts_with('-')
        && n != ".."
        && n.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// SHA-256 over one `<sha256 of content>  <relative path>` line per file, in
/// path order: it changes with any file's content or path, not with mtimes.
fn hash(entries: &[Entry]) -> Result<String, String> {
    let mut list = Sha256::new();
    for e in entries {
        let bytes =
            fs::read(&e.path).map_err(|e2| format!("cannot read {}: {e2}", e.path.display()))?;
        list.update(format!("{}  {}\n", hex(&Sha256::digest(&bytes)), e.rel));
    }
    Ok(hex(&list.finalize()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The namespace and workspace name of a rendered provision command, refused
/// unless both are DNS-safe: they become part of the store folder's URL.
fn target(manifest: &str) -> Result<(String, String), String> {
    let doc: serde_yaml::Value =
        serde_yaml::from_str(manifest).map_err(|e| format!("rendered command is not YAML: {e}"))?;
    let ns = command::manifest_namespace(manifest).unwrap_or_default();
    let name = doc["metadata"]["name"]
        .as_str()
        .and_then(|n| n.strip_prefix(PROVISION_PREFIX))
        .unwrap_or_default();
    if !dns_label(name, 49) {
        return Err(format!(
            "workspace name {name:?} must be a DNS-safe name of at most 49 characters"
        ));
    }
    if tenant_token(&ns).is_err() || !dns_label(&ns, 63) {
        return Err(format!(
            "tenant namespace {ns:?} must be tenant-<name>, a DNS-safe name of at most 63 characters"
        ));
    }
    Ok((ns, name.to_string()))
}

/// A DNS-1123 label of at most `max` characters.
fn dns_label(s: &str, max: usize) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= max
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
        && b[0] != b'-'
        && b[b.len() - 1] != b'-'
}

/// The `kubectl exec` arguments that run curl with `curl_args` in the store pod.
pub(crate) fn store_exec<'a>(stdin: bool, curl_args: &[&'a str]) -> Vec<&'a str> {
    let mut argv = vec!["exec"];
    if stdin {
        argv.push("-i");
    }
    argv.extend(["-n", SYSTEM_NS, STORE, "--", "curl"]);
    argv.extend_from_slice(curl_args);
    argv
}

/// Delete `folder` and prove it gone: the filer must then answer 404 for it.
fn clear(folder: &str) -> Result<(), String> {
    let delete = format!("{folder}?recursive=true");
    run_passthrough(
        "kubectl",
        &store_exec(false, &["-fsS", "-g", "-X", "DELETE", &delete]),
    )
    .map_err(|e| format!("deleting the instructions folder failed: {e}"))?;
    let status = run_output(
        "kubectl",
        &store_exec(
            false,
            &["-sS", "-g", "-o", "/dev/null", "-w", "%{http_code}", folder],
        ),
    )
    .map_err(|e| format!("checking the instructions folder failed: {e}"))?;
    if status != "404" {
        return Err(format!(
            "the instructions folder is still present after its delete (status {status})"
        ));
    }
    Ok(())
}

/// Upload one file into `folder`, streamed as the exec's stdin.
fn upload(folder: &str, e: &Entry) -> Result<(), String> {
    let input =
        File::open(&e.path).map_err(|e2| format!("cannot open {}: {e2}", e.path.display()))?;
    let url = format!("{folder}{}", e.rel);
    run_passthrough_from(
        "kubectl",
        &store_exec(true, &["-fsS", "-g", "-o", "/dev/null", "-T", "-", &url]),
        input,
    )
    .map_err(|e2| format!("uploading {} failed: {e2}", e.rel))
}
