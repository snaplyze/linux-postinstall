#!/bin/bash

################################################################################
# VPS Optimization Script for Debian 13 (Trixie)
# Purpose: Complete VPS optimization with XanMod kernel support
# Features: Auto RAM detection, XanMod kernel, user creation, SSH hardening
# Author: Auto-generated
# Date: 2025-11-11
# Fixed: Removed duplicates, cleaned up code structure
################################################################################

set -e

# Colors for output
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

# Default variables (can be overridden by environment)
NEW_USER=${NEW_USER:-snaplyze}
TIMEZONE=${TIMEZONE:-Europe/Berlin}
LOCALE_TO_GENERATE=${LOCALE_TO_GENERATE:-"en_US.UTF-8"}
DEFAULT_LOCALE=${DEFAULT_LOCALE:-"en_US.UTF-8"}
QUIET_MODE=${QUIET_MODE:-true}

# Logging functions with quiet mode support
log() { 
    [[ "$QUIET_MODE" == "false" ]] && echo -e "${GREEN}[INFO]${RESET} $*"
}

info() { 
    [[ "$QUIET_MODE" == "false" ]] && echo -e "${BLUE}[INFO]${RESET} $*"
}

warn() { 
    echo -e "${YELLOW}[WARN]${RESET} $*" 
}

error() { 
    echo -e "${RED}[ERROR]${RESET} $*" 
}

# Helper to ensure running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

require_root

# Show help
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo -e "${GREEN}VPS Optimization Script for Debian 13 (Trixie)${RESET}"
    echo ""
    echo -e "${CYAN}Usage:${RESET}"
    echo -e "  $0 [OPTIONS]"
    echo ""
    echo -e "${CYAN}Options:${RESET}"
    echo -e "  ${GREEN}-v, --verbose${RESET}   Show detailed output (default is quiet)"
    echo -e "  ${GREEN}-q, --quiet${RESET}     Run in quiet mode (minimal output)"
    echo -e "  ${GREEN}-h, --help${RESET}      Show this help message"
    echo ""
    echo -e "${CYAN}Remote Execution:${RESET}"
    echo -e "  bash <(curl -s https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/optimize_vps.sh)"
    echo ""
    echo -e "${CYAN}Examples:${RESET}"
    echo -e "  sudo $0              # Interactive mode"
    echo -e "  sudo $0 --verbose    # Detailed output mode"
    echo -e "  sudo $0 --quiet      # Minimal output mode"
    exit 0
fi

# Auto-detect remote execution (curl/bash) and force quiet mode
if [[ "$0" == "/dev/fd/63" || "$0" == "/proc/self/fd/11" || "$0" == "/dev/stdin" ]]; then
    QUIET_MODE=true
    export REMOTE_EXECUTION=true
fi

# Check for verbose mode (overrides default quiet)
if [[ "$1" == "--verbose" || "$1" == "-v" ]]; then
    QUIET_MODE=false
    shift
fi

# Check for explicit quiet mode
if [[ "$1" == "--quiet" || "$1" == "-q" ]]; then
    QUIET_MODE=true
    shift
fi

log "=== Starting VPS Optimization ==="

################################################################################
# 0. Detect OS Version
################################################################################
log "Step 0: Detecting operating system..."

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$NAME
    OS_VERSION=$VERSION_ID
    OS_CODENAME=$VERSION_CODENAME
    log "Detected OS: $OS_NAME $OS_VERSION ($OS_CODENAME)"
else
    error "Cannot detect OS version. /etc/os-release not found."
    exit 1
fi

# Check if Debian-based
if [[ ! "$ID" =~ ^(debian|ubuntu)$ ]]; then
    error "This script is designed for Debian/Ubuntu only. Detected: $ID"
    exit 1
fi

# Validate Debian version (support Debian 11, 12, 13 and Ubuntu 20.04+)
case "$ID" in
    debian)
        if [[ ! "$VERSION_ID" =~ ^(11|12|13)$ ]]; then
            warn "This script is optimized for Debian 11-13. Detected: Debian $VERSION_ID"
            warn "Continuing anyway, but some features may not work correctly."
        fi
        ;;
    ubuntu)
        if (( $(echo "$VERSION_ID < 20.04" | bc -l) )); then
            warn "This script is optimized for Ubuntu 20.04+. Detected: Ubuntu $VERSION_ID"
            warn "Continuing anyway, but some features may not work correctly."
        fi
        ;;
esac

################################################################################
# 1. User Creation and SSH Key Setup
################################################################################
log "Step 1: User account setup..."

if [[ "$QUIET_MODE" == "false" ]]; then
    echo ""
    info "We need to create a new sudo user for secure access."
    info "Root login will be disabled after setup."
    echo ""
fi

if [[ -n "$NEW_USER" && "$NEW_USER" != "snaplyze" ]]; then
    log "Using predefined username: $NEW_USER"
else
    read -p "Enter new username [snaplyze]: " NEW_USER_INPUT
    NEW_USER=${NEW_USER_INPUT:-snaplyze}
    [[ "$QUIET_MODE" == "false" ]] && log "Using username: $NEW_USER"
fi

if [ -z "$NEW_USER" ]; then
    error "Username cannot be empty!"
    exit 1
fi

# Check if user already exists
if id "$NEW_USER" &>/dev/null; then
    warn "User $NEW_USER already exists. Skipping user creation..."
else
    adduser --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    log "User $NEW_USER created and added to sudo group"
fi

# Store user for later use (adding to docker group)
DOCKER_USER=$NEW_USER

# Configure passwordless sudo for the new user
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$NEW_USER
chmod 440 /etc/sudoers.d/$NEW_USER
log "Passwordless sudo configured for $NEW_USER"

# Configure passwordless sudo for root
if ! grep -q "^root.*NOPASSWD:ALL" /etc/sudoers.d/root 2>/dev/null; then
    echo "root ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/root
    chmod 440 /etc/sudoers.d/root
    log "Passwordless sudo configured for root"
fi

# Setup SSH keys
USER_HOME=$(eval echo ~$NEW_USER)
mkdir -p "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"

if [[ -z "$SSH_PUBLIC_KEY" ]]; then
    echo ""
    info "Please paste your SSH public key (the content of your id_rsa.pub or id_ed25519.pub):"
    info "If you don't have one, generate it on your local machine with: ssh-keygen -t ed25519"
    echo ""
    read -p "SSH Public Key: " SSH_PUBLIC_KEY
fi

if [ -z "$SSH_PUBLIC_KEY" ]; then
    error "SSH public key cannot be empty!"
    exit 1
fi

echo "$SSH_PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R $NEW_USER:$NEW_USER "$USER_HOME/.ssh"
log "SSH key configured for $NEW_USER"

echo ""
warn "IMPORTANT: Please test SSH login with the new user in another terminal!"
warn "Command: ssh $NEW_USER@$(hostname -I | awk '{print $1}')"
echo ""
read -p "Press Enter once you've verified SSH access works..."

################################################################################
# 1.5. System Localization Settings
################################################################################
log "Step 1.5: Configuring system localization..."

if [[ "$QUIET_MODE" == "false" ]]; then
    echo ""
    info "Setting up system locale, hostname, and timezone..."
    echo ""

    # Locale selection
    echo "Select system locale:"
    echo "1) en_US.UTF-8 (English)"
    echo "2) ru_RU.UTF-8 (Russian)"
    echo "3) Both (en_US.UTF-8 + ru_RU.UTF-8)"
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
            warn "Invalid choice. Using English (en_US.UTF-8) as default"
            LOCALE_TO_GENERATE="en_US.UTF-8"
            DEFAULT_LOCALE="en_US.UTF-8"
            ;;
    esac
fi

# Ensure locales package is installed
if ! dpkg -s locales >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y locales
fi

log "Generating locales..."
for locale in $LOCALE_TO_GENERATE; do
    if ! grep -q -E "^${locale}[[:space:]]+UTF-8" /etc/locale.gen 2>/dev/null; then
        echo "${locale} UTF-8" >> /etc/locale.gen
    else
        sed -i "s/^#\s*\(${locale} UTF-8\)/\1/" /etc/locale.gen || true
    fi
done

locale-gen

# Fallback: try localedef if locale not present
for wanted in $LOCALE_TO_GENERATE; do
    if ! locale -a | grep -qi "^${wanted}$"; then
        base="${wanted%%.*}"
        log "Locale $wanted not found, trying localedef..."
        localedef -i "$base" -f UTF-8 "$wanted" 2>/dev/null || warn "localedef for $wanted failed"
    fi
done

update-locale LANG=$DEFAULT_LOCALE LC_ALL=$DEFAULT_LOCALE
export LANG=$DEFAULT_LOCALE
export LC_ALL=$DEFAULT_LOCALE
log "Default locale set to: $DEFAULT_LOCALE"

# Hostname configuration
if [[ "$QUIET_MODE" == "false" ]]; then
    echo ""
    read -p "Enter new hostname (press Enter to keep current: $(hostname)): " NEW_HOSTNAME

    if [ -n "$NEW_HOSTNAME" ]; then
        if [[ $NEW_HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
            hostnamectl set-hostname "$NEW_HOSTNAME"
            sed -i "s/127.0.1.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
            if ! grep -q "127.0.1.1" /etc/hosts; then
                echo "127.0.1.1	${NEW_HOSTNAME}" >> /etc/hosts
            fi
            log "Hostname changed to: $NEW_HOSTNAME"
        else
            warn "Invalid hostname format. Keeping current hostname: $(hostname)"
        fi
    else
        log "Keeping current hostname: $(hostname)"
    fi
fi

# Timezone configuration
if [[ "$QUIET_MODE" == "false" ]]; then
    echo ""
    info "Current timezone: $(timedatectl show --property=Timezone --value)"
    info "Examples: Europe/Moscow, America/New_York, Asia/Tokyo, UTC"
    echo ""
    read -p "Enter timezone (press Enter to keep current): " NEW_TIMEZONE

    if [ -n "$NEW_TIMEZONE" ]; then
        if timedatectl list-timezones | grep -q "^${NEW_TIMEZONE}$"; then
            timedatectl set-timezone "$NEW_TIMEZONE"
            log "Timezone set to: $NEW_TIMEZONE"
        else
            warn "Invalid timezone. Keeping current timezone."
        fi
    else
        log "Keeping current timezone: $(timedatectl show --property=Timezone --value)"
    fi
fi

timedatectl set-ntp true
log "NTP synchronization enabled"

################################################################################
# 1.7. Zsh and Starship Installation
################################################################################
log "Step 1.7: Installing and configuring Zsh + Starship..."

[[ "$QUIET_MODE" == "false" ]] && info "Installing Zsh and Starship for better shell experience..."

apt-get install -y zsh git curl locales

# Install Starship prompt
curl -sS https://starship.rs/install.sh | sh -s -- -y
log "Starship prompt installed"

# Function to setup Zsh for a user
setup_zsh_for_user() {
    local username=$1
    local user_home=$(eval echo ~$username)

    log "Setting up Zsh for user: $username"

    mkdir -p "$user_home/.zsh"

    # Install zsh-autosuggestions
    if [ ! -d "$user_home/.zsh/zsh-autosuggestions" ]; then
        git clone https://github.com/zsh-users/zsh-autosuggestions "$user_home/.zsh/zsh-autosuggestions"
    else
        cd "$user_home/.zsh/zsh-autosuggestions" && git pull origin master
    fi

    # Install zsh-syntax-highlighting
    if [ ! -d "$user_home/.zsh/zsh-syntax-highlighting" ]; then
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$user_home/.zsh/zsh-syntax-highlighting"
    else
        cd "$user_home/.zsh/zsh-syntax-highlighting" && git pull master
    fi

    # Install zsh-completions
    if [ ! -d "$user_home/.zsh/zsh-completions" ]; then
        git clone https://github.com/zsh-users/zsh-completions "$user_home/.zsh/zsh-completions"
    else
        cd "$user_home/.zsh/zsh-completions" && git pull master
    fi

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

# Load zsh-autosuggestions FIRST
if [[ -f ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
    source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
    ZSH_AUTOSUGGEST_STRATEGY=(history completion)
    ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
    ZSH_AUTOSUGGEST_USE_ASYNC=true
    bindkey '^ ' autosuggest-accept
    bindkey '^[^M' autosuggest-execute
fi

# Completion settings
fpath=(~/.zsh/zsh-completions/src $fpath)
autoload -Uz compinit
if [[ -n ${ZDOTDIR}/.zcompdump(#qN.mh+24) ]]; then
    compinit
else
    compinit -C
fi

setopt COMPLETE_IN_WORD ALWAYS_TO_END PATH_DIRS AUTO_MENU AUTO_LIST AUTO_PARAM_SLASH
unsetopt FLOW_CONTROL

zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#) ([0-9a-z-]#)*=01;34=0=01'
zstyle ':completion:*:*:*:*:processes' command "ps -u $USER -o pid,user,comm -w -w"
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ~/.zsh/cache

# Bash compatibility
setopt BASH_REMATCH KSH_ARRAYS
autoload -Uz bashcompinit && bashcompinit

# Key bindings
bindkey '^[[A' up-line-or-history
bindkey '^[[B' down-line-or-history
bindkey '^[[3~' delete-char
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line

# Environment variables
export EDITOR='vim'
export VISUAL='vim'
export PAGER='less'

# Docker aliases
alias d='docker'
alias dc='docker compose'
alias dps='docker ps'
alias dpsa='docker ps -a'
alias di='docker images'
alias dcu='docker compose up -d'
alias dcd='docker compose down'
alias dcl='docker compose logs -f'
alias dex='docker exec -it'
alias drm='docker rm'
alias drmi='docker rmi'
alias dprune='docker system prune -af'

# Git aliases
alias g='git'
alias gs='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gp='git pull'
alias gP='git push'
alias gl='git log --oneline --graph --decorate'
alias gd='git diff'
alias gb='git branch'
alias gco='git checkout'

# System aliases
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias cls='clear'
alias c='clear'
alias ..='cd ..'
alias ...='cd ../..'

# System monitoring
alias meminfo='free -h'
alias cpuinfo='lscpu'
alias diskinfo='df -h'
alias ports='netstat -tulanp'

# Package management
alias update='sudo apt update && sudo apt upgrade -y'
alias install='sudo apt install'
alias autoremove='sudo apt autoremove -y'

# Safety aliases
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias mkdir='mkdir -pv'

# Useful functions
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
            *)           echo "'$1' cannot be extracted" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}

# Initialize Starship prompt
eval "$(starship init zsh)"

# Load zsh-syntax-highlighting LAST
if [[ -f ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
    source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
    ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern)
fi
ZSHRC

    # Create Starship config
    mkdir -p "$user_home/.config"
    cat > "$user_home/.config/starship.toml" <<'STARSHIP'
command_timeout = 1000
add_newline = true

format = """
$username\
$hostname\
$directory\
$git_branch\
$git_status\
$docker_context\
$line_break\
$character"""

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
STARSHIP

    mkdir -p "$user_home/.zsh/cache"
    chown -R "$username:$username" "$user_home/.zsh" "$user_home/.zshrc" "$user_home/.config" 2>/dev/null || true
    chmod 644 "$user_home/.zshrc" "$user_home/.config/starship.toml" 2>/dev/null || true
    
    chsh -s $(which zsh) "$username" >/dev/null 2>&1 || warn "Unable to change shell for $username"
}

setup_zsh_for_user root
setup_zsh_for_user $NEW_USER

if ! command -v zsh &> /dev/null || ! command -v starship &> /dev/null; then
    error "Zsh or Starship installation failed!"
    exit 1
fi

log "Zsh + Starship configured successfully"

################################################################################
# 2. Detect CPU Architecture and RAM
################################################################################
log "Step 2: Detecting system specifications..."

CPU_ARCH=$(uname -m)
log "CPU Architecture: $CPU_ARCH"

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_RAM_KB/1024/1024}")
log "Total RAM: ${TOTAL_RAM_GB}GB"

# Calculate swap size based on RAM
if (( $(echo "$TOTAL_RAM_GB < 3" | bc -l) )); then
    SWAP_SIZE=$(awk "BEGIN {printf \"%.0f\", $TOTAL_RAM_GB * 2}")
    SWAPPINESS=60
else
    SWAP_SIZE=$(awk "BEGIN {printf \"%.0f\", $TOTAL_RAM_GB / 2}")
    SWAPPINESS=10
fi

################################################################################
# 3. System Update and Essential Packages
################################################################################
log "Step 3: Updating system and installing essential packages..."

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
apt-get install -y \
    curl wget git htop iotop sysstat net-tools ufw fail2ban \
    unattended-upgrades apt-listchanges needrestart ncdu tree \
    vim tmux zip unzip bc gnupg ca-certificates lsb-release

################################################################################
# 4. XanMod Kernel Installation
################################################################################
log "Step 4: Checking XanMod kernel compatibility..."

if [[ "$CPU_ARCH" == "x86_64" ]]; then
    log "CPU architecture is compatible with XanMod kernel"

    if grep -q 'avx2' /proc/cpuinfo; then
        XANMOD_VARIANT="x64v3"
    elif grep -q 'sse4_2' /proc/cpuinfo; then
        XANMOD_VARIANT="x64v2"
    else
        XANMOD_VARIANT="x64v1"
    fi
    
    log "Using XanMod $XANMOD_VARIANT variant"

    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-release.list
    apt-get update
    apt-get install -y linux-xanmod-$XANMOD_VARIANT

    log "XanMod kernel installed successfully"
    XANMOD_INSTALLED=true
else
    warn "CPU architecture ($CPU_ARCH) not compatible with XanMod. Skipping..."
    XANMOD_INSTALLED=false
fi

################################################################################
# 5. Docker and Docker Compose Installation
################################################################################
log "Step 5: Installing Docker and Docker Compose..."

for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y $pkg 2>/dev/null || true
done

apt-get install -y ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

usermod -aG docker "$DOCKER_USER"
log "User $DOCKER_USER added to docker group"

cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "default-address-pools": [
    {"base": "172.17.0.0/12", "size": 24}
  ]
}
EOF

systemctl restart docker
log "Docker and Docker Compose installed"

################################################################################
# 6. Kernel Parameters Optimization
################################################################################
log "Step 6: Optimizing kernel parameters..."

cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%F) 2>/dev/null || true

cat > /etc/sysctl.d/99-vps-optimization.conf <<EOF
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

# Virtual Memory
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

# Kernel
kernel.panic = 10
kernel.panic_on_oops = 1
EOF

sysctl -p /etc/sysctl.d/99-vps-optimization.conf

################################################################################
# 7. Swap Optimization
################################################################################
log "Step 7: Setting up swap file..."

if swapon --show | grep -q "/swapfile"; then
    swapoff /swapfile
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab
fi

log "Creating ${SWAP_SIZE}GB swap file..."
fallocate -l ${SWAP_SIZE}G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "Swap configured: ${SWAP_SIZE}GB (swappiness=$SWAPPINESS)"

################################################################################
# 8. Firewall Configuration (UFW)
################################################################################
log "Step 8: Configuring firewall..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}')
SSH_PORT=${SSH_PORT:-22}

ufw allow $SSH_PORT/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

log "Firewall configured"

################################################################################
# 9. Fail2Ban Configuration
################################################################################
log "Step 9: Configuring Fail2Ban..."

systemctl enable fail2ban
systemctl start fail2ban

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
EOF

systemctl restart fail2ban

################################################################################
# 10. System Limits Optimization
################################################################################
log "Step 10: Optimizing system limits..."

cat > /etc/security/limits.d/99-vps-limits.conf <<EOF
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
# 11. Automatic Security Updates
################################################################################
log "Step 11: Configuring automatic security updates..."

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

################################################################################
# 12. Journal Log Size Limit
################################################################################
log "Step 12: Limiting systemd journal size..."

mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/00-journal-size.conf <<EOF
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=100M
RuntimeMaxUse=100M
EOF

systemctl restart systemd-journald

################################################################################
# 13. SSH Hardening
################################################################################
log "Step 13: Hardening SSH configuration..."

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%F) 2>/dev/null || true

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
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
    log "SSH hardened successfully"
else
    error "SSH configuration invalid! Reverting..."
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    exit 1
fi

################################################################################
# 14. Optimize tmpfs
################################################################################
log "Step 14: Optimizing tmpfs..."

if ! grep -q "tmpfs /tmp" /etc/fstab; then
    cat >> /etc/fstab <<EOF
tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,noexec,mode=1777,size=1G 0 0
tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,noexec,mode=1777,size=512M 0 0
EOF
fi

################################################################################
# 15. Disable Unnecessary Services
################################################################################
log "Step 15: Disabling unnecessary services..."

for service in bluetooth.service cups.service avahi-daemon.service; do
    if systemctl is-enabled "$service" 2>/dev/null; then
        systemctl disable "$service"
        systemctl stop "$service"
        log "Disabled $service"
    fi
done

################################################################################
# 16. I/O Scheduler Optimization
################################################################################
log "Step 16: Optimizing I/O scheduler..."

cat > /etc/udev/rules.d/60-ioschedulers.conf <<EOF
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
EOF

################################################################################
# 17. Create Monitoring Script
################################################################################
log "Step 17: Creating utility scripts..."

cat > /usr/local/bin/vps-monitor.sh <<'SCRIPT'
#!/bin/bash
echo "=== VPS System Monitor ==="
echo ""
echo "=== CPU Usage ==="
top -bn1 | head -n 5
echo ""
echo "=== Memory Usage ==="
free -h
echo ""
echo "=== Disk Usage ==="
df -h | grep -v tmpfs
echo ""
echo "=== Network Connections ==="
ss -s
echo ""
echo "=== Load Average ==="
uptime
echo ""
echo "=== Top 5 Processes by Memory ==="
ps aux --sort=-%mem | head -6
echo ""
echo "=== Top 5 Processes by CPU ==="
ps aux --sort=-%cpu | head -6
SCRIPT

chmod +x /usr/local/bin/vps-monitor.sh

################################################################################
# 18. Create Cleanup Script
################################################################################

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
echo "Cleanup completed!"
SCRIPT

chmod +x /usr/local/bin/vps-cleanup.sh

cat > /etc/cron.weekly/vps-cleanup <<'EOF'
#!/bin/bash
/usr/local/bin/vps-cleanup.sh >> /var/log/vps-cleanup.log 2>&1
EOF

chmod +x /etc/cron.weekly/vps-cleanup

################################################################################
# 19. Network Performance Test Script
################################################################################

cat > /usr/local/bin/network-test.sh <<'SCRIPT'
#!/bin/bash
echo "=== Network Performance Test ==="
echo ""
if ! command -v speedtest-cli &> /dev/null; then
    echo "Installing speedtest-cli..."
    apt-get install -y speedtest-cli
fi
speedtest-cli
echo ""
echo "=== Network Statistics ==="
netstat -s | head -20
SCRIPT

chmod +x /usr/local/bin/network-test.sh

################################################################################
# 20. System Information Script
################################################################################

cat > /usr/local/bin/vps-info.sh <<'SCRIPT'
#!/bin/bash
echo "=== VPS System Information ==="
echo ""
echo "Hostname: $(hostname)"
echo "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p | sed 's/up //')"
echo ""
echo "CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs || echo "Unknown")"
echo "CPU Cores: $(nproc)"
echo "Architecture: $(uname -m)"
echo ""
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
echo ""

echo "Disk Usage:"
df -h | grep -E '^/dev/' | while read filesystem size used avail use_percent mount; do
    echo "  $filesystem: $used/$size ($use_percent) mounted on $mount"
done
echo ""

echo "Public IP: $(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "Unable to detect")"
echo "TCP Congestion: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "Swappiness: $(sysctl -n vm.swappiness)"
echo "Load Average: $(uptime | awk -F'load average:' '{print $2}' | xargs)"
echo ""

if command -v docker &> /dev/null; then
    echo "Docker: $(docker --version 2>/dev/null | sed 's/Docker version //' | sed 's/, build.*//')"
    echo "Docker Compose: $(docker compose version 2>/dev/null | sed 's/Docker Compose version //')"
    echo "Docker Status: $(systemctl is-active docker 2>/dev/null)"
    echo "Running Containers: $(docker ps -q 2>/dev/null | wc -l)"
    echo ""
fi

echo "Top 5 Processes by CPU:"
ps aux --sort=-%cpu | head -6 | tail -5 | awk '{printf "  %-8s %5s%% %s\n", $1, $3, $11}'
echo ""
echo "Top 5 Processes by Memory:"
ps aux --sort=-%mem | head -6 | tail -5 | awk '{printf "  %-8s %5s%% %s\n", $1, $4, $11}'
SCRIPT

chmod +x /usr/local/bin/vps-info.sh

################################################################################
# Final Summary
################################################################################
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}           ✅ VPS OPTIMIZATION COMPLETE${RESET}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "${GREEN}📋 SYSTEM CONFIGURATION${RESET}"
echo -e "   ${CYAN}•${RESET} OS: $OS_NAME $OS_VERSION ($OS_CODENAME)"
echo -e "   ${CYAN}•${RESET} Locale: $DEFAULT_LOCALE"
echo -e "   ${CYAN}•${RESET} Hostname: $(hostname)"
echo -e "   ${CYAN}•${RESET} Timezone: $(timedatectl show --property=Timezone --value)"
echo ""
echo -e "${GREEN}👤 USER & SHELL${RESET}"
echo -e "   ${CYAN}•${RESET} User created: $NEW_USER (sudo + docker)"
echo -e "   ${CYAN}•${RESET} Zsh + Starship installed"
echo -e "   ${CYAN}•${RESET} Plugins: autosuggestions, syntax-highlighting, completions"
echo -e "   ${CYAN}•${RESET} Passwordless sudo: enabled"
echo ""
echo -e "${GREEN}🔧 SYSTEM OPTIMIZATIONS${RESET}"
echo -e "   ${CYAN}•${RESET} Kernel: BBR congestion control"
if [ "$XANMOD_INSTALLED" = true ]; then
    echo -e "   ${CYAN}•${RESET} XanMod kernel: $XANMOD_VARIANT"
fi
echo -e "   ${CYAN}•${RESET} Swap: ${SWAP_SIZE}GB (swappiness=$SWAPPINESS)"
echo -e "   ${CYAN}•${RESET} Docker & Docker Compose: latest"
echo -e "   ${CYAN}•${RESET} Firewall: UFW (SSH, HTTP, HTTPS)"
echo -e "   ${CYAN}•${RESET} Security: Fail2Ban + SSH hardening"
echo -e "   ${CYAN}•${RESET} Updates: automatic security updates"
echo ""
echo -e "${GREEN}🛠️ UTILITY SCRIPTS${RESET}"
echo -e "   ${CYAN}•${RESET} vps-monitor.sh   - System monitoring"
echo -e "   ${CYAN}•${RESET} vps-cleanup.sh   - Cleanup (runs weekly)"
echo -e "   ${CYAN}•${RESET} vps-info.sh      - System information"
echo -e "   ${CYAN}•${RESET} network-test.sh  - Network test"
echo ""
echo -e "${GREEN}🔒 SECURITY${RESET}"
echo -e "   ${RED}•${RESET} Root login: ${RED}DISABLED${RESET}"
echo -e "   ${RED}•${RESET} Password auth: ${RED}DISABLED${RESET}"
echo -e "   ${GREEN}•${RESET} SSH key auth: ${GREEN}ENABLED${RESET}"
echo -e "   ${CYAN}•${RESET} SSH port: $SSH_PORT"
echo -e "   ${CYAN}•${RESET} Allowed users: $NEW_USER"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${RED}⚠️  CRITICAL: VERIFY SSH ACCESS BEFORE DISCONNECTING${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "   ${YELLOW}1.${RESET} Open new terminal (don't close this!)"
echo -e "   ${YELLOW}2.${RESET} Test: ${CYAN}ssh $NEW_USER@$(hostname -I | awk '{print $1}')${RESET}"
echo -e "   ${YELLOW}3.${RESET} Test: ${CYAN}sudo -l${RESET} (no password required)"
echo -e "   ${YELLOW}4.${RESET} Only disconnect after successful test"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}                 📊 SYSTEM STATUS${RESET}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
/usr/local/bin/vps-info.sh
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${RED}🔄 REBOOT REQUIRED${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
if [ "$XANMOD_INSTALLED" = true ]; then
    echo -e "   ${CYAN}•${RESET} Boot into new XanMod kernel"
fi
echo -e "   ${CYAN}•${RESET} Activate Docker group membership"
echo -e "   ${CYAN}•${RESET} Apply all system optimizations"
echo ""
read -p "Reboot now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}⏳ Rebooting in 5 seconds...${RESET}"
    sleep 5
    reboot
else
    echo -e "${YELLOW}⏭️  Reboot skipped. Run: ${CYAN}sudo reboot${RESET}"
    if [ "$XANMOD_INSTALLED" = true ]; then
        echo -e "${YELLOW}💡 After reboot, check: ${CYAN}uname -r${RESET}"
    fi
fi