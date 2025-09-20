#!/bin/bash
# Скрипт настройки Debian 12/13
# Автоматическая настройка системы, оптимизация производительности и безопасности

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен с правами root"
    exit 1
fi

# Поддержка неинтерактивного режима через переменные окружения
# Примеры запуска скрипта из интернета:
#  - bash/zsh: bash <(curl -fsSL https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-vps.sh)
#  - fish:  curl -fsSL https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-vps.sh | bash
# Неинтерактивно (пример):
#  NONINTERACTIVE=true NEW_USERNAME=admin INSTALL_FISH=true \
#    curl -fsSL https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-vps.sh | bash

export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}

# Определение версии Debian
if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    echo "Не удалось определить версию операционной системы"
    exit 1
fi

if [ "${ID}" != "debian" ]; then
    echo "Этот скрипт предназначен для Debian 12 (Bookworm) и Debian 13 (Trixie)"
    exit 1
fi

DEBIAN_VERSION_MAJOR="${VERSION_ID%%.*}"
case "${DEBIAN_VERSION_MAJOR}" in
    12)
        DEBIAN_CODENAME="${VERSION_CODENAME:-bookworm}"
        ;;
    13)
        DEBIAN_CODENAME="${VERSION_CODENAME:-trixie}"
        ;;
    *)
        echo "Обнаружена неподдерживаемая версия Debian: ${VERSION_ID:-неизвестно}"
        echo "Поддерживаются только Debian 12 (Bookworm) и Debian 13 (Trixie)."
        exit 1
        ;;
esac

DEBIAN_CODENAME_TITLE="${DEBIAN_CODENAME^}"
DEBIAN_VERSION_HUMAN="Debian ${DEBIAN_VERSION_MAJOR} (${DEBIAN_CODENAME_TITLE})"

export DEBIAN_VERSION_MAJOR
export DEBIAN_CODENAME
export DEBIAN_VERSION_HUMAN

# Переменные для неинтерактивного режима
NONINTERACTIVE=${NONINTERACTIVE:-false}
NEW_USERNAME=${NEW_USERNAME:-""}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-""}
NEW_HOSTNAME=${NEW_HOSTNAME:-""}
# Дополнительные переменные для неинтерактивного режима
# Пример: SETUP_TIMEZONE=true TIMEZONE=Europe/Berlin
TIMEZONE=${TIMEZONE:-""}
# Пример: SETUP_LOCALES=true LOCALE_DEFAULT=ru_RU.UTF-8 (или en_US.UTF-8)
LOCALE_DEFAULT=${LOCALE_DEFAULT:-""}
# Пример: AUTO_REBOOT=true (перезагрузка без запроса в конце)
AUTO_REBOOT=${AUTO_REBOOT:-false}

# Функция для вывода текущего шага
step() {
    echo -e "\n\033[1;32m>>> $1\033[0m"
}

# Функция для проверки, установлен ли пакет
is_installed() {
    dpkg -l | grep -q "^ii  $1"
    return $?
}

# Функция для вывода цветного текста
print_color() {
    case "$1" in
        "red") color="\033[0;31m" ;;
        "green") color="\033[0;32m" ;;
        "yellow") color="\033[0;33m" ;;
        "blue") color="\033[0;34m" ;;
        "reset") color="\033[0m" ;;
        *) color="\033[0m" ;;
    esac
    echo -e "${color}$2\033[0m"
}

# Проверяет наличие локали с учетом разных написаний
locale_exists() {
    local candidate input="$1"
    if [ -z "$input" ]; then
        return 1
    fi

    for candidate in \
        "$input" \
        "${input/.UTF-8/.utf8}" \
        "${input/.utf8/.UTF-8}" \
        "${input//-/_}" \
        "${input/.UTF-8/.utf8//-/_}" \
        "${input/.utf8/.UTF-8//-/_}"; do
        if [ -z "$candidate" ]; then
            continue
        fi
        if locale -a 2>/dev/null | grep -iq "^${candidate}$"; then
            return 0
        fi
    done

    return 1
}

# Экранирование специальных символов для sed
escape_sed_pattern() {
    printf '%s' "$1" | sed 's/[.[\*^$(){}?+|\\/-]/\\&/g'
}

# Обеспечивает наличие указанной локали в системе
ensure_locale() {
    local locale_name="$1"
    local charset="${2:-UTF-8}"

    if [ -z "$locale_name" ]; then
        return 1
    fi

    if locale_exists "$locale_name"; then
        return 0
    fi

    if [ ! -f /etc/locale.gen ]; then
        return 1
    fi

    local escaped
    escaped="$(escape_sed_pattern "$locale_name")"

    if grep -iq "^#? *${escaped}[[:space:]]" /etc/locale.gen; then
        sed -i -E "s/^# *${escaped}[[:space:]]+/${locale_name} /I" /etc/locale.gen
    else
        printf '%s %s\n' "$locale_name" "$charset" >> /etc/locale.gen
    fi

    locale-gen "$locale_name" >/dev/null 2>&1 || return 1

    if locale_exists "$locale_name"; then
        return 0
    fi

    return 1
}

# Переменные для выбора компонентов
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

# Инициализация переменных
new_username=""
ssh_key_added=false
xanmod_installed=false
kernel_variant=""
xanmod_installed_version=""

# Текущая локаль системы для последующего использования (fish, оболочка)
SYSTEM_LOCALE_DEFAULT="$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}' | tail -n1)"
if [ -z "$SYSTEM_LOCALE_DEFAULT" ] || [ "$SYSTEM_LOCALE_DEFAULT" = "C" ] || [ "$SYSTEM_LOCALE_DEFAULT" = "POSIX" ]; then
    SYSTEM_LOCALE_DEFAULT="en_US.UTF-8"
fi

# Набор пакетов мониторинга с учетом версии Debian.
MONITORING_PACKAGES=(sysstat atop iperf3 nmon smartmontools lm-sensors)

# Функция для выбора компонентов
select_components() {
    clear
    echo ""
    print_color "blue" "╔═════════════════════════════════════════╗"
    print_color "blue" "$(printf '║ %-37s ║' "НАСТРОЙКА: ${DEBIAN_VERSION_HUMAN}")"
    print_color "blue" "╚═════════════════════════════════════════╝"
    echo ""
    
    # Функция для выбора опции
    select_option() {
        local option="$1"
        local var_name="$2"
        local already_installed="$3"
        
        if [ "$already_installed" = true ]; then
            echo -e "\033[0;32m✓ $option (уже установлено)\033[0m"
            return 0
        fi
        
        if [ "${!var_name}" = true ]; then
            echo -ne "\033[0;32m✓\033[0m $option (y/n): "
        else
            echo -ne "\033[0;33m○\033[0m $option (y/n): "
        fi
        
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            eval "$var_name=true"
            echo -e "  \033[0;32m✓ Выбрано\033[0m"
        else
            eval "$var_name=false"
            echo "  ○ Пропущено"
        fi
        return 0
    }
    
    print_color "blue" "═════════════════════════════════════════"
    print_color "blue" "  ВЫБЕРИТЕ КОМПОНЕНТЫ ДЛЯ УСТАНОВКИ"
    print_color "blue" "═════════════════════════════════════════"
    echo

    # Проверка, была ли система обновлена недавно
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
        if ! is_installed $util; then
            base_utils_installed=false
            break
        fi
    done
    
    if [ "$base_utils_installed" = true ]; then
        echo -e "\033[0;32m✓ Базовые утилиты (уже установлены)\033[0m"
    else
        select_option "Базовые утилиты" "INSTALL_BASE_UTILS" "$base_utils_installed"
    fi
    
    # Проверка создания пользователя с sudo
    select_option "Создание нового пользователя с правами sudo (без пароля)" "CREATE_USER" "false"
    
    # Проверка изменения имени хоста (hostname)
    current_hostname=$(hostname)
    echo -e "  Текущее имя хоста: \033[1;34m$current_hostname\033[0m"
    select_option "Изменить имя хоста (hostname) сервера" "CHANGE_HOSTNAME" "false"
    
    if { [ -f /etc/ssh/sshd_config ] && grep -q "prohibit-password" /etc/ssh/sshd_config; } || grep -q "prohibit-password" /etc/ssh/sshd_config.d/secure.conf 2>/dev/null; then
        ssh_configured=true
        echo -e "\033[0;32m✓ Настройка SSH (уже настроено)\033[0m"
    else
        ssh_configured=false
        select_option "Настройка SSH" "SETUP_SSH" "$ssh_configured"
    fi
    
    if is_installed fail2ban && systemctl is-active --quiet fail2ban; then
        fail2ban_configured=true
        echo -e "\033[0;32m✓ Настройка Fail2ban (уже настроено)\033[0m"
    else
        fail2ban_configured=false
        select_option "Настройка Fail2ban" "SETUP_FAIL2BAN" "$fail2ban_configured"
    fi
    
    if is_installed ufw && systemctl is-active --quiet ufw; then
        firewall_configured=true
        echo -e "\033[0;32m✓ Настройка Firewall (UFW) (уже настроено)\033[0m"
    else
        firewall_configured=false
        select_option "Настройка Firewall (UFW)" "SETUP_FIREWALL" "$firewall_configured"
    fi
    
    # Проверка BBR через текущие значения sysctl или конфиги в /etc/sysctl.d
    bbr_configured=false
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] || \
       grep -qs "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || \
       grep -qs "tcp_congestion_control=bbr" /etc/sysctl.d/*.conf 2>/dev/null; then
        bbr_configured=true
        echo -e "\033[0;32m✓ Включение TCP BBR (уже настроено)\033[0m"
    else
        select_option "Включение TCP BBR" "SETUP_BBR" "$bbr_configured"
    fi
    
    # Проверка установки XanMod ядра
    if uname -r | grep -q "xanmod"; then
        xanmod_installed=true
        current_kernel_full="$(uname -r)"
        echo -e "\033[0;32m✓ Ядро XanMod (уже установлено: ${current_kernel_full})\033[0m"
        xanmod_installed_version=$(dpkg-query -W -f='${Version}' linux-xanmod 2>/dev/null)
        if [ -z "$xanmod_installed_version" ]; then
            xanmod_installed_version=$(dpkg -l 'linux-xanmod*' 2>/dev/null | awk '/^ii/{print $3; exit}')
        fi
        detected_variant=$(echo "$current_kernel_full" | sed -n 's/.*-\(x64v[0-9]\)-xanmod.*/\1/p')
        if [ -n "$detected_variant" ]; then
            kernel_variant="$detected_variant"
        fi
    else
        xanmod_installed=false
        select_option "Установка оптимизированного ядра XanMod" "INSTALL_XANMOD" "$xanmod_installed"
    fi
    
    # Проверка оптимизаций: по текущим значениям или наличию нашего конфигурационного файла
    system_optimized=false
    if [ "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)" = "3" ] || \
       [ -f /etc/sysctl.d/99-optimization.conf ]; then
        system_optimized=true
        echo -e "\033[0;32m✓ Оптимизация производительности системы (уже настроено)\033[0m"
    else
        select_option "Оптимизация производительности системы" "OPTIMIZE_SYSTEM" "$system_optimized"
    fi
    
    if [ -f /swapfile ] && grep -q "/swapfile" /etc/fstab; then
        swap_configured=true
        echo -e "\033[0;32m✓ Настройка swap (уже настроено)\033[0m"
    else
        swap_configured=false
        select_option "Настройка swap (50% от ОЗУ). Если ОЗУ меньше или равно 3 ГБ, устанавливаем swap = 2 ГБ" "SETUP_SWAP" "$swap_configured"
    fi
    
    if is_installed systemd-timesyncd && systemctl is-active --quiet systemd-timesyncd; then
        ntp_configured=true
        echo -e "\033[0;32m✓ NTP синхронизация (уже настроено)\033[0m"
    else
        ntp_configured=false
        select_option "NTP синхронизация" "SETUP_NTP" "$ntp_configured"
    fi
    
    if [ -f /etc/logrotate.d/custom ]; then
        logrotate_configured=true
        echo -e "\033[0;32m✓ Настройка logrotate (уже настроено)\033[0m"
    else
        logrotate_configured=false
        select_option "Настройка logrotate" "SETUP_LOGROTATE" "$logrotate_configured"
    fi
    
    if is_installed unattended-upgrades && [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
        auto_updates_configured=true
        echo -e "\033[0;32m✓ Автоматические обновления безопасности (уже настроено)\033[0m"
    else
        auto_updates_configured=false
        select_option "Автоматические обновления безопасности" "SETUP_AUTO_UPDATES" "$auto_updates_configured"
    fi
    
    monitoring_installed=true
    for util in "${MONITORING_PACKAGES[@]}"; do
        if ! is_installed "$util"; then
            monitoring_installed=false
            break
        fi
    done
    
    if [ "$monitoring_installed" = true ]; then
        echo -e "\033[0;32m✓ Инструменты мониторинга (уже установлены)\033[0m"
    else
        select_option "Инструменты мониторинга" "INSTALL_MONITORING" "$monitoring_installed"
    fi
    
    docker_installed=false
    if is_installed docker-ce && is_installed docker-compose-plugin; then
        docker_installed=true
        echo -e "\033[0;32m✓ Docker и Docker Compose (уже установлены)\033[0m"
    else
        select_option "Docker и Docker Compose" "INSTALL_DOCKER" "$docker_installed"
    fi
    
    current_timezone=$(timedatectl show --property=Timezone --value)
    if [ -n "$current_timezone" ]; then
        echo -e "  Текущий часовой пояс: \033[1;34m$current_timezone\033[0m"
        timezone_option="Настройка часового пояса (текущий: $current_timezone)"
    else
        timezone_option="Настройка часового пояса"
    fi
    select_option "$timezone_option" "SETUP_TIMEZONE" "false"
    
    # Проверка статуса русской локали
    locales_set=false
    if locale -a 2>/dev/null | grep -q "ru_RU.utf8"; then
        locales_set=true
        echo -e "\033[0;32m✓ Настройка локалей (уже настроены)\033[0m"
    else
        select_option "Настройка локалей (включая русскую)" "SETUP_LOCALES" "$locales_set"
    fi
    
    # Проверка усиленной безопасности SSH
    select_option "Усиленная безопасность SSH (отключение входа по паролю)" "SECURE_SSH" "false"
    
    # Добавляю выбор установки и настройки fish shell
    select_option "Установка и настройка fish shell (Fisher, плагины, Starship, fzf и др.)" "INSTALL_FISH" "false"
    
    echo
    print_color "yellow" "═════════════════════════════════════════"
    print_color "yellow" "  Выбранные компоненты будут установлены"
    print_color "yellow" "═════════════════════════════════════════"
    read -r -p "Продолжить? (y/n): " continue_install
    if [[ "$continue_install" != "y" && "$continue_install" != "Y" ]]; then
        echo "Установка отменена."
        exit 0
    fi
}

# Функция для неинтерактивного выбора компонентов
select_components_noninteractive() {
    echo ""
    print_color "blue" "╔═════════════════════════════════════════╗"
    print_color "blue" "$(printf '║ %-37s ║' "НАСТРОЙКА: ${DEBIAN_VERSION_HUMAN}")"
    print_color "blue" "$(printf '║ %-37s ║' "НЕИНТЕРАКТИВНЫЙ РЕЖИМ")"
    print_color "blue" "╚═════════════════════════════════════════╝"
    echo ""
    
    print_color "blue" "═════════════════════════════════════════"
    print_color "blue" "  НАСТРОЙКА КОМПОНЕНТОВ ЧЕРЕЗ ПЕРЕМЕННЫЕ"
    print_color "blue" "═════════════════════════════════════════"
    echo
    
    # Устанавливаем компоненты на основе переменных окружения
    # Если переменная не установлена, используем значение по умолчанию false
    
    # Обновление системы
    if [ "$UPDATE_SYSTEM" = "true" ]; then
        echo -e "\033[0;32m✓ Обновление системы (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Обновление системы (отключено)\033[0m"
    fi
    
    # Базовые утилиты
    if [ "$INSTALL_BASE_UTILS" = "true" ]; then
        echo -e "\033[0;32m✓ Базовые утилиты (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Базовые утилиты (отключено)\033[0m"
    fi
    
    # Создание пользователя
    if [ "$CREATE_USER" = "true" ]; then
        echo -e "\033[0;32m✓ Создание нового пользователя (включено)"
        if [ -n "$NEW_USERNAME" ]; then
            echo -e "  Имя пользователя: $NEW_USERNAME\033[0m"
        else
            echo -e "  (имя пользователя не указано)\033[0m"
        fi
    else
        echo -e "\033[0;33m○ Создание нового пользователя (отключено)\033[0m"
    fi
    
    # Изменение hostname
    if [ "$CHANGE_HOSTNAME" = "true" ]; then
        echo -e "\033[0;32m✓ Изменение hostname (включено)"
        if [ -n "$NEW_HOSTNAME" ]; then
            echo -e "  Новое имя хоста: $NEW_HOSTNAME\033[0m"
        else
            echo -e "  (имя хоста не указано)\033[0m"
        fi
    else
        echo -e "\033[0;33m○ Изменение hostname (отключено)\033[0m"
    fi
    
    # SSH
    if [ "$SETUP_SSH" = "true" ]; then
        echo -e "\033[0;32m✓ Настройка SSH (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Настройка SSH (отключено)\033[0m"
    fi
    
    # Fail2ban
    if [ "$SETUP_FAIL2BAN" = "true" ]; then
        echo -e "\033[0;32m✓ Настройка Fail2ban (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Настройка Fail2ban (отключено)\033[0m"
    fi
    
    # Firewall
    if [ "$SETUP_FIREWALL" = "true" ]; then
        echo -e "\033[0;32m✓ Настройка Firewall (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Настройка Firewall (отключено)\033[0m"
    fi
    
    # BBR
    if [ "$SETUP_BBR" = "true" ]; then
        echo -e "\033[0;32m✓ Включение TCP BBR (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Включение TCP BBR (отключено)\033[0m"
    fi
    
    # XanMod
    if [ "$INSTALL_XANMOD" = "true" ]; then
        echo -e "\033[0;32m✓ Установка ядра XanMod (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Установка ядра XanMod (отключено)\033[0m"
    fi
    
    # Оптимизация системы
    if [ "$OPTIMIZE_SYSTEM" = "true" ]; then
        echo -e "\033[0;32m✓ Оптимизация системы (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Оптимизация системы (отключено)\033[0m"
    fi
    
    # Swap
    if [ "$SETUP_SWAP" = "true" ]; then
        echo -e "\033[0;32m✓ Настройка swap (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Настройка swap (отключено)\033[0m"
    fi
    
    # NTP
    if [ "$SETUP_NTP" = "true" ]; then
        echo -e "\033[0;32m✓ NTP синхронизация (включено)\033[0m"
    else
        echo -e "\033[0;33m○ NTP синхронизация (отключено)\033[0m"
    fi
    
    # Logrotate
    if [ "$SETUP_LOGROTATE" = "true" ]; then
        echo -e "\033[0;32m✓ Настройка logrotate (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Настройка logrotate (отключено)\033[0m"
    fi
    
    # Автообновления
    if [ "$SETUP_AUTO_UPDATES" = "true" ]; then
        echo -e "\033[0;32m✓ Автоматические обновления (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Автоматические обновления (отключено)\033[0m"
    fi
    
    # Мониторинг
    if [ "$INSTALL_MONITORING" = "true" ]; then
        echo -e "\033[0;32m✓ Инструменты мониторинга (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Инструменты мониторинга (отключено)\033[0m"
    fi
    
    # Docker
    if [ "$INSTALL_DOCKER" = "true" ]; then
        echo -e "\033[0;32m✓ Docker и Docker Compose (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Docker и Docker Compose (отключено)\033[0m"
    fi
    
    # Часовой пояс
    if [ "$SETUP_TIMEZONE" = "true" ]; then
        echo -e "\033[0;32m✓ Настройка часового пояса (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Настройка часового пояса (отключено)\033[0m"
    fi
    
    # Локали
    if [ "$SETUP_LOCALES" = "true" ]; then
        echo -e "\033[0;32m✓ Настройка локалей (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Настройка локалей (отключено)\033[0m"
    fi
    
    # Усиленная безопасность SSH
    if [ "$SECURE_SSH" = "true" ]; then
        echo -e "\033[0;32m✓ Усиленная безопасность SSH (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Усиленная безопасность SSH (отключено)\033[0m"
    fi
    
    # Fish shell
    if [ "$INSTALL_FISH" = "true" ]; then
        echo -e "\033[0;32m✓ Установка fish shell (включено)\033[0m"
    else
        echo -e "\033[0;33m○ Установка fish shell (отключено)\033[0m"
    fi
    
    echo
    print_color "yellow" "═════════════════════════════════════════"
    print_color "yellow" "  Начинаем установку выбранных компонентов"
    print_color "yellow" "═════════════════════════════════════════"
    echo
}

# Вызываем выбор компонентов
if [ "$NONINTERACTIVE" = "true" ]; then
    select_components_noninteractive
else
    select_components
fi

# 1. Обновление системы
if [ "$UPDATE_SYSTEM" = true ]; then
    step "Обновление системы"
    apt update
    apt upgrade -y
    apt full-upgrade -y
    apt autoremove -y
    apt clean
fi

# 2. Установка необходимых утилит и инструментов
if [ "$INSTALL_BASE_UTILS" = true ]; then
    step "Установка необходимых утилит"
    apt install -y \
        sudo curl wget htop iotop nload iftop \
        git zip unzip mc vim nano ncdu \
        net-tools dnsutils lsof strace \
        cron \
        screen tmux \
        ca-certificates gnupg apt-transport-https \
        python3 python3-pip
fi

# 3. Создание нового пользователя с правами sudo (перемещено в начало скрипта)
if [ "$CREATE_USER" = true ]; then
    step "Создание нового пользователя с правами sudo"
    
    # Установка sudo, если не установлен
    if ! is_installed sudo; then
        apt install -y sudo
    fi
    
    # В неинтерактивном режиме используем переменную NEW_USERNAME
    if [ "$NONINTERACTIVE" = "true" ]; then
        if [ -z "$NEW_USERNAME" ]; then
            print_color "red" "Ошибка: В неинтерактивном режиме необходимо указать NEW_USERNAME"
            exit 1
        fi
        new_username="$NEW_USERNAME"
    else
        # Запрос имени пользователя с проверкой корректности
        while true; do
            read -r -p "Введите имя нового пользователя: " new_username
            
            # Проверка корректности имени пользователя
            if [[ ! $new_username =~ ^[a-z][-a-z0-9_]*$ ]]; then
                print_color "red" "Ошибка: Имя пользователя должно:"
                print_color "red" "- Начинаться с буквы в нижнем регистре"
                print_color "red" "- Содержать только буквы в нижнем регистре, цифры, дефисы и подчеркивания"
                print_color "red" "- Не содержать пробелов или специальных символов"
                continue
            fi
            
            # Проверка длины имени пользователя
            if [ ${#new_username} -gt 32 ]; then
                print_color "red" "Ошибка: Имя пользователя слишком длинное (максимум 32 символа)"
                continue
            fi
            
            # Если дошли до этой точки, имя пользователя корректно
            break
        done
    fi
    
    # Проверка корректности имени пользователя в неинтерактивном режиме
    if [ "$NONINTERACTIVE" = "true" ]; then
        if [[ ! $new_username =~ ^[a-z][-a-z0-9_]*$ ]]; then
            print_color "red" "Ошибка: Некорректное имя пользователя в переменной NEW_USERNAME"
            print_color "red" "Имя пользователя должно начинаться с буквы в нижнем регистре"
            exit 1
        fi
        
        if [ ${#new_username} -gt 32 ]; then
            print_color "red" "Ошибка: Имя пользователя слишком длинное (максимум 32 символа)"
            exit 1
        fi
    fi
    
    # Проверка, существует ли уже такой пользователь
    if id "$new_username" &>/dev/null; then
        echo "Пользователь $new_username уже существует"
        if [ "$NONINTERACTIVE" != "true" ]; then
            read -r -p "Продолжить настройку sudo для этого пользователя? (y/n): " configure_sudo
            if [[ "$configure_sudo" != "y" && "$configure_sudo" != "Y" ]]; then
                echo "Пропуск создания пользователя."
                continue
            fi
        fi
        
        # Настройка sudo без пароля для существующего пользователя
        if [ ! -d "/etc/sudoers.d" ]; then
            mkdir -p /etc/sudoers.d
        fi
        
        echo "$new_username ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/nopasswd-$new_username
        echo "root ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/nopasswd-root
        
        # Установка правильных прав доступа
        chmod 440 /etc/sudoers.d/nopasswd-$new_username
        chmod 440 /etc/sudoers.d/nopasswd-root
        
        echo "Настроено выполнение команд sudo без пароля для пользователей $new_username и root"
    else
        # Создание нового пользователя
        if [ "$NONINTERACTIVE" = "true" ]; then
            # В неинтерактивном режиме создаем пользователя без пароля
            useradd -m -s /bin/bash -G sudo $new_username
            echo "Пользователь $new_username создан без пароля (только SSH ключи)"
        else
            # Создание нового пользователя (с запросом пароля)
            echo "Будет запрошен и установлен пароль для нового пользователя."
            echo "Примечание: Даже после установки пароля, для sudo пароль запрашиваться не будет."
            adduser --gecos "" $new_username
        fi
        
        # Добавление пользователя в группу sudo
        usermod -aG sudo $new_username
        echo "Пользователь $new_username создан и добавлен в группу sudo"
        
        # Настройка sudo без пароля для нового пользователя и root
        if [ ! -d "/etc/sudoers.d" ]; then
            mkdir -p /etc/sudoers.d
        fi
        
        echo "$new_username ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/nopasswd-$new_username
        echo "root ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/nopasswd-root
        
        # Установка правильных прав доступа
        chmod 440 /etc/sudoers.d/nopasswd-$new_username
        chmod 440 /etc/sudoers.d/nopasswd-root
        
        echo "Настроено выполнение команд sudo без пароля для пользователей $new_username и root"
    fi
    
    # Настройка SSH для нового пользователя
    if [ ! -d "/home/$new_username/.ssh" ]; then
        mkdir -p /home/$new_username/.ssh
        touch /home/$new_username/.ssh/authorized_keys
        chown -R $new_username:$new_username /home/$new_username/.ssh
        chmod 700 /home/$new_username/.ssh
        chmod 600 /home/$new_username/.ssh/authorized_keys
    fi
    
    # Добавление SSH ключа
    if [ "$NONINTERACTIVE" = "true" ]; then
        # В неинтерактивном режиме используем переменную SSH_PUBLIC_KEY
        if [ -n "$SSH_PUBLIC_KEY" ]; then
            echo "$SSH_PUBLIC_KEY" >> /home/$new_username/.ssh/authorized_keys
            echo "SSH ключ добавлен для пользователя $new_username"
            ssh_key_added=true
        else
            echo "SSH ключ не указан в переменной SSH_PUBLIC_KEY"
            ssh_key_added=false
        fi
    else
        # Спрашиваем, нужно ли добавить SSH ключ для нового пользователя
        read -r -p "Хотите добавить SSH ключ для пользователя $new_username? (y/n): " add_ssh_key
        if [[ "$add_ssh_key" == "y" || "$add_ssh_key" == "Y" ]]; then
            read -r -p "Введите публичный SSH ключ: " ssh_key
            echo "$ssh_key" >> /home/$new_username/.ssh/authorized_keys
            echo "SSH ключ добавлен для пользователя $new_username"
            
            # Сохраняем информацию о добавлении ключа в переменную
            ssh_key_added=true
        else
            # Если ключ не добавлен, отмечаем это
            ssh_key_added=false
        fi
    fi
fi

# 3.1 Изменение имени хоста (hostname)
if [ "$CHANGE_HOSTNAME" = true ]; then
    step "Изменение имени хоста (hostname)"
    
    current_hostname=$(hostname)
    echo "Текущее имя хоста: $current_hostname"
    
    # В неинтерактивном режиме используем переменную NEW_HOSTNAME
    if [ "$NONINTERACTIVE" = "true" ]; then
        if [ -z "$NEW_HOSTNAME" ]; then
            print_color "red" "Ошибка: В неинтерактивном режиме необходимо указать NEW_HOSTNAME"
            exit 1
        fi
        new_hostname="$NEW_HOSTNAME"
    else
        # Запрос нового имени хоста с проверкой корректности
        while true; do
            read -r -p "Введите новое имя хоста: " new_hostname
            
            # Проверка корректности имени хоста
            if [[ ! $new_hostname =~ ^[a-z0-9][-a-z0-9]*[a-z0-9]$ ]]; then
                print_color "red" "Ошибка: Имя хоста должно:"
                print_color "red" "- Начинаться и заканчиваться буквой или цифрой"
                print_color "red" "- Содержать только буквы в нижнем регистре, цифры и дефисы"
                print_color "red" "- Не содержать пробелов, подчеркиваний или специальных символов"
                continue
            fi
            
            # Проверка длины имени хоста
            if [ ${#new_hostname} -gt 63 ]; then
                print_color "red" "Ошибка: Имя хоста слишком длинное (максимум 63 символа)"
                continue
            fi
            
            # Если дошли до этой точки, имя хоста корректно
            break
        done
    fi
    
    # Проверка корректности имени хоста в неинтерактивном режиме
    if [ "$NONINTERACTIVE" = "true" ]; then
        if [[ ! $new_hostname =~ ^[a-z0-9][-a-z0-9]*[a-z0-9]$ ]]; then
            print_color "red" "Ошибка: Некорректное имя хоста в переменной NEW_HOSTNAME"
            print_color "red" "Имя хоста должно начинаться и заканчиваться буквой или цифрой"
            exit 1
        fi
        
        if [ ${#new_hostname} -gt 63 ]; then
            print_color "red" "Ошибка: Имя хоста слишком длинное (максимум 63 символа)"
            exit 1
        fi
    fi
    
    # Изменение имени хоста
    hostnamectl set-hostname "$new_hostname"
    
    # Добавление записи в /etc/hosts, если её там нет
    if ! grep -q "$new_hostname" /etc/hosts; then
        # Добавляем запись для нового имени хоста
        sed -i "s/127.0.1.1.*/127.0.1.1\t$new_hostname/g" /etc/hosts
        # Если записи с 127.0.1.1 нет, добавляем её
        if ! grep -q "127.0.1.1" /etc/hosts; then
            echo "127.0.1.1	$new_hostname" >> /etc/hosts
        fi
    fi
    
    echo "Имя хоста изменено на: $new_hostname"
    echo "Новое имя хоста будет полностью применено после перезагрузки системы."
fi

# 4. Настройка защиты SSH
if [ "$SETUP_SSH" = true ]; then
    step "Настройка базовой безопасности SSH"
    # Обеспечим наличие сервера OpenSSH
    if ! is_installed openssh-server; then
        apt install -y openssh-server
    fi
    # Создание резервной копии оригинального конфига
    if [ -f /etc/ssh/sshd_config ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    fi

    # Безопасные настройки SSH
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

    step "Перезапуск SSH-сервера"
    systemctl restart sshd
fi

# 5. Настройка Fail2ban
if [ "$SETUP_FAIL2BAN" = true ]; then
    step "Настройка Fail2ban"
    
    if ! is_installed fail2ban; then
        apt install -y fail2ban
    fi
    
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

# 6. Настройка Firewall (UFW)
if [ "$SETUP_FIREWALL" = true ]; then
    step "Настройка UFW"
    
    if ! is_installed ufw; then
        apt install -y ufw
    fi
    
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    # Раскомментируйте другие порты по необходимости
    # ufw allow 8080/tcp

    step "Активация UFW"
    echo "y" | ufw enable
fi

# 7. Настройка TCP BBR для улучшения сетевой производительности
if [ "$SETUP_BBR" = true ]; then
    step "Включение TCP BBR"
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
# Включение TCP BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    # Применяем все конфигурации sysctl (включая drop-in в /etc/sysctl.d)
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true
fi

# 7.1 Установка оптимизированного ядра XanMod
if [ "$INSTALL_XANMOD" = true ]; then
    step "Установка оптимизированного ядра XanMod"
    
    # Проверяем текущую версию ядра
    current_kernel=$(uname -r)
    echo "Текущее ядро: $current_kernel"

    # Проверяем архитектуру (ядра x64 доступны только для amd64)
    arch=$(dpkg --print-architecture)
    if [ "$arch" != "amd64" ]; then
        print_color "yellow" "Архитектура $arch не поддерживается сборками linux-xanmod-x64v*. Пропуск установки XanMod."
        INSTALL_XANMOD=false
    fi
    
    # Создаем каталог для ключей, если он не существует
    mkdir -p /etc/apt/keyrings
    
    # Загружаем и импортируем ключ XanMod
    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -vo /etc/apt/keyrings/xanmod-archive-keyring.gpg
    
    # Добавляем репозиторий XanMod
    echo 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-release.list
    
    # Обновляем информацию о репозиториях
    apt update
    
    # Определяем наиболее оптимальную версию ядра для процессора
    echo "Определение оптимальной версии ядра XanMod для вашего процессора..."
    
    if grep -q 'avx512' /proc/cpuinfo; then
        # Для процессоров с поддержкой AVX512 (новейшие процессоры Intel/AMD)
        # ВАЖНО: Пакета linux-xanmod-x64v4 не существует, для AVX-512 используем x64v3
        kernel_variant="x64v3"
        kernel_description="XanMod x64v3 (AVX-512) - для новейших процессоров с поддержкой AVX512 (Intel Icelake/AMD Zen3 и новее)"
    elif grep -q 'avx2' /proc/cpuinfo; then
        # Для процессоров с поддержкой AVX2 (большинство современных процессоров)
        kernel_variant="x64v3"
        kernel_description="XanMod x64v3 - для современных процессоров с поддержкой AVX2 (Intel Haswell/AMD Excavator и новее)"
    elif grep -q 'avx' /proc/cpuinfo; then
        # Для процессоров с поддержкой AVX (Intel Sandy Bridge и новее)
        kernel_variant="x64v2"
        kernel_description="XanMod x64v2 - для процессоров с поддержкой AVX (Intel Sandy Bridge/AMD Bulldozer и новее)"
    else
        # Для старых процессоров
        kernel_variant="x64v1"
        kernel_description="XanMod x64v1 - базовая версия для любых 64-битных процессоров"
    fi
    
    print_color "green" "╔═════════════════════════════════════════════════════════════╗"
    print_color "green" "║             ИНФОРМАЦИЯ О ВЫБРАННОМ ЯДРЕ                     ║"
    print_color "green" "╚═════════════════════════════════════════════════════════════╝"
    print_color "yellow" "→ Выбрана версия: $kernel_description"
    print_color "yellow" "→ Пакет: linux-xanmod-$kernel_variant"
    print_color "yellow" "→ Особенности: улучшенная производительность, низкие задержки, оптимизации для серверов"
    echo
    
    # Устанавливаем ядро XanMod
    print_color "blue" "Установка ядра linux-xanmod-$kernel_variant..."
    apt install -y linux-xanmod-$kernel_variant
    
    # Проверка успешности установки
    if [ $? -eq 0 ]; then
        print_color "green" "✓ Ядро XanMod успешно установлено"
        # Получаем информацию о установленной версии
        xanmod_version=$(dpkg-query -W -f='${Version}' linux-xanmod-$kernel_variant 2>/dev/null)
        xanmod_installed_version="$xanmod_version"
        print_color "green" "✓ Установленная версия: $xanmod_version"
        print_color "yellow" "⚠ Для применения нового ядра потребуется перезагрузка системы"
        xanmod_installed=true
    else
        print_color "red" "✗ Ошибка при установке ядра XanMod"
        print_color "yellow" "⚠ Пробуем установить стандартную версию ядра XanMod"
        
        # Пробуем установить стандартную версию
        apt install -y linux-xanmod
        
        if [ $? -eq 0 ]; then
            print_color "green" "✓ Стандартное ядро XanMod успешно установлено"
            xanmod_version=$(dpkg-query -W -f='${Version}' linux-xanmod 2>/dev/null)
            kernel_variant="standard"
            xanmod_installed_version="$xanmod_version"
            print_color "green" "✓ Установленная версия: $xanmod_version"
            print_color "yellow" "⚠ Для применения нового ядра потребуется перезагрузка системы"
            xanmod_installed=true
        else
            print_color "red" "✗ Не удалось установить ядро XanMod. Продолжаем настройку с текущим ядром."
        fi
    fi
    
    # Проверяем, установлен ли пакет inxi для системной информации
    if ! is_installed inxi; then
        apt install -y --no-install-recommends inxi
    fi
    
    if [ "$xanmod_installed" = true ]; then
        echo
        print_color "blue" "После перезагрузки можно проверить информацию о ядре следующими командами:"
        print_color "yellow" "  uname -r       # Версия ядра"
        print_color "yellow" "  inxi -S        # Краткая информация о системе"
        print_color "yellow" "  inxi -Fxxxz    # Подробная информация о системе и ядре"
    fi
fi

# 8. Оптимизация производительности системы
if [ "$OPTIMIZE_SYSTEM" = true ]; then
    step "Оптимизация производительности системы"
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-optimization.conf << 'EOF'
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

# Оптимизация использования памяти
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
    # Применение изменений из всех источников
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true
fi

# 9. Настройка часового пояса
if [ "$SETUP_TIMEZONE" = true ]; then
    step "Настройка часового пояса"
    if [ "$NONINTERACTIVE" = "true" ]; then
        TZ_TO_SET="$TIMEZONE"
        if [ -z "$TZ_TO_SET" ]; then
            TZ_TO_SET="$(timedatectl show --property=Timezone --value 2>/dev/null || echo UTC)"
        fi
    else
        echo "Доступные часовые пояса:"
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
            1) TZ_TO_SET="Europe/Moscow" ;;
            2) TZ_TO_SET="Europe/Kiev" ;;
            3) TZ_TO_SET="Europe/Berlin" ;;
            4) TZ_TO_SET="Europe/London" ;;
            5) TZ_TO_SET="America/New_York" ;;
            6) TZ_TO_SET="America/Los_Angeles" ;;
            7) TZ_TO_SET="Asia/Tokyo" ;;
            8) TZ_TO_SET="Asia/Shanghai" ;;
            9) TZ_TO_SET="Australia/Sydney" ;;
            10)
                read -r -p "Введите часовой пояс (например, Europe/Paris): " TZ_TO_SET
                ;;
            *) TZ_TO_SET="UTC" ;;
        esac
    fi
    if [ -n "$TZ_TO_SET" ]; then
        timedatectl set-timezone "$TZ_TO_SET"
        echo "Установлен часовой пояс: $TZ_TO_SET"
    fi
fi

# 10. Настройка NTP для синхронизации времени
if [ "$SETUP_NTP" = true ]; then
    step "Настройка NTP синхронизации"
    apt install -y systemd-timesyncd
    systemctl enable systemd-timesyncd
    systemctl start systemd-timesyncd
fi

# 11. Создание swap файла с размером 50% от ОЗУ
if [ "$SETUP_SWAP" = true ]; then
    step "Настройка swap (50% от ОЗУ). Если ОЗУ меньше или равно 3 ГБ, устанавливаем swap = 2 ГБ"
    if [ -f /swapfile ]; then
        # Если swap-файл уже существует, отключаем его
        swapoff /swapfile
        rm -f /swapfile
        # Удаляем запись из /etc/fstab
        sed -i '/swapfile/d' /etc/fstab
    fi
    
    # Получаем размер ОЗУ в килобайтах
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    # Конвертируем в мегабайты
    total_mem_mb=$((total_mem_kb / 1024))
    # Вычисляем размер swap-файла (50% от ОЗУ в мегабайтах)
    swap_size_mb=$((total_mem_mb / 2))
    
    # Если ОЗУ меньше или равно 3 ГБ, устанавливаем swap = 2 ГБ
    if [ $total_mem_mb -le 3072 ]; then
        swap_size_mb=2048
        echo "ОЗУ меньше или равно 3 ГБ, устанавливаем размер swap в 2 ГБ"
    else
        # Округляем до ближайшего целого ГБ
        swap_size_gb=$(((swap_size_mb + 512) / 1024))
        swap_size_mb=$((swap_size_gb * 1024))
        echo "Размер ОЗУ: $total_mem_mb МБ, размер swap будет: $swap_size_mb МБ (${swap_size_gb} ГБ)"
    fi
    
    echo "Создание swap-файла размером ${swap_size_mb} МБ"
    
    # Создаем swap-файл нужного размера
    dd if=/dev/zero of=/swapfile bs=1M count=$swap_size_mb
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    
    # Оптимизация использования swap через /etc/sysctl.d
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/60-swap.conf << 'EOF'
vm.swappiness=10
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true
    
    # Проверка статуса swap
    echo "Статус swap после настройки:"
    swapon --show
    free -h
fi

# 12. Установка и настройка локалей
if [ "$SETUP_LOCALES" = true ]; then
    step "Настройка локалей"
    apt install -y locales
    ensure_locale "ru_RU.UTF-8"
    ensure_locale "en_US.UTF-8"

    if [ "$NONINTERACTIVE" = "true" ]; then
        case "$LOCALE_DEFAULT" in
            ru_RU.UTF-8|ru_RU.utf8)
                if ensure_locale "ru_RU.UTF-8" && update-locale LANG=ru_RU.UTF-8 LC_ALL=ru_RU.UTF-8; then
                    SYSTEM_LOCALE_DEFAULT="ru_RU.UTF-8"
                    echo "Установлена русская локаль по умолчанию (ru_RU.UTF-8)"
                else
                    print_color "yellow" "Не удалось активировать ru_RU.UTF-8, используется en_US.UTF-8"
                    ensure_locale "en_US.UTF-8"
                    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
                    SYSTEM_LOCALE_DEFAULT="en_US.UTF-8"
                fi
                ;;
            en_US.UTF-8|en_US.utf8|*)
                ensure_locale "en_US.UTF-8"
                update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
                SYSTEM_LOCALE_DEFAULT="en_US.UTF-8"
                echo "Установлена английская локаль по умолчанию (en_US.UTF-8)"
                ;;
        esac
    else
        echo "Выберите локаль по умолчанию:"
        echo "1) Русская (ru_RU.UTF-8)"
        echo "2) Английская (en_US.UTF-8)"
        read -r -p "Выберите локаль (1/2): " locale_choice
        case "$locale_choice" in
            1)
                if ensure_locale "ru_RU.UTF-8" && update-locale LANG=ru_RU.UTF-8 LC_ALL=ru_RU.UTF-8; then
                    SYSTEM_LOCALE_DEFAULT="ru_RU.UTF-8"
                    echo "Установлена русская локаль по умолчанию (ru_RU.UTF-8)"
                else
                    print_color "yellow" "Не удалось активировать ru_RU.UTF-8, используется en_US.UTF-8"
                    ensure_locale "en_US.UTF-8"
                    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
                    SYSTEM_LOCALE_DEFAULT="en_US.UTF-8"
                fi
                ;;
            *)
                ensure_locale "en_US.UTF-8"
                update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
                SYSTEM_LOCALE_DEFAULT="en_US.UTF-8"
                echo "Установлена английская локаль по умолчанию (en_US.UTF-8)"
                ;;
        esac
    fi
fi

# 13. Настройка logrotate для лог-файлов
if [ "$SETUP_LOGROTATE" = true ]; then
    step "Настройка logrotate"
    
    if ! is_installed logrotate; then
        apt install -y logrotate
    fi
    
    cat > /etc/logrotate.d/custom << EOF
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

# 14. Настройка периодических обновлений безопасности
if [ "$SETUP_AUTO_UPDATES" = true ]; then
    step "Настройка автоматических обновлений безопасности"
    apt install -y unattended-upgrades apt-listchanges
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${DEBIAN_CODENAME}-security,label=Debian-Security";
    "origin=Debian,codename=${DEBIAN_CODENAME}-updates,label=Debian";
    "origin=Debian,codename=${DEBIAN_CODENAME},label=Debian";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    # Активируем автоматические обновления
    cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
fi

# 15. Установка Docker и Docker Compose
if [ "$INSTALL_DOCKER" = true ]; then
    step "Установка Docker и Docker Compose"
    
    if ! is_installed docker-ce; then
        # Удаляем старые версии Docker, если они установлены
        apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        
        # Добавляем GPG ключ Docker
        if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
        fi
        
        # Добавляем репозиторий Docker с авто-выбором дистро: пробуем текущий codename, затем fallback на bookworm
        docker_key="/etc/apt/keyrings/docker.gpg"
        docker_list="/etc/apt/sources.list.d/docker.list"

        try_docker_codename() {
            local codename="$1"
            echo "deb [arch=$(dpkg --print-architecture) signed-by=${docker_key}] https://download.docker.com/linux/debian ${codename} stable" > "${docker_list}"
            # Обновляем только этот источник, не затрагивая остальные
            apt-get update -o Dir::Etc::sourcelist="${docker_list}" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
        }

        CHOSEN_DOCKER_CODENAME=""
        if try_docker_codename "$DEBIAN_CODENAME"; then
            CHOSEN_DOCKER_CODENAME="$DEBIAN_CODENAME"
        elif [ "$DEBIAN_CODENAME" != "bookworm" ] && try_docker_codename "bookworm"; then
            CHOSEN_DOCKER_CODENAME="bookworm"
            print_color "yellow" "Docker репозиторий для ${DEBIAN_CODENAME} недоступен. Используем bookworm как fallback."
        else
            print_color "red" "Не удалось добавить репозиторий Docker для ${DEBIAN_CODENAME} или bookworm."
            print_color "yellow" "Пропуск установки Docker."
            INSTALL_DOCKER=false
        fi

        if [ "$INSTALL_DOCKER" = false ]; then
            :
        else
            echo "Используется репозиторий Docker для: ${CHOSEN_DOCKER_CODENAME}"
        fi
        
        # Устанавливаем Docker Engine и Docker Compose (если репозиторий успешно настроен)
        if [ "$INSTALL_DOCKER" = true ]; then
            apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        else
            # Перейти к следующему блоку, не падая
            continue
        fi
        
        # Проверяем, что Docker работает
        systemctl enable docker
        systemctl start docker
        
        # Создаем группу docker, если её нет
        if ! getent group docker > /dev/null; then
            groupadd docker
        fi
        
        # Добавление в группу docker текущего пользователя (если это не root)
        if [ "$SUDO_USER" != "" ]; then
            usermod -aG docker $SUDO_USER
            echo "Пользователь $SUDO_USER добавлен в группу docker."
        fi
        
        # Добавление в группу docker нового пользователя, если он был создан ранее
        if [ "$CREATE_USER" = true ] && [ -n "$new_username" ]; then
            if id "$new_username" &>/dev/null; then
                usermod -aG docker $new_username
                echo "Пользователь $new_username добавлен в группу docker."
            fi
        fi
        
        echo "Чтобы изменения группы docker вступили в силу, выйдите из системы и войдите снова или выполните: newgrp docker"
        
        # Проверяем версию Docker
        docker version
        docker compose version
    else
        echo "Docker уже установлен. Текущая версия:"
        docker version | grep "Version"
        docker compose version
        
        # Добавление пользователя в группу docker, если Docker уже установлен
        if [ "$CREATE_USER" = true ] && [ -n "$new_username" ]; then
            if id "$new_username" &>/dev/null; then
                if ! groups $new_username | grep -q "\bdocker\b"; then
                    usermod -aG docker $new_username
                    echo "Пользователь $new_username добавлен в группу docker."
                else
                    echo "Пользователь $new_username уже в группе docker."
                fi
            fi
        fi
    fi
fi

# 16. Установка дополнительных инструментов мониторинга
if [ "$INSTALL_MONITORING" = true ]; then
    step "Установка инструментов мониторинга"
    apt install -y --no-install-recommends "${MONITORING_PACKAGES[@]}"

    # Настройка сбора статистики sysstat
    if [ -f /etc/default/sysstat ]; then
        sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
        systemctl enable sysstat
        systemctl restart sysstat
    fi
fi

# 17. Настройка усиленной безопасности SSH (отключение входа по паролю) - в конце скрипта
if [ "$SECURE_SSH" = true ]; then
    step "Настройка усиленной безопасности SSH"
    
    # Проверяем, добавлен ли SSH ключ
    ssh_key_exists=false
    
    # Проверяем, был ли добавлен ключ для нового пользователя
    if [ "$CREATE_USER" = true ] && [ "$ssh_key_added" = true ]; then
        ssh_key_exists=true
    else
        # Проверяем, есть ли ключи для текущего пользователя или root
        if [ -f "/root/.ssh/authorized_keys" ] && [ -s "/root/.ssh/authorized_keys" ]; then
            ssh_key_exists=true
        elif [ "$SUDO_USER" != "" ] && [ -f "/home/$SUDO_USER/.ssh/authorized_keys" ] && [ -s "/home/$SUDO_USER/.ssh/authorized_keys" ]; then
            ssh_key_exists=true
        fi
    fi
    
    # Выводим предупреждение, если SSH ключ не добавлен
    if [ "$ssh_key_exists" = false ]; then
        print_color "red" "ВНИМАНИЕ! Не обнаружено добавленных SSH ключей!"
        print_color "red" "Отключение входа по паролю без добавления SSH ключа приведет к ПОЛНОЙ ПОТЕРЕ ДОСТУПА к серверу!"
        echo
        read -r -p "Вы уверены, что SSH ключ уже добавлен и вы хотите продолжить? (y/n): " confirm_ssh_hardening
        
        if [[ "$confirm_ssh_hardening" != "y" && "$confirm_ssh_hardening" != "Y" ]]; then
            echo "Отмена изменений настроек SSH."
            SECURE_SSH=false
        fi
    else
        print_color "green" "Обнаружены добавленные SSH ключи. Можно безопасно отключить вход по паролю."
    fi
    
    if [ "$SECURE_SSH" = true ]; then
        # Создаем резервную копию конфигурации SSH (если есть)
        if [ -f /etc/ssh/sshd_config ]; then
            cp /etc/ssh/sshd_config /etc/ssh/sshd_config.$(date +%Y%m%d-%H%M%S).bak
        fi
        
        # Настраиваем SSH для запрета входа по паролю и запрета входа под root
        cat > /etc/ssh/sshd_config.d/security.conf << EOF
# Усиленные настройки безопасности SSH
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
EOF
        
        print_color "yellow" "Настройки SSH обновлены:"
        print_color "yellow" "1. Отключен вход по паролю (только по SSH ключу)"
        print_color "yellow" "2. Запрещен вход под пользователем root"
        
        # Перезапускаем SSH-сервер
        systemctl restart sshd
        
        echo "SSH сервер перезапущен с новыми настройками безопасности."
        print_color "green" "Теперь вы можете подключаться только по SSH ключу."
    fi
fi

# 18. Полная настройка fish shell для root и пользователя
if [ "$INSTALL_FISH" = true ]; then
    step "Полная настройка fish shell (Fisher, плагины, fzf, fd, bat, Starship, автодополнения Docker)"

    # Установка fish shell и дополнительных утилит
    apt install -y fish fzf fd-find bat

    # Установка Starship глобально (для всех пользователей)
    step "Установка Starship prompt"
    curl -fsSL --connect-timeout 15 --retry 3 https://starship.rs/install.sh | sh -s -- -y

    fish_locale="${SYSTEM_LOCALE_DEFAULT:-ru_RU.UTF-8}"
    if ! ensure_locale "$fish_locale"; then
        if ensure_locale "en_US.UTF-8"; then
            fish_locale="en_US.UTF-8"
        else
            fish_locale="C.UTF-8"
        fi
        print_color "yellow" "Используется локаль $fish_locale для fish shell."
    fi

    # --- Настройка для root ---
    # Создание директорий для конфигурации
    mkdir -p /root/.config/fish/functions
    mkdir -p /root/.config/fish/completions

# Основной config.fish для root
    cat > /root/.config/fish/config.fish << 'ROOT_CONFIG_EOF'
# Настройки Debian
set -gx LANG __FISH_LOCALE__
set -gx LC_ALL __FISH_LOCALE__

# Алиасы
alias ll='ls -la'
alias la='ls -A'
alias l='ls'
alias cls='clear'
alias ..='cd ..'
alias ...='cd ../..'

# Улучшенные утилиты
if type -q batcat
    alias cat='batcat --paging=never'
end
if type -q fd
    alias find='fd'
end

# Настройка fish
set -U fish_greeting
set fish_key_bindings fish_default_key_bindings
set fish_autosuggestion_enabled 1

# FZF интеграция
set -gx FZF_DEFAULT_COMMAND 'fd --type f --strip-cwd-prefix 2>/dev/null || find . -type f'
set -gx FZF_CTRL_T_COMMAND $FZF_DEFAULT_COMMAND

# Утилиты для запуска bash-команд из fish
function b --description 'Run command in bash -lc'
    set -l cmd (string join ' ' -- $argv)
    bash -lc "$cmd"
end

function bcurl --description 'Download URL and run via bash'
    if test (count $argv) -lt 1
        echo 'Usage: bcurl <url>'
        return 1
    end
    curl -fsSL $argv[1] | bash
end

# Starship prompt
starship init fish | source
ROOT_CONFIG_EOF
    sed -i "s|__FISH_LOCALE__|$fish_locale|g" /root/.config/fish/config.fish

    # Приветствие для root
    cat > /root/.config/fish/functions/fish_greeting.fish << 'ROOT_GREETING_EOF'
function fish_greeting
    echo "🐧 Debian [ROOT] - "(date '+%Y-%m-%d %H:%M')""
end
ROOT_GREETING_EOF

    # Автодополнения Docker для root
    mkdir -p /root/.config/fish/completions
    curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/docker/cli/master/contrib/completion/fish/docker.fish -o /root/.config/fish/completions/docker.fish || true
    curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/docker/compose/master/contrib/completion/fish/docker-compose.fish -o /root/.config/fish/completions/docker-compose.fish || true

    # Установка Fisher и плагинов для root
    step "Установка Fisher и плагинов для root"
    
    # Создаем временный fish скрипт для установки Fisher
    cat > /tmp/install_fisher_root.fish << 'FISHER_ROOT_SCRIPT_EOF'
#!/usr/bin/env fish
# Установка Fisher и плагинов для root
curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
fisher install jorgebucaran/fisher
fisher install jethrokuan/z
fisher install PatrickF1/fzf.fish
fisher install jorgebucaran/autopair.fish
fisher install franciscolourenco/done
fisher install edc/bass
FISHER_ROOT_SCRIPT_EOF

    chmod +x /tmp/install_fisher_root.fish
    fish /tmp/install_fisher_root.fish
    rm -f /tmp/install_fisher_root.fish

    # Установка fish по умолчанию для root
    chsh -s /usr/bin/fish root

    # --- Настройка для нового пользователя ---
    if [ "$CREATE_USER" = true ] && [ -n "$new_username" ]; then
        step "Настройка fish shell для пользователя $new_username"
        
        # Создание директорий
        su - $new_username -c "mkdir -p ~/.config/fish/functions"
        su - $new_username -c "mkdir -p ~/.config/fish/completions"

# Создаем временные файлы для конфигурации пользователя
        cat > /tmp/user_config.fish << 'USER_CONFIG_EOF'
# Настройки Debian
set -gx LANG __FISH_LOCALE__
set -gx LC_ALL __FISH_LOCALE__

# Алиасы
alias ll='ls -la'
alias la='ls -A'
alias l='ls'
alias cls='clear'
alias ..='cd ..'
alias ...='cd ../..'

# Улучшенные утилиты
if type -q batcat
    alias cat='batcat --paging=never'
end
if type -q fd
    alias find='fd'
end

# Настройка fish
set -U fish_greeting
set fish_key_bindings fish_default_key_bindings
set fish_autosuggestion_enabled 1

# FZF интеграция
set -gx FZF_DEFAULT_COMMAND 'fd --type f --strip-cwd-prefix 2>/dev/null || find . -type f'
set -gx FZF_CTRL_T_COMMAND $FZF_DEFAULT_COMMAND

# Утилиты для запуска bash-команд из fish
function b --description 'Run command in bash -lc'
    set -l cmd (string join ' ' -- $argv)
    bash -lc "$cmd"
end

function bcurl --description 'Download URL and run via bash'
    if test (count $argv) -lt 1
        echo 'Usage: bcurl <url>'
        return 1
    end
    curl -fsSL $argv[1] | bash
end

# Starship prompt
starship init fish | source
USER_CONFIG_EOF
        sed -i "s|__FISH_LOCALE__|$fish_locale|g" /tmp/user_config.fish

        cat > /tmp/user_greeting.fish << 'USER_GREETING_EOF'
function fish_greeting
    echo "🐧 Debian - "(date '+%Y-%m-%d %H:%M')""
end
USER_GREETING_EOF

        # Копируем файлы конфигурации для пользователя
        cp /tmp/user_config.fish /home/$new_username/.config/fish/config.fish
        cp /tmp/user_greeting.fish /home/$new_username/.config/fish/functions/fish_greeting.fish
        chown -R $new_username:$new_username /home/$new_username/.config/fish

        # Очищаем временные файлы
        rm -f /tmp/user_config.fish /tmp/user_greeting.fish

        # Автодополнения Docker для пользователя
        su - $new_username -c "curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/docker/cli/master/contrib/completion/fish/docker.fish -o ~/.config/fish/completions/docker.fish || true"
        su - $new_username -c "curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/docker/compose/master/contrib/completion/fish/docker-compose.fish -o ~/.config/fish/completions/docker-compose.fish || true"

        # Установка Fisher и плагинов для пользователя
        step "Установка Fisher и плагинов для пользователя $new_username"
        
        # Создаем временный скрипт для установки Fisher
        cat > /tmp/install_fisher.sh << 'FISHER_SCRIPT_EOF'
#!/usr/bin/env fish
# Установка Fisher и плагинов
curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
fisher install jorgebucaran/fisher
fisher install jethrokuan/z
fisher install PatrickF1/fzf.fish
fisher install jorgebucaran/autopair.fish
fisher install franciscolourenco/done
fisher install edc/bass
FISHER_SCRIPT_EOF

        chmod +x /tmp/install_fisher.sh
        su - $new_username -c "fish /tmp/install_fisher.sh"
        rm -f /tmp/install_fisher.sh

        # Установка fish по умолчанию для пользователя
        chsh -s /usr/bin/fish $new_username
    fi
    
    echo -e "\033[0;32m✓ Fish shell успешно настроен для всех пользователей\033[0m"
    echo -e "\033[0;33m⚠ Для применения изменений перезапустите терминал или выполните: exec fish\033[0m"
else
    :
fi

# Очистка временных файлов
if [ "$UPDATE_SYSTEM" = true ]; then
    step "Очистка временных файлов"
    apt clean
    journalctl --vacuum-time=1d
fi

# Установки завершены
step "Настройка завершена!"
echo "Система успешно настроена."

# Информация о системе после настройки
echo -e "\n\033[1;34m=== Информация о системе ===\033[0m"
uname -a
echo -e "\n\033[1;34m=== Имя хоста ===\033[0m"
hostname
echo -e "\n\033[1;34m=== Память и Swap ===\033[0m"
free -h
echo -e "\n\033[1;34m=== Дисковое пространство ===\033[0m"
df -h
echo -e "\n\033[1;34m=== Сетевые интерфейсы ===\033[0m"
ip a

if [ "$CREATE_USER" = true ]; then
    echo -e "\n\033[1;33mПользователь $new_username может выполнять команды sudo без пароля.\033[0m"
    echo -e "\033[1;33mПри создании пользователя был установлен пароль, но для команд sudo он не требуется.\033[0m"
fi

if [ "$INSTALL_DOCKER" = true ]; then
    echo -e "\n\033[1;33mЕсли вы добавили пользователя в группу docker,\nвойдите в систему заново, чтобы изменения вступили в силу.\033[0m"
fi

if [ "$CHANGE_HOSTNAME" = true ]; then
    echo -e "\n\033[1;33mИмя хоста изменено на: $(hostname)\033[0m"
    echo -e "\033[1;33mИзменение имени хоста будет полностью применено после перезагрузки.\033[0m"
fi

if [ "$INSTALL_XANMOD" = true ] && [ "$xanmod_installed" = true ]; then
    echo -e "\n\033[1;33mЯдро XanMod установлено. Для его активации требуется перезагрузка.\033[0m"
    kernel_info="$xanmod_installed_version"
    if [ -z "$kernel_info" ] && [ -n "$kernel_variant" ]; then
        kernel_info=$(dpkg-query -W -f='${Version}' "linux-xanmod-$kernel_variant" 2>/dev/null)
    fi
    if [ -z "$kernel_info" ]; then
        kernel_info=$(dpkg-query -W -f='${Version}' linux-xanmod 2>/dev/null)
    fi
    if [ -n "$kernel_info" ]; then
        variant_summary="$kernel_variant"
        if [ -z "$variant_summary" ]; then
            variant_summary="standard"
        fi
        echo -e "\033[1;33mУстановленная версия: $kernel_info (тип: $variant_summary)\033[0m"
    fi
    echo -e "\033[1;33mПосле перезагрузки можно проверить версию ядра командой: uname -r\033[0m"
fi

if [ "$SECURE_SSH" = true ]; then
    echo -e "\n\033[1;31mВНИМАНИЕ: Вход по паролю отключен. Убедитесь, что у вас есть доступ по SSH-ключу!\033[0m"
    if [ "$CREATE_USER" = true ]; then
        echo -e "\033[1;33mВы можете подключиться к серверу командой:\033[0m"
        echo -e "\033[1;33mssh $new_username@$(hostname -I | awk '{print $1}')\033[0m"
    fi
fi

echo -e "\n\033[1;32mРекомендуется перезагрузить систему.\033[0m"
if [ "$NONINTERACTIVE" = "true" ]; then
    if [ "$AUTO_REBOOT" = "true" ]; then
        echo "Перезагрузка системы..."
        if command -v systemctl >/dev/null 2>&1; then
            systemctl reboot
        elif command -v shutdown >/dev/null 2>&1; then
            shutdown -r now
        else
            reboot
        fi
    else
        echo "Для ручной перезагрузки введите: sudo reboot"
    fi
else
    read -r -p "Перезагрузить сейчас? (y/n): " reboot_now
    if [[ "$reboot_now" == "y" || "$reboot_now" == "Y" ]]; then
        echo "Перезагрузка системы..."
        # Пробуем разные способы перезагрузки
        if command -v systemctl >/dev/null 2>&1; then
            systemctl reboot
        elif command -v shutdown >/dev/null 2>&1; then
            shutdown -r now
        else
            reboot
        fi
    else
        echo "Для ручной перезагрузки введите: sudo reboot"
    fi
fi
