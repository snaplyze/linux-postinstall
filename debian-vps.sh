#!/bin/bash
# VPS setup for Debian 12 (bookworm) and Debian 13 (trixie)
# Final fixed version:
#  - Robust locale setup (no LC_ALL override; proper locale.gen edits; noninteractive support)
#  - Fish config rewritten with proper multi-line if/else blocks (fixes 'end outside of a block')
#  - Correct apt-get usage (no '-y' on update)
#  - Docker repo for current codename with fallback to bookworm
#  - Keyrings-based APT keys (no apt-key)
#  - Noninteractive-safe reboot handling
#  - Idempotent UFW, swap, sysctl, and user creation
#  - Safer require_packages

set -u
export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}

# Root check
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root"; exit 1
fi

# OS detection
if [ -f /etc/os-release ]; then . /etc/os-release; else echo "No /etc/os-release"; exit 1; fi
[ "${ID:-}" = "debian" ] || { echo "Only Debian supported (found: ${ID:-?})"; exit 1; }
DEBIAN_VERSION_ID="${VERSION_ID:-}"
DEBIAN_CODENAME="${VERSION_CODENAME:-}"
DEBIAN_MAJOR="${DEBIAN_VERSION_ID%%.*}"
case "$DEBIAN_MAJOR" in 12|13) ;; *) echo "Supported: Debian 12/13. Found: ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME})"; exit 1;; esac

# Helpers
step(){ echo -e "\n\033[1;32m>>> $1\033[0m"; }
color(){ case "$1" in red) c="\033[0;31m";; green) c="\033[0;32m";; yellow) c="\033[0;33m";; blue) c="\033[0;34m";; *) c="\033[0m";; esac; shift; echo -e "${c}$*\033[0m"; }
is_installed(){ dpkg -s "$1" >/dev/null 2>&1; }
require_packages(){ local miss=(); for p in "$@"; do is_installed "$p" || miss+=("$p"); done; if [ ${#miss[@]} -gt 0 ]; then apt-get update || true; apt-get install -y "${miss[@]}"; fi; }

# Flags & vars
NONINTERACTIVE=${NONINTERACTIVE:-false}
NEW_USERNAME=${NEW_USERNAME:-""}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-""}
DEFAULT_LOCALE=${DEFAULT_LOCALE:-ru_RU.UTF-8}
NEW_HOSTNAME=${NEW_HOSTNAME:-""}

UPDATE_SYSTEM=${UPDATE_SYSTEM:-false}
INSTALL_BASE_UTILS=${INSTALL_BASE_UTILS:-false}
CREATE_USER=${CREATE_USER:-false}
CHANGE_HOSTNAME=${CHANGE_HOSTNAME:-false}
SETUP_SSH=${SETUP_SSH:-false}
SETUP_FAIL2BAN=${SETUP_FAIL2BAN:-false}
SETUP_FIREWALL=${SETUP_FIREWALL:-false}
SETUP_BBR=${SETUP_BBR:-false}
INSTALL_XANMOD=${INSTALL_XANMOD:-false}
OPTIMIZE_SYSTEM=${OPTIMIZE_SYSTEM:-false}
SETUP_TIMEZONE=${SETUP_TIMEZONE:-false}
SETUP_NTP=${SETUP_NTP:-false}
SETUP_SWAP=${SETUP_SWAP:-false}
SETUP_LOCALES=${SETUP_LOCALES:-false}
SETUP_LOGROTATE=${SETUP_LOGROTATE:-false}
SETUP_AUTO_UPDATES=${SETUP_AUTO_UPDATES:-false}
INSTALL_MONITORING=${INSTALL_MONITORING:-false}
INSTALL_DOCKER=${INSTALL_DOCKER:-false}
SECURE_SSH=${SECURE_SSH:-false}
INSTALL_FISH=${INSTALL_FISH:-false}

new_username=""; ssh_key_added=false

# 1) Update
if [ "$UPDATE_SYSTEM" = true ]; then
  step "System update"
  apt-get update
  apt-get upgrade -y
  apt-get dist-upgrade -y || true
  apt-get autoremove -y
  apt-get clean
fi

# 2) Base utils
if [ "$INSTALL_BASE_UTILS" = true ]; then
  step "Base utils"
  require_packages sudo curl wget htop iotop nload iftop git zip unzip mc vim nano ncdu \
                  net-tools dnsutils lsof strace cron screen tmux ca-certificates gnupg \
                  python3 python3-pip
fi

# 3) User
if [ "$CREATE_USER" = true ]; then
  step "Create sudo user (NOPASSWD)"
  require_packages sudo
  if [ "$NONINTERACTIVE" = "true" ]; then
    [ -n "$NEW_USERNAME" ] || { color red "NEW_USERNAME required"; exit 1; }
    new_username="$NEW_USERNAME"
  else
    read -r -p "New username: " new_username
  fi
  [[ "$new_username" =~ ^[a-z][-a-z0-9_]*$ ]] || { color red "Invalid username"; exit 1; }
  [ ${#new_username} -le 32 ] || { color red "Username too long"; exit 1; }
  if ! id "$new_username" &>/dev/null; then useradd -m -s /bin/bash -G sudo "$new_username"; fi
  install -d -m 0700 "/home/$new_username/.ssh"
  touch "/home/$new_username/.ssh/authorized_keys"
  chown -R "$new_username:$new_username" "/home/$new_username/.ssh"
  chmod 0600 "/home/$new_username/.ssh/authorized_keys"
  if [ -n "$SSH_PUBLIC_KEY" ]; then echo "$SSH_PUBLIC_KEY" >> "/home/$new_username/.ssh/authorized_keys"; ssh_key_added=true; fi
  install -d -m 0755 /etc/sudoers.d
  echo "$new_username ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/nopasswd-$new_username"
  echo "root ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/nopasswd-root
  chmod 440 "/etc/sudoers.d/nopasswd-$new_username" /etc/sudoers.d/nopasswd-root
fi

# 3.1) Hostname
if [ "$CHANGE_HOSTNAME" = true ]; then
  step "Hostname"
  if [ "$NONINTERACTIVE" = "true" ]; then
    [ -n "$NEW_HOSTNAME" ] || { color red "NEW_HOSTNAME required"; exit 1; }
    new_hostname="$NEW_HOSTNAME"
  else
    read -r -p "New hostname: " new_hostname
  fi
  [[ "$new_hostname" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])$ ]] || { color red "Invalid hostname"; exit 1; }
  [ ${#new_hostname} -le 63 ] || { color red "Hostname too long"; exit 1; }
  hostnamectl set-hostname "$new_hostname" || { color red "Failed to set hostname"; exit 1; }
  if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1\s\+.*/127.0.1.1\t$new_hostname/g" /etc/hosts
  else
    echo -e "127.0.1.1\t$new_hostname" >> /etc/hosts
  fi
fi

# 4) SSH baseline
if [ "$SETUP_SSH" = true ]; then
  step "SSH baseline"
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true
  mkdir -p /etc/ssh/sshd_config.d/
  cat > /etc/ssh/sshd_config.d/secure.conf << EOF
# Safe SSH defaults
PermitRootLogin prohibit-password
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
AllowTcpForwarding yes
AllowAgentForwarding yes
PrintMotd no
AcceptEnv LANG LC_*
EOF
  systemctl restart sshd || systemctl restart ssh || true
fi

# 5) Fail2ban
if [ "$SETUP_FAIL2BAN" = true ]; then
  step "Fail2ban"
  require_packages fail2ban
  cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
[sshd]
enabled = true
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban
fi

# 6) UFW
if [ "$SETUP_FIREWALL" = true ]; then
  step "UFW"
  require_packages ufw
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
fi

# 7) BBR
if [ "$SETUP_BBR" = true ]; then
  step "TCP BBR"
  if ! grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf; then
    cat >> /etc/sysctl.conf << 'EOF'

# TCP BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p || true
  fi
fi

# 7.1) XanMod
if [ "$INSTALL_XANMOD" = true ]; then
  step "XanMod kernel"
  require_packages wget gnupg ca-certificates
  mkdir -p /etc/apt/keyrings
  wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' > /etc/apt/sources.list.d/xanmod-release.list
  apt-get update
  kernel_variant="x64v1"; kernel_description="XanMod x64v1"
  if grep -qi 'avx512' /proc/cpuinfo; then kernel_variant="x64v3"; kernel_description="XanMod x64v3 (AVX512)"
  elif grep -qi 'avx2' /proc/cpuinfo; then kernel_variant="x64v3"; kernel_description="XanMod x64v3 (AVX2)"
  elif grep -qi 'avx' /proc/cpuinfo; then kernel_variant="x64v2"; kernel_description="XanMod x64v2 (AVX)"; fi
  color green "Selected: $kernel_description"
  if ! apt-get install -y "linux-xanmod-$kernel_variant"; then apt-get install -y linux-xanmod || true; fi
fi

# 8) sysctl tune
if [ "$OPTIMIZE_SYSTEM" = true ]; then
  step "sysctl tuning"
  if ! grep -q "tcp_fastopen=3" /etc/sysctl.conf; then
    cat >> /etc/sysctl.conf << 'EOF'

# Net tuning
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=1200
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_timestamps=0
net.ipv4.tcp_tw_reuse=1
net.core.netdev_max_backlog=16384
net.core.somaxconn=4096

# Memory
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
    sysctl -p || true
  fi
fi

# 9) Timezone
if [ "$SETUP_TIMEZONE" = true ]; then
  step "Timezone"
  echo "1) Europe/Moscow"; echo "2) Europe/Kiev"; echo "3) Europe/Berlin"; echo "4) Europe/London"
  echo "5) America/New_York"; echo "6) America/Los_Angeles"; echo "7) Asia/Tokyo"; echo "8) Asia/Shanghai"; echo "9) Australia/Sydney"; echo "10) Custom"
  read -r -p "Choose (1-10): " tz_choice
  case $tz_choice in
    1) TZ="Europe/Moscow";; 2) TZ="Europe/Kiev";; 3) TZ="Europe/Berlin";; 4) TZ="Europe/London";;
    5) TZ="America/New_York";; 6) TZ="America/Los_Angeles";; 7) TZ="Asia/Tokyo";; 8) TZ="Asia/Shanghai";;
    9) TZ="Australia/Sydney";; 10) read -r -p "TZ (e.g., Europe/Paris): " TZ;; *) TZ="UTC";;
  esac
  timedatectl set-timezone "$TZ"
fi

# 10) NTP
if [ "$SETUP_NTP" = true ]; then
  step "NTP (systemd-timesyncd)"
  require_packages systemd-timesyncd
  systemctl enable systemd-timesyncd
  systemctl start systemd-timesyncd || true
  timedatectl set-ntp true || true
fi

# 11) Swap
if [ "$SETUP_SWAP" = true ]; then
  step "Swap"
  if ! swapon --show | grep -q '/swapfile'; then
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}'); total_mem_mb=$((total_mem_kb / 1024))
    swap_size_mb=$((total_mem_mb / 2)); [ $total_mem_mb -le 3072 ] && swap_size_mb=2048
    dd if=/dev/zero of=/swapfile bs=1M count=$swap_size_mb status=none
    chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    if ! grep -q "vm.swappiness=10" /etc/sysctl.conf; then echo "vm.swappiness=10" >> /etc/sysctl.conf; sysctl -p || true; fi
  else
    color yellow "Swap already present"
  fi
fi

# 12) Locales
if [ "$SETUP_LOCALES" = true ]; then
  step "Locales"
  require_packages locales
  TARGET_LOCALE="$DEFAULT_LOCALE"
  case "$TARGET_LOCALE" in ru_RU.UTF-8|en_US.UTF-8) ;; *) TARGET_LOCALE="en_US.UTF-8";; esac
  for loc in ru_RU.UTF-8 en_US.UTF-8; do
    if ! grep -qE "^[#\s]*${loc}\s+UTF-8" /etc/locale.gen; then
      echo "${loc} UTF-8" >> /etc/locale.gen
    else
      sed -i "s/^[#\s]*${loc}\s\+UTF-8/${loc} UTF-8/" /etc/locale.gen
    fi
  done
  locale-gen || { color red "locale-gen failed"; exit 1; }
  lang_code="${TARGET_LOCALE%%.*}"; lang_primary="${lang_code%%_*}"
  update-locale LANG="$TARGET_LOCALE" LANGUAGE="$lang_primary:en"
  color yellow "Locale set to $TARGET_LOCALE (applies on next login session)"
fi

# 13) logrotate
if [ "$SETUP_LOGROTATE" = true ]; then
  step "logrotate"
  require_packages logrotate rsyslog
  cat > /etc/logrotate.d/custom << 'EOF'
/var/log/syslog
/var/log/messages
/var/log/kern.log
{
  rotate 7
  daily
  missingok
  notifempty
  compress
  delaycompress
  postrotate
      systemctl restart rsyslog 2>/dev/null || true
  endscript
}
EOF
fi

# 14) Unattended-upgrades
if [ "$SETUP_AUTO_UPDATES" = true ]; then
  step "unattended-upgrades"
  require_packages unattended-upgrades apt-listchanges
  cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=${DEBIAN_CODENAME},label=Debian";
  "origin=Debian,codename=${DEBIAN_CODENAME}-security,label=Debian-Security";
  "origin=Debian,codename=${DEBIAN_CODENAME}-updates,label=Debian";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
  systemctl enable unattended-upgrades.service 2>/dev/null || true
  systemctl start unattended-upgrades.service 2>/dev/null || true
fi

# 15) Docker
if [ "$INSTALL_DOCKER" = true ]; then
  step "Docker"
  apt-get remove -y docker docker-engine docker.io containerd runc podman-docker 2>/dev/null || true
  require_packages ca-certificates curl gnupg lsb-release
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${DEBIAN_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update || true
  candidate=$(apt-cache policy docker-ce | awk '/Candidate:/ {print $2}')
  if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
    color yellow "No Docker packages for ${DEBIAN_CODENAME}; fallback to bookworm"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
    apt-get update || true
  fi
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker; systemctl start docker
  getent group docker >/dev/null || groupadd docker
  if [ -n "${SUDO_USER:-}" ]; then usermod -aG docker "$SUDO_USER" && echo "Added $SUDO_USER to docker group"; fi
  if [ -n "$new_username" ] && id "$new_username" &>/dev/null; then usermod -aG docker "$new_username" && echo "Added $new_username to docker group"; fi
fi

# 16) Monitoring
if [ "$INSTALL_MONITORING" = true ]; then
  step "Monitoring"
  require_packages sysstat atop iperf3 nmon smartmontools lm-sensors
  if [ -f /etc/default/sysstat ]; then
    sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
    systemctl enable sysstat; systemctl restart sysstat || true
  fi
fi

# 17) Secure SSH (keys only)
if [ "$SECURE_SSH" = true ]; then
  step "Secure SSH (keys only)"
  ssh_key_exists=false
  if [ "$CREATE_USER" = true ] && [ "$ssh_key_added" = true ]; then
    ssh_key_exists=true
  else
    if [ -s "/root/.ssh/authorized_keys" ] || { [ -n "${SUDO_USER:-}" ] && [ -s "/home/$SUDO_USER/.ssh/authorized_keys" ]; }; then
      ssh_key_exists=true
    fi
  fi
  if [ "$ssh_key_exists" = false ] && [ "$NONINTERACTIVE" != "true" ]; then
    color red "No SSH keys found. Disabling password login may lock you out!"
    read -r -p "Proceed? (y/n): " confirm; [[ "$confirm" =~ ^[yY]$ ]] || { color yellow "SSH hardening skipped"; SECURE_SSH=false; }
  fi
  if [ "$SECURE_SSH" = true ]; then
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null || true
    cat > /etc/ssh/sshd_config.d/security.conf << 'EOF'
# Hardened SSH
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
EOF
    systemctl restart sshd || systemctl restart ssh || true
  fi
fi

# 18) Fish shell (fixed config)
if [ "$INSTALL_FISH" = true ]; then
  step "Fish shell + Starship + Fisher"
  require_packages fish fzf fd-find bat curl
  command -v fd >/dev/null || { command -v fdfind >/dev/null && ln -sf "$(command -v fdfind)" /usr/local/bin/fd; }
  command -v bat >/dev/null || { command -v batcat >/dev/null && ln -sf "$(command -v batcat)" /usr/local/bin/bat; }
  # Starship
  curl -sS https://starship.rs/install.sh | sh -s -- -y

  # Root config
  install -d -m 0755 /root/.config/fish/functions /root/.config/fish/completions
  cat > /root/.config/fish/config.fish <<'FISHCFG'
# Don't override system LC_ALL here
# Keep locale from environment or fallback to en_US.UTF-8
if not set -q LANG
    set -gx LANG en_US.UTF-8
end
if not set -q LANGUAGE
    set -gx LANGUAGE (string split . -- $LANG)[1]
end

alias ll='ls -la'
alias la='ls -A'
alias l='ls'
alias cls='clear'
alias ..='cd ..'
alias ...='cd ../..'

# Prefer bat/batcat for cat
if type -q bat
    alias cat='bat --paging=never'
else if type -q batcat
    alias cat='batcat --paging=never'
end

# Prefer fd/fdfind for find
if type -q fd
    alias find='fd'
else if type -q fdfind
    alias find='fdfind'
end

set -U fish_greeting
set fish_key_bindings fish_default_key_bindings
set -gx FZF_DEFAULT_COMMAND 'fd --type f --strip-cwd-prefix 2>/dev/null || find . -type f'
set -gx FZF_CTRL_T_COMMAND $FZF_DEFAULT_COMMAND
starship init fish | source
FISHCFG

  cat > /root/.config/fish/functions/fish_greeting.fish <<'FISHGREETING'
function fish_greeting
    echo "🐧 Debian $(uname -r) [ROOT] - "(date '+%Y-%m-%d %H:%M')""
end
FISHGREETING

  curl -sL https://raw.githubusercontent.com/docker/cli/master/contrib/completion/fish/docker.fish -o /root/.config/fish/completions/docker.fish
  curl -sL https://raw.githubusercontent.com/docker/compose/master/contrib/completion/fish/docker-compose.fish -o /root/.config/fish/completions/docker-compose.fish

  # Fisher plugins for root
  cat > /tmp/install_fisher_root.fish <<'FISHER_ROOT'
#!/usr/bin/env fish
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
fisher install jorgebucaran/fisher jethrokuan/z PatrickF1/fzf.fish jorgebucaran/autopair.fish franciscolourenco/done edc/bass
FISHER_ROOT
  chmod +x /tmp/install_fisher_root.fish; fish /tmp/install_fisher_root.fish; rm -f /tmp/install_fisher_root.fish
  chsh -s /usr/bin/fish root || true

  # Setup for created user
  if [ -n "$new_username" ] && id "$new_username" &>/dev/null; then
    su - "$new_username" -c "mkdir -p ~/.config/fish/functions ~/.config/fish/completions"
    cat > /tmp/user_config.fish <<'USERCFG'
alias ll='ls -la'
alias la='ls -A'
alias l='ls'
alias cls='clear'
alias ..='cd ..'
alias ...='cd ../..'

if type -q bat
    alias cat='bat --paging=never'
else if type -q batcat
    alias cat='batcat --paging=never'
end

if type -q fd
    alias find='fd'
else if type -q fdfind
    alias find='fdfind'
end

set -U fish_greeting
set fish_key_bindings fish_default_key_bindings
set -gx FZF_DEFAULT_COMMAND 'fd --type f --strip-cwd-prefix 2>/dev/null || find . -type f'
set -gx FZF_CTRL_T_COMMAND $FZF_DEFAULT_COMMAND
starship init fish | source
USERCFG
    cat > /tmp/user_greeting.fish <<'USERGREETING'
function fish_greeting
    echo "🐧 Debian - "(date '+%Y-%m-%d %H:%M')""
end
USERGREETING
    su - "$new_username" -c "cp /tmp/user_config.fish ~/.config/fish/config.fish"
    su - "$new_username" -c "cp /tmp/user_greeting.fish ~/.config/fish/functions/fish_greeting.fish"
    su - "$new_username" -c "curl -sL https://raw.githubusercontent.com/docker/cli/master/contrib/completion/fish/docker.fish -o ~/.config/fish/completions/docker.fish"
    su - "$new_username" -c "curl -sL https://raw.githubusercontent.com/docker/compose/master/contrib/completion/fish/docker-compose.fish -o ~/.config/fish/completions/docker-compose.fish"
    su - "$new_username" -c "curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source; fisher install jorgebucaran/fisher jethrokuan/z PatrickF1/fzf.fish jorgebucaran/autopair.fish franciscolourenco/done edc/bass"
    rm -f /tmp/user_config.fish /tmp/user_greeting.fish
    chsh -s /usr/bin/fish "$new_username" || true
  fi
fi

# 19) Monitoring
if [ "$INSTALL_MONITORING" = true ]; then
  step "Monitoring"
  require_packages sysstat atop iperf3 nmon smartmontools lm-sensors
  if [ -f /etc/default/sysstat ]; then
    sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
    systemctl enable sysstat; systemctl restart sysstat || true
  fi
fi

# Final summary
step "Done"
echo -e "\n\033[1;34mSystem:\033[0m"; uname -a
echo -e "\n\033[1;34mHostname:\033[0m"; hostname
echo -e "\n\033[1;34mMemory/Swap:\033[0m"; free -h
echo -e "\n\033[1;34mDisks:\033[0m"; df -h
echo -e "\n\033[1;34mNetwork:\033[0m"; ip a

if [ "$NONINTERACTIVE" = "true" ]; then
  echo "NONINTERACTIVE=true — reboot manually when ready: sudo reboot"
else
  read -r -p "Reboot now? (y/n): " rb; if [[ "$rb" =~ ^[yY]$ ]]; then
    if command -v systemctl >/dev/null 2>&1; then systemctl reboot; elif command -v shutdown >/dev/null 2>&1; then shutdown -r now; else reboot; fi
  fi
fi
