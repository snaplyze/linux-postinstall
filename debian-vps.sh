#!/bin/bash
# Скрипт настройки VPS на Debian 12 (bookworm) и Debian 13 (trixie)
# Автоматическая настройка системы, оптимизация производительности и безопасности
# Обновления в этой версии:
#  - Автоопределение версии Debian (12/13) и кодового имени
#  - Корректная поддержка Docker APT-репозитория для trixie с фолбэком на bookworm
#  - Исправлен unattended-upgrades (Debian-специфичная конфигурация, без Ubuntu ESM)
#  - Гарантированная установка gpg/curl/ca-certificates в секциях Docker и XanMod
#  - Более надёжное включение UFW (без интерактивного подтверждения)
#  - timesyncd: включение через systemd + timedatectl
#  - Исправлена установка локалей: проверка locale.gen, корректная генерация и запись LANG/LANGUAGE (без LC_ALL), fallback на en_US.UTF-8
#  - Убраны некорректные 'apt-get update -y'; везде корректный синтаксис apt-get
#  - Fail-safe и мелкие правки (useradd/hostnamectl/systemctl, перезапуск sshd/ssh, skip reboot в NONINTERACTIVE)
#
# Пример неинтерактивного запуска:
#   sudo NONINTERACTIVE=true UPDATE_SYSTEM=true INSTALL_DOCKER=true \
#        SETUP_AUTO_UPDATES=true SECURE_SSH=true \
#        CREATE_USER=true NEW_USERNAME=snaplyze SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." \
#        DEFAULT_LOCALE=ru_RU.UTF-8 \
#        ./debian-vps-12-13.sh
#
set -u
export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}

# ————————————————————————————————————————————————————————————————————
# Проверка прав root
# ————————————————————————————————————————————————————————————————————
if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен с правами root"
    exit 1
fi

# ————————————————————————————————————————————————————————————————————
# Определяем версию Debian и кодовое имя
# ————————————————————————————————————————————————————————————————————
if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "Не удалось определить версию системы: отсутствует /etc/os-release"
    exit 1
fi

if [ "${ID:-}" != "debian" ]; then
    echo "Поддерживается только Debian (обнаружено: ${ID:-unknown})"
    exit 1
fi

DEBIAN_VERSION_ID="${VERSION_ID:-}"
DEBIAN_CODENAME="${VERSION_CODENAME:-}"
DEBIAN_MAJOR="${DEBIAN_VERSION_ID%%.*}"

case "$DEBIAN_MAJOR" in
  12|13) ;;  # поддерживаем
  *)
    echo "Этот скрипт поддерживает только Debian 12 (bookworm) и Debian 13 (trixie). Обнаружено: ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME})"
    exit 1
    ;;
esac

# ————————————————————————————————————————————————————————————————————
# Утилиты: вывод шагов, цвета, проверки
# ————————————————————————————————————————————————————————————————————
step() { echo -e "\n\033[1;32m>>> $1\033[0m"; }

print_color() {
    case "$1" in
        red) color="\033[0;31m" ;;
        green) color="\033[0;32m" ;;
        yellow) color="\033[0;33m" ;;
        blue) color="\033[0;34m" ;;
        reset|*) color="\033[0m" ;;
    esac
    echo -e "${color}$2\033[0m"
}

is_installed() {
    dpkg -s "$1" >/dev/null 2>&1
}

require_packages() {
    # Устанавливает отсутствующие пакеты из списка аргументов
    local missing=()
    for p in "$@"; do
        if ! is_installed "$p"; then
            missing+=("$p")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        apt-get update || true
        apt-get install -y "${missing[@]}"
    fi
}

# ————————————————————————————————————————————————————————————————————
# Переменные неинтерактивного режима
# ————————————————————————————————————————————————————————————————————
NONINTERACTIVE=${NONINTERACTIVE:-false}
NEW_USERNAME=${NEW_USERNAME:-""}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-""}
NEW_HOSTNAME=${NEW_HOSTNAME:-""}
DEFAULT_LOCALE=${DEFAULT_LOCALE:-ru_RU.UTF-8}

# Флаги компонентов (по умолчанию выключены)
UPDATE_SYSTEM=false
INSTALL_BASE_UTILS=false
CREATE_USER=false
CHANGE_HOSTNAME=false
SETUP_SSH=false
SETUP_FAIL2BAN=false
SETUP_FIREWALL=false
SETUP_BBR=false
INSTALL_XANMOD=false
OPTIMIZE_SYSTEM=false
SETUP_TIMEZONE=false
SETUP_NTP=false
SETUP_SWAP=false
SETUP_LOCALES=false
SETUP_LOGROTATE=false
SETUP_AUTO_UPDATES=false
INSTALL_MONITORING=false
INSTALL_DOCKER=false
SECURE_SSH=false
INSTALL_FISH=false

new_username=""
ssh_key_added=false

# ————————————————————————————————————————————————————————————————————
# Меню выбора компонентов (интерактив)
# ————————————————————————————————————————————————————————————————————
select_components() {
    clear
    echo ""
    print_color blue "╔═════════════════════════════════════════╗"
    printf "\033[0;34m║     НАСТРОЙКА VPS НА DEBIAN %-10s ║\033[0m\n" "${DEBIAN_MAJOR} (${DEBIAN_CODENAME})"
    print_color blue "╚═════════════════════════════════════════╝"
    echo ""

    select_option() {
        local option="$1" var_name="$2" already="$3"
        if [ "$already" = true ]; then
            echo -e "\033[0;32m✓ $option (уже установлено)\033[0m"; return 0
        fi
        if [ "${!var_name}" = true ]; then
            echo -ne "\033[0;32m✓\033[0m $option (y/n): "
        else
            echo -ne "\033[0;33m○\033[0m $option (y/n): "
        fi
        read -r choice
        if [[ "$choice" =~ ^[yY]$ ]]; then eval "$var_name=true"; echo -e "  \033[0;32m✓ Выбрано\033[0m"; else eval "$var_name=false"; echo "  ○ Пропущено"; fi
    }

    print_color blue "═════════════════════════════════════════"
    print_color blue "  ВЫБЕРИТЕ КОМПОНЕНТЫ ДЛЯ УСТАНОВКИ"
    print_color blue "═════════════════════════════════════════"
    echo

    apt_update_time=$(stat -c %Y /var/cache/apt/pkgcache.bin 2>/dev/null || echo 0)
    current_time=$(date +%s)
    time_diff=$((current_time - apt_update_time))
    if [ $time_diff -lt 86400 ]; then
        sys_updated=true
        echo -e "\033[0;32m✓ Обновление системы (выполнено менее 24 часов назад)\033[0m"
    else
        sys_updated=false
        select_option "Обновление системы" "UPDATE_SYSTEM" "$sys_updated"
    fi

    base_utils_installed=true
    for util in curl wget htop git nano mc; do
        if ! is_installed "$util"; then base_utils_installed=false; break; fi
    done
    if [ "$base_utils_installed" = true ]; then
        echo -e "\033[0;32m✓ Базовые утилиты (уже установлены)\033[0m"
    else
        select_option "Базовые утилиты" "INSTALL_BASE_UTILS" "$base_utils_installed"
    fi

    select_option "Создание нового пользователя с правами sudo (без пароля)" "CREATE_USER" false

    current_hostname=$(hostname)
    echo -e "  Текущее имя хоста: \033[1;34m$current_hostname\033[0m"
    select_option "Изменить имя хоста (hostname) сервера" "CHANGE_HOSTNAME" false

    if grep -q "prohibit-password" /etc/ssh/sshd_config || grep -q "prohibit-password" /etc/ssh/sshd_config.d/secure.conf 2>/dev/null; then
        ssh_configured=true; echo -e "\033[0;32m✓ Настройка SSH (уже настроено)\033[0m"
    else
        ssh_configured=false; select_option "Настройка SSH" "SETUP_SSH" "$ssh_configured"
    fi

    if is_installed fail2ban && systemctl is-active --quiet fail2ban; then
        echo -e "\033[0;32m✓ Настройка Fail2ban (уже настроено)\033[0m"
    else
        select_option "Настройка Fail2ban" "SETUP_FAIL2BAN" false
    fi

    if is_installed ufw && systemctl is-active --quiet ufw; then
        echo -e "\033[0;32m✓ Настройка Firewall (UFW) (уже настроено)\033[0m"
    else
        select_option "Настройка Firewall (UFW)" "SETUP_FIREWALL" false
    fi

    if grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo -e "\033[0;32m✓ Включение TCP BBR (уже настроено)\033[0m"
    else
        select_option "Включение TCP BBR" "SETUP_BBR" false
    fi

    if uname -r | grep -q "xanmod"; then
        echo -e "\033[0;32m✓ Ядро XanMod (уже установлено: $(uname -r))\033[0m"
    else
        select_option "Установка оптимизированного ядра XanMod" "INSTALL_XANMOD" false
    fi

    if grep -q "tcp_fastopen=3" /etc/sysctl.conf; then
        echo -e "\033[0;32m✓ Оптимизация производительности системы (уже настроено)\033[0m"
    else
        select_option "Оптимизация производительности системы" "OPTIMIZE_SYSTEM" false
    fi

    if [ -f /swapfile ] && grep -q "/swapfile" /etc/fstab; then
        echo -e "\033[0;32m✓ Настройка swap (уже настроено)\033[0m"
    else
        select_option "Настройка swap (50% от ОЗУ, ≤3ГБ → swap=2ГБ)" "SETUP_SWAP" false
    fi

    if is_installed systemd-timesyncd && systemctl is-active --quiet systemd-timesyncd; then
        echo -e "\033[0;32m✓ NTP синхронизация (уже настроено)\033[0m"
    else
        select_option "NTP синхронизация" "SETUP_NTP" false
    fi

    if [ -f /etc/logrotate.d/custom ]; then
        echo -e "\033[0;32m✓ Настройка logrotate (уже настроено)\033[0m"
    else
        select_option "Настройка logrotate" "SETUP_LOGROTATE" false
    fi

    if is_installed unattended-upgrades && [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
        echo -e "\033[0;32m✓ Автоматические обновления безопасности (уже настроено)\033[0m"
    else
        select_option "Автоматические обновления безопасности" "SETUP_AUTO_UPDATES" false
    fi

    monitoring_installed=true
    for util in sysstat atop iperf3; do if ! is_installed "$util"; then monitoring_installed=false; break; fi; done
    if [ "$monitoring_installed" = true ]; then
        echo -e "\033[0;32m✓ Инструменты мониторинга (уже установлены)\033[0m"
    else
        select_option "Инструменты мониторинга" "INSTALL_MONITORING" false
    fi

    if is_installed docker-ce && is_installed docker-compose-plugin; then
        echo -e "\033[0;32m✓ Docker и Docker Compose (уже установлены)\033[0m"
    else
        select_option "Docker и Docker Compose" "INSTALL_DOCKER" false
    fi

    current_timezone=$(timedatectl show --property=Timezone --value)
    if [ -n "$current_timezone" ]; then
        echo -e "\033[0;32m✓ Часовой пояс (текущий: $current_timezone)\033[0m"
    else
        select_option "Настройка часового пояса" "SETUP_TIMEZONE" false
    fi

    if locale -a 2>/dev/null | grep -qi "ru_RU.utf8"; then
        echo -e "\033[0;32m✓ Настройка локалей (уже настроены)\033[0m"
    else
        select_option "Настройка локалей (включая русскую)" "SETUP_LOCALES" false
    fi

    select_option "Усиленная безопасность SSH (отключение входа по паролю)" "SECURE_SSH" false
    select_option "Установка и настройка fish shell (Fisher, плагины, Starship, fzf и др.)" "INSTALL_FISH" false

    echo
    print_color yellow "═════════════════════════════════════════"
    print_color yellow "  Выбранные компоненты будут установлены"
    print_color yellow "═════════════════════════════════════════"
    read -r -p "Продолжить? (y/n): " continue_install
    if [[ ! "$continue_install" =~ ^[yY]$ ]]; then echo "Установка отменена."; exit 0; fi
}

# ————————————————————————————————————————————————————————————————————
# Неинтерактивный выбор (печать статуса по переменным)
# ————————————————————————————————————————————————————————————————————
select_components_noninteractive() {
    echo ""
    print_color blue "╔═════════════════════════════════════════╗"
    printf "\033[0;34m║  НАСТРОЙКА VPS НА DEBIAN %-12s ║\033[0m\n" "${DEBIAN_MAJOR} (${DEBIAN_CODENAME})"
    print_color blue "║           НЕИНТЕРАКТИВНЫЙ РЕЖИМ         ║"
    print_color blue "╚═════════════════════════════════════════╝"
    echo ""
    print_color blue "═════════════════════════════════════════"
    print_color blue "  НАСТРОЙКА КОМПОНЕНТОВ ЧЕРЕЗ ПЕРЕМЕННЫЕ"
    print_color blue "═════════════════════════════════════════"

    show_flag(){ local name="$1" flag="$2"; if [ "$flag" = "true" ]; then echo -e "\033[0;32m✓ $name (включено)\033[0m"; else echo -e "\033[0;33m○ $name (отключено)\033[0m"; fi }

    show_flag "Обновление системы" "$UPDATE_SYSTEM"
    show_flag "Базовые утилиты" "$INSTALL_BASE_UTILS"
    if [ "$CREATE_USER" = "true" ]; then echo -e "\033[0;32m✓ Создание нового пользователя (включено)\n  Имя пользователя: ${NEW_USERNAME:-не указано}\033[0m"; else echo -e "\033[0;33m○ Создание нового пользователя (отключено)\033[0m"; fi
    if [ "$CHANGE_HOSTNAME" = "true" ]; then echo -e "\033[0;32m✓ Изменение hostname (включено)\n  Новое имя хоста: ${NEW_HOSTNAME:-не указано}\033[0m"; else echo -e "\033[0;33m○ Изменение hostname (отключено)\033[0m"; fi
    show_flag "Настройка SSH" "$SETUP_SSH"
    show_flag "Настройка Fail2ban" "$SETUP_FAIL2BAN"
    show_flag "Настройка Firewall (UFW)" "$SETUP_FIREWALL"
    show_flag "Включение TCP BBR" "$SETUP_BBR"
    show_flag "Установка ядра XanMod" "$INSTALL_XANMOD"
    show_flag "Оптимизация системы" "$OPTIMIZE_SYSTEM"
    show_flag "Настройка swap" "$SETUP_SWAP"
    show_flag "NTP синхронизация" "$SETUP_NTP"
    show_flag "Настройка logrotate" "$SETUP_LOGROTATE"
    show_flag "Автоматические обновления" "$SETUP_AUTO_UPDATES"
    show_flag "Инструменты мониторинга" "$INSTALL_MONITORING"
    show_flag "Docker и Docker Compose" "$INSTALL_DOCKER"
    show_flag "Настройка часового пояса" "$SETUP_TIMEZONE"
    show_flag "Настройка локалей" "$SETUP_LOCALES"
    show_flag "Усиленная безопасность SSH" "$SECURE_SSH"
    show_flag "Установка fish shell" "$INSTALL_FISH"

    echo
    print_color yellow "═════════════════════════════════════════"
    print_color yellow "  Начинаем установку выбранных компонентов"
    print_color yellow "═════════════════════════════════════════"
}

# ————————————————————————————————————————————————————————————————————
# Запуск выбора компонентов
# ————————————————————————————————————————————————————————————————————
if [ "$NONINTERACTIVE" = "true" ]; then select_components_noninteractive; else select_components; fi

# ————————————————————————————————————————————————————————————————————
# 1. Обновление системы
# ————————————————————————————————————————————————————————————————————
if [ "$UPDATE_SYSTEM" = true ]; then
    step "Обновление системы"
    apt-get update
    apt-get upgrade -y
    apt-get dist-upgrade -y || true
    apt-get autoremove -y
    apt-get clean
fi

# ————————————————————————————————————————————————————————————————————
# 2. Базовые утилиты
# ————————————————————————————————————————————————————————————————————
if [ "$INSTALL_BASE_UTILS" = true ]; then
    step "Установка необходимых утилит"
    require_packages \
        sudo curl wget htop iotop nload iftop \
        git zip unzip mc vim nano ncdu \
        net-tools dnsutils lsof strace \
        cron \
        screen tmux \
        ca-certificates gnupg \
        python3 python3-pip
fi

# ————————————————————————————————————————————————————————————————————
# 3. Создание пользователя (sudo NOPASSWD, SSH ключи)
# ————————————————————————————————————————————————————————————————————
if [ "$CREATE_USER" = true ]; then
    step "Создание нового пользователя с правами sudo"
    require_packages sudo

    if [ "$NONINTERACTIVE" = "true" ]; then
        if [ -z "$NEW_USERNAME" ]; then print_color red "Ошибка: В неинтерактивном режиме необходимо указать NEW_USERNAME"; exit 1; fi
        new_username="$NEW_USERNAME"
    else
        while true; do
            read -r -p "Введите имя нового пользователя: " new_username
            [[ "$new_username" =~ ^[a-z][-a-z0-9_]*$ ]] || { print_color red "Некорректное имя пользователя"; continue; }
            [ ${#new_username} -le 32 ] || { print_color red "Слишком длинное имя (≤32)"; continue; }
            break
        done
    fi

    if [ "$NONINTERACTIVE" = "true" ]; then
        [[ "$new_username" =~ ^[a-z][-a-z0-9_]*$ ]] || { print_color red "Некорректное имя пользователя (NEW_USERNAME)"; exit 1; }
        [ ${#new_username} -le 32 ] || { print_color red "Слишком длинное имя (≤32)"; exit 1; }
    fi

    if id "$new_username" &>/dev/null; then
        echo "Пользователь $new_username уже существует"
    else
        if [ "$NONINTERACTIVE" = "true" ]; then
            useradd -m -s /bin/bash -G sudo "$new_username"
            echo "Пользователь $new_username создан без пароля (только SSH ключи)"
        else
            echo "Будет запрошен пароль для нового пользователя (но sudo без пароля)."
            adduser --gecos "" "$new_username"
            usermod -aG sudo "$new_username"
        fi
    fi

    mkdir -p "/etc/sudoers.d"
    echo "$new_username ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/nopasswd-$new_username"
    echo "root ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/nopasswd-root"
    chmod 440 "/etc/sudoers.d/nopasswd-$new_username" "/etc/sudoers.d/nopasswd-root"

    # SSH каталог
    if [ ! -d "/home/$new_username/.ssh" ]; then
        mkdir -p "/home/$new_username/.ssh" && touch "/home/$new_username/.ssh/authorized_keys"
        chown -R "$new_username:$new_username" "/home/$new_username/.ssh"
        chmod 700 "/home/$new_username/.ssh" && chmod 600 "/home/$new_username/.ssh/authorized_keys"
    fi

    if [ "$NONINTERACTIVE" = "true" ]; then
        if [ -n "$SSH_PUBLIC_KEY" ]; then echo "$SSH_PUBLIC_KEY" >> "/home/$new_username/.ssh/authorized_keys"; ssh_key_added=true; fi
    else
        read -r -p "Добавить SSH ключ для $new_username? (y/n): " add_ssh
        if [[ "$add_ssh" =~ ^[yY]$ ]]; then read -r -p "Введите публичный SSH ключ: " ssh_key; echo "$ssh_key" >> "/home/$new_username/.ssh/authorized_keys"; ssh_key_added=true; fi
    fi
fi

# ————————————————————————————————————————————————————————————————————
# 3.1 Изменение hostname
# ————————————————————————————————————————————————————————————————————
if [ "$CHANGE_HOSTNAME" = true ]; then
    step "Изменение имени хоста"
    current_hostname=$(hostname)
    echo "Текущее имя хоста: $current_hostname"
    if [ "$NONINTERACTIVE" = "true" ]; then
        [ -n "$NEW_HOSTNAME" ] || { print_color red "Ошибка: NEW_HOSTNAME не указан"; exit 1; }
        new_hostname="$NEW_HOSTNAME"
    else
        while true; do
            read -r -p "Введите новое имя хоста: " new_hostname
            [[ "$new_hostname" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])$ ]] || { print_color red "Некорректное имя"; continue; }
            [ ${#new_hostname} -le 63 ] || { print_color red "Слишком длинное имя (≤63)"; continue; }
            break
        done
    fi

    if [ "$NONINTERACTIVE" = "true" ]; then
        [[ "$new_hostname" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])$ ]] || { print_color red "Некорректный NEW_HOSTNAME"; exit 1; }
        [ ${#new_hostname} -le 63 ] || { print_color red "Слишком длинное имя (≤63)"; exit 1; }
    fi

    hostnamectl set-hostname "$new_hostname" || { print_color red "Не удалось установить hostname"; exit 1; }
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/^127\.0\.1\.1\s\+.*/127.0.1.1\t$new_hostname/g" /etc/hosts
    else
        echo -e "127.0.1.1\t$new_hostname" >> /etc/hosts
    fi
    echo "Имя хоста изменено на: $new_hostname (полностью применится после перезагрузки)"
fi

# ————————————————————————————————————————————————————————————————————
# 4. Базовая настройка SSH
# ————————————————————————————————————————————————————————————————————
if [ "$SETUP_SSH" = true ]; then
    step "Настройка базовой безопасности SSH"
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true
    mkdir -p /etc/ssh/sshd_config.d/
    cat > /etc/ssh/sshd_config.d/secure.conf << EOF
# Безопасные настройки SSH
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

# ————————————————————————————————————————————————————————————————————
# 5. Fail2ban
# ————————————————————————————————————————————————————————————————————
if [ "$SETUP_FAIL2BAN" = true ]; then
    step "Настройка Fail2ban"
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

# ————————————————————————————————————————————————————————————————————
# 6. UFW
# ————————————————————————————————————————————————————————————————————
if [ "$SETUP_FIREWALL" = true ]; then
    step "Настройка UFW"
    require_packages ufw
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming
    ufw default allow outgoing
    if ufw app list 2>/dev/null | grep -qi "OpenSSH"; then
        ufw allow OpenSSH
    else
        ufw allow 22/tcp
    fi
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
fi

# ————————————————————————————————————————————————————————————————————
# 7. TCP BBR
# ————————————————————————————————————————————————————————————————————
if [ "$SETUP_BBR" = true ]; then
    step "Включение TCP BBR"
    if ! grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf; then
        cat >> /etc/sysctl.conf << 'EOF'

# Включение TCP BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl -p || true
    fi
fi

# ————————————————————————————————————————————————————————————————————
# 7.1 XanMod ядро (с проверками зависимостей)
# ————————————————————————————————————————————————————————————————————
if [ "$INSTALL_XANMOD" = true ]; then
    step "Установка оптимизированного ядра XanMod"
    require_packages wget gnupg ca-certificates

    mkdir -p /etc/apt/keyrings
    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' \
        > /etc/apt/sources.list.d/xanmod-release.list
    apt-get update

    echo "Определение оптимальной версии ядра XanMod для ЦПУ..."
    kernel_variant="x64v1"; kernel_description="XanMod x64v1 - базовая версия"
    if grep -qi 'avx512' /proc/cpuinfo; then
        kernel_variant="x64v3"; kernel_description="XanMod x64v3 (AVX2/AVX-512)"
    elif grep -qi 'avx2' /proc/cpuinfo; then
        kernel_variant="x64v3"; kernel_description="XanMod x64v3 (AVX2)"
    elif grep -qi 'avx' /proc/cpuinfo; then
        kernel_variant="x64v2"; kernel_description="XanMod x64v2 (AVX)"
    fi

    print_color green "Выбрана версия: $kernel_description"
    print_color blue "Установка linux-xanmod-$kernel_variant..."
    if apt-get install -y "linux-xanmod-$kernel_variant"; then
        print_color green "✓ Ядро XanMod установлено"
        print_color yellow "⚠ Для применения нового ядра потребуется перезагрузка"
        xanmod_installed=true
    else
        print_color red "✗ Ошибка установки linux-xanmod-$kernel_variant. Пробуем linux-xanmod"
        if apt-get install -y linux-xanmod; then
            print_color green "✓ Установлена стандартная версия linux-xanmod"
            print_color yellow "⚠ Для применения нового ядра потребуется перезагрузка"
            xanmod_installed=true
        else
            print_color red "✗ Не удалось установить XanMod. Продолжаем с текущим ядром."
            xanmod_installed=false
        fi
    fi

    require_packages inxi
    if [ "${xanmod_installed:-false}" = true ]; then
        print_color blue "После перезагрузки проверьте: uname -r; inxi -S"
    fi
fi

# ————————————————————————————————————————————————————————————————————
# 8. Оптимизация sysctl
# ————————————————————————————————————————————————————————————————————
if [ "$OPTIMIZE_SYSTEM" = true ]; then
    step "Оптимизация производительности системы"
    if ! grep -q "tcp_fastopen=3" /etc/sysctl.conf; then
        cat >> /etc/sysctl.conf << 'EOF'

# Оптимизация сетевого стека
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

# Оптимизация памяти
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
        sysctl -p || true
    fi
fi

# ————————————————————————————————————————————————————————————————————
# 9. Часовой пояс
# ————————————————————————————————————————————————————————————————————
if [ "$SETUP_TIMEZONE" = true ]; then
    step "Настройка часового пояса"
    echo "1) Europe/Moscow"
    echo "2) Europe/Kiev"
    echo "3) Europe/Berlin"
    echo "4) Europe/London"
    echo "5) America/New_York"
    echo "6) America/Los_Angeles"
    echo "7) Asia/Tokyo"
    echo "8) Asia/Shanghai"
    echo "9) Australia/Sydney"
    echo "10) Ввести свой"
    read -r -p "Выберите часовой пояс (1-10): " tz_choice
    case $tz_choice in
        1) TZ="Europe/Moscow" ;; 2) TZ="Europe/Kiev" ;; 3) TZ="Europe/Berlin" ;; 4) TZ="Europe/London" ;;
        5) TZ="America/New_York" ;; 6) TZ="America/Los_Angeles" ;; 7) TZ="Asia/Tokyo" ;; 8) TZ="Asia/Shanghai" ;;
        9) TZ="Australia/Sydney" ;; 10) read -r -p "Введите TZ (например, Europe/Paris): " TZ ;; *) TZ="UTC" ;;
    esac
    timedatectl set-timezone "$TZ"
    echo "Установлен часовой пояс: $TZ"
fi

# ————————————————————————————————————————————————————————————————————
# 10. NTP / timesyncd
# ————————————————————————————————————————————————————————————————————
if [ "$SETUP_NTP" = true ]; then
    step "Настройка NTP синхронизации"
    require_packages systemd-timesyncd
    systemctl enable systemd-timesyncd
    systemctl start systemd-timesyncd || true
    timedatectl set-ntp true || true
fi

# ————————————————————————————————————————————————————————————————————
# 11. Swap (50% RAM; ≤3ГБ → 2ГБ)
# ————————————————————————————————————————————————————————————————————
if [ "$SETUP_SWAP" = true ]; then
    step "Настройка swap"
    if [ -f /swapfile ]; then swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; sed -i '/\s\/swapfile\s/d' /etc/fstab; fi
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_mem_mb=$((total_mem_kb / 1024))
    swap_size_mb=$((total_mem_mb / 2))
    if [ $total_mem_mb -le 3072 ]; then swap_size_mb=2048; else swap_size_gb=$(((swap_size_mb + 512) / 1024)); swap_size_mb=$((swap_size_gb * 1024)); fi
    echo "Создание swap-файла ${swap_size_mb} МБ"; dd if=/dev/zero of=/swapfile bs=1M count=$swap_size_mb status=none
    chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    if ! grep -q "vm.swappiness=10" /etc/sysctl.conf; then echo "vm.swappiness=10" >> /etc/sysctl.conf; sysctl -p || true; fi
    swapon --show; free -h
fi

# ————————————————————————————————————————————————————————————————————
# 12. Локали (исправлено)
# ————————————————————————————————————————————————————————————————————
if [ "$SETUP_LOCALES" = true ]; then
    step "Настройка локалей"
    require_packages locales

    if [ "$NONINTERACTIVE" = "true" ]; then
        TARGET_LOCALE="$DEFAULT_LOCALE"
    else
        echo "Выберите локаль по умолчанию:"
        echo "1) Русская (ru_RU.UTF-8)"
        echo "2) Английская (en_US.UTF-8)"
        read -r -p "Выберите локаль (1/2): " choice
        if [ "$choice" = "2" ]; then TARGET_LOCALE="en_US.UTF-8"; else TARGET_LOCALE="ru_RU.UTF-8"; fi
    fi

    case "$TARGET_LOCALE" in
        ru_RU.UTF-8|en_US.UTF-8) ;;
        *) TARGET_LOCALE="en_US.UTF-8"; print_color yellow "Неизвестная локаль. Используем en_US.UTF-8";;
    esac

    for loc in ru_RU.UTF-8 en_US.UTF-8; do
        if ! grep -qE "^[#\s]*${loc}\s+UTF-8" /etc/locale.gen; then
            echo "${loc} UTF-8" >> /etc/locale.gen
        else
            sed -i "s/^[#\s]*${loc}\s\+UTF-8/${loc} UTF-8/" /etc/locale.gen
        fi
    done

    locale-gen || { print_color red "Ошибка генерации локалей"; exit 1; }

    lang_code="${TARGET_LOCALE%%.*}"         # ru_RU
    lang_primary="${lang_code%%_*}"          # ru
    update-locale LANG="$TARGET_LOCALE" LANGUAGE="$lang_primary:en"

    printf "\nТекущие локали:\n"; locale || true
    printf "\n/etc/default/locale:\n"; cat /etc/default/locale || true
    print_color yellow "Новые значения LANG/LANGUAGE применятся в новой сессии"
fi

# ————————————————————————————————————————————————————————————————————
# 13. logrotate
# ————————————————————————————————————————————————————————————————————
if [ "$SETUP_LOGROTATE" = true ]; then
    step "Настройка logrotate"
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

# ————————————————————————————————————————————————————————————————————
# 14. Автообновления (Debian-специфичная конфигурация)
# ————————————————————————————————————————————————————————————————————
if [ "$SETUP_AUTO_UPDATES" = true ]; then
    step "Настройка автоматических обновлений безопасности"
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

# ————————————————————————————————————————————————————————————————————
# 15. Docker Engine + Compose plugin (с поддержкой trixie)
# ————————————————————————————————————————————————————————————————————
if [ "$INSTALL_DOCKER" = true ]; then
    step "Установка Docker и Docker Compose"
    # Удаляем возможные конфликтующие пакеты
    apt-get remove -y docker docker-engine docker.io containerd runc podman-docker 2>/dev/null || true

    # Требуемые утилиты
    require_packages ca-certificates curl gnupg lsb-release

    # Ключ Docker
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Репозиторий (пробуем codename; при отсутствии кандидата — фолбэк на bookworm)
    DOCKER_SUITE="$DEBIAN_CODENAME"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${DOCKER_SUITE} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update || true

    candidate=$(apt-cache policy docker-ce | awk '/Candidate:/ {print $2}')
    if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
        print_color yellow "В репозитории Docker нет пакетов для ${DOCKER_SUITE}. Пробуем bookworm."
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update || true
    fi

    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    # docker группа
    if ! getent group docker >/dev/null; then groupadd docker; fi
    if [ -n "${SUDO_USER:-}" ]; then usermod -aG docker "$SUDO_USER" && echo "Пользователь $SUDO_USER добавлен в группу docker."; fi
    if [ "$CREATE_USER" = true ] && [ -n "$new_username" ] && id "$new_username" &>/dev/null; then
        usermod -aG docker "$new_username" && echo "Пользователь $new_username добавлен в группу docker."
    fi

    docker version || true
    docker compose version || true
    echo "Чтобы группа docker применилась: выполните 'newgrp docker' или перелогиньтесь."
fi

# ————————————————————————————————————————————————————————————————————
# 16. Инструменты мониторинга
# ————————————————————————————————————————————————————————————————————
if [ "$INSTALL_MONITORING" = true ]; then
    step "Установка инструментов мониторинга"
    require_packages sysstat atop iperf3 nmon smartmontools lm-sensors
    if [ -f /etc/default/sysstat ]; then
        sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
        systemctl enable sysstat
        systemctl restart sysstat
    fi
fi

# ————————————————————————————————————————————————————————————————————
# 17. Усиленная безопасность SSH (только по ключам)
# ————————————————————————————————————————————————————————————————————
if [ "$SECURE_SSH" = true ]; then
    step "Усиленная безопасность SSH"
    ssh_key_exists=false
    if [ "$CREATE_USER" = true ] && [ "$ssh_key_added" = true ]; then
        ssh_key_exists=true
    else
        if [ -s "/root/.ssh/authorized_keys" ] || { [ -n "${SUDO_USER:-}" ] && [ -s "/home/$SUDO_USER/.ssh/authorized_keys" ]; }; then
            ssh_key_exists=true
        fi
    fi

    if [ "$ssh_key_exists" = false ] && [ "$NONINTERACTIVE" != "true" ]; then
        print_color red "ВНИМАНИЕ! Не обнаружено SSH ключей. Отключение пароля приведёт к потере доступа!"
        read -r -p "Продолжить? (y/n): " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || { echo "Отмена изменений SSH."; SECURE_SSH=false; }
    fi

    if [ "$SECURE_SSH" = true ]; then
        cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null || true
        cat > /etc/ssh/sshd_config.d/security.conf << 'EOF'
# Усиленные настройки безопасности SSH
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
EOF
        systemctl restart sshd || systemctl restart ssh || true
        print_color green "Парольный вход отключён. Доступ только по SSH ключу."
    fi
fi

# ————————————————————————————————————————————————————————————————————
# 18. Полная настройка fish shell (root и новый пользователь)
# ————————————————————————————————————————————————————————————————————
if [ "$INSTALL_FISH" = true ]; then
    step "Установка и настройка fish shell"
    require_packages fish fzf fd-find bat curl

    # Symlink для fd и bat (в Debian бинарники fdfind/batcat)
    if command -v fdfind >/dev/null && ! command -v fd >/dev/null; then ln -sf "$(command -v fdfind)" /usr/local/bin/fd; fi
    if command -v batcat >/dev/null && ! command -v bat >/dev/null; then ln -sf "$(command -v batcat)" /usr/local/bin/bat; fi

    # Starship
    step "Установка Starship prompt"
    curl -sS https://starship.rs/install.sh | sh -s -- -y

    # Конфиг для root
    mkdir -p /root/.config/fish/functions /root/.config/fish/completions
    cat > /root/.config/fish/config.fish << 'ROOT_CONFIG_EOF'
set -gx LANG ru_RU.UTF-8
set -gx LC_ALL ru_RU.UTF-8
alias ll='ls -la'; alias la='ls -A'; alias l='ls'; alias cls='clear'; alias ..='cd ..'; alias ...='cd ../..'
if type -q bat; alias cat='bat --paging=never'; else if type -q batcat; alias cat='batcat --paging=never'; end; end
if type -q fd; alias find='fd'; else if type -q fdfind; alias find='fdfind'; end; end
set -U fish_greeting
set fish_key_bindings fish_default_key_bindings
set fish_autosuggestion_enabled 1
set -gx FZF_DEFAULT_COMMAND 'fd --type f --strip-cwd-prefix 2>/dev/null || find . -type f'
set -gx FZF_CTRL_T_COMMAND $FZF_DEFAULT_COMMAND
starship init fish | source
ROOT_CONFIG_EOF

    cat > /root/.config/fish/functions/fish_greeting.fish << 'ROOT_GREETING_EOF'
function fish_greeting
    echo "🐧 Debian $(uname -r) [ROOT] - "(date '+%Y-%m-%d %H:%M')""
end
ROOT_GREETING_EOF

    mkdir -p /root/.config/fish/completions
    curl -sL https://raw.githubusercontent.com/docker/cli/master/contrib/completion/fish/docker.fish -o /root/.config/fish/completions/docker.fish
    curl -sL https://raw.githubusercontent.com/docker/compose/master/contrib/completion/fish/docker-compose.fish -o /root/.config/fish/completions/docker-compose.fish

    # Fisher + плагины для root
    cat > /tmp/install_fisher_root.fish << 'FISHER_ROOT'
#!/usr/bin/env fish
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
fisher install jorgebucaran/fisher jethrokuan/z PatrickF1/fzf.fish jorgebucaran/autopair.fish franciscolourenco/done edc/bass
FISHER_ROOT
    chmod +x /tmp/install_fisher_root.fish; fish /tmp/install_fisher_root.fish; rm -f /tmp/install_fisher_root.fish

    chsh -s /usr/bin/fish root || true

    # Пользователь
    if [ "$CREATE_USER" = true ] && [ -n "$new_username" ] && id "$new_username" &>/dev/null; then
        step "Настройка fish для пользователя $new_username"
        su - "$new_username" -c "mkdir -p ~/.config/fish/functions ~/.config/fish/completions"
        cat > /tmp/user_config.fish << 'USER_CONFIG'
set -gx LANG ru_RU.UTF-8
set -gx LC_ALL ru_RU.UTF-8
alias ll='ls -la'; alias la='ls -A'; alias l='ls'; alias cls='clear'; alias ..='cd ..'; alias ...='cd ../..'
if type -q bat; alias cat='bat --paging=never'; else if type -q batcat; alias cat='batcat --paging=never'; end; end
if type -q fd; alias find='fd'; else if type -q fdfind; alias find='fdfind'; end; end
set -U fish_greeting
set fish_key_bindings fish_default_key_bindings
set fish_autosuggestion_enabled 1
set -gx FZF_DEFAULT_COMMAND 'fd --type f --strip-cwd-prefix 2>/dev/null || find . -type f'
set -gx FZF_CTRL_T_COMMAND $FZF_DEFAULT_COMMAND
starship init fish | source
USER_CONFIG
        cat > /tmp/user_greeting.fish << 'USER_GREETING'
function fish_greeting
    echo "🐧 Debian - "(date '+%Y-%m-%d %H:%M')""
end
USER_GREETING
        cp /tmp/user_config.fish "/home/$new_username/.config/fish/config.fish"
        cp /tmp/user_greeting.fish "/home/$new_username/.config/fish/functions/fish_greeting.fish"
        chown -R "$new_username:$new_username" "/home/$new_username/.config/fish"
        rm -f /tmp/user_config.fish /tmp/user_greeting.fish
        su - "$new_username" -c "curl -sL https://raw.githubusercontent.com/docker/cli/master/contrib/completion/fish/docker.fish -o ~/.config/fish/completions/docker.fish"
        su - "$new_username" -c "curl -sL https://raw.githubusercontent.com/docker/compose/master/contrib/completion/fish/docker-compose.fish -o ~/.config/fish/completions/docker-compose.fish"
        cat > /tmp/install_fisher_user.fish << 'FISHER_USER'
#!/usr/bin/env fish
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
fisher install jorgebucaran/fisher jethrokuan/z PatrickF1/fzf.fish jorgebucaran/autopair.fish franciscolourenco/done edc/bass
FISHER_USER
        chmod +x /tmp/install_fisher_user.fish
        su - "$new_username" -c "fish /tmp/install_fisher_user.fish"
        rm -f /tmp/install_fisher_user.fish
        chsh -s /usr/bin/fish "$new_username" || true
    fi

    echo -e "\033[0;32m✓ Fish shell настроен\033[0m"
    echo -e "\033[0;33m⚠ Перезапустите терминал или выполните: exec fish\033[0m"
fi

# ————————————————————————————————————————————————————————————————————
# 19. Очистка
# ————————————————————————————————————————————————————————————————————
if [ "$UPDATE_SYSTEM" = true ]; then
    step "Очистка временных файлов"
    apt-get clean
    journalctl --vacuum-time=1d || true
fi

# ————————————————————————————————————————————————————————————————————
# Итоговая информация
# ————————————————————————————————————————————————————————————————————
step "Настройка завершена!"
echo -e "\n\033[1;34m=== Система ===\033[0m"; uname -a
echo -e "\n\033[1;34m=== Хостнейм ===\033[0m"; hostname
echo -e "\n\033[1;34m=== Память/Swap ===\033[0m"; free -h
echo -e "\n\033[1;34m=== Диски ===\033[0m"; df -h
echo -e "\n\033[1;34m=== Сеть ===\033[0m"; ip a

if [ "$CREATE_USER" = true ]; then
    echo -e "\n\033[1;33mПользователь $new_username может выполнять sudo без пароля.\033[0m"
fi
if [ "$INSTALL_DOCKER" = true ]; then
    echo -e "\n\033[1;33mЕсли добавили пользователя в группу docker, перелогиньтесь или выполните: newgrp docker\033[0m"
fi
if [ "$CHANGE_HOSTNAME" = true ]; then
    echo -e "\n\033[1;33mИмя хоста изменено на: $(hostname). Полное применение — после перезагрузки.\033[0m"
fi
if [ "${xanmod_installed:-false}" = true ]; then
    echo -e "\n\033[1;33mЯдро XanMod установлено. Для активации перезагрузите систему.\033[0m"
fi
if [ "$SECURE_SSH" = true ]; then
    echo -e "\n\033[1;31mВНИМАНИЕ: Вход по паролю отключён. Доступ только по SSH ключу!\033[0m"
    if [ "$CREATE_USER" = true ]; then
        echo -e "\033[1;33mПример подключения: ssh $new_username@$(hostname -I | awk '{print $1}')\033[0m"
    fi
fi

echo -e "\n\033[1;32mРекомендуется перезагрузить систему.\033[0m"
if [ "$NONINTERACTIVE" = "true" ]; then
    echo "NONINTERACTIVE=true — перезагрузку нужно выполнить вручную: sudo reboot"
else
    read -r -p "Перезагрузить сейчас? (y/n): " reboot_now
    if [[ "$reboot_now" =~ ^[yY]$ ]]; then
        echo "Перезагрузка..."
        if command -v systemctl >/dev/null 2>&1; then systemctl reboot; elif command -v shutdown >/dev/null 2>&1; then shutdown -r now; else reboot; fi
    else
        echo "Для ручной перезагрузки: sudo reboot"
    fi
fi
