//! Ctrl-C and SIGTERM cleanup: restore terminal echo and remove the private
//! temp files a command holds, then exit 130. The handler runs on its own
//! thread, so it may take locks and spawn `stty`.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, Once};

static ECHO_OFF: AtomicBool = AtomicBool::new(false);
static FILES: Tracked = Tracked::new();
static INSTALL: Once = Once::new();

/// Paths to remove if the command is interrupted.
struct Tracked(Mutex<Vec<PathBuf>>);

impl Tracked {
    const fn new() -> Self {
        Tracked(Mutex::new(Vec::new()))
    }

    fn track(&self, path: PathBuf) {
        if let Ok(mut files) = self.0.lock() {
            files.push(path);
        }
    }

    fn forget(&self, path: &Path) {
        if let Ok(mut files) = self.0.lock() {
            files.retain(|f| f != path);
        }
    }

    /// Remove every tracked path; one already gone, or never created, is not
    /// an error.
    fn remove_all(&self) {
        if let Ok(files) = self.0.lock() {
            for f in files.iter() {
                let _ = std::fs::remove_file(f);
            }
        }
    }
}

fn install() {
    INSTALL.call_once(|| {
        let _ = ctrlc::set_handler(|| {
            if ECHO_OFF.load(Ordering::SeqCst) {
                set_echo(true);
                eprintln!();
            }
            FILES.remove_all();
            std::process::exit(130);
        });
    });
}

fn set_echo(on: bool) {
    let _ = Command::new("stty")
        .arg(if on { "echo" } else { "-echo" })
        .stdin(Stdio::inherit())
        .status();
}

/// Turn terminal echo off until `echo_on`; an interrupt turns it back on.
pub(crate) fn echo_off() {
    install();
    ECHO_OFF.store(true, Ordering::SeqCst);
    set_echo(false);
}

pub(crate) fn echo_on() {
    set_echo(true);
    ECHO_OFF.store(false, Ordering::SeqCst);
}

/// Remove `path` if the command is interrupted before `forget` is called.
/// Called before the file is created, so no window leaves it untracked.
pub(crate) fn track(path: PathBuf) {
    install();
    FILES.track(path);
}

pub(crate) fn forget(path: &Path) {
    FILES.forget(path);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("syco-interrupt-{}-{name}", std::process::id()));
        std::fs::write(&p, "x").unwrap();
        p
    }

    #[test]
    fn removes_tracked_files_only() {
        let t = Tracked::new();
        let (kept, gone, forgotten) = (file("kept"), file("gone"), file("forgotten"));
        t.track(gone.clone());
        t.track(forgotten.clone());
        t.track(std::env::temp_dir().join("syco-interrupt-never-created"));
        t.forget(&forgotten);
        t.remove_all();
        assert!(!gone.exists());
        assert!(kept.exists());
        assert!(forgotten.exists());
        for p in [kept, forgotten] {
            std::fs::remove_file(p).unwrap();
        }
    }
}
