mod gitconfig;

slint::include_modules!();

fn main() -> Result<(), slint::PlatformError> {
    let window = MainWindow::new()?;

    window.set_user_name(gitconfig::read("user.name").unwrap_or_default().into());
    window.set_user_email(gitconfig::read("user.email").unwrap_or_default().into());

    let weak = window.as_weak();
    window.on_save_clicked(move || {
        let window = weak.unwrap();
        let name = window.get_user_name();
        let email = window.get_user_email();

        let result = gitconfig::write("user.name", &name)
            .and_then(|()| gitconfig::write("user.email", &email));

        let status = match result {
            Ok(()) => "Saved.".to_string(),
            Err(e) => format!("Error: {e}"),
        };
        window.set_status_text(status.into());
    });

    window.run()
}
