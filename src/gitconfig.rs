//! Read and write git configuration exclusively through the `git config` CLI.
//!
//! The `.gitconfig` file is never parsed directly; every access goes through
//! `git config --global ...` via `std::process::Command`.

use std::process::Command;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

/// `CREATE_NO_WINDOW`: stop Windows from allocating a console for the child
/// process. A GUI-subsystem build has no console to inherit, so without this
/// flag every `git` call would flash a console window of its own.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Build a `git` invocation that never opens a console window on Windows.
fn git(args: &[&str]) -> Command {
    let mut command = Command::new("git");
    command.args(args);
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

/// Read a key from the global git configuration.
///
/// Returns `Ok(String::new())` when the key is not set (git exits with 1).
pub fn read(key: &str) -> Result<String, String> {
    let output = git(&["config", "--global", "--get", key])
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
    let output = git(&["config", "--global", key, value])
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
    let output = git(&["config", "--global", "--unset", key])
        .output()
        .map_err(|e| format!("failed to run git: {e}"))?;

    if output.status.success() || output.status.code() == Some(5) {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}
