#!/usr/bin/env bash
set -euo pipefail

# Arch Linux Universal Optimizer (based on arch-os ideas, with extended checks)
# Можно запускать напрямую: curl -fsSL <URL> | bash

# === COLORS ===
RED='\e[1;31m'; GREEN='\e[1;32m'; YELLOW='\e[1;33m'; BLUE='\e[1;34m'; NC='\e[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()    { echo -e "${RED}[FAIL]${NC} $*"; }
ask()     { echo -ne "${BLUE}[?]${NC} $* "; }
header()  { echo -e "\n${BLUE}========== $* ==========${NC}\n"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# === ROOT CHECK (авто sudo) ===
if [[ $EUID -ne 0 ]]; then
    if command_exists sudo; then
        exec sudo bash "$0" "$@"
    else
        fail "Скрипт должен запускаться от root или через sudo!"
        exit 1
    fi
fi

header "Arch Linux Post-Install Optimizer"
echo -e "Этот скрипт оптимизирует систему Arch Linux после чистой установки.\nБезопасен для повторного запуска. Не изменяет пользователей и разделы.\n"

# === ПЕРВИЧНЫЕ ПРОВЕРКИ ===
if ! grep -qi arch /etc/os-release; then
    fail "Система не является Arch Linux! Прерывание."
    exit 1
fi

# === ДЕТЕКТ ОКРУЖЕНИЯ ===
CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs || echo "Unknown")
TOTAL_RAM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
BTRFS_ROOT=0
if mount | grep -qE 'on / .*btrfs'; then BTRFS_ROOT=1; fi

HAS_SSD=0; HAS_HDD=0; SSD_LIST=(); HDD_LIST=()
while read -r dev rota type; do
    case "$rota" in
        0) HAS_SSD=1; SSD_LIST+=("$dev ($type)");;
        1) HAS_HDD=1; HDD_LIST+=("$dev ($type)");;
    esac
done < <(lsblk -d -o NAME,ROTA,TYPE | awk 'NR>1')

# === ИНТЕРАКТИВНОЕ МЕНЮ ===
echo "Выберите, что оптимизировать:"
echo " 1) Оптимизация pacman и housekeeping"
echo " 2) Swap, память (zram, sysctl, oomd)"
echo " 3) SSD/NVMe/HDD обслуживание (fstrim, irqbalance, smartd, дефрагментация ext4)"
echo " 4) Btrfs & Snapper (snapshots)"
echo " 5) Ядро, microcode, watchdog"
echo " 6) CLI-утилиты (fish, starship, zoxide, fzf, bat, eza, aliases)"
echo " 7) Всё сразу (рекомендуется)"
echo " 0) Выйти"
ask "Ваш выбор (например 7):"
read -r choice

[[ "$choice" == "0" ]] && exit 0

OPT_PACMAN=0; OPT_SWAP=0; OPT_SSD=0; OPT_BTRFS=0; OPT_KERNEL=0; OPT_UTILS=0
case "$choice" in
    1) OPT_PACMAN=1 ;;
    2) OPT_SWAP=1 ;;
    3) OPT_SSD=1 ;;
    4) OPT_BTRFS=1 ;;
    5) OPT_KERNEL=1 ;;
    6) OPT_UTILS=1 ;;
    7) OPT_PACMAN=1; OPT_SWAP=1; OPT_SSD=1; OPT_BTRFS=1; OPT_KERNEL=1; OPT_UTILS=1 ;;
    *) fail "Неверный выбор!"; exit 1 ;;
esac

# === PACMAN, HOUSEKEEPING ===
if [[ $OPT_PACMAN -eq 1 ]]; then
    header "Pacman и housekeeping"
    if grep -q '^#ParallelDownloads' /etc/pacman.conf; then
        sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
        info "Включены параллельные загрузки pacman."
    fi
    if ! grep -q 'ILoveCandy' /etc/pacman.conf; then
        sed -i '/^#Color/s/#Color/Color\nILoveCandy/' /etc/pacman.conf
        info "Включён цветной вывод pacman и ILoveCandy."
    fi
    if grep -q '^\[multilib\]' /etc/pacman.conf && grep -A1 '^\[multilib\]' /etc/pacman.conf | grep -q '#Include'; then
        sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
        info "Включён репозиторий multilib."
    fi
    pacman -Sy --noconfirm
    for pkg in pacman-contrib reflector pkgfile smartmontools irqbalance; do
        if ! pacman -Q $pkg &>/dev/null; then pacman -S --noconfirm $pkg; fi
    done
    systemctl enable --now reflector.service paccache.timer pkgfile-update.timer smartd irqbalance.service
    info "Все housekeeping сервисы включены."
fi

# === SWAP, ZRAM, SYSCTL, OOMD ===
if [[ $OPT_SWAP -eq 1 ]]; then
    header "ZRAM, swap и параметры памяти"
    if ! pacman -Q zram-generator &>/dev/null; then pacman -S --noconfirm zram-generator; fi
    if [[ ! -f /etc/systemd/zram-generator.conf ]]; then
        cat <<EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF
        info "Создан конфиг zram-generator."
    fi
    cat <<EOF > /etc/sysctl.d/99-vm-zram-parameters.conf
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF
    systemctl enable --now systemd-zram-setup@zram0.service
    if ! systemctl is-enabled systemd-oomd.service &>/dev/null; then
        systemctl enable --now systemd-oomd.service
        info "Включён systemd-oomd."
    fi
    info "ZRAM и параметры памяти оптимизированы."
fi

# === SSD/NVMe/HDD ===
if [[ $OPT_SSD -eq 1 ]]; then
    header "Обслуживание SSD/NVMe/HDD"
    if [[ $HAS_SSD -eq 1 ]]; then
        systemctl enable --now fstrim.timer
        info "fstrim.timer включён для SSD/NVMe: ${SSD_LIST[*]}"
    fi
    if [[ $HAS_HDD -eq 1 ]]; then
        info "Обнаружен HDD: ${HDD_LIST[*]}"
        systemctl enable --now smartd
        info "Сервис smartd включён для мониторинга состояния HDD."
        # Дефрагментация для ext4
        if mount | grep -q ext4; then
            warn "Для повышения производительности ext4 на HDD можно выполнять дефрагментацию: e4defrag /"
        fi
        # Пример строки smartd.conf
        echo -e "${YELLOW}Для расширенного мониторинга температуры HDD добавьте строку в /etc/smartd.conf:"
        echo "DEVICESCAN -a -o on -S on -s (S/../.././02|L/../../6/03) -m ваш@email -M exec /usr/share/smartmontools/smartd-runner${NC}"
    fi
    if [[ $HAS_SSD -eq 0 && $HAS_HDD -eq 0 ]]; then
        warn "Не обнаружены ни SSD/NVMe, ни HDD."
    fi
    systemctl enable --now irqbalance.service smartd
    info "irqbalance и smartd включены."
fi

# === Btrfs & Snapper ===
if [[ $OPT_BTRFS -eq 1 ]]; then
    header "Btrfs и Snapper"
    if [[ $BTRFS_ROOT -eq 1 ]]; then
        if ! pacman -Q snapper &>/dev/null; then pacman -S --noconfirm snapper btrfs-progs; fi
        if [[ ! -d /etc/snapper/configs/root ]]; then snapper --no-dbus -c root create-config /; fi
        for t in snapper-timeline.timer snapper-cleanup.timer snapper-boot.timer btrfs-scrub@-.timer btrfs-scrub@home.timer btrfs-scrub@snapshots.timer; do
            systemctl enable --now $t
        done
        mkdir -p /etc/pacman.d/hooks/
        cat <<EOF > /etc/pacman.d/hooks/50-btrfs-snapshot.hook
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Creating BTRFS snapshot
When = PreTransaction
Exec = /bin/sh -c '/usr/bin/btrfs subvolume snapshot -r / /.snapshots/"\$(date "+%Y-%m-%d_%H-%M-%S")"'
EOF
        info "Snapper и btrfs scrub настроены."
    else
        warn "Корневая файловая система НЕ btrfs — опция пропущена."
    fi
fi

# === ЯДРО, MICROCODE, WATCHDOG ===
if [[ $OPT_KERNEL -eq 1 ]]; then
    header "Ядро, microcode, watchdog"
    CPU_TYPE=$(lscpu | grep -o 'GenuineIntel\|AuthenticAMD' || true)
    if [[ $CPU_TYPE == "GenuineIntel" ]]; then
        if ! pacman -Q intel-ucode &>/dev/null; then pacman -S --noconfirm intel-ucode; fi
        info "Intel-ucode установлен."
    elif [[ $CPU_TYPE == "AuthenticAMD" ]]; then
        if ! pacman -Q amd-ucode &>/dev/null; then pacman -S --noconfirm amd-ucode; fi
        info "AMD-ucode установлен."
    fi
    # Watchdog
    mkdir -p /etc/modprobe.d/
    echo -e "blacklist sp5100_tco\nblacklist iTCO_wdt" > /etc/modprobe.d/blacklist-watchdog.conf
    # sudo pwfeedback
    if ! grep -q 'pwfeedback' /etc/sudoers; then
        sed -i '/^Defaults.*env_reset/a Defaults pwfeedback' /etc/sudoers
        info "sudo pwfeedback включён."
    fi
    info "Ядро и параметры оптимизированы."
fi

# === CLI УТИЛИТЫ и КОНФИГИ ===
if [[ $OPT_UTILS -eq 1 ]]; then
    header "CLI-утилиты и удобства"
    pacman -S --noconfirm fish starship zoxide fd fzf bat eza fastfetch mc btop nano man-db bash-completion nano-syntax-highlighting ttf-firacode-nerd ttf-nerd-fonts-symbols
    for HOME_DIR in /root /home/*; do
        [ -d "$HOME_DIR" ] || continue
        ALIASES="$HOME_DIR/.aliases"
        BASHRC="$HOME_DIR/.bashrc"
        cat <<'EOF' > "$ALIASES"
alias ls='eza -h --color=always --group-directories-first'
alias ll='ls -l'
alias la='ls -la'
alias lt='ls -Tal'
alias logs='systemctl --failed; echo; journalctl -p 3 -b'
alias q='exit'
alias c='clear'
alias fetch='fastfetch'
alias myip='curl ipv4.icanhazip.com'
EOF
        if ! grep -q '.aliases' "$BASHRC" 2>/dev/null; then
            echo '[[ -f ~/.aliases ]] && source ~/.aliases' >> "$BASHRC"
        fi
        chown -R "$(basename "$HOME_DIR")":"$(basename "$HOME_DIR")" "$HOME_DIR" 2>/dev/null || true
    done
    info "CLI-утилиты и алиасы добавлены всем пользователям."
fi

header "Все выбранные оптимизации применены!"
echo -e "${GREEN}Рекомендуется перезагрузить систему для полного применения изменений.${NC}"
