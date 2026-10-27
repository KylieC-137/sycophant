use std::fs;
use std::path::{Path, PathBuf};

use base64::engine::general_purpose::STANDARD;
use base64::Engine;

use crate::cli::Values;
use crate::commands::operator::TempFile;

/// `rel` is the `/`-separated path under the folder.
enum Entry {
    Dir { rel: String },
    File { rel: String, path: PathBuf },
}

impl Entry {
    fn rel(&self) -> &str {
        match self {
            Entry::Dir { rel } | Entry::File { rel, .. } => rel,
        }
    }
}

pub(crate) fn pack(values: &Values) -> Result<TempFile, String> {
    let [file] = values.files.as_slice() else {
        return Err("instructions up takes exactly one -f".into());
    };
    let entries = walk(&folder(Path::new(file))?)?;
    let archive = STANDARD.encode(gzip(&tar(&entries)?));
    // The archive rides a values file, not argv, which it can outgrow.
    TempFile::new(
        "yaml",
        &format!("instructions:\n  archive: \"{archive}\"\n"),
    )
}

/// The folder the values file names. A relative path resolves against the
/// values file's directory.
fn folder(file: &Path) -> Result<PathBuf, String> {
    let text =
        fs::read_to_string(file).map_err(|e| format!("cannot read {}: {e}", file.display()))?;
    let doc: serde_yaml::Value =
        serde_yaml::from_str(&text).map_err(|e| format!("{} is not YAML: {e}", file.display()))?;
    let dir = doc["instructions"]["folder"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("instructions.folder must be a directory path")?;
    Ok(file.parent().unwrap_or(Path::new("")).join(dir))
}

/// Every directory and regular file under `root`, sorted by relative path.
/// Entries are read with lstat, so a link is refused, never followed.
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
    entries.sort_by(|a, b| a.rel().as_bytes().cmp(b.rel().as_bytes()));
    Ok(entries)
}

fn walk_dir(dir: &Path, prefix: &str, out: &mut Vec<Entry>) -> Result<(), String> {
    let read = fs::read_dir(dir).map_err(|e| format!("cannot read {}: {e}", dir.display()))?;
    for item in read {
        let item = item.map_err(|e| format!("cannot read {}: {e}", dir.display()))?;
        let path = item.path();
        let rel = format!("{prefix}{}", item.file_name().to_string_lossy());
        let kind = fs::symlink_metadata(&path)
            .map_err(|e| format!("cannot stat {}: {e}", path.display()))?
            .file_type();
        if kind.is_dir() {
            walk_dir(&path, &format!("{rel}/"), out)?;
            out.push(Entry::Dir { rel });
        } else if kind.is_file() {
            out.push(Entry::File { rel, path });
        } else {
            return Err(format!(
                "instructions entry {} is not a regular file or directory",
                path.display()
            ));
        }
    }
    Ok(())
}

const BLOCK: usize = 512;

/// A ustar archive of `entries`: directories 0755, files 0644, owned by 0:0
/// at mtime 0, so the same folder always packs to the same bytes.
fn tar(entries: &[Entry]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    for e in entries {
        match e {
            Entry::Dir { rel } => out.extend(header(&format!("{rel}/"), 0o755, 0, b'5')?),
            Entry::File { rel, path } => {
                let bytes =
                    fs::read(path).map_err(|e2| format!("cannot read {}: {e2}", path.display()))?;
                out.extend(header(rel, 0o644, bytes.len(), b'0')?);
                out.extend(&bytes);
                out.resize(out.len().next_multiple_of(BLOCK), 0);
            }
        }
    }
    out.resize(out.len() + 2 * BLOCK, 0);
    Ok(out)
}

/// One ustar header block. A path over 100 bytes is split at a `/` into the
/// 155-byte prefix field and the 100-byte name field.
fn header(path: &str, mode: u32, size: usize, kind: u8) -> Result<[u8; BLOCK], String> {
    let (prefix, name) = if path.len() <= 100 {
        ("", path)
    } else {
        path.char_indices()
            .filter(|&(i, c)| c == '/' && i <= 155 && path.len() - i - 1 <= 100)
            .map(|(i, _)| (&path[..i], &path[i + 1..]))
            .find(|(_, n)| !n.is_empty())
            .ok_or_else(|| format!("instructions path {path} is too long to archive"))?
    };
    let mut h = [0u8; BLOCK];
    let mut put = |at: usize, bytes: &[u8]| h[at..at + bytes.len()].copy_from_slice(bytes);
    put(0, name.as_bytes());
    put(100, format!("{mode:07o}\0").as_bytes());
    put(108, b"0000000\0");
    put(116, b"0000000\0");
    put(124, format!("{size:011o}\0").as_bytes());
    put(136, b"00000000000\0");
    put(148, b"        ");
    put(156, &[kind]);
    put(257, b"ustar\0");
    put(263, b"00");
    put(345, prefix.as_bytes());
    let sum: u32 = h.iter().map(|&b| u32::from(b)).sum();
    h[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
    Ok(h)
}

/// `data` as a gzip member of stored (uncompressed) deflate blocks: valid for
/// any gunzip, with no compression dependency.
fn gzip(data: &[u8]) -> Vec<u8> {
    const MAX: usize = 0xffff;
    let mut out = vec![0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff];
    let mut chunks = data.chunks(MAX).peekable();
    while let Some(chunk) = chunks.next() {
        let last = chunks.peek().is_none();
        // A chunk is at most MAX bytes, so its length fits the u16 field.
        let len = chunk.len() as u16;
        out.push(u8::from(last));
        out.extend(len.to_le_bytes());
        out.extend((!len).to_le_bytes());
        out.extend(chunk);
    }
    out.extend(crc32(data).to_le_bytes());
    // ISIZE is the input length modulo 2^32.
    out.extend((data.len() as u32).to_le_bytes());
    out
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &b in data {
        crc ^= u32::from(b);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb8_8320 & (crc & 1).wrapping_neg());
        }
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("syco-instr-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("sub")).unwrap();
        fs::write(dir.join("AGENTS.md"), "a").unwrap();
        fs::write(dir.join("sub/x.md"), "x").unwrap();
        dir
    }

    #[test]
    fn walk_lists_exactly_the_folder() {
        let dir = scratch("exact");
        let rels: Vec<String> = walk(&dir)
            .unwrap()
            .iter()
            .map(|e| e.rel().to_string())
            .collect();
        fs::remove_dir_all(&dir).unwrap();
        assert_eq!(rels, ["AGENTS.md", "sub", "sub/x.md"]);
    }

    #[test]
    fn walk_refuses_a_link() {
        let dir = scratch("link");
        std::os::unix::fs::symlink("/etc/passwd", dir.join("sub/ln")).unwrap();
        let err = walk(&dir).err();
        fs::remove_dir_all(&dir).unwrap();
        assert!(err.unwrap().contains("is not a regular file or directory"));
    }

    #[test]
    fn crc32_matches_the_check_value() {
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
    }

    #[test]
    fn header_checksum_covers_the_block() {
        let h = header("AGENTS.md", 0o644, 5, b'0').unwrap();
        let sum: u32 = h
            .iter()
            .enumerate()
            .map(|(i, &b)| u32::from(if (148..156).contains(&i) { b' ' } else { b }))
            .sum();
        assert_eq!(&h[148..155], format!("{sum:06o}\0").as_bytes());
    }

    #[test]
    fn long_paths_split_into_prefix_and_name() {
        let path = format!("{}/{}", "a".repeat(120), "b".repeat(90));
        let h = header(&path, 0o644, 0, b'0').unwrap();
        assert_eq!(&h[0..90], "b".repeat(90).as_bytes());
        assert_eq!(&h[345..465], "a".repeat(120).as_bytes());
    }
}
