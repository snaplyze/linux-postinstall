#!/usr/bin/env bash
# install-go-latest.sh
# Installs the latest stable Go on Debian 13 (and Debian-like) systems directly from go.dev
# Supports: auto-arch detection (amd64/arm64), version pinning, checksum verification, uninstall, and env setup.
#
# Usage examples:
#   bash install-go-latest.sh                   # install latest stable
#   bash install-go-latest.sh --version 1.23.2  # pin exact version
#   bash install-go-latest.sh --uninstall       # remove /usr/local/go and env file
#   bash install-go-latest.sh --prefix /usr/local  # change prefix (default /usr/local)
#   bash install-go-latest.sh --no-profile      # skip editing profile files
#
# Notes:
# - Requires curl, tar, and sha256sum.
# - Installs Go into <prefix>/go (default /usr/local/go).
# - Adds PATH and GOPATH to /etc/profile.d/golang.sh (system-wide) if possible; otherwise to ~/.profile.
# - Idempotent: re-running updates to the requested version.
#
set -euo pipefail

# -------- Defaults --------
PREFIX="/usr/local"
INSTALL_DIR="${PREFIX}/go"
SET_PROFILE=1
REQUESTED_VERSION=""
ARCH_OVERRIDE=""
UNINSTALL=0
FORCE=0
VERIFY=1

# -------- Helpers --------
log() { printf "\033[1;34m[go-install]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[error]\033[0m %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

need_bin() { command -v "$1" >/dev/null 2>&1 || die "Required tool '$1' not found. Please install it."; }

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

sudo_if_needed() {
  if is_root; then
    "$@"
  else
    if command -v sudo >/dev/null 2>&1; then
      sudo "$@"
    else
      die "This action requires root. Install sudo or run this script as root."
    fi
  fi
}

sanitize_version() {
  # Strip optional "go" prefix and whitespace/newlines from version strings
  local raw="$1"
  raw="${raw#go}"
  printf '%s' "$raw" | tr -d '[:space:]'
}

usage() {
  cat <<EOF
install-go-latest.sh — install the latest stable Go on Debian 13

Options:
  --version X.Y.Z     Pin exact Go version (e.g., 1.23.2). Default: latest stable.
  --arch [amd64|arm64]  Override arch (auto-detected by default).
  --prefix DIR        Install prefix. Default: /usr/local (Go ends up in DIR/go).
  --uninstall         Remove installed Go and system profile file.
  --force             Proceed even if version detection fails in non-critical paths.
  --no-profile        Do not modify profile files.
  --no-verify         Skip checksum verification (not recommended).
  -h, --help          Show this help.

Examples:
  bash install-go-latest.sh
  bash install-go-latest.sh --version 1.23.2
  bash install-go-latest.sh --uninstall
EOF
}

# -------- Parse args --------
while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      shift; REQUESTED_VERSION="${1:-}"; [ -n "$REQUESTED_VERSION" ] || die "--version requires a value";;
    --arch)
      shift; ARCH_OVERRIDE="${1:-}"; [ -n "$ARCH_OVERRIDE" ] || die "--arch requires a value";;
    --prefix)
      shift; PREFIX="${1:-}"; [ -n "$PREFIX" ] || die "--prefix requires a value"; INSTALL_DIR="${PREFIX}/go";;
    --uninstall) UNINSTALL=1;;
    --force) FORCE=1;;
    --no-profile) SET_PROFILE=0;;
    --no-verify) VERIFY=0;;
    -h|--help) usage; exit 0;;
    *)
      err "Unknown option: $1"; usage; exit 1;;
  esac
  shift
done

if [ -n "$REQUESTED_VERSION" ]; then
  REQUESTED_VERSION="$(sanitize_version "$REQUESTED_VERSION")"
fi

need_bin curl
need_bin tar
need_bin sha256sum

# -------- Arch detection --------
detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      die "Unsupported architecture: $m (supported: amd64, arm64)"
      ;;
  esac
}

ARCH="${ARCH_OVERRIDE:-$(detect_arch)}"
OS="linux"

# -------- Uninstall path --------
if [ "$UNINSTALL" -eq 1 ]; then
  log "Uninstalling Go from ${INSTALL_DIR}..."
  if [ -d "$INSTALL_DIR" ]; then
    sudo_if_needed rm -rf "$INSTALL_DIR"
    log "Removed ${INSTALL_DIR}."
  else
    warn "Nothing to remove at ${INSTALL_DIR}."
  fi
  # Remove system-wide profile if created by us
  SYS_PROFILE="/etc/profile.d/golang.sh"
  if [ -f "$SYS_PROFILE" ]; then
    sudo_if_needed rm -f "$SYS_PROFILE"
    log "Removed ${SYS_PROFILE}."
  fi
  # Optional: do not edit user profiles on uninstall; the lines are harmless if left.
  log "Uninstall complete."
  exit 0
fi

# -------- Determine version --------
if [ -z "$REQUESTED_VERSION" ]; then
  log "Detecting latest stable Go version from go.dev..."
  if LATEST=$(curl -fsSL "https://go.dev/VERSION?m=text"); then
    # API returns one version per line; only care about the first stable entry
    LATEST="${LATEST%%$'\n'*}"
    REQUESTED_VERSION="$(sanitize_version "$LATEST")"
    [ -n "$REQUESTED_VERSION" ] || [ "$FORCE" -eq 1 ] || die "Failed to parse latest version string: '$LATEST'"
  else
    [ "$FORCE" -eq 1 ] || die "Failed to get latest version from go.dev. Use --force to continue."
  fi
fi

[ -n "$REQUESTED_VERSION" ] || die "Could not determine version. Use --version X.Y.Z."

TARBALL="go${REQUESTED_VERSION}.${OS}-${ARCH}.tar.gz"
BASE_URL="https://go.dev/dl"
URL="${BASE_URL}/${TARBALL}"
SUM_URL="${URL}.sha256"
DOWNLOAD_URL="${URL}?download=1"
CHECKSUM_URL="${SUM_URL}?download=1"

log "Installing Go ${REQUESTED_VERSION} for ${OS}-${ARCH} into ${INSTALL_DIR}"
log "Download URL: ${URL}"

# -------- Temp workspace --------
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

cd "$WORKDIR"
curl -fsSLo "$TARBALL" "$DOWNLOAD_URL"

if [ "$VERIFY" -eq 1 ]; then
  log "Downloading checksum and verifying..."
  curl -fsSLo "${TARBALL}.sha256" "$CHECKSUM_URL"
  # File format: "<sha256>  <filename>"
  EXPECTED="$(awk '{print $1}' "${TARBALL}.sha256")"
  if ! printf '%s' "$EXPECTED" | grep -Eq '^[0-9a-f]{64}$'; then
    die "Checksum download for ${TARBALL} looked invalid (got: ${EXPECTED}). Try rerunning with --no-verify or check network access."
  fi
  ACTUAL="$(sha256sum "$TARBALL" | awk '{print $1}')"
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    die "Checksum mismatch! expected=$EXPECTED actual=$ACTUAL"
  fi
  log "Checksum OK."
else
  warn "Skipping checksum verification (--no-verify)."
fi

# -------- Install --------
log "Removing any existing ${INSTALL_DIR} ..."
sudo_if_needed rm -rf "$INSTALL_DIR"

log "Extracting to ${PREFIX} ..."
sudo_if_needed tar -C "$PREFIX" -xzf "$TARBALL"

# -------- Profile setup --------
if [ "$SET_PROFILE" -eq 1 ]; then
  SYS_PROFILE="/etc/profile.d/golang.sh"
  PROFILE_CONTENT=$(cat <<'EOP'
# golang system-wide environment (installed by install-go-latest.sh)
export PATH="$PATH:/usr/local/go/bin"
export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin"
EOP
)
  if is_root; then
    printf "%s\n" "$PROFILE_CONTENT" > "$SYS_PROFILE"
    log "Wrote $SYS_PROFILE"
  else
    if sudo_if_needed sh -c "printf '%s\n' \"$PROFILE_CONTENT\" > '$SYS_PROFILE'"; then
      log "Wrote $SYS_PROFILE (system-wide)."
    else
      warn "Could not write $SYS_PROFILE. Falling back to per-user profile (~/.profile)."
      # Append lines to ~/.profile if not already present
      USER_PROFILE="${HOME}/.profile"
      touch "$USER_PROFILE"
      grep -q '/usr/local/go/bin' "$USER_PROFILE" || printf '\nexport PATH=$PATH:/usr/local/go/bin\n' >> "$USER_PROFILE"
      grep -q 'export GOPATH=' "$USER_PROFILE" || printf 'export GOPATH=$HOME/go\n' >> "$USER_PROFILE"
      grep -q '$GOPATH/bin' "$USER_PROFILE" || printf 'export PATH=$PATH:$GOPATH/bin\n' >> "$USER_PROFILE"
      warn "Added Go env to $USER_PROFILE. Run: source ~/.profile"
    fi
  fi
else
  warn "Skipped profile modification (--no-profile). Ensure /usr/local/go/bin is on your PATH."
fi

# -------- Final check --------
log "Installation complete."
if command -v go >/dev/null 2>&1; then
  log "Detected go in PATH: $(go version)"
else
  # Call the absolute path
  GO_BIN="${INSTALL_DIR}/bin/go"
  if [ -x "$GO_BIN" ]; then
    "$GO_BIN" version || true
    warn "go is not yet on your PATH. Open a new shell or 'source /etc/profile' (or '~/.profile')."
  else
    warn "Go binary not found at expected path: $GO_BIN"
  fi
fi
