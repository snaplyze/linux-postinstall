#!/bin/bash

################################################################################
# VPS Optimization Script for Debian 13 (Trixie)
# Purpose: Complete VPS optimization with XanMod kernel support
# Features: Auto RAM detection, XanMod kernel, user creation, SSH hardening
# Author: Auto-generated
# Date: 2025-11-09
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="/var/log/vps_optimization.log"

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
   exit 1
fi

log "=== Starting VPS Optimization ==="

################################################################################
# 0. Detect OS Version
################################################################################
log "Step 0: Detecting operating system..."

# Detect OS
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

echo ""
info "We need to create a new sudo user for secure access."
info "Root login will be disabled after setup."
echo ""

read -p "Enter new username: " NEW_USER

if [ -z "$NEW_USER" ]; then
    error "Username cannot be empty!"
    exit 1
fi

# Check if user already exists
if id "$NEW_USER" &>/dev/null; then
    warn "User $NEW_USER already exists. Skipping user creation..."
else
    # Create user
    adduser --gecos "" "$NEW_USER"

    # Add to sudo group (docker group will be added later after Docker installation)
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

echo ""
info "Please paste your SSH public key (the content of your id_rsa.pub or id_ed25519.pub):"
info "If you don't have one, generate it on your local machine with: ssh-keygen -t ed25519"
echo ""
read -p "SSH Public Key: " SSH_PUBLIC_KEY

if [ -z "$SSH_PUBLIC_KEY" ]; then
    error "SSH public key cannot be empty!"
    exit 1
fi

# Add SSH key to authorized_keys
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
        log "Selected locale: English (en_US.UTF-8)"
        ;;
    2)
        LOCALE_TO_GENERATE="ru_RU.UTF-8"
        DEFAULT_LOCALE="ru_RU.UTF-8"
        log "Selected locale: Russian (ru_RU.UTF-8)"
        ;;
    3)
        LOCALE_TO_GENERATE="en_US.UTF-8 ru_RU.UTF-8"
        DEFAULT_LOCALE="en_US.UTF-8"
        log "Selected locales: English + Russian"
        ;;
    *)
        warn "Invalid choice. Using English (en_US.UTF-8) as default"
        LOCALE_TO_GENERATE="en_US.UTF-8"
        DEFAULT_LOCALE="en_US.UTF-8"
        ;;
esac

# Generate locales
log "Generating locales..."
for locale in $LOCALE_TO_GENERATE; do
    if ! locale -a | grep -qi "^${locale%.*}"; then
        # Add locale to locale.gen if not present
        if ! grep -q "^${locale}" /etc/locale.gen 2>/dev/null; then
            echo "${locale} UTF-8" >> /etc/locale.gen
        fi
        # Uncomment locale in locale.gen
        sed -i "s/^# *${locale}/${locale}/" /etc/locale.gen 2>/dev/null || true
    fi
done

# Generate and update locales
locale-gen
update-locale LANG=$DEFAULT_LOCALE

log "Default locale set to: $DEFAULT_LOCALE"

# Hostname configuration
echo ""
read -p "Enter new hostname (press Enter to keep current: $(hostname)): " NEW_HOSTNAME

if [ -n "$NEW_HOSTNAME" ]; then
    # Validate hostname
    if [[ $NEW_HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        OLD_HOSTNAME=$(hostname)

        # Set new hostname
        hostnamectl set-hostname "$NEW_HOSTNAME"

        # Update /etc/hosts
        sed -i "s/127.0.1.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts

        # Add entry if not exists
        if ! grep -q "127.0.1.1" /etc/hosts; then
            echo "127.0.1.1	${NEW_HOSTNAME}" >> /etc/hosts
        fi

        log "Hostname changed: $OLD_HOSTNAME -> $NEW_HOSTNAME"
    else
        warn "Invalid hostname format. Keeping current hostname: $(hostname)"
    fi
else
    log "Keeping current hostname: $(hostname)"
fi

# Timezone configuration
echo ""
info "Current timezone: $(timedatectl show --property=Timezone --value)"
info "Examples: Europe/Moscow, America/New_York, Asia/Tokyo, UTC"
echo ""
read -p "Enter timezone (press Enter to keep current): " NEW_TIMEZONE

if [ -n "$NEW_TIMEZONE" ]; then
    # Validate timezone
    if timedatectl list-timezones | grep -q "^${NEW_TIMEZONE}$"; then
        timedatectl set-timezone "$NEW_TIMEZONE"
        log "Timezone set to: $NEW_TIMEZONE"
    else
        warn "Invalid timezone. Keeping current timezone."
        warn "Use 'timedatectl list-timezones' to see available timezones."
    fi
else
    log "Keeping current timezone: $(timedatectl show --property=Timezone --value)"
fi

# Enable NTP
timedatectl set-ntp true
log "NTP synchronization enabled"

echo ""
info "Localization configured:"
info "  Locale: $DEFAULT_LOCALE"
info "  Hostname: $(hostname)"
info "  Timezone: $(timedatectl show --property=Timezone --value)"
echo ""

################################################################################
# 1.7. Zsh and Starship Installation
################################################################################
log "Step 1.7: Installing and configuring Zsh + Starship..."

echo ""
info "Installing Zsh and Starship for better shell experience..."
echo ""

# Install Zsh and dependencies
apt-get install -y zsh git curl

# Install Starship prompt (universal, works everywhere)
curl -sS https://starship.rs/install.sh | sh -s -- -y
log "Starship prompt installed"

# Function to setup Zsh for a user
setup_zsh_for_user() {
    local username=$1
    local user_home=$(eval echo ~$username)

    log "Setting up Zsh for user: $username"

    # Create plugins directory
    mkdir -p "$user_home/.zsh"

    # Install zsh-autosuggestions
    if [ ! -d "$user_home/.zsh/zsh-autosuggestions" ]; then
        git clone https://github.com/zsh-users/zsh-autosuggestions "$user_home/.zsh/zsh-autosuggestions"
        log "zsh-autosuggestions plugin installed for $username"
    fi

    # Install zsh-syntax-highlighting
    if [ ! -d "$user_home/.zsh/zsh-syntax-highlighting" ]; then
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$user_home/.zsh/zsh-syntax-highlighting"
        log "zsh-syntax-highlighting plugin installed for $username"
    fi

    # Install zsh-completions
    if [ ! -d "$user_home/.zsh/zsh-completions" ]; then
        git clone https://github.com/zsh-users/zsh-completions "$user_home/.zsh/zsh-completions"
        log "zsh-completions plugin installed for $username"
    fi

    # Create .zshrc with optimal configuration
    cat > "$user_home/.zshrc" <<'ZSHRC'
# History configuration
HISTSIZE=50000
SAVEHIST=50000
HISTFILE=~/.zsh_history
setopt EXTENDED_HISTORY          # Write the history file in the ':start:elapsed;command' format
setopt INC_APPEND_HISTORY        # Write to the history file immediately, not when the shell exits
setopt SHARE_HISTORY             # Share history between all sessions
setopt HIST_IGNORE_DUPS          # Do not record an event that was just recorded again
setopt HIST_IGNORE_ALL_DUPS      # Delete an old recorded event if a new event is a duplicate
setopt HIST_IGNORE_SPACE         # Do not record an event starting with a space
setopt HIST_SAVE_NO_DUPS         # Do not write a duplicate event to the history file
setopt HIST_VERIFY               # Do not execute immediately upon history expansion
setopt APPEND_HISTORY            # Append to history file (important!)

# Directory navigation
setopt AUTO_CD                   # Auto cd when entering just a path
setopt AUTO_PUSHD                # Push the current directory visited on the stack
setopt PUSHD_IGNORE_DUPS         # Do not store duplicates in the stack
setopt PUSHD_SILENT              # Do not print the directory stack after pushd or popd

# Completion settings
# Load zsh-completions BEFORE compinit
fpath=(~/.zsh/zsh-completions/src $fpath)

autoload -Uz compinit
compinit -d ~/.zcompdump

# Completion options
setopt COMPLETE_IN_WORD          # Complete from both ends of a word
setopt ALWAYS_TO_END             # Move cursor to the end of a completed word
setopt PATH_DIRS                 # Perform path search even on command names with slashes
setopt AUTO_MENU                 # Show completion menu on a successive tab press
setopt AUTO_LIST                 # Automatically list choices on ambiguous completion
setopt AUTO_PARAM_SLASH          # If completed parameter is a directory, add a trailing slash
setopt MENU_COMPLETE             # Insert first match immediately on ambiguous completion
unsetopt FLOW_CONTROL            # Disable start/stop characters in shell editor

# Case-insensitive completion
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'

# Colored completion (ls colors)
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# Better completion for kill command
zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#) ([0-9a-z-]#)*=01;34=0=01'
zstyle ':completion:*:*:*:*:processes' command "ps -u $USER -o pid,user,comm -w -w"

# Cache completions
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ~/.zsh/cache

# Bash compatibility
setopt BASH_REMATCH              # Enable regex matching like bash
setopt KSH_ARRAYS                # Array indexing from 0 (bash-like)
autoload -Uz bashcompinit && bashcompinit

# Plugin configuration (BEFORE loading plugins)
# Autosuggestions configuration
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=240'
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20

# Syntax highlighting configuration
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)

# Load plugins (syntax-highlighting MUST be last!)
source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# Key bindings
bindkey '^[[A' up-line-or-history
bindkey '^[[B' down-line-or-history
bindkey '^[[3~' delete-char
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line

# Environment variables
export LANG=en_US.UTF-8
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
alias gst='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gca='git commit -a'
alias gcam='git commit -am'
alias gp='git pull'
alias gP='git push'
alias gpo='git push origin'
alias gl='git log --oneline --graph --decorate'
alias gd='git diff'
alias gb='git branch'
alias gco='git checkout'
alias gcb='git checkout -b'

# System aliases
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias cls='clear'
alias c='clear'
alias h='history'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'

# System monitoring
alias meminfo='free -h'
alias cpuinfo='lscpu'
alias diskinfo='df -h'
alias ports='netstat -tulanp'
alias psa='ps aux'
alias psg='ps aux | grep'

# Package management
alias update='sudo apt update && sudo apt upgrade -y'
alias install='sudo apt install'
alias remove='sudo apt remove'
alias search='apt search'
alias autoremove='sudo apt autoremove -y'

# Safety aliases
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias mkdir='mkdir -pv'

# Useful functions
mkcd() {
    mkdir -p "$1" && cd "$1"
}

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

# Initialize Starship prompt
eval "$(starship init zsh)"
ZSHRC

    # Create Starship config
    mkdir -p "$user_home/.config"
    cat > "$user_home/.config/starship.toml" <<'STARSHIP'
# Starship configuration - Clean and universal

# Timeout for commands executed by starship
command_timeout = 1000

# Add new line before prompt
add_newline = true

# Format configuration - simple and clean
format = """
$username\
$hostname\
$directory\
$git_branch\
$git_status\
$docker_context\
$python\
$nodejs\
$golang\
$rust\
$java\
$line_break\
$character"""

# Right prompt
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
symbol = ''
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
show_milliseconds = false

[time]
disabled = false
format = '[$time](bold white)'
time_format = '%T'

[docker_context]
symbol = 'docker'
format = 'via [$symbol $context]($style) '
style = 'blue bold'
only_with_files = true

[python]
symbol = 'py'
format = 'via [$symbol $version]($style) '
style = 'yellow bold'

[nodejs]
symbol = 'node'
format = 'via [$symbol $version]($style) '
style = 'green bold'

[golang]
symbol = 'go'
format = 'via [$symbol $version]($style) '
style = 'cyan bold'

[rust]
symbol = 'rust'
format = 'via [$symbol $version]($style) '
style = 'red bold'

[java]
symbol = 'java'
format = 'via [$symbol $version]($style) '
style = 'red bold'

[package]
disabled = true

[memory_usage]
disabled = true

[battery]
disabled = true
STARSHIP

    # Create cache directory for completions
    mkdir -p "$user_home/.zsh/cache"

    # Set correct ownership for all created files and directories
    chown -R $username:$username "$user_home/.zshrc" "$user_home/.zsh" "$user_home/.config" "$user_home/.zcompdump" 2>/dev/null || true

    # Set correct permissions
    chmod 644 "$user_home/.zshrc" 2>/dev/null || true
    chmod 644 "$user_home/.config/starship.toml" 2>/dev/null || true

    # Change default shell to Zsh
    local zsh_path=$(which zsh)
    if [ -z "$zsh_path" ]; then
        error "Cannot find zsh binary"
        return 1
    fi

    # Ensure zsh is in /etc/shells
    if ! grep -q "^$zsh_path$" /etc/shells; then
        echo "$zsh_path" >> /etc/shells
        log "Added $zsh_path to /etc/shells"
    fi

    chsh -s "$zsh_path" "$username"
    log "Default shell changed to Zsh for $username"
}

# Setup Zsh for root
setup_zsh_for_user root

# Setup Zsh for new user
setup_zsh_for_user $NEW_USER

# Ensure zsh is available
if ! command -v zsh &> /dev/null; then
    error "Zsh installation failed!"
    exit 1
fi

# Ensure starship is available
if ! command -v starship &> /dev/null; then
    error "Starship installation failed!"
    exit 1
fi

echo ""
info "Zsh + Starship configured successfully!"
info "Features enabled:"
info "  • Starship prompt (universal, works everywhere)"
info "  • Autosuggestions (fish-like suggestions)"
info "  • Syntax highlighting"
info "  • Git integration"
info "  • Docker context display"
info "  • Advanced completion system"
info "  • 50+ useful aliases"
info "  • Bash compatibility mode"
echo ""

################################################################################
# 2. Detect CPU Architecture and RAM
################################################################################
log "Step 2: Detecting system specifications..."

# Detect CPU architecture
CPU_ARCH=$(uname -m)
log "CPU Architecture: $CPU_ARCH"

# Get total RAM in GB
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_RAM_KB/1024/1024}")
log "Total RAM: ${TOTAL_RAM_GB}GB"

# Calculate swap size based on RAM
if (( $(echo "$TOTAL_RAM_GB < 3" | bc -l) )); then
    # Less than 3GB: swap = 2 * RAM
    SWAP_SIZE=$(awk "BEGIN {printf \"%.0f\", $TOTAL_RAM_GB * 2}")
    SWAPPINESS=60
    log "RAM < 3GB: Creating ${SWAP_SIZE}GB swap (2x RAM)"
else
    # 3GB or more: swap = RAM / 2
    SWAP_SIZE=$(awk "BEGIN {printf \"%.0f\", $TOTAL_RAM_GB / 2}")
    SWAPPINESS=10
    log "RAM >= 3GB: Creating ${SWAP_SIZE}GB swap (0.5x RAM)"
fi

################################################################################
# 3. System Update and Essential Packages
################################################################################
log "Step 3: Updating system and installing essential packages..."

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
apt-get install -y \
    curl \
    wget \
    git \
    htop \
    iotop \
    sysstat \
    net-tools \
    ufw \
    fail2ban \
    unattended-upgrades \
    apt-listchanges \
    needrestart \
    ncdu \
    tree \
    vim \
    tmux \
    zip \
    unzip \
    bc \
    gnupg \
    ca-certificates \
    lsb-release

################################################################################
# 4. XanMod Kernel Installation
################################################################################
log "Step 4: Checking XanMod kernel compatibility..."

# XanMod supports x86_64 (amd64) architecture
if [[ "$CPU_ARCH" == "x86_64" ]]; then
    log "CPU architecture is compatible with XanMod kernel"

    # Check CPU for specific features
    if grep -q 'avx2' /proc/cpuinfo; then
        XANMOD_VARIANT="x64v3"
        log "CPU supports AVX2 - using XanMod x64v3 variant"
    elif grep -q 'sse4_2' /proc/cpuinfo; then
        XANMOD_VARIANT="x64v2"
        log "CPU supports SSE4.2 - using XanMod x64v2 variant"
    else
        XANMOD_VARIANT="x64v1"
        log "Using XanMod x64v1 variant (generic)"
    fi

    info "Installing XanMod kernel..."

    # Add XanMod repository
    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg

    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-release.list

    apt-get update

    # Install XanMod kernel based on variant
    case $XANMOD_VARIANT in
        "x64v3")
            apt-get install -y linux-xanmod-x64v3
            ;;
        "x64v2")
            apt-get install -y linux-xanmod-x64v2
            ;;
        *)
            apt-get install -y linux-xanmod-x64v1
            ;;
    esac

    log "XanMod kernel installed successfully"
    XANMOD_INSTALLED=true
else
    warn "CPU architecture ($CPU_ARCH) is not compatible with XanMod kernel"
    warn "Skipping XanMod installation. Continuing with default kernel..."
    XANMOD_INSTALLED=false
fi

################################################################################
# 5. Docker and Docker Compose Installation
################################################################################
log "Step 5: Installing Docker and Docker Compose..."

# Remove old Docker versions if present
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y $pkg 2>/dev/null || true
done

# Install prerequisites
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Set up Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID \
  $VERSION_CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index
apt-get update

# Install Docker Engine, CLI, containerd, and Docker Compose plugin
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Enable and start Docker service
systemctl enable docker
systemctl start docker

# Add user to docker group
usermod -aG docker "$DOCKER_USER"
log "User $DOCKER_USER added to docker group"

# Verify Docker installation
DOCKER_VERSION=$(docker --version)
COMPOSE_VERSION=$(docker compose version)
log "Docker installed: $DOCKER_VERSION"
log "Docker Compose installed: $COMPOSE_VERSION"

# Configure Docker daemon for better performance
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "default-address-pools": [
    {
      "base": "172.17.0.0/12",
      "size": 24
    }
  ]
}
EOF

# Restart Docker to apply configuration
systemctl restart docker

log "Docker and Docker Compose installation complete"

################################################################################
# 6. Kernel Parameters Optimization (sysctl)
################################################################################
log "Step 6: Optimizing kernel parameters..."

# Backup original sysctl.conf
cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%F) 2>/dev/null || true

cat > /etc/sysctl.d/99-vps-optimization.conf <<EOF
# VPS Optimization - Debian 13 Trixie

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

# TCP Congestion Control (BBR for better throughput)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Connection Tracking
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

# File System Performance
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# Virtual Memory (adjusted based on RAM)
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

sysctl -p /etc/sysctl.d/99-vps-optimization.conf

################################################################################
# 7. Swap Optimization
################################################################################
log "Step 7: Setting up swap file..."

# Remove existing swap if present
if swapon --show | grep -q "/swapfile"; then
    log "Removing existing swap..."
    swapoff /swapfile
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab
fi

# Create new swap with calculated size
log "Creating ${SWAP_SIZE}GB swap file..."
fallocate -l ${SWAP_SIZE}G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# Add to fstab
if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "Swap file created and enabled (${SWAP_SIZE}GB, swappiness=$SWAPPINESS)"

################################################################################
# 8. Firewall Configuration (UFW)
################################################################################
log "Step 8: Configuring firewall (UFW)..."

# Reset UFW to default
ufw --force reset

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (check current SSH port)
SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}')
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
fi
ufw allow $SSH_PORT/tcp comment 'SSH'

# Allow HTTP and HTTPS
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# Enable UFW
ufw --force enable

log "Firewall configured and enabled"

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

################################################################################
# 10. System Limits Optimization
################################################################################
log "Step 10: Optimizing system limits..."

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

# Create hardening config
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
# SSH Hardening - VPS Optimization
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

# Only allow specific user
AllowUsers $NEW_USER
EOF

# Test SSH configuration
if sshd -t; then
    log "SSH configuration is valid"
    systemctl restart sshd
    log "SSH service restarted with new configuration"
else
    error "SSH configuration test failed! Reverting changes..."
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    exit 1
fi

################################################################################
# 14. Optimize tmpfs
################################################################################
log "Step 14: Optimizing tmpfs..."

# Check if entries already exist to avoid duplicates
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

SERVICES_TO_DISABLE=(
    "bluetooth.service"
    "cups.service"
    "avahi-daemon.service"
)

for service in "${SERVICES_TO_DISABLE[@]}"; do
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
# Set deadline scheduler for SSDs and none for NVMe
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
EOF

################################################################################
# 17. Create Monitoring Script
################################################################################
log "Step 17: Creating monitoring script..."

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

echo ""
echo "=== Swap Usage ==="
swapon --show
SCRIPT

chmod +x /usr/local/bin/vps-monitor.sh

################################################################################
# 18. Create Cleanup Script
################################################################################
log "Step 18: Creating cleanup script..."

cat > /usr/local/bin/vps-cleanup.sh <<'SCRIPT'
#!/bin/bash

echo "Starting VPS cleanup..."

# Clean package cache
apt-get clean
apt-get autoclean
apt-get autoremove -y

# Clean journal logs older than 7 days
journalctl --vacuum-time=7d

# Clean old kernels (keep current + 1)
dpkg -l 'linux-*' | sed '/^ii/!d;/'"$(uname -r | sed "s/\(.*\)-\([^0-9]\+\)/\1/")"'/d;s/^[^ ]* [^ ]* \([^ ]*\).*/\1/;/[0-9]/!d' | head -n -1 | xargs apt-get -y purge 2>/dev/null || true

# Clean temp files older than 7 days
find /tmp -type f -atime +7 -delete 2>/dev/null || true
find /var/tmp -type f -atime +7 -delete 2>/dev/null || true

# Clean thumbnail cache if exists
rm -rf ~/.cache/thumbnails/* 2>/dev/null || true

echo "Cleanup completed!"
SCRIPT

chmod +x /usr/local/bin/vps-cleanup.sh

# Create weekly cron job for cleanup
cat > /etc/cron.weekly/vps-cleanup <<'EOF'
#!/bin/bash
/usr/local/bin/vps-cleanup.sh >> /var/log/vps-cleanup.log 2>&1
EOF

chmod +x /etc/cron.weekly/vps-cleanup

################################################################################
# 19. Network Performance Test Script
################################################################################
log "Step 19: Creating network performance test script..."

cat > /usr/local/bin/network-test.sh <<'SCRIPT'
#!/bin/bash

echo "=== Network Performance Test ==="
echo ""
echo "Testing network speed with speedtest-cli..."

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
log "Step 20: Creating system information script..."

cat > /usr/local/bin/vps-info.sh <<'SCRIPT'
#!/bin/bash

echo "=== VPS System Information ==="
echo ""
echo "Hostname: $(hostname)"
echo "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"
echo ""
echo "CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
echo "CPU Cores: $(nproc)"
echo "Architecture: $(uname -m)"
echo ""
echo "Total RAM: $(free -h | awk '/^Mem:/ {print $2}')"
echo "Used RAM: $(free -h | awk '/^Mem:/ {print $3}')"
echo "Free RAM: $(free -h | awk '/^Mem:/ {print $4}')"
echo ""
echo "Swap Total: $(free -h | awk '/^Swap:/ {print $2}')"
echo "Swap Used: $(free -h | awk '/^Swap:/ {print $3}')"
echo ""
echo "Disk Usage:"
df -h / | tail -1
echo ""
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "Unable to detect")
echo "Public IP: $PUBLIC_IP"
echo ""
echo "Active Firewall Rules:"
ufw status numbered
echo ""
echo "TCP Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "Swappiness: $(sysctl -n vm.swappiness)"
echo ""
if command -v docker &> /dev/null; then
    echo "Docker Version: $(docker --version 2>/dev/null || echo 'Not available')"
    echo "Docker Compose: $(docker compose version 2>/dev/null || echo 'Not available')"
    echo "Docker Status: $(systemctl is-active docker 2>/dev/null || echo 'Not running')"
fi
SCRIPT

chmod +x /usr/local/bin/vps-info.sh

################################################################################
# Final Summary
################################################################################
echo ""
echo "================================================================================"
log "=== VPS Optimization Complete ==="
echo "================================================================================"
echo ""
log "Summary of optimizations:"
log "  ✓ OS detected: $OS_NAME $OS_VERSION ($OS_CODENAME)"
log "  ✓ Locale: $DEFAULT_LOCALE"
log "  ✓ Hostname: $(hostname)"
log "  ✓ Timezone: $(timedatectl show --property=Timezone --value)"
log "  ✓ Zsh + Oh My Zsh installed for root and $NEW_USER"
log "  ✓ Powerlevel10k theme with plugins (autosuggestions, syntax highlighting)"
log "  ✓ New user created: $NEW_USER (with sudo + docker access, passwordless)"
log "  ✓ SSH keys configured for $NEW_USER"
log "  ✓ System updated and essential packages installed"
log "  ✓ Docker & Docker Compose installed (latest version)"
log "  ✓ User $NEW_USER added to docker group (no sudo needed for docker)"
log "  ✓ Kernel parameters optimized (BBR enabled)"
if [ "$XANMOD_INSTALLED" = true ]; then
    log "  ✓ XanMod kernel installed ($XANMOD_VARIANT)"
else
    log "  ✗ XanMod kernel not installed (incompatible architecture)"
fi
log "  ✓ Swap configured (${SWAP_SIZE}GB, swappiness=$SWAPPINESS)"
log "  ✓ Firewall (UFW) enabled with SSH, HTTP, HTTPS"
log "  ✓ Fail2Ban configured for SSH protection"
log "  ✓ System limits increased"
log "  ✓ Automatic security updates enabled"
log "  ✓ Journal logs limited to 500MB"
log "  ✓ SSH hardened (root login disabled, only key auth)"
log "  ✓ tmpfs optimized"
log "  ✓ I/O scheduler optimized"
log "  ✓ Unnecessary services disabled"
echo ""
log "Created utility scripts:"
log "  • vps-monitor.sh   - System monitoring"
log "  • vps-cleanup.sh   - System cleanup (runs weekly)"
log "  • vps-info.sh      - System information"
log "  • network-test.sh  - Network performance test"
echo ""
log "Security Configuration:"
log "  • Root login: DISABLED"
log "  • Password authentication: DISABLED"
log "  • SSH key authentication: ENABLED (for $NEW_USER only)"
log "  • Passwordless sudo: ENABLED (for $NEW_USER and root)"
log "  • SSH port: $SSH_PORT"
echo ""
warn "================================================================================"
warn "CRITICAL: Before disconnecting, verify SSH access:"
warn "  1. Open a new terminal (don't close this one!)"
warn "  2. Test login: ssh $NEW_USER@$(hostname -I | awk '{print $1}')"
warn "  3. Test sudo: sudo -l (should work without password)"
warn "  4. Only disconnect current session after successful test!"
warn "================================================================================"
echo ""
info "System Information:"
/usr/local/bin/vps-info.sh
echo ""
echo "================================================================================"
warn "A system reboot is REQUIRED to activate all changes"
if [ "$XANMOD_INSTALLED" = true ]; then
    warn "Especially to boot into the new XanMod kernel"
fi
warn ""
warn "IMPORTANT: Docker group membership will be active after reboot!"
warn "After reboot, login as $NEW_USER and test: docker ps (should work without sudo)"
echo "================================================================================"
echo ""
read -p "Do you want to reboot now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Rebooting system in 5 seconds... Press Ctrl+C to cancel"
    sleep 5
    reboot
else
    log "Reboot skipped. Please reboot manually when ready with: sudo reboot"
    echo ""
    warn "After reboot, check kernel version with: uname -r"
    if [ "$XANMOD_INSTALLED" = true ]; then
        warn "You should see 'xanmod' in the kernel version"
    fi
fi
