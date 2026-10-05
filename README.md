# GitTune

A small desktop tool to view and edit your global git identity — because
tuning git should be as easy as tuning a guitar.

GitTune talks to git **exclusively through the `git config` CLI**. It never
parses or rewrites `~/.gitconfig` itself, so whatever git understands,
GitTune understands.

**Version 1.0.0** — first release.

## Features

- View and edit the global `user.name` and `user.email`
- Material-style UI built with [Slint](https://slint.dev)
- All reads and writes go through `git config --global`, never direct file access

## Requirements

- [Rust](https://www.rust-lang.org/tools/install) (edition 2024 toolchain)
- `git` available on `PATH`

## Build & Run

```sh
cargo run --release
```

On first build, Cargo downloads and compiles the Slint dependencies.
The UI style is set to Material at compile time (see `build.rs`).

## Usage

Launch the app, edit the **Name** and **Email** fields, and press **Save**.
The values are written with:

```sh
git config --global user.name  "<name>"
git config --global user.email "<email>"
```

Verify from a terminal:

```sh
git config --global user.name
git config --global user.email
```

## Project Layout

```
build.rs            # compiles ui/main.slint with the Material style
src/main.rs         # app entry: wires the UI to the git backend
src/gitconfig.rs    # thin wrapper around `git config --global`
ui/main.slint       # declarative UI (Slint)
```

## Roadmap

- Edit more `gitconfig` keys (signing key, default branch, aliases, ...)
- Support other scopes (`--local`, `--system`)
- Validation feedback for malformed values

## Contributing

See [CONTRIBUTION](CONTRIBUTION). Issues and pull requests are welcome.

## License

[MIT](LICENSE) © 2026 Oliver Lin & ZIT Studio
