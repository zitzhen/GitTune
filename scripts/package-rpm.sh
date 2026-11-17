#!/usr/bin/env bash
# Build the GitTune RPM package.
#
# The release binary is compiled inside a CentOS Stream 9 container so its
# glibc baseline matches RHEL 9 / Fedora. The spec itself only installs that
# pre-built binary plus desktop integration files.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${GITTUNE_RPM_IMAGE:-quay.io/centos/centos:stream9}"
CONTAINER="gittune-rpm-build-$$"

VERSION="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO/Cargo.toml" | head -n 1)"
if [ -z "$VERSION" ]; then
  echo "Error: cannot read version from Cargo.toml" >&2
  exit 1
fi
if ! grep -Fqx "Version:        $VERSION" "$REPO/rpm/git-tune.spec"; then
  echo "Error: rpm/git-tune.spec Version does not match Cargo.toml ($VERSION)" >&2
  exit 1
fi

for tool in docker convert; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: required tool not found: $tool" >&2
    exit 1
  fi
done

# /tmp is a tiny tmpfs on some hosts; /var/tmp has real disk behind it.
WORK="$(mktemp -d -p /var/tmp gittune-rpm.XXXXXX)"
cleanup() {
  # Everything under /build was created as root inside the container, so let
  # the container remove its own files before it is stopped.
  docker exec "$CONTAINER" bash -c \
    'rm -rf /build/* /build/.[!.]* 2>/dev/null || true' >/dev/null 2>&1 || true
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if [ -d "$WORK" ]; then
    rmdir "$WORK" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

mkdir -p "$WORK/rpmbuild"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
mkdir -p "$WORK/stage"

echo "==> Starting build container ($IMAGE)"
docker run -d --name "$CONTAINER" \
  -v "$REPO:/src:ro" -v "$WORK:/build" \
  -e CARGO_HOME=/build/cargo \
  -e RUSTUP_HOME=/build/rustup \
  -e CARGO_TARGET_DIR=/build/target \
  "$IMAGE" sleep infinity >/dev/null

echo "==> Installing RPM build and Slint system dependencies"
docker exec "$CONTAINER" bash -lc '
set -euo pipefail
dnf install -y --allowerasing --setopt=install_weak_deps=False \
  gcc gcc-c++ make pkgconf-pkg-config curl ca-certificates tar gzip git \
  libxcb-devel libxkbcommon-devel \
  fontconfig-devel mesa-libGL-devel wayland-devel libX11-devel \
  rpm-build redhat-rpm-config
'

echo "==> Building release binary with cargo $VERSION"
docker exec "$CONTAINER" bash -lc '
set -euo pipefail
if [ ! -x /build/cargo/bin/rustup ]; then
  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path
fi
. /build/cargo/env
cd /src
cargo build --release --locked
cp /build/target/release/GitTune /build/GitTune
strip /build/GitTune
file /build/GitTune
'

echo "==> Staging RPM source tree"
STAGE="$WORK/stage/git-tune-$VERSION-x86_64"
mkdir -p "$STAGE"
cp "$WORK/GitTune" "$STAGE/GitTune"
cp "$REPO/rpm/git-tune.desktop" "$STAGE/git-tune.desktop"
cp "$REPO/LICENSE" "$STAGE/LICENSE"
cp "$REPO/README.md" "$STAGE/README.md"

# The checked-in man page title has drifted before; force it to the Cargo
# version at build time as a final safety net.
sed -E "s/GitTune [0-9]+\.[0-9]+\.[0-9]+/GitTune $VERSION/" \
  "$REPO/debian/git-tune.1" | gzip -9n > "$STAGE/git-tune.1.gz"

for size in 48 128 256; do
  mkdir -p "$STAGE/hicolor/${size}x${size}/apps"
  convert "$REPO/snap/gui/git-tune.png" -resize "${size}x${size}" -background none \
    "$STAGE/hicolor/${size}x${size}/apps/git-tune.png"
done
mkdir -p "$STAGE/hicolor/scalable/apps"
cp "$REPO/Assets/gittune-mark.svg" "$STAGE/hicolor/scalable/apps/git-tune.svg"

TARBALL="$WORK/rpmbuild/SOURCES/git-tune-$VERSION-x86_64.tar.gz"
tar -czf "$TARBALL" -C "$WORK/stage" "git-tune-$VERSION-x86_64"
if [ "$(tar -tzf "$TARBALL" | sed -n '1p')" != "git-tune-$VERSION-x86_64/" ]; then
  echo "Error: unexpected tarball top-level directory" >&2
  exit 1
fi
cp "$REPO/rpm/git-tune.spec" "$WORK/rpmbuild/SPECS/git-tune.spec"

echo "==> Running rpmbuild"
docker exec "$CONTAINER" bash -lc '
set -euo pipefail
rpmbuild --define "_topdir /build/rpmbuild" \
  -bb /build/rpmbuild/SPECS/git-tune.spec
'

mkdir -p "$REPO/dist/rpm"
cp "$WORK"/rpmbuild/RPMS/x86_64/*.rpm "$REPO/dist/rpm/"
echo "==> RPM packages:"
ls -lh "$REPO/dist/rpm/"
