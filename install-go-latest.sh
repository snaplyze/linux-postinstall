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

download_with_fallback() {
  # Usage: download_with_fallback <output> <label> <primary_url> [fallback_url]
  local output="$1" label="$2" primary="$3" fallback="${4:-}"
  if curl -fsSL -o "$output" "$primary"; then
    return 0
  fi
  if [ -n "$fallback" ]; then
    warn "Failed to download ${label} from ${primary}. Trying mirror..."
    curl -fsSL -o "$output" "$fallback" || die "Failed to download ${label} from mirror ${fallback}"
  else
    die "Failed to download ${label} from ${primary}"
  fi
}

shell_present() {
  local shell_name="$1"
  command -v "$shell_name" >/dev/null 2>&1 && return 0
  if [ -f /etc/shells ]; then
    if awk -v shell="$shell_name" 'BEGIN { FS="/" }
      $0 !~ /^#/ { if ($NF == shell) { exit 0 } }
      END { exit 1 }' /etc/shells; then
      return 0
    fi
  fi
  return 1
}

install_system_snippet() {
  # Usage: install_system_snippet <destination> <content>
  local target="$1" content="$2" dir
  dir="$(dirname "$target")"
  sudo_if_needed mkdir -p "$dir" || return 1
  if is_root; then
    printf '%s\n' "$content" > "$target" || return 1
  else
    printf '%s\n' "$content" | sudo tee "$target" >/dev/null || return 1
  fi
  sudo_if_needed chmod 644 "$target" >/dev/null 2>&1 || true
  return 0
}

append_user_snippet() {
  # Usage: append_user_snippet <file> <marker> <snippet>
  local file="$1" marker="$2" snippet="$3"
  local dir
  dir="$(dirname "$file")"
  mkdir -p "$dir" || return 2
  touch "$file" || return 2
  if grep -Fq "$marker" "$file"; then
    return 1
  fi
  {
    printf '\n%s\n' "$snippet"
  } >> "$file" || return 2
  return 0
}

ensure_user_posix_profiles() {
  local marker="# golang env (install-go-latest.sh)" appended=()
  local snippet="$marker
export PATH=\"\$PATH:/usr/local/go/bin\"
export GOPATH=\"\$HOME/go\"
export PATH=\"\$PATH:\$GOPATH/bin\""
  local files=("${HOME}/.profile") file

  if shell_present bash; then
    files+=("${HOME}/.bashrc")
  fi
  if shell_present zsh; then
    files+=("${HOME}/.zshrc")
  fi
  if shell_present ksh; then
    files+=("${HOME}/.kshrc")
  fi

  for file in "${files[@]}"; do
    if append_user_snippet "$file" "$marker" "$snippet"; then
      appended+=("$file")
    fi
  done

  if [ ${#appended[@]} -gt 0 ]; then
    warn "Added Go env to ${appended[*]}. Run: source the updated files or restart the shell."
  fi
}

ensure_user_csh_profiles() {
  local marker="# golang env (install-go-latest.sh)" appended=()
  local snippet="$marker
setenv GOPATH \"\$HOME/go\"
if ( $?PATH ) then
  setenv PATH \"\$PATH:/usr/local/go/bin:\${GOPATH}/bin\"
else
  setenv PATH \"/usr/local/go/bin:\${GOPATH}/bin\"
endif"
  local files=() file

  if shell_present csh; then
    files+=("${HOME}/.cshrc")
  fi
  if shell_present tcsh; then
    files+=("${HOME}/.tcshrc")
  fi

  for file in "${files[@]}"; do
    if append_user_snippet "$file" "$marker" "$snippet"; then
      appended+=("$file")
    fi
  done

  if [ ${#appended[@]} -gt 0 ]; then
    warn "Added Go env to ${appended[*]}. Run: source the updated files or restart the shell."
  fi
}

ensure_user_fish_profile() {
  local conf_dir="${HOME}/.config/fish/conf.d"
  local file="${conf_dir}/golang.fish"
  mkdir -p "$conf_dir" || return 1
  cat <<'EOF' > "$file"
# golang env (install-go-latest.sh)
set -gx GOPATH $HOME/go
set -l go_bin /usr/local/go/bin
set -l gopath_bin $GOPATH/bin
if not contains $go_bin $PATH
  set -gx PATH $go_bin $PATH
end
if not contains $gopath_bin $PATH
  set -gx PATH $PATH $gopath_bin
end
EOF
  return 0
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
PRIMARY_BASE="https://go.dev/dl"
MIRROR_BASE="https://dl.google.com/go"
URL="${PRIMARY_BASE}/${TARBALL}"
SUM_URL="${URL}.sha256"
DOWNLOAD_URL="${URL}?download=1"
CHECKSUM_URL="${SUM_URL}?download=1"
MIRROR_URL="${MIRROR_BASE}/${TARBALL}"
MIRROR_SUM_URL="${MIRROR_BASE}/${TARBALL}.sha256"

log "Installing Go ${REQUESTED_VERSION} for ${OS}-${ARCH} into ${INSTALL_DIR}"
log "Download URL: ${URL}"

# -------- Temp workspace --------
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

cd "$WORKDIR"
download_with_fallback "$TARBALL" "Go archive" "$DOWNLOAD_URL" "$MIRROR_URL"

if [ "$VERIFY" -eq 1 ]; then
  log "Downloading checksum and verifying..."
  CHECKSUM_FILE="${TARBALL}.sha256"
  CHECKSUM_SOURCE="$CHECKSUM_URL"
  if ! curl -fsSL -o "$CHECKSUM_FILE" "$CHECKSUM_URL"; then
    warn "Failed to download checksum from ${CHECKSUM_URL}. Trying mirror..."
    curl -fsSL -o "$CHECKSUM_FILE" "$MIRROR_SUM_URL" || die "Failed to download checksum for ${TARBALL}."
    CHECKSUM_SOURCE="$MIRROR_SUM_URL"
  fi
  # File format: "<sha256>  <filename>"
  EXPECTED="$(awk '{print $1}' "$CHECKSUM_FILE")"
  if ! printf '%s' "$EXPECTED" | grep -Eq '^[0-9a-f]{64}$'; then
    if [ "$CHECKSUM_SOURCE" = "$CHECKSUM_URL" ]; then
      warn "Checksum from ${CHECKSUM_URL} looked invalid. Retrying via mirror..."
      curl -fsSL -o "$CHECKSUM_FILE" "$MIRROR_SUM_URL" || die "Failed to download checksum for ${TARBALL}."
      CHECKSUM_SOURCE="$MIRROR_SUM_URL"
      EXPECTED="$(awk '{print $1}' "$CHECKSUM_FILE")"
    fi
  fi
  if ! printf '%s' "$EXPECTED" | grep -Eq '^[0-9a-f]{64}$'; then
    die "Checksum download for ${TARBALL} looked invalid (source: ${CHECKSUM_SOURCE}). Try rerunning with --no-verify or check network access."
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
  POSIX_PROFILE_CONTENT=$(cat <<'EOP'
# golang system-wide environment (installed by install-go-latest.sh)
export PATH="$PATH:/usr/local/go/bin"
export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin"
EOP
)
  CSH_PROFILE_CONTENT=$(cat <<'EOC'
# golang system-wide environment (installed by install-go-latest.sh)
setenv GOPATH "$HOME/go"
if ( $?PATH ) then
  setenv PATH "$PATH:/usr/local/go/bin:${GOPATH}/bin"
else
  setenv PATH "/usr/local/go/bin:${GOPATH}/bin"
endif
EOC
)
  FISH_PROFILE_CONTENT=$(cat <<'EOFISH'
# golang system-wide environment (installed by install-go-latest.sh)
set -gx GOPATH $HOME/go
set -l go_bin /usr/local/go/bin
set -l gopath_bin $GOPATH/bin
if not contains $go_bin $PATH
  set -gx PATH $go_bin $PATH
end
if not contains $gopath_bin $PATH
  set -gx PATH $PATH $gopath_bin
end
EOFISH
)

  POSIX_SYSTEM_OK=0
  CSH_SYSTEM_OK=0
  FISH_SYSTEM_OK=0

  if install_system_snippet "/etc/profile.d/golang.sh" "$POSIX_PROFILE_CONTENT"; then
    POSIX_SYSTEM_OK=1
    log "Wrote /etc/profile.d/golang.sh"
  else
    warn "Could not write /etc/profile.d/golang.sh"
  fi

  if shell_present csh || shell_present tcsh; then
    if install_system_snippet "/etc/profile.d/golang.csh" "$CSH_PROFILE_CONTENT"; then
      CSH_SYSTEM_OK=1
      log "Wrote /etc/profile.d/golang.csh"
    else
      warn "Could not write /etc/profile.d/golang.csh"
    fi
  else
    CSH_SYSTEM_OK=1
  fi

  if shell_present fish; then
    if install_system_snippet "/etc/fish/conf.d/golang.fish" "$FISH_PROFILE_CONTENT"; then
      FISH_SYSTEM_OK=1
      log "Wrote /etc/fish/conf.d/golang.fish"
    else
      warn "Could not write /etc/fish/conf.d/golang.fish"
    fi
  else
    FISH_SYSTEM_OK=1
  fi

  if [ "$POSIX_SYSTEM_OK" -ne 1 ]; then
    warn "Falling back to user-level profile updates for POSIX-compatible shells."
    ensure_user_posix_profiles
  fi

  if [ "$CSH_SYSTEM_OK" -ne 1 ]; then
    warn "Falling back to user-level profile updates for C-shell derivatives."
    ensure_user_csh_profiles
  fi

  if [ "$FISH_SYSTEM_OK" -ne 1 ] && shell_present fish; then
    warn "Falling back to user-level profile updates for fish shell."
    if ensure_user_fish_profile; then
      warn "Added Go env to ${HOME}/.config/fish/conf.d/golang.fish. Run: source ~/.config/fish/conf.d/golang.fish"
    else
      warn "Failed to configure fish shell profile. Please add /usr/local/go/bin and $HOME/go/bin to fish PATH manually."
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
