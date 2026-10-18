//! Open the platform's own folder chooser and return the selected path.
//!
//! Slint has no file-dialog API, so this shells out to the desktop's native
//! chooser instead of pulling in a GUI toolkit dependency: zenity/kdialog on
//! Linux and other Unix desktops, AppleScript on macOS, and the WinForms
//! folder browser on Windows.
//!
//! `Ok(None)` means the user cancelled; `Err` means no chooser could be run.

use std::process::Command;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[cfg(windows)]
pub fn pick_folder() -> Result<Option<String>, String> {
    pick_windows()
}

#[cfg(target_os = "macos")]
pub fn pick_folder() -> Result<Option<String>, String> {
    pick_macos()
}

#[cfg(all(unix, not(target_os = "macos")))]
pub fn pick_folder() -> Result<Option<String>, String> {
    pick_unix()
}

#[cfg(not(any(windows, unix)))]
pub fn pick_folder() -> Result<Option<String>, String> {
    Err("folder picking is not supported on this platform".to_string())
}

#[cfg(all(unix, not(target_os = "macos")))]
fn pick_unix() -> Result<Option<String>, String> {
    // Prefer the chooser that matches the running desktop, then fall back to
    // the other one. If the first existing chooser is cancelled we return
    // `Ok(None)` rather than opening a second dialog.
    let prefer_kdialog = std::env::var("XDG_CURRENT_DESKTOP")
        .map(|desktop| desktop.to_ascii_lowercase().contains("kde"))
        .unwrap_or(false);

    let zenity = (
        "zenity",
        &[
            "--file-selection",
            "--directory",
            "--title=Select a folder to trust",
        ][..],
    );
    let kdialog = (
        "kdialog",
        &[
            "--getexistingdirectory",
            ".",
            "--title",
            "Select a folder to trust",
        ][..],
    );
    let candidates = if prefer_kdialog {
        [kdialog, zenity]
    } else {
        [zenity, kdialog]
    };

    for (program, args) in candidates {
        match Command::new(program).args(args).output() {
            Ok(output) => {
                // The chooser ran: either a path was chosen or the user
                // cancelled. Don't fall through to another dialog.
                if !output.status.success() {
                    return Ok(None);
                }
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                return Ok(if path.is_empty() { None } else { Some(path) });
            }
            // The chooser isn't installed; try the next one.
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(format!("failed to run {program}: {error}")),
        }
    }
    Err("no folder picker found (install zenity or kdialog)".to_string())
}

#[cfg(target_os = "macos")]
fn pick_macos() -> Result<Option<String>, String> {
    let script = r#"POSIX path of (choose folder with prompt "Select a folder to trust")"#;
    let output = Command::new("osascript")
        .args(["-e", script])
        .output()
        .map_err(|error| format!("failed to run osascript: {error}"))?;

    if !output.status.success() {
        return Ok(None);
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Ok(if path.is_empty() { None } else { Some(path) })
}

#[cfg(windows)]
fn pick_windows() -> Result<Option<String>, String> {
    let script = r#"
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = 'Select a folder to trust'
$dialog.ShowNewFolderButton = $false
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    Write-Output $dialog.SelectedPath
}
"#;
    let output = Command::new("powershell")
        .args(["-NoProfile", "-STA", "-Command", script])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|error| format!("failed to run powershell: {error}"))?;

    if !output.status.success() {
        return Ok(None);
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Ok(if path.is_empty() { None } else { Some(path) })
}
