%global debug_package %{nil}

Name:           git-tune
Version:        1.6.1
Release:        1%{?dist}
Summary:        View and edit your global git identity

License:        MIT
URL:            https://github.com/zitzhen/GitTune
Source0:        git-tune-%{version}-x86_64.tar.gz
BuildArch:      x86_64

Requires:       git
Requires:       gnupg2

%description
GitTune is a small desktop tool for viewing and editing your global Git
identity. Reads and writes go through "git config --global", and GPG secret
keys are listed with "gpg --list-secret-keys".

%prep
%setup -q -n git-tune-%{version}-x86_64

%build
# The release binary is built by scripts/package-rpm.sh inside a CentOS
# Stream 9 container so that the glibc baseline matches RHEL 9 / Fedora.
# Nothing to compile here.

%install
rm -rf %{buildroot}
install -Dpm 0755 GitTune \
  %{buildroot}%{_bindir}/git-tune
install -Dpm 0644 git-tune.desktop \
  %{buildroot}%{_datadir}/applications/git-tune.desktop
install -Dpm 0644 git-tune.1.gz \
  %{buildroot}%{_mandir}/man1/git-tune.1.gz
install -Dpm 0644 LICENSE \
  %{buildroot}%{_datadir}/licenses/%{name}/LICENSE
install -Dpm 0644 README.md \
  %{buildroot}%{_datadir}/doc/%{name}/README.md

for s in 48 128 256; do
  install -Dpm 0644 "hicolor/${s}x${s}/apps/git-tune.png" \
    "%{buildroot}%{_datadir}/icons/hicolor/${s}x${s}/apps/git-tune.png"
done
install -Dpm 0644 hicolor/scalable/apps/git-tune.svg \
  %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/git-tune.svg

%files
%license %{_datadir}/licenses/%{name}/LICENSE
%doc %{_datadir}/doc/%{name}/README.md
%{_bindir}/git-tune
%{_datadir}/applications/git-tune.desktop
%{_mandir}/man1/git-tune.1*
%{_datadir}/icons/hicolor/48x48/apps/git-tune.png
%{_datadir}/icons/hicolor/128x128/apps/git-tune.png
%{_datadir}/icons/hicolor/256x256/apps/git-tune.png
%{_datadir}/icons/hicolor/scalable/apps/git-tune.svg

%changelog
* Tue Nov 17 2026 Oliver Lin <oliver@liuxiaozhen.dev> - 1.6.1-1
- Initial RPM package.
