// Release builds are GUI applications on Windows: without this the binary is a
// console-subsystem program, and Windows allocates a console window for it
// before `main` runs (i.e. before the Slint window can appear). Debug builds
// keep the console so `cargo run` still shows output.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod folder_picker;
mod gitconfig;
mod gpg;

slint::include_modules!();

use std::cell::RefCell;
use std::rc::Rc;

use slint::Model;

fn main() -> Result<(), slint::PlatformError> {
    let window = MainWindow::new()?;

    // The crate version comes from Cargo.toml (bumped there, not in the UI).
    window.set_app_version(env!("CARGO_PKG_VERSION").into());

    // Load current git config values.
    let name = gitconfig::read("user.name").unwrap_or_default();
    let email = gitconfig::read("user.email").unwrap_or_default();
    let signing_key = gitconfig::read("user.signingkey").unwrap_or_default();
    let default_branch = gitconfig::read("init.defaultBranch").unwrap_or_default();
    let commit_gpgsign = gitconfig::read("commit.gpgsign").unwrap_or_default() == "true";
    let tag_gpgsign = gitconfig::read("tag.gpgsign").unwrap_or_default() == "true";
    let autocrlf = gitconfig::read("core.autocrlf").unwrap_or_default();
    let quotepath = gitconfig::read("core.quotepath").unwrap_or_default();
    let core_editor = gitconfig::read("core.editor").unwrap_or_default();
    let credential_helper = gitconfig::read("credential.helper").unwrap_or_default();
    let http_proxy = gitconfig::read("http.proxy").unwrap_or_default();
    let https_proxy = gitconfig::read("https.proxy").unwrap_or_default();
    let smtp_from = gitconfig::read("sendemail.from").unwrap_or_default();
    let smtp_user = gitconfig::read("sendemail.smtpuser").unwrap_or_default();
    let smtp_server = gitconfig::read("sendemail.smtpserver").unwrap_or_default();
    let smtp_port = gitconfig::read("sendemail.smtpserverport").unwrap_or_default();
    let smtp_enc = gitconfig::read("sendemail.smtpencryption").unwrap_or_default();

    window.set_user_name(name.into());
    window.set_user_email(email.into());

    // `credential.helper` takes a helper name plus optional arguments. Offer
    // only helpers that actually exist on this platform: `wincred` is
    // Windows-only, `osxkeychain` macOS-only, and `libsecret`/`cache` are
    // Unix-only. `store` and Git Credential Manager work everywhere.
    // `Custom...` covers anything else; an existing value outside the list is
    // preselected there so it is never lost.
    let known_credential_helpers: &[&str] = if cfg!(target_os = "windows") {
        &["manager", "manager-core", "wincred", "store"]
    } else if cfg!(target_os = "macos") {
        &["manager", "manager-core", "osxkeychain", "cache", "store"]
    } else {
        &["manager", "manager-core", "libsecret", "cache", "store"]
    };
    let mut credential_helper_options: Vec<slint::SharedString> =
        vec!["Default (unset)".into()];
    credential_helper_options.extend(
        known_credential_helpers
            .iter()
            .map(|helper| slint::SharedString::from(*helper)),
    );
    credential_helper_options.push("Custom...".into());
    window.set_credential_helper_options(slint::ModelRc::new(slint::VecModel::from(
        credential_helper_options,
    )));

    let mut credential_helper_selected = slint::SharedString::from("Default (unset)");
    let mut credential_helper_custom = slint::SharedString::new();
    if !credential_helper.is_empty() {
        if known_credential_helpers.contains(&credential_helper.as_str()) {
            credential_helper_selected = credential_helper.as_str().into();
        } else {
            credential_helper_selected = "Custom...".into();
            credential_helper_custom = credential_helper.as_str().into();
        }
    }
    window.set_credential_helper_selected_value(credential_helper_selected);
    window.set_credential_helper_custom_value(credential_helper_custom);
    window.set_commit_gpgsign(commit_gpgsign);
    window.set_tag_gpgsign(tag_gpgsign);

    // `core.autocrlf` accepts `true`, `input` and `false`. `unset` is shown
    // explicitly so the app never pretends an unset key has a value; git's
    // default when unset is `false`.
    let autocrlf_options: Vec<slint::SharedString> =
        vec!["unset".into(), "false".into(), "input".into(), "true".into()];
    window.set_autocrlf_options(slint::ModelRc::new(slint::VecModel::from(autocrlf_options)));
    let autocrlf_selected: slint::SharedString = match autocrlf.as_str() {
        "true" => "true".into(),
        "input" => "input".into(),
        "false" => "false".into(),
        _ => "unset".into(),
    };
    window.set_autocrlf_selected_value(autocrlf_selected);

    // `core.quotepath` is a boolean, but also has an unset state (git's
    // default is `true`); keep the three states distinct.
    let quotepath_options: Vec<slint::SharedString> =
        vec!["unset".into(), "true".into(), "false".into()];
    window.set_quotepath_options(slint::ModelRc::new(slint::VecModel::from(quotepath_options)));
    let quotepath_selected: slint::SharedString = match quotepath.as_str() {
        "true" => "true".into(),
        "false" => "false".into(),
        _ => "unset".into(),
    };
    window.set_quotepath_selected_value(quotepath_selected);

    // `core.editor` is free-form, so offer the common editors in a list with
    // `Custom...` at the bottom. `notepad` only makes sense on Windows. An
    // unset key is shown as its own choice so the app never invents a value.
    let mut known_editors: Vec<&str> = vec!["vim", "nano", "emacs", "code --wait", "subl --wait"];
    if cfg!(target_os = "windows") {
        known_editors.push("notepad");
    }
    let mut editor_options: Vec<slint::SharedString> = vec!["Default (unset)".into()];
    editor_options.extend(
        known_editors
            .iter()
            .map(|editor| slint::SharedString::from(*editor)),
    );
    editor_options.push("Custom...".into());
    window.set_core_editor_options(slint::ModelRc::new(slint::VecModel::from(editor_options)));

    let mut editor_selected = slint::SharedString::from("Default (unset)");
    let mut editor_custom = slint::SharedString::new();
    if !core_editor.is_empty() {
        if known_editors.contains(&core_editor.as_str()) {
            editor_selected = core_editor.as_str().into();
        } else {
            editor_selected = "Custom...".into();
            editor_custom = core_editor.as_str().into();
        }
    }
    window.set_core_editor_selected_value(editor_selected);
    window.set_core_editor_custom_value(editor_custom);

    window.set_http_proxy(http_proxy.into());
    window.set_https_proxy(https_proxy.into());

    window.set_sendemail_from(smtp_from.into());
    window.set_sendemail_smtpuser(smtp_user.into());
    window.set_sendemail_smtpserver(smtp_server.into());
    window.set_sendemail_smtpserverport(smtp_port.into());

    let encryption_options: Vec<slint::SharedString> =
        vec!["none".into(), "ssl".into(), "tls".into()];
    window.set_encryption_options(slint::ModelRc::new(slint::VecModel::from(encryption_options)));
    let encryption_selected: slint::SharedString = match smtp_enc.as_str() {
        "ssl" => "ssl".into(),
        "tls" => "tls".into(),
        _ => "none".into(),
    };
    window.set_encryption_selected_value(encryption_selected);

    // Load local GPG secret keys.
    let gpg_keys = gpg::list_keys().unwrap_or_default();
    let mut gpg_display_to_fpr: Vec<(slint::SharedString, String)> = Vec::new();
    let mut gpg_options: Vec<slint::SharedString> = Vec::new();

    for key in &gpg_keys {
        let last8 = if key.fingerprint.len() >= 8 {
            &key.fingerprint[key.fingerprint.len() - 8..]
        } else {
            &key.fingerprint
        };
        let display = format!("{} — {}", key.name, last8);
        let shared = slint::SharedString::from(display.clone());
        gpg_display_to_fpr.push((shared.clone(), key.fingerprint.clone()));
        gpg_options.push(shared);
    }
    gpg_options.push("Custom...".into());
    window.set_gpg_options(slint::ModelRc::new(slint::VecModel::from(gpg_options)));

    let mut gpg_selected = slint::SharedString::from("Custom...");
    let mut gpg_custom = slint::SharedString::new();
    if !signing_key.is_empty() {
        if let Some((display, _)) = gpg_display_to_fpr
            .iter()
            .find(|(_, fpr)| fpr == &signing_key)
        {
            gpg_selected = display.clone();
        } else {
            gpg_custom = signing_key.into();
        }
    }
    window.set_gpg_selected_value(gpg_selected);
    window.set_gpg_custom_value(gpg_custom);

    // Default branch options.
    let branch_options: Vec<slint::SharedString> =
        vec!["main".into(), "master".into(), "develop".into(), "Custom...".into()];
    window.set_branch_options(slint::ModelRc::new(slint::VecModel::from(branch_options)));

    let known = ["main", "master", "develop"];
    let mut branch_selected = slint::SharedString::from("Custom...");
    let mut branch_custom = slint::SharedString::new();
    if !default_branch.is_empty() && known.contains(&default_branch.as_str()) {
        branch_selected = default_branch.into();
    } else if !default_branch.is_empty() {
        branch_custom = default_branch.into();
    }
    window.set_branch_selected_value(branch_selected);
    window.set_branch_custom_value(branch_custom);

    // `safe.directory` is multi-valued. Keep the trusted list in a model so
    // the UI can add and remove rows; Save rewrites every value.
    let safe_directories: Rc<slint::VecModel<slint::SharedString>> = Rc::new(
        gitconfig::read_all("safe.directory")
            .unwrap_or_default()
            .into_iter()
            .map(slint::SharedString::from)
            .collect::<Vec<_>>()
            .into(),
    );
    window.set_safe_directories(slint::ModelRc::from(safe_directories.clone()));

    // A path containing `*` is held here until the user confirms the warning.
    let wildcard_pending: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));

    {
        let weak = window.as_weak();
        window.on_browse_folder(move || {
            let Some(window) = weak.upgrade() else { return };
            match folder_picker::pick_folder() {
                Ok(Some(path)) => window.set_safe_directory_input(path.into()),
                Ok(None) => {}
                Err(error) => {
                    window.set_status_text(format!("Could not open folder picker: {error}").into())
                }
            }
        });
    }

    {
        let weak = window.as_weak();
        let model = safe_directories.clone();
        let pending = wildcard_pending.clone();
        window.on_add_safe_directory(move || {
            let Some(window) = weak.upgrade() else { return };
            let path = window.get_safe_directory_input().trim().to_string();
            if path.is_empty() {
                return;
            }
            if path.contains('*') {
                *pending.borrow_mut() = Some(path);
                window.set_show_safe_warning(true);
                return;
            }
            push_safe_directory(&model, path);
            window.set_safe_directory_input("".into());
        });
    }

    {
        let weak = window.as_weak();
        let model = safe_directories.clone();
        let pending = wildcard_pending.clone();
        window.on_confirm_safe_warning(move || {
            let Some(window) = weak.upgrade() else { return };
            if let Some(path) = pending.borrow_mut().take() {
                push_safe_directory(&model, path);
                window.set_safe_directory_input("".into());
            }
            window.set_show_safe_warning(false);
        });
    }

    {
        let weak = window.as_weak();
        let pending = wildcard_pending.clone();
        window.on_dismiss_safe_warning(move || {
            pending.borrow_mut().take();
            if let Some(window) = weak.upgrade() {
                window.set_show_safe_warning(false);
            }
        });
    }

    {
        let model = safe_directories.clone();
        window.on_remove_safe_directory(move |index| {
            let index = index.max(0) as usize;
            if index < model.row_count() {
                model.remove(index);
            }
        });
    }

    // Save callback.
    let safe_directories_for_save = safe_directories.clone();
    let weak = window.as_weak();
    window.on_save_clicked(move || {
        let window = weak.unwrap();
        let safe_directory_values: Vec<String> = safe_directories_for_save
            .iter()
            .map(|value| value.to_string())
            .collect();
        let name = window.get_user_name();
        let email = window.get_user_email();

        let custom_label = slint::SharedString::from("Custom...");

        let gpg_val = if window.get_gpg_selected_value() == custom_label {
            window.get_gpg_custom_value()
        } else {
            gpg_display_to_fpr
                .iter()
                .find(|(d, _)| d == &window.get_gpg_selected_value())
                .map(|(_, fpr)| slint::SharedString::from(fpr.as_str()))
                .unwrap_or_default()
        };

        let branch_val = if window.get_branch_selected_value() == custom_label {
            window.get_branch_custom_value()
        } else {
            window.get_branch_selected_value()
        };

        let commit_gpg = if window.get_commit_gpgsign() { "true" } else { "false" };
        let tag_gpg = if window.get_tag_gpgsign() { "true" } else { "false" };

        let smtp_from = window.get_sendemail_from();
        let smtp_user = window.get_sendemail_smtpuser();
        let smtp_server = window.get_sendemail_smtpserver();
        let smtp_port = window.get_sendemail_smtpserverport();
        let smtp_enc = window.get_encryption_selected_value();
        let unset_label = slint::SharedString::from("unset");
        let autocrlf_val = window.get_autocrlf_selected_value();
        let quotepath_val = window.get_quotepath_selected_value();
        let core_editor = if window.get_core_editor_selected_value() == custom_label {
            window.get_core_editor_custom_value()
        } else if window.get_core_editor_selected_value() == "Default (unset)" {
            slint::SharedString::new()
        } else {
            window.get_core_editor_selected_value()
        };
        let http_proxy = window.get_http_proxy();
        let https_proxy = window.get_https_proxy();
        let credential_helper =
            if window.get_credential_helper_selected_value() == custom_label {
                window.get_credential_helper_custom_value()
            } else if window.get_credential_helper_selected_value() == "Default (unset)" {
                slint::SharedString::new()
            } else {
                window.get_credential_helper_selected_value()
            };

        let result = gitconfig::write("user.name", &name)
            .and_then(|()| gitconfig::write("user.email", &email))
            .and_then(|()| {
                if gpg_val.is_empty() {
                    gitconfig::unset("user.signingkey")
                } else {
                    gitconfig::write("user.signingkey", &gpg_val)
                }
            })
            .and_then(|()| {
                if branch_val.is_empty() {
                    gitconfig::unset("init.defaultBranch")
                } else {
                    gitconfig::write("init.defaultBranch", &branch_val)
                }
            })
            .and_then(|()| gitconfig::write("commit.gpgsign", commit_gpg))
            .and_then(|()| gitconfig::write("tag.gpgsign", tag_gpg))
            .and_then(|()| {
                if autocrlf_val == unset_label {
                    gitconfig::unset("core.autocrlf")
                } else {
                    gitconfig::write("core.autocrlf", &autocrlf_val)
                }
            })
            .and_then(|()| {
                if quotepath_val == unset_label {
                    gitconfig::unset("core.quotepath")
                } else {
                    gitconfig::write("core.quotepath", &quotepath_val)
                }
            })
            .and_then(|()| {
                if core_editor.is_empty() {
                    gitconfig::unset("core.editor")
                } else {
                    gitconfig::write("core.editor", &core_editor)
                }
            })
            .and_then(|()| {
                if http_proxy.is_empty() {
                    gitconfig::unset("http.proxy")
                } else {
                    gitconfig::write("http.proxy", &http_proxy)
                }
            })
            .and_then(|()| {
                if https_proxy.is_empty() {
                    gitconfig::unset("https.proxy")
                } else {
                    gitconfig::write("https.proxy", &https_proxy)
                }
            })
            .and_then(|()| {
                if credential_helper.is_empty() {
                    gitconfig::unset("credential.helper")
                } else {
                    gitconfig::write("credential.helper", &credential_helper)
                }
            })
            .and_then(|()| {
                gitconfig::unset_all("safe.directory").and_then(|()| {
                    for directory in &safe_directory_values {
                        gitconfig::add("safe.directory", directory)?;
                    }
                    Ok(())
                })
            })
            .and_then(|()| {
                if smtp_from.is_empty() {
                    gitconfig::unset("sendemail.from")
                } else {
                    gitconfig::write("sendemail.from", &smtp_from)
                }
            })
            .and_then(|()| {
                if smtp_user.is_empty() {
                    gitconfig::unset("sendemail.smtpuser")
                } else {
                    gitconfig::write("sendemail.smtpuser", &smtp_user)
                }
            })
            .and_then(|()| {
                if smtp_server.is_empty() {
                    gitconfig::unset("sendemail.smtpserver")
                } else {
                    gitconfig::write("sendemail.smtpserver", &smtp_server)
                }
            })
            .and_then(|()| {
                if smtp_port.is_empty() {
                    gitconfig::unset("sendemail.smtpserverport")
                } else {
                    gitconfig::write("sendemail.smtpserverport", &smtp_port)
                }
            })
            .and_then(|()| {
                if smtp_enc == "none" {
                    gitconfig::unset("sendemail.smtpencryption")
                } else {
                    gitconfig::write("sendemail.smtpencryption", &smtp_enc)
                }
            });

        let status = match result {
            Ok(()) => "Saved.".to_string(),
            Err(e) => format!("Error: {e}"),
        };
        window.set_status_text(status.into());
    });

    window.run()
}

/// Append a trusted directory unless it is already in the list.
fn push_safe_directory(model: &slint::VecModel<slint::SharedString>, path: String) {
    if model.iter().any(|existing| existing.as_str() == path) {
        return;
    }
    model.push(path.into());
}
