//! List local GPG secret keys via the `gpg` CLI.
//!
//! Parses the machine-readable colon-delimited output of
//! `gpg --list-secret-keys --with-colons --keyid-format long`.
//! The `~/.gnupg` directory is never read directly.

use std::process::Command;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

/// `CREATE_NO_WINDOW`: stop Windows from allocating a console for the child
/// process. A GUI-subsystem build has no console to inherit, so without this
/// flag the `gpg` call would flash a console window of its own.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Build a `gpg` invocation that never opens a console window on Windows.
fn gpg(args: &[&str]) -> Command {
    let mut command = Command::new("gpg");
    command.args(args);
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

/// A local GPG secret (primary) key.
pub struct GpgKey {
    /// Full 40-character uppercase fingerprint of the primary key.
    pub fingerprint: String,
    /// First non-revoked user ID, e.g. `Name <email>`. May be empty.
    pub name: String,
}

/// List all local GPG secret keys.
///
/// Subkeys (`ssb`) are ignored. Returns an error if gpg cannot be executed
/// or exits with a non-zero status.
pub fn list_keys() -> Result<Vec<GpgKey>, String> {
    let output = gpg(&[
        "--list-secret-keys",
        "--with-colons",
        "--keyid-format",
        "long",
    ])
    .output()
    .map_err(|e| format!("failed to run gpg: {e}"))?;

    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut keys: Vec<GpgKey> = Vec::new();
    let mut current: Option<GpgKey> = None;

    for line in stdout.lines() {
        let mut fields = line.split(':');
        match fields.next() {
            Some("sec") => {
                // A new primary key block starts; flush the previous one.
                if let Some(key) = current.take() {
                    if !key.fingerprint.is_empty() {
                        keys.push(key);
                    }
                }
                current = Some(GpgKey {
                    fingerprint: String::new(),
                    name: String::new(),
                });
            }
            Some("fpr") => {
                // Field 10 (index 9) is the fingerprint. Only the first fpr
                // line of a block belongs to the primary key; subkey fpr
                // lines arrive after it and are ignored.
                if let Some(key) = current.as_mut() {
                    if key.fingerprint.is_empty() {
                        key.fingerprint = fields.nth(8).unwrap_or("").to_string();
                    }
                }
            }
            Some("uid") => {
                // Field 2 is the validity ('r' = revoked); field 10 is the
                // user ID string.
                let validity = fields.next().unwrap_or("");
                if let Some(key) = current.as_mut() {
                    if key.name.is_empty() && validity != "r" {
                        key.name = fields.nth(7).unwrap_or("").to_string();
                    }
                }
            }
            _ => {}
        }
    }

    if let Some(key) = current.take() {
        if !key.fingerprint.is_empty() {
            keys.push(key);
        }
    }

    Ok(keys)
}
