mod gitconfig;
mod gpg;

slint::include_modules!();

fn main() -> Result<(), slint::PlatformError> {
    let window = MainWindow::new()?;

    // Load current git config values.
    let name = gitconfig::read("user.name").unwrap_or_default();
    let email = gitconfig::read("user.email").unwrap_or_default();
    let signing_key = gitconfig::read("user.signingkey").unwrap_or_default();
    let default_branch = gitconfig::read("init.defaultBranch").unwrap_or_default();
    let commit_gpgsign = gitconfig::read("commit.gpgsign").unwrap_or_default() == "true";
    let tag_gpgsign = gitconfig::read("tag.gpgsign").unwrap_or_default() == "true";

    window.set_user_name(name.into());
    window.set_user_email(email.into());
    window.set_commit_gpgsign(commit_gpgsign);
    window.set_tag_gpgsign(tag_gpgsign);

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

    // Save callback.
    let weak = window.as_weak();
    window.on_save_clicked(move || {
        let window = weak.unwrap();
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
            .and_then(|()| gitconfig::write("tag.gpgsign", tag_gpg));

        let status = match result {
            Ok(()) => "Saved.".to_string(),
            Err(e) => format!("Error: {e}"),
        };
        window.set_status_text(status.into());
    });

    window.run()
}
