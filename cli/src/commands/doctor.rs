use std::env;
use std::path::PathBuf;
use std::process::Command;

/// Find the existing Sycophant preflight script.
fn find_preflight_script() -> Result<PathBuf, String> {
    let current_dir =
        env::current_dir().map_err(|err| format!("Cannot determine current directory: {err}"))?;

    for directory in current_dir.ancestors() {
        let script = directory.join("scripts/preflight.sh");

        if script.is_file() {
            return Ok(script);
        }
    }

    Err("Could not find scripts/preflight.sh. \
         Run doctor from inside a Sycophant repository checkout."
        .to_string())
}

/// Run read-only diagnostics using Sycophant's existing preflight script.
pub(crate) fn run() -> Result<(), String> {
    println!("Sycophant Environment Diagnostics");
    println!("Running preflight checks...");
    println!();

    let script = find_preflight_script()?;

    let status = Command::new("bash")
        .arg(&script)
        .env("SYCO_PREFLIGHT_SKIP_VM_DISK", "1")
        .status()
        .map_err(|err| format!("Failed to run preflight: {err}"))?;

    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "Environment diagnostics failed (exit status: {status})"
        ))
    }
}
