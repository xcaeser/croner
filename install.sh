#!/bin/sh

set -eu

repo="xcaeser/croner"
croner_home=${CRONER_HOME:-$HOME/.croner}
bin_dir=${CRONER_BIN_DIR:-$HOME/.local/bin}

fail() {
    printf 'croner: %s\n' "$1" >&2
    exit 1
}

for command_name in curl tar awk mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || fail "missing required command: $command_name"
done

case "$croner_home" in
    /*) ;;
    *) fail "CRONER_HOME must be an absolute path" ;;
esac
case "$bin_dir" in
    /*) ;;
    *) fail "CRONER_BIN_DIR must be an absolute path" ;;
esac

case "$(uname -s)" in
    Darwin) os="macos" ;;
    Linux) os="linux" ;;
    *) fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    arm64 | aarch64) arch="aarch64" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
esac

asset="croner-$arch-$os.tar.gz"
release_url="https://github.com/$repo/releases/latest/download"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/croner.XXXXXX")
archive="$tmp_dir/$asset"
checksums="$tmp_dir/SHA256SUMS"
temp_binary=""
temp_link=""

cleanup() {
    [ -z "$temp_binary" ] || rm -f "$temp_binary"
    [ -z "$temp_link" ] || rm -f "$temp_link"
    rm -rf "$tmp_dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

printf 'Downloading %s\n' "$asset"
curl -fsSL "$release_url/$asset" -o "$archive"
curl -fsSL "$release_url/SHA256SUMS" -o "$checksums"

expected=$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "$checksums")
[ -n "$expected" ] || fail "checksum not found for $asset"
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$archive" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$archive" | awk '{ print $1 }')
else
    fail "sha256sum or shasum is required"
fi
[ "$actual" = "$expected" ] || fail "checksum verification failed"

tar -xzf "$archive" -C "$tmp_dir"
[ -f "$tmp_dir/croner" ] || fail "release archive does not contain croner"

install_dir="$croner_home/bin"
install_path="$install_dir/croner"
link_path="$bin_dir/croner"
[ ! -d "$link_path" ] || fail "$link_path is a directory"
mkdir -p "$install_dir" "$bin_dir"

temp_binary="$install_dir/.croner.$$"
cp "$tmp_dir/croner" "$temp_binary"
chmod 755 "$temp_binary"
mv -f "$temp_binary" "$install_path"
temp_binary=""

temp_link="$bin_dir/.croner-link.$$"
ln -s "$install_path" "$temp_link"
mv -f "$temp_link" "$link_path"
temp_link=""

printf 'Installed croner to %s\n' "$install_path"
printf 'Linked %s\n' "$link_path"
case ":${PATH:-}:" in
    *":$bin_dir:"*) ;;
    *) printf 'Add %s to PATH to run croner directly.\n' "$bin_dir" ;;
esac
