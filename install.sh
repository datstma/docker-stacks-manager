#!/usr/bin/env bash
#
# Install, update or uninstall Docker Stack Manager.
#
#   curl -fsSL https://raw.githubusercontent.com/datstma/docker-stacks-manager/main/install.sh | bash
#
# Options (also settable as environment variables):
#   --prefix DIR   Install into DIR/bin               (DSM_PREFIX; default ~/.local, /usr/local as root)
#   --ref REF      Release tag or branch to install   (DSM_REF; default: latest release)
#   --uninstall    Remove an installed copy
#
# Pass options through a pipe with:  curl -fsSL .../install.sh | bash -s -- --prefix /opt/dsm
#
# Run from a clone (./install.sh), it installs the clone's own script instead
# of downloading one. Running it again updates an existing install, as does
# `dsm --update`.
#
set -euo pipefail

REPO="datstma/docker-stacks-manager"
NAME="docker-stacks-manager"
ALIAS="dsm"

if [ "$(id -u)" -eq 0 ]; then default_prefix=/usr/local; else default_prefix="$HOME/.local"; fi
PREFIX="${DSM_PREFIX:-$default_prefix}"
REF="${DSM_REF:-}"
UNINSTALL=false

if [ -t 1 ]; then
    B=$'\033[1m' G=$'\033[0;32m' Y=$'\033[1;33m' R=$'\033[0;31m' D=$'\033[2m' N=$'\033[0m'
else
    B="" G="" Y="" R="" D="" N=""
fi
info() { printf '%s==>%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%sWarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sError:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX="$2"; shift ;;
        --prefix=*) PREFIX="${1#--prefix=}" ;;
        --ref) [ $# -ge 2 ] || die "--ref needs a tag or branch"; REF="$2"; shift ;;
        --ref=*) REF="${1#--ref=}" ;;
        --uninstall) UNINSTALL=true ;;
        -h|--help) sed -n '3,17p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

BIN_DIR="$PREFIX/bin"
TARGET="$BIN_DIR/$NAME"
LINK="$BIN_DIR/$ALIAS"

if $UNINSTALL; then
    removed=false
    for f in "$LINK" "$TARGET"; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            rm -f "$f" || die "could not remove $f (try with sudo)"
            info "Removed $f"; removed=true
        fi
    done
    $removed || warn "nothing installed in $BIN_DIR"
    exit 0
fi

fetch() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 "$1"
    elif command -v wget >/dev/null 2>&1; then wget -qO- "$1"
    else die "curl or wget is required"; fi
}

mkdir -p "$BIN_DIR" 2>/dev/null || die "cannot create $BIN_DIR (try with sudo, or --prefix ~/.local)"
[ -w "$BIN_DIR" ] || die "no write access to $BIN_DIR (try with sudo, or --prefix ~/.local)"

tmp="$(mktemp "$BIN_DIR/.$NAME.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

src_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -z "$REF" ] && [ -n "$src_dir" ] && [ -f "$src_dir/$NAME.sh" ]; then
    info "Installing from $src_dir"
    cp "$src_dir/$NAME.sh" "$tmp"
else
    if [ -z "$REF" ]; then
        REF="$(fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null |
            sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1 || true)"
        [ -n "$REF" ] || REF=main
    fi
    info "Downloading $NAME ($REF)"
    fetch "https://raw.githubusercontent.com/$REPO/$REF/$NAME.sh" > "$tmp" ||
        die "download failed: https://raw.githubusercontent.com/$REPO/$REF/$NAME.sh"
fi

head -1 "$tmp" | grep -q '^#!.*bash' && bash -n "$tmp" 2>/dev/null ||
    die "the downloaded file is not a valid $NAME script"
new_version="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$tmp" | head -1)"

old_version=""
[ -f "$TARGET" ] && old_version="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$TARGET" | head -1)"

chmod 755 "$tmp"
mv -f "$tmp" "$TARGET"
trap - EXIT
ln -sf "$NAME" "$LINK"

if [ "$old_version" = "$new_version" ]; then
    info "Reinstalled $TARGET ($new_version)"
elif [ -n "$old_version" ]; then
    info "Updated $TARGET: $old_version -> $new_version"
else
    info "Installed $TARGET ($new_version)"
fi
info "Shortcut: $LINK"

# Checks that would stop it from running
bash_major="$(bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
if [ "$bash_major" -lt 4 ]; then
    if [ "$(uname -s)" = Darwin ]; then
        warn "the bash on your PATH is $(bash -c 'echo $BASH_VERSION'); $NAME needs 4.0+. Install one with: brew install bash"
    else
        warn "the bash on your PATH is too old; $NAME needs bash 4.0+"
    fi
fi
command -v docker >/dev/null 2>&1 || warn "docker was not found on your PATH"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        warn "$BIN_DIR is not on your PATH. Add this to your shell profile (~/.bashrc, ~/.zshrc):"
        printf '\n    export PATH="%s:$PATH"\n\n' "$BIN_DIR" >&2
        ;;
esac

cat <<EOF

${B}Get started${N}
  cd ~/docker-stacks && $ALIAS -I     ${D}# interactive TUI, run from your stacks directory${N}
  $ALIAS -d ~/docker-stacks           ${D}# ...or point it at the directory${N}
  $ALIAS --update                     ${D}# update to the latest release${N}

EOF
