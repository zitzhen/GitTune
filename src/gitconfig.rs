//! Read and write git configuration exclusively through the `git config` CLI.
//!
//! The `.gitconfig` file is never parsed directly; every access goes through
//! `git config --global ...` via `std::process::Command`.

use std::process::Command;

/// Read a key from the global git configuration.
///
/// Returns `Ok(String::new())` when the key is not set (git exits with 1).
pub fn read(key: &str) -> Result<String, String> {
    let output = Command::new("git")
        .args(["config", "--global", "--get", key])
        .output()
        .map_err(|e| format!("failed to run git: {e}"))?;

    match output.status.code() {
        Some(0) => Ok(String::from_utf8_lossy(&output.stdout)
            .trim_end_matches('\n')
            .to_string()),
        Some(1) => Ok(String::new()),
        _ => Err(String::from_utf8_lossy(&output.stderr).trim().to_string()),
    }
}

/// Write a key to the global git configuration.
pub fn write(key: &str, value: &str) -> Result<(), String> {
    let output = Command::new("git")
        .args(["config", "--global", key, value])
        .output()
        .map_err(|e| format!("failed to run git: {e}"))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

/// Remove a key from the global git configuration.
///
/// Exit code 5 (key does not exist) is treated as success.
pub fn unset(key: &str) -> Result<(), String> {
    let output = Command::new("git")
        .args(["config", "--global", "--unset", key])
        .output()
        .map_err(|e| format!("failed to run git: {e}"))?;

    if output.status.success() || output.status.code() == Some(5) {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}
