#!/bin/bash

################################################################################
# VPS Optimization Script for Debian 13 (Trixie) - OPTIMIZED VERSION
# Purpose: Complete VPS optimization with XanMod kernel support
# Features: Auto RAM detection, XanMod kernel, user creation, SSH hardening
# Author: Auto-generated
# Date: 2025-11-11
# Fixed: Duplicates, inefficient logging, locale issues, redundancy
################################################################################

set -e

# Colors for output
readonly RED="\e[31m"
readonly GREEN="\e[32m"
readonly YELLOW="\e[33m"
readonly BLUE="\e[34m"
readonly RESET="\e[0m"

# Logging
readonly LOG_FILE="/var/log/vps_optimization.log"

# Default variables (can be overridden by environment)
NEW_USER=${NEW_USER:-snaplyze}
TIMEZONE=${TIMEZONE:-Europe/Moscow}
LOCALE_TO_GENERATE=${LOCALE_TO_GENERATE:-"ru_RU.UTF-8"}
DEFAULT_LOCALE=${DEFAULT_LOCALE:-"ru_RU.UTF-8"}
QUIET_MODE=${QUIET_MODE:-true}

# Force basic locale (will be updated later after proper setup)
export LC_ALL=C
export LANG=C
export LANGUAGE=en

# Helper functions
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Optimized logging functions
log() { 
    [[ "$QUIET_MODE" == "false" ]] && echo -e "${GREEN}✓${RESET} $*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" >> "$LOG_FILE"
}

info() { 
    [[ "$QUIET_MODE" == "false" ]] && echo -e "${BLUE}ℹ${RESET} $*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" >> "$LOG_FILE"
}

warn() { 
    echo -e "${YELLOW}⚠${RESET} $*" 
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" >> "$LOG_FILE"
}

error() { 
    echo -e "${RED}✗${RESET} $*" 
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >> "$LOG_FILE"
}

step() {
    [[ "$QUIET_MODE" == "false" ]] && {
        echo ""
        echo -e "${BLUE}══════════════════════════════════════════════════════════════${RESET}"
        echo -e "${BLUE}🔄 $1${RESET}"
        echo -e "${BLUE}══════════════════════════════════════════════════════════════${RESET}"
        echo ""
    }
    echo "$(date '+%Y-%m-%d %H:%M:%S') [STEP] $1" >> "$LOG_FILE"
}

show_progress() {
    local message="$1"
    local pid="$2"
    [[ "$QUIET_MODE" == "false" ]] && {
        echo -n "${BLUE}[INFO]${RESET} $message... "
        while kill -0 "$pid" 2>/dev/null; do
            echo -n "."
            sleep 1
        done
        echo " ${GREEN}✓${RESET}"
    }
}

# Consolidated package installation
install_packages() {
    local packages="$*"
    log "Installing packages: ${packages}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y $packages >> "$LOG_FILE" 2>&1
}

# Consolidated locale setup
setup_locale() {
    local locales_to_generate="$1"
    local default_locale="$2"
    
    log "Setting up locale: $default_locale"
    
    # Ensure locales package is installed
    if ! dpkg -s locales >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y locales >> "$LOG_FILE" 2>&1
    fi
    
    # Configure locales
    for locale in $locales_to_generate; do
        if ! grep -q -E "^${locale}[[:space:]]+UTF-8" /etc/locale.gen 2>/dev/null; then
            echo "${locale} UTF-8" >> /etc/locale.gen
        else
            sed -i "s/^#\s*\(${locale} UTF-8\)/\1/" /etc/locale.gen || true
        fi
    done
    
    # Generate locales with error handling
    if locale-gen 2>> "$LOG_FILE"; then
        log "Locales generated successfully"
    else
        warn "Some locales failed to generate, continuing..."
    fi
    
    # Set system default locale
    if update-locale LANG="$default_locale" LC_ALL="$default_locale" 2>> "$LOG_FILE"; then
        # Export for current session
        export LANG="$default_locale"
        export LC_ALL="$default_locale"
        export LANGUAGE="${default_locale%.*}:en"
        log "Locale configured: $default_locale"
    else
        warn "Failed to set locale $default_locale, keeping C locale"
        export LANG=C
        export LC_ALL=C
        export LANGUAGE=en
    fi
}

require_root

# Show help
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    cat << EOF
${GREEN}VPS Optimization Script for Debian 13 (Trixie)${RESET}

${CYAN}Usage:${RESET}
  $0 [OPTIONS]

${CYAN}Options:${RESET}
  ${GREEN}-v, --verbose${RESET}   Show detailed output (default is quiet)
  ${GREEN}-q, --quiet${RESET}     Run in quiet mode (minimal output)
  ${GREEN}-h, --help${RESET}      Show this help message

${CYAN}Remote Execution:${RESET}
  bash <(curl -s https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/optimize_vps.sh)

${CYAN}Examples:${RESET}
  sudo $0              # Interactive mode
  sudo $0 --verbose    # Detailed output mode
  sudo $0 --quiet      # Minimal output mode
EOF
    exit 0
fi

# Auto-detect remote execution and set quiet mode
if [[ "$0" == "/dev/fd/63" || "$0" == "/proc/self/fd/11" || "$0" == "/dev/stdin" ]]; then
    QUIET_MODE=true
    export REMOTE_EXECUTION=true
fi

# Process command line arguments
case "$1" in
    --verbose|-v) QUIET_MODE=false ;;
    --quiet|-q)   QUIET_MODE=true ;;
esac

log "=== Starting VPS Optimization ==="

################################################################################
# 0. System Detection and Initial Setup
################################################################################
step "Installing dependencies and detecting system..."

# Single update and install essential packages
{
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y bc locales curl wget git
} >> "$LOG_FILE" 2>&1

# Setup locale once (after packages are installed)
setup_locale "$LOCALE_TO_GENERATE" "$DEFAULT_LOCALE"

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    log "Detected OS: $NAME $VERSION_ID ($VERSION_CODENAME)"
else
    error "Cannot detect OS version. /etc/os-release not found."
    exit 1
fi

# Validate OS
if [[ ! "$ID" =~ ^(debian|ubuntu)$ ]]; then
    error "This script is designed for Debian/Ubuntu only. Detected: $ID"
    exit 1
fi

# Validate version
case "$ID" in
    debian)
        if [[ ! "$VERSION_ID" =~ ^(11|12|13)$ ]]; then
            warn "Optimized for Debian 11-13. Detected: Debian $VERSION_ID"
        fi
        ;;
    ubuntu)
        if (( $(echo "$VERSION_ID < 20.04" | bc -l) )); then
            warn "Optimized for Ubuntu 20.04+. Detected: Ubuntu $VERSION_ID"
        fi
        ;;
esac

################################################################################
# 1. User Creation and SSH Setup
################################################################################
step "User account setup..."

[[ "$QUIET_MODE" == "false" ]] && {
    info "We need to create a new sudo user for secure access."
    info "Root login will be disabled after setup."
}

# Handle username input
if [[ -n "$NEW_USER" && "$NEW_USER" != "snaplyze" ]]; then
    log "Using predefined username: $NEW_USER"
else
    read -p "Enter new username: " NEW_USER_INPUT
    NEW_USER=${NEW_USER_INPUT:-snaplyze}
    log "Using username: $NEW_USER"
fi

[[ -z "$NEW_USER" ]] && { error "Username cannot be empty!"; exit 1; }

# Create user if not exists
if id "$NEW_USER" &>/dev/null; then
    warn "User $NEW_USER already exists. Skipping creation..."
else
    adduser --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    log "User $NEW_USER created and added to sudo group"
fi

# Configure passwordless sudo
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$NEW_USER
chmod 440 /etc/sudoers.d/$NEW_USER
log "Passwordless sudo configured for $NEW_USER"

# Configure root passwordless sudo if not exists
if ! grep -q "^root.*NOPASSWD:ALL" /etc/sudoers.d/root 2>/dev/null; then
    echo "root ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/root
    chmod 440 /etc/sudoers.d/root
    log "Passwordless sudo configured for root"
fi

# SSH key setup
USER_HOME=$(eval echo ~$NEW_USER)
mkdir -p "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"

if [[ -n "$SSH_PUBLIC_KEY" ]]; then
    log "Using predefined SSH key"
else
    info "Please paste your SSH public key:"
    info "Generate with: ssh-keygen -t ed25519"
    read -p "SSH Public Key: " SSH_PUBLIC_KEY
fi

[[ -z "$SSH_PUBLIC_KEY" ]] && { error "SSH public key cannot be empty!"; exit 1; }

echo "$SSH_PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R $NEW_USER:$NEW_USER "$USER_HOME/.ssh"
log "SSH key configured for $NEW_USER"

warn "IMPORTANT: Test SSH login in another terminal!"
warn "Command: ssh $NEW_USER@$(hostname -I | awk '{print $1}')"
read -p "Press Enter once verified..."

################################################################################
# 2. System Localization
################################################################################
step "Configuring system localization..."

# Locale selection (only if not predefined and not in quiet mode)
if [[ -z "$LOCALE_TO_GENERATE" || "$LOCALE_TO_GENERATE" == "en_US.UTF-8" ]] && [[ "$QUIET_MODE" == "false" ]]; then
    echo "Select system locale:"
    echo "1) en_US.UTF-8 (English)"
    echo "2) ru_RU.UTF-8 (Russian)"
    echo "3) Both"
    read -p "Enter choice [1-3]: " LOCALE_CHOICE

    case $LOCALE_CHOICE in
        1) 
            LOCALE_TO_GENERATE="en_US.UTF-8"
            DEFAULT_LOCALE="en_US.UTF-8"
            ;;
        2)
            LOCALE_TO_GENERATE="ru_RU.UTF-8"
            DEFAULT_LOCALE="ru_RU.UTF-8"
            ;;
        3)
            LOCALE_TO_GENERATE="en_US.UTF-8 ru_RU.UTF-8"
            DEFAULT_LOCALE="en_US.UTF-8"
            ;;
        *)
            warn "Invalid choice. Using English"
            LOCALE_TO_GENERATE="en_US.UTF-8"
            DEFAULT_LOCALE="en_US.UTF-8"
            ;;
    esac
    setup_locale "$LOCALE_TO_GENERATE" "$DEFAULT_LOCALE"
elif [[ -z "$LOCALE_TO_GENERATE" || "$LOCALE_TO_GENERATE" == "en_US.UTF-8" ]]; then
    # In quiet mode, use English by default
    setup_locale "$LOCALE_TO_GENERATE" "$DEFAULT_LOCALE"
fi

# Hostname configuration
read -p "Enter new hostname (current: $(hostname)): " NEW_HOSTNAME
if [[ -n "$NEW_HOSTNAME" ]]; then
    if [[ $NEW_HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        OLD_HOSTNAME=$(hostname)
        hostnamectl set-hostname "$NEW_HOSTNAME"
        sed -i "s/127.0.1.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
        [[ ! -f "/etc/hosts" ]] && echo "127.0.1.1	${NEW_HOSTNAME}" >> /etc/hosts
        log "Hostname changed: $OLD_HOSTNAME -> $NEW_HOSTNAME"
    else
        warn "Invalid hostname. Keeping current: $(hostname)"
    fi
fi

# Timezone configuration
read -p "Enter timezone (current: $(timedatectl show --property=Timezone --value)): " NEW_TIMEZONE
if [[ -n "$NEW_TIMEZONE" ]]; then
    if timedatectl list-timezones | grep -q "^${NEW_TIMEZONE}$"; then
        timedatectl set-timezone "$NEW_TIMEZONE"
        log "Timezone set to: $NEW_TIMEZONE"
    else
        warn "Invalid timezone. Keeping current."
    fi
fi

timedatectl set-ntp true
log "NTP synchronization enabled"

################################################################################
# 3. Zsh and Starship Installation
################################################################################
step "Installing Zsh and Starship..."

# Install packages once
install_packages zsh git curl

# Install Starship
curl -sS https://starship.rs/install.sh | sh -s -- -y
log "Starship prompt installed"

# Shared plugins directory
readonly SHARED_ZSH_DIR="/opt/zsh-plugins"
mkdir -p "$SHARED_ZSH_DIR"

# Install plugins once
install_zsh_plugins() {
    local plugins=(
        "zsh-users/zsh-autosuggestions"
        "zsh-users/zsh-syntax-highlighting"
        "zsh-users/zsh-completions"
    )
    
    for plugin in "${plugins[@]}"; do
        local plugin_name=$(basename "$plugin")
        local plugin_dir="$SHARED_ZSH_DIR/$plugin_name"
        
        if [[ ! -d "$plugin_dir" ]]; then
            git clone "https://github.com/$plugin" "$plugin_dir" >> "$LOG_FILE" 2>&1
            log "$plugin_name installed"
        else
            cd "$plugin_dir" && git pull origin master >> "$LOG_FILE" 2>&1
            log "$plugin_name updated"
        fi
    done
    
    chmod -R 755 "$SHARED_ZSH_DIR"
    chown -R root:root "$SHARED_ZSH_DIR"
}

install_zsh_plugins

# Setup Zsh for user
setup_zsh_for_user() {
    local username=$1
    local user_home=$(eval echo ~$username)
    
    log "Setting up Zsh for: $username"
    
    # Create .zshrc
    cat > "$user_home/.zshrc" <<'ZSHRC'
# History configuration
HISTSIZE=50000
SAVEHIST=50000
HISTFILE=~/.zsh_history
setopt EXTENDED_HISTORY INC_APPEND_HISTORY SHARE_HISTORY
setopt HIST_IGNORE_DUPS HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE
setopt HIST_SAVE_NO_DUPS HIST_VERIFY APPEND_HISTORY

# Directory navigation
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT

# Load plugins
if [[ -f /opt/zsh-plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
    source /opt/zsh-plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
    ZSH_AUTOSUGGEST_STRATEGY=(history completion)
    ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
    ZSH_AUTOSUGGEST_USE_ASYNC=true
    bindkey '^ ' autosuggest-accept
    bindkey '^[^M' autosuggest-execute
fi

# Completions
fpath=(/opt/zsh-plugins/zsh-completions/src $fpath)
autoload -Uz compinit
compinit -C

# Completion options
setopt COMPLETE_IN_WORD ALWAYS_TO_END PATH_DIRS AUTO_MENU AUTO_LIST
setopt AUTO_PARAM_SLASH
unsetopt FLOW_CONTROL

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# Key bindings
bindkey '^[[A' up-line-or-history
bindkey '^[[B' down-line-or-history
bindkey '^[[3~' delete-char
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line

# Environment
export EDITOR='vim'
export VISUAL='vim'
export PAGER='less'

# Aliases
alias d='docker' dc='docker compose' dps='docker ps' dpsa='docker ps -a'
alias di='docker images' dcu='docker compose up -d' dcd='docker compose down'
alias dcl='docker compose logs -f' dex='docker exec -it' drm='docker rm'
alias drmi='docker rmi' dprune='docker system prune -af'

alias g='git' gs='git status' ga='git add' gaa='git add --all'
alias gc='git commit' gcm='git commit -m' gp='git pull' gP='git push'
alias gl='git log --oneline --graph --decorate' gd='git diff' gb='git branch'
alias gco='git checkout' gcb='git checkout -b'

alias ll='ls -alFh' la='ls -A' l='ls -CF' cls='clear' c='clear'
alias h='history' ..='cd ..' ...='cd ../..' ....='cd ../../..'

alias meminfo='free -h' cpuinfo='lscpu' diskinfo='df -h'
alias ports='netstat -tulanp' psa='ps aux' psg='ps aux | grep'

alias update='sudo apt update && sudo apt upgrade -y'
alias install='sudo apt install' remove='sudo apt remove'
alias search='apt search' autoremove='sudo apt autoremove -y'

# Safety aliases
alias rm='rm -i' cp='cp -i' mv='mv -i' mkdir='mkdir -pv'

# Functions
mkcd() { mkdir -p "$1" && cd "$1"; }

extract() {
    if [ -f $1 ] ; then
        case $1 in
            *.tar.bz2)   tar xjf $1     ;;
            *.tar.gz)    tar xzf $1     ;;
            *.bz2)       bunzip2 $1     ;;
            *.rar)       unrar e $1     ;;
            *.gz)        gunzip $1      ;;
            *.tar)       tar xf $1      ;;
            *.tbz2)      tar xjf $1     ;;
            *.tgz)       tar xzf $1     ;;
            *.zip)       unzip $1       ;;
            *.Z)         uncompress $1  ;;
            *.7z)        7z x $1        ;;
            *)           echo "'$1' cannot be extracted via extract()" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}

# Starship prompt
eval "$(starship init zsh)"

# Syntax highlighting (load last)
if [[ -f /opt/zsh-plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
    source /opt/zsh-plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
    ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern)
    typeset -A ZSH_HIGHLIGHT_STYLES
    ZSH_HIGHLIGHT_STYLES[command]='fg=green'
    ZSH_HIGHLIGHT_STYLES[alias]='fg=green'
    ZSH_HIGHLIGHT_STYLES[builtin]='fg=green'
    ZSH_HIGHLIGHT_STYLES[function]='fg=green'
    ZSH_HIGHLIGHT_STYLES[path]='fg=cyan'
    ZSH_HIGHLIGHT_STYLES[globbing]='fg=yellow'
else
    echo "Warning: zsh-syntax-highlighting not found"
fi
ZSHRC

    # Create Starship config
    mkdir -p "$user_home/.config"
    cat > "$user_home/.config/starship.toml" <<'STARSHIP'
command_timeout = 1000
add_newline = true

format = """$username$hostname$directory$git_branch$git_status$docker_context$line_break$character"""
right_format = """$cmd_duration $time"""

[username]
style_user = 'cyan bold'
style_root = 'red bold'
format = '[$user]($style) '
disabled = false
show_always = true

[hostname]
ssh_only = false
format = 'on [$hostname](bold yellow) '
disabled = false
trim_at = '.'

[directory]
truncation_length = 3
truncate_to_repo = true
style = 'blue bold'
format = 'in [$path]($style)[$read_only]($read_only_style) '

[character]
success_symbol = '[➜](bold green)'
error_symbol = '[✗](bold red)'

[git_branch]
symbol = '🌱 '
format = 'on [$symbol$branch]($style) '
style = 'purple bold'

[git_status]
format = '([\[$all_status$ahead_behind\]]($style) )'
style = 'red bold'
conflicted = '='
ahead = '⇡${count}'
behind = '⇣${count}'
diverged = '⇕${ahead_count}⇣${behind_count}'
untracked = '?${count}'
stashed = '\$${count}'
modified = '!${count}'
staged = '+${count}'
renamed = '»${count}'
deleted = 'x${count}'

[cmd_duration]
min_time = 500
format = 'took [$duration](bold yellow)'

[time]
disabled = false
format = '[$time](bold white)'
time_format = '%H:%M:%S'

[docker_context]
symbol = '🐳 '
format = 'via [$symbol $context]($style) '
style = 'blue bold'
only_with_files = true

[python]
symbol = '🐍 '
format = 'via [$symbol $version]($style) '
style = 'yellow bold'

[nodejs]
symbol = '⬢ '
format = 'via [$symbol $version]($style) '
style = 'green bold'

[golang]
symbol = '🐹 '
format = 'via [$symbol $version]($style) '
style = 'cyan bold'

[rust]
symbol = '🦀 '
format = 'via [$symbol $version]($style) '
style = 'red bold'

[java]
symbol = '☕ '
format = 'via [$symbol $version]($style) '
style = 'red bold'

[package]
disabled = true

[memory_usage]
disabled = true

[battery]
disabled = true
STARSHIP

    # Set permissions and ownership
    mkdir -p "$user_home/.zsh/cache"
    chown -R "$username:$username" "$user_home/.zshrc" "$user_home/.zsh" "$user_home/.config" 2>/dev/null || true
    chmod 644 "$user_home/.zshrc" "$user_home/.config/starship.toml" 2>/dev/null || true
    
    # Change shell
    chsh -s $(which zsh) "$username" >/dev/null 2>&1 || warn "Unable to change shell for $username"
}

# Setup for both users
setup_zsh_for_user $NEW_USER
setup_zsh_for_user root

# Verify installations
command -v zsh &> /dev/null || { error "Zsh installation failed!"; exit 1; }
command -v starship &> /dev/null || { error "Starship installation failed!"; exit 1; }

log "Zsh + Starship configured successfully!"

################################################################################
# 4. System Detection
################################################################################
step "Detecting system specifications..."

# CPU and RAM detection
CPU_ARCH=$(uname -m)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_RAM_KB/1024/1024}")

log "CPU: $CPU_ARCH, RAM: ${TOTAL_RAM_GB}GB"

# Calculate swap
if (( $(echo "$TOTAL_RAM_GB < 3" | bc -l) )); then
    SWAP_SIZE=$(awk "BEGIN {printf \"%.0f\", $TOTAL_RAM_GB * 2}")
    SWAPPINESS=60
else
    SWAP_SIZE=$(awk "BEGIN {printf \"%.0f\", $TOTAL_RAM_GB / 2}")
    SWAPPINESS=10
fi

log "Will create ${SWAP_SIZE}GB swap (swappiness=$SWAPPINESS)"

################################################################################
# 5. System Update and Essential Packages
################################################################################
step "Updating system and installing packages..."

# Install all essential packages at once
ESSENTIAL_PACKAGES="
    htop iotop sysstat net-tools ufw fail2ban unattended-upgrades
    apt-listchanges needrestart ncdu tree vim tmux zip unzip gnupg
    ca-certificates lsb-release language-pack-en bc
"

install_packages $ESSENTIAL_PACKAGES

################################################################################
# 6. XanMod Kernel Installation
################################################################################
step "Checking XanMod kernel compatibility..."

XANMOD_INSTALLED=false
if [[ "$CPU_ARCH" == "x86_64" ]]; then
    log "CPU compatible with XanMod"
    
    # Determine variant
    if grep -q 'avx2' /proc/cpuinfo; then
        XANMOD_VARIANT="x64v3"
    elif grep -q 'sse4_2' /proc/cpuinfo; then
        XANMOD_VARIANT="x64v2"
    else
        XANMOD_VARIANT="x64v1"
    fi
    
    log "Using XanMod variant: $XANMOD_VARIANT"
    
    # Install XanMod
    {
        wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
        echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-release.list
        apt-get update
        apt-get install -y linux-xanmod-$XANMOD_VARIANT
    } >> "$LOG_FILE" 2>&1
    
    XANMOD_INSTALLED=true
    log "XanMod kernel installed"
else
    warn "CPU architecture ($CPU_ARCH) not compatible with XanMod"
fi

################################################################################
# 7. Docker Installation
################################################################################
step "Installing Docker..."

# Remove old versions and install Docker
{
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        apt-get remove -y $pkg 2>/dev/null || true
    done
    
    # Add Docker repository
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update
    install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    systemctl enable docker
    systemctl start docker
} >> "$LOG_FILE" 2>&1

# Add user to docker group
usermod -aG docker "$NEW_USER"
log "User $NEW_USER added to docker group"

# Configure Docker daemon
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "storage-driver": "overlay2",
  "default-address-pools": [{"base": "172.17.0.0/12", "size": 24}]
}
EOF

systemctl restart docker
log "Docker configured and started"

################################################################################
# 8. System Optimization
################################################################################
step "Optimizing system parameters..."

# Kernel parameters
cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%F) 2>/dev/null || true

cat > /etc/sysctl.d/99-vps-optimization.conf <<EOF
# VPS Optimization

# Network Performance
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8096
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535

# TCP BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Connection Tracking
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

# File System
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# Memory
vm.swappiness = $SWAPPINESS
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 65536

# Security
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Kernel Performance
kernel.panic = 10
kernel.panic_on_oops = 1
EOF

sysctl -p /etc/sysctl.d/99-vps-optimization.conf >/dev/null

# System limits
cat > /etc/security/limits.d/99-vps-limits.conf <<EOF
# VPS Limits Optimization
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
root soft nofile 65535
root hard nofile 65535
root soft nproc 65535
root hard nproc 65535
EOF

################################################################################
# 9. Swap Configuration
################################################################################
step "Setting up swap file..."

# Remove existing swap
if swapon --show | grep -q "/swapfile"; then
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab
fi

# Create new swap
log "Creating ${SWAP_SIZE}GB swap file..."
fallocate -l ${SWAP_SIZE}G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# Add to fstab
if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "Swap configured: ${SWAP_SIZE}GB (swappiness=$SWAPPINESS)"

################################################################################
# 10. Security Configuration
################################################################################
step "Configuring security..."

# Firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' || echo "22")
ufw allow $SSH_PORT/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

# Fail2Ban
systemctl enable fail2ban
systemctl start fail2ban

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
sendername = Fail2Ban

[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
EOF

systemctl restart fail2ban

# SSH Hardening
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%F) 2>/dev/null || true

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
# SSH Hardening
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 10
AllowTcpForwarding yes
AllowUsers $NEW_USER
EOF

if sshd -t; then
    systemctl restart sshd
    log "SSH configuration updated"
else
    error "SSH configuration test failed!"
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    exit 1
fi

# Automatic updates
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Journal size limit
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/00-journal-size.conf <<EOF
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=100M
RuntimeMaxUse=100M
EOF

systemctl restart systemd-journald

log "Security configuration completed"

################################################################################
# 11. Additional Optimizations
################################################################################
step "Applying additional optimizations..."

# tmpfs optimization
if ! grep -q "tmpfs /tmp" /etc/fstab; then
    cat >> /etc/fstab <<EOF
tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,noexec,mode=1777,size=1G 0 0
tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,noexec,mode=1777,size=512M 0 0
EOF
fi

# Disable unnecessary services
for service in bluetooth.service cups.service avahi-daemon.service; do
    if systemctl is-enabled "$service" 2>/dev/null; then
        systemctl disable "$service"
        systemctl stop "$service"
        log "Disabled $service"
    fi
done

# I/O scheduler optimization
cat > /etc/udev/rules.d/60-ioschedulers.conf <<EOF
# I/O Scheduler Optimization
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
EOF

################################################################################
# 12. Utility Scripts
################################################################################
step "Creating utility scripts..."

# Monitor script
cat > /usr/local/bin/vps-monitor.sh <<'SCRIPT'
#!/bin/bash
echo "=== VPS System Monitor ==="
echo "=== CPU Usage ==="
top -bn1 | head -n 5
echo -e "\n=== Memory Usage ==="
free -h
echo -e "\n=== Disk Usage ==="
df -h | grep -v tmpfs
echo -e "\n=== Network Connections ==="
ss -s
echo -e "\n=== Load Average ==="
uptime
echo -e "\n=== Top 5 Processes by Memory ==="
ps aux --sort=-%mem | head -6
echo -e "\n=== Top 5 Processes by CPU ==="
ps aux --sort=-%cpu | head -6
echo -e "\n=== Swap Usage ==="
swapon --show
SCRIPT

# Cleanup script
cat > /usr/local/bin/vps-cleanup.sh <<'SCRIPT'
#!/bin/bash
echo "Starting VPS cleanup..."
apt-get clean
apt-get autoclean
apt-get autoremove -y
journalctl --vacuum-time=7d
dpkg -l 'linux-*' | sed '/^ii/!d;/'"$(uname -r | sed "s/\(.*\)-\([^0-9]\+\)/\1/")"'/d;s/^[^ ]* [^ ]* \([^ ]*\).*/\1/;/[0-9]/!d' | head -n -1 | xargs apt-get -y purge 2>/dev/null || true
find /tmp -type f -atime +7 -delete 2>/dev/null || true
find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
rm -rf ~/.cache/thumbnails/* 2>/dev/null || true
echo "Cleanup completed!"
SCRIPT

# Info script
cat > /usr/local/bin/vps-info.sh <<'SCRIPT'
#!/bin/bash
echo "=== VPS System Information ==="
echo "Hostname: $(hostname)"
echo "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p | sed 's/up //')"
echo "CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs || echo "Unknown")"
echo "CPU Cores: $(nproc)"
echo "Architecture: $(uname -m)"
echo "Total RAM: $(free -h | awk '/^Mem:/ {print $2}')"
echo "Used RAM: $(free -h | awk '/^Mem:/ {print $3}') ($(free | awk '/^Mem:/ {printf "%.1f", $3/$2 * 100.0}')%)"
echo "Free RAM: $(free -h | awk '/^Mem:/ {print $4}')"

TOTAL_SWAP=$(free -h | awk '/^Swap:/ {print $2}')
if [[ "$TOTAL_SWAP" != "0B" ]]; then
    echo "Total Swap: $TOTAL_SWAP"
    echo "Used Swap: $(free -h | awk '/^Swap:/ {print $3}') ($(free | awk '/^Swap:/ {if($2>0) printf "%.1f", $3/$2 * 100.0; else print "0"}')%)"
else
    echo "Swap: Disabled"
fi

echo "Disk Usage:"
df -h | grep -E '^/dev/' | while read filesystem size used avail use_percent mount; do
    echo "  $filesystem: $used/$size ($use_percent) mounted on $mount"
done

echo "Public IP: $(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "Unable to detect")"
echo "TCP Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "Swappiness: $(sysctl -n vm.swappiness)"
echo "Load Average: $(uptime | awk -F'load average:' '{print $2}' | xargs)"

if command -v docker &> /dev/null; then
    echo "Docker Version: $(docker --version 2>/dev/null | sed 's/Docker version //' | sed 's/, build.*//')"
    echo "Docker Compose: $(docker compose version 2>/dev/null | sed 's/Docker Compose version //' | sed 's/, build.*//')"
    echo "Docker Status: $(systemctl is-active docker 2>/dev/null)"
    echo "Running Containers: $(docker ps -q 2>/dev/null | wc -l)"
fi

echo -e "\nTop 5 Processes by CPU:"
ps aux --sort=-%cpu | head -6 | tail -5 | awk '{printf "  %-8s %5s%% %s\n", $1, $3, $11}'

echo -e "\nTop 5 Processes by Memory:"
ps aux --sort=-%mem | head -6 | tail -5 | awk '{printf "  %-8s %5s%% %s\n", $1, $4, $11}'
SCRIPT

# Network test script
cat > /usr/local/bin/network-test.sh <<'SCRIPT'
#!/bin/bash
echo "=== Network Performance Test ==="
if ! command -v speedtest-cli &> /dev/null; then
    echo "Installing speedtest-cli..."
    apt-get install -y speedtest-cli >/dev/null 2>&1
fi
speedtest-cli
echo -e "\n=== Network Statistics ==="
netstat -s | head -20
SCRIPT

# Make scripts executable
chmod +x /usr/local/bin/vps-{monitor,cleanup,info}.sh /usr/local/bin/network-test.sh

# Weekly cleanup cron job
cat > /etc/cron.weekly/vps-cleanup <<'EOF'
#!/bin/bash
/usr/local/bin/vps-cleanup.sh >> /var/log/vps-cleanup.log 2>&1
EOF
chmod +x /etc/cron.weekly/vps-cleanup

log "Utility scripts created"

################################################################################
# 13. Final Summary and Reboot
################################################################################
step "Final summary..."

log "=== VPS Optimization Complete ==="
log "System Configuration:"
log "  ✓ Swap: ${SWAP_SIZE}GB (swappiness=$SWAPPINESS)"
log "  ✓ Firewall: UFW enabled (SSH, HTTP, HTTPS)"
log "  ✓ Security: Fail2Ban + SSH hardening"
log "  ✓ System limits increased"
log "  ✓ Automatic security updates enabled"
log "  ✓ Journal logs limited to 500MB"
log "  ✓ Unnecessary services disabled"
[[ "$XANMOD_INSTALLED" == true ]] && log "  ✓ XanMod kernel installed"

log "Created utility scripts:"
log "  • vps-monitor.sh   - System monitoring"
log "  • vps-cleanup.sh   - System cleanup (runs weekly)"
log "  • vps-info.sh      - System information"
log "  • network-test.sh  - Network performance test"

log "Security Configuration:"
log "  • Root login: DISABLED"
log "  • Password authentication: DISABLED"
log "  • SSH key authentication: ENABLED ($NEW_USER only)"
log "  • Passwordless sudo: ENABLED ($NEW_USER + root)"
log "  • SSH port: $SSH_PORT"

warn "CRITICAL: Before disconnecting, verify SSH access:"
warn "  1. Open a new terminal (don't close this one!)"
warn "  2. Test login: ssh $NEW_USER@$(hostname -I | awk '{print $1}')"
warn "  3. Test sudo: sudo -l (should work without password)"
warn "  4. Only disconnect after successful test!"

echo -e "\n${BLUE}=== System Information ===${RESET}"
/usr/local/bin/vps-info.sh

warn "A system reboot is REQUIRED to activate all changes"
[[ "$XANMOD_INSTALLED" == true ]] && warn "Especially to boot into the new XanMod kernel"
warn "IMPORTANT: Docker group membership will be active after reboot!"
warn "After reboot, login as $NEW_USER and test: docker ps"

read -p "Do you want to reboot now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Rebooting system in 5 seconds... Press Ctrl+C to cancel"
    sleep 5
    reboot
else
    log "Reboot skipped. Please reboot manually when ready with: sudo reboot"
    [[ "$XANMOD_INSTALLED" == true ]] && warn "After reboot, check for 'xanmod' in kernel version: uname -r"
fi

log "=== VPS Optimization Script Finished ==="
