#!/usr/bin/env bash
# install.sh — symlink bin/brew-cooldown into a PATH directory.
# Idempotent. Re-run anytime to refresh the symlink.

set -euo pipefail
IFS=$'\n\t'

usage() {
    cat <<EOF
install.sh — install brew-cooldown into a PATH directory.

USAGE:
  ./install.sh [--prefix DIR] [--force] [--uninstall]

OPTIONS:
  --prefix DIR    install into DIR (default: /usr/local/bin if writable, else \$HOME/.local/bin)
  --force         overwrite an existing brew-cooldown that points elsewhere
  --uninstall     remove a brew-cooldown symlink that points at this repo
  -h, --help      show this help

After install, run:
    brew-cooldown --version
to verify it's on PATH. If not, add the install dir to PATH in your shell rc.
EOF
}

log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'install.sh: WARN: %s\n' "$*" >&2; }
die()  { printf 'install.sh: ERROR: %s\n' "$*" >&2; exit 1; }

PREFIX=""
FORCE=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            if [[ $# -lt 2 ]]; then die "--prefix requires a directory"; fi
            PREFIX="$2"; shift 2 ;;
        --force)     FORCE=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown argument: $1 (try --help)" ;;
    esac
done

# Resolve repo root (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_BIN="${SCRIPT_DIR}/bin/brew-cooldown"

if [[ ! -f "$REPO_BIN" ]]; then
    die "expected brew-cooldown at $REPO_BIN; run install.sh from inside the cloned repo"
fi
if [[ ! -x "$REPO_BIN" ]]; then
    chmod +x "$REPO_BIN"
fi

# Default prefix
if [[ -z "$PREFIX" ]]; then
    if [[ -w /usr/local/bin ]]; then
        PREFIX="/usr/local/bin"
    else
        PREFIX="${HOME}/.local/bin"
    fi
fi
if [[ ! -d "$PREFIX" ]]; then
    log "creating $PREFIX"
    mkdir -p "$PREFIX" || die "cannot create $PREFIX"
fi
if [[ ! -w "$PREFIX" ]]; then
    die "$PREFIX is not writable; pass --prefix DIR with somewhere you can write"
fi

TARGET="${PREFIX}/brew-cooldown"

# Uninstall path
if [[ "$UNINSTALL" -eq 1 ]]; then
    if [[ ! -e "$TARGET" && ! -L "$TARGET" ]]; then
        log "nothing to uninstall at $TARGET"
        exit 0
    fi
    if [[ -L "$TARGET" ]]; then
        link_target=$(readlink "$TARGET" || true)
        if [[ "$link_target" != "$REPO_BIN" && "$FORCE" -ne 1 ]]; then
            die "$TARGET is a symlink to $link_target, not this repo. Re-run with --force to remove."
        fi
        rm -f "$TARGET"
        log "removed $TARGET"
        exit 0
    fi
    if [[ "$FORCE" -ne 1 ]]; then
        die "$TARGET exists and is not a symlink. Re-run with --force to remove."
    fi
    rm -f "$TARGET"
    log "removed $TARGET"
    exit 0
fi

# Verify required deps (warn-only for brew, since user may install brew after us)
for dep in curl jq; do
    if ! type -P "$dep" >/dev/null 2>&1; then
        die "required dependency '$dep' is not on PATH; install it first (e.g., brew install $dep)"
    fi
done
if ! type -P brew >/dev/null 2>&1; then
    warn "Homebrew ('brew') is not on PATH. brew-cooldown will fail when invoked until brew is installed."
fi

# Install / refresh the symlink
if [[ -e "$TARGET" || -L "$TARGET" ]]; then
    if [[ -L "$TARGET" ]]; then
        link_target=$(readlink "$TARGET" || true)
        if [[ "$link_target" == "$REPO_BIN" ]]; then
            log "already installed: $TARGET -> $REPO_BIN (no change)"
        else
            if [[ "$FORCE" -ne 1 ]]; then
                die "$TARGET points at $link_target, not this repo. Re-run with --force to overwrite."
            fi
            ln -snf "$REPO_BIN" "$TARGET"
            log "replaced symlink: $TARGET -> $REPO_BIN"
        fi
    else
        if [[ "$FORCE" -ne 1 ]]; then
            die "$TARGET exists and is not a symlink. Re-run with --force to overwrite."
        fi
        rm -f "$TARGET"
        ln -s "$REPO_BIN" "$TARGET"
        log "replaced regular file with symlink: $TARGET -> $REPO_BIN"
    fi
else
    ln -s "$REPO_BIN" "$TARGET"
    log "installed: $TARGET -> $REPO_BIN"
fi

# PATH check
case ":${PATH}:" in
    *":${PREFIX}:"*) ;;
    *) warn "$PREFIX is not on your \$PATH. Add this to your shell rc (e.g. ~/.bashrc, ~/.zshrc):" \
       && warn "    export PATH=\"\$HOME/.local/bin:\$PATH\"" \
       && warn "(or use the appropriate path for --prefix=$PREFIX)" ;;
esac

cat <<EOF

Done. Try:
    brew-cooldown --version
    brew-cooldown --help

Optional config: \${XDG_CONFIG_HOME:-\$HOME/.config}/brew-cooldown/config
See README.md and docs/spec.md for usage; docs/threat-model.md for security stance.
EOF
