#!/bin/bash
# Скрипт настройки Debian 12/13 (WSL)
# - Поддерживаются Debian 12 (Bookworm) и Debian 13 (Trixie)
# - Интерактивное меню в стиле VPS-скрипта (y/n по каждому пункту)
# - Поддерживается неинтерактивный режим через переменные окружения
# Примеры запуска:
#   Интерактивно:
#     sudo bash debian-wsl.sh
#   Неинтерактивно (пример набора шагов):
#     sudo NONINTERACTIVE=true \
#          UPDATE_SYSTEM=true INSTALL_BASE_UTILS=true \
#          SETUP_LOCALES=true LOCALE_DEFAULT=ru_RU.UTF-8 \
#          SETUP_TIMEZONE=true TIMEZONE=Europe/Moscow \
#          SETUP_WSL_CONF=true WSL_DEFAULT_USER=$USER \
#          SETUP_AUTO_UPDATES=true \
#          bash debian-wsl.sh
#   Создание пользователя:
#     sudo NONINTERACTIVE=true CREATE_USER=true NEW_USERNAME=dev NEW_PASSWORD='StrongPass' bash debian-wsl.sh
#   Установка Fish для пользователя:
#     sudo NONINTERACTIVE=true SETUP_FISH=true FISH_USER=$USER bash debian-wsl.sh

# Проверка, что скрипт запущен с правами root

if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен с правами root. Выполните: sudo $0"
    exit 1
fi

# Неинтерактивные установки
export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}

# --- Определение версии Debian (12/13) ---
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

# --- Вспомогательные функции ---

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

# Функция для вывода текущего шага
step() {
    echo
    print_color "blue" "══════════════════════════════════════════════════════════════════════════════"
    print_color "blue" ">>> $1"
    print_color "blue" "══════════════════════════════════════════════════════════════════════════════"
}

# Функция для проверки, установлен ли пакет
is_installed() {
    dpkg -l | grep -q "^ii  $1"
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
        [ -z "$candidate" ] && continue
        if locale -a 2>/dev/null | grep -iq "^${candidate}$"; then
            return 0
        fi
    done
    return 1
}

# Экранирует строку для sed
escape_sed_pattern() {
    printf '%s' "$1" | sed 's/[.[\*^$(){}?+|\\\/-]/\\&/g'
}

# Обеспечивает наличие указанной локали в системе
ensure_locale() {
    local locale_name="$1"
    local charset="${2:-UTF-8}"
    [ -n "$locale_name" ] || return 1
    if locale_exists "$locale_name"; then
        return 0
    fi
    [ -f /etc/locale.gen ] || return 1
    local escaped
    escaped="$(escape_sed_pattern "$locale_name")"
    if grep -iq "^#? *${escaped}[[:space:]]" /etc/locale.gen; then
        sed -i -E "s/^# *${escaped}[[:space:]]+/${locale_name} /I" /etc/locale.gen
    else
        printf '%s %s\n' "$locale_name" "$charset" >> /etc/locale.gen
    fi
    locale-gen "$locale_name" >/dev/null 2>&1 || return 1
    locale_exists "$locale_name"
}

# Аккуратное обогащение APT-компонентов (contrib, non-free, non-free-firmware)
enrich_apt_components_in_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    # Только для строк deb; если уже есть non-free-firmware — не трогаем
    sed -i -E '/^\s*deb\s/ { /non-free-firmware/! s/(^deb\s+[^#]*\bmain)(\s|$)/\1 contrib non-free non-free-firmware\2/ }' "$f"
}

enrich_all_apt_components() {
    local f
    # Основной список
    enrich_apt_components_in_file "/etc/apt/sources.list"
    # Все дополнительные списки
    for f in /etc/apt/sources.list.d/*.list; do
        [ -e "$f" ] || continue
        enrich_apt_components_in_file "$f"
    done
}

# Гарантирует наличие базовых репозиториев Debian (main, updates, security)
ensure_debian_base_repos() {
    local codename="$DEBIAN_CODENAME"
    local f="/etc/apt/sources.list"
    touch "$f"

    ensure_line() {
        local file="$1"; shift
        local line="$*"
        # Сопоставляем без учёта лишних пробелов
        local pattern="^$(printf '%s' "$line" | sed -E 's/[[:space:]]+/\\s+/g')$"
        if ! grep -Eq "$pattern" "$file" 2>/dev/null; then
            echo "$line" >> "$file"
        fi
    }

    ensure_line "$f" "deb http://deb.debian.org/debian ${codename} main contrib non-free non-free-firmware"
    ensure_line "$f" "deb http://deb.debian.org/debian ${codename}-updates main contrib non-free non-free-firmware"
    ensure_line "$f" "deb http://security.debian.org/debian-security ${codename}-security main contrib non-free non-free-firmware"
}

# --- Переменные режима и окружения ---
NONINTERACTIVE=${NONINTERACTIVE:-false}
NEW_USERNAME=${NEW_USERNAME:-""}
NEW_PASSWORD=${NEW_PASSWORD:-""}
WSL_DEFAULT_USER=${WSL_DEFAULT_USER:-""}
FISH_USER=${FISH_USER:-""}
LOCALE_DEFAULT=${LOCALE_DEFAULT:-""}
TIMEZONE=${TIMEZONE:-""}

# --- Переменные для выбора компонентов ---
UPDATE_SYSTEM=false
CREATE_USER=false
SETUP_TIMEZONE=false
SETUP_LOCALES=false
SETUP_WSL_CONF=false
INSTALL_NVIDIA=false
INSTALL_BASE_UTILS=false
SETUP_FISH=false
INSTALL_DOCKER=false
SETUP_AUTO_UPDATES=false

# --- Определение имени пользователя, не являющегося root ---
if [ -n "$SUDO_USER" ]; then
    DEFAULT_USER=$SUDO_USER
else
    DEFAULT_USER=$(logname 2>/dev/null || whoami)
fi

# --- Функции установки компонентов ---

# 1. Создание пользователя
create_user() {
    step "1. Создание нового пользователя"
    local new_user=""
    if [ "$NONINTERACTIVE" = true ]; then
        new_user="$NEW_USERNAME"
        if [ -z "$new_user" ]; then
            print_color "red" "NONINTERACTIVE=true, но переменная NEW_USERNAME не задана. Пропуск."
            return 1
        fi
    else
        print_color "yellow" "Введите имя нового пользователя:"
        read -r new_user < /dev/tty
        if [ -z "$new_user" ]; then
            print_color "red" "Имя пользователя не может быть пустым. Пропуск."
            return 1
        fi
    fi

    # Установка sudo при необходимости
    if ! is_installed sudo; then
        apt-get install -y sudo
    fi

    if id "$new_user" &>/dev/null; then
        print_color "yellow" "Пользователь '$new_user' уже существует. Применяем параметры..."

        # Смена пароля
        if [ "$NONINTERACTIVE" = true ]; then
            if [ -n "$NEW_PASSWORD" ]; then
                echo "$new_user:$NEW_PASSWORD" | chpasswd || true
                print_color "green" "Пароль пользователя '$new_user' обновлен."
            else
                print_color "yellow" "NONINTERACTIVE: пароль не изменен (NEW_PASSWORD пуст)."
            fi
        else
            read -r -p "Сменить пароль для '$new_user'? (y/N): " chpass < /dev/tty
            if [[ "$chpass" == "y" || "$chpass" == "Y" ]]; then
                passwd "$new_user" < /dev/tty || true
            fi
        fi

        # Добавление в группу sudo
        if ! id -nG "$new_user" | grep -qw sudo; then
            usermod -aG sudo "$new_user"
            print_color "green" "Пользователь '$new_user' добавлен в группу sudo."
        else
            print_color "green" "Пользователь '$new_user' уже в группе sudo."
        fi

        # Настройка sudo без пароля
        mkdir -p /etc/sudoers.d
        echo "$new_user ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$new_user"
        chmod 440 "/etc/sudoers.d/$new_user"
        print_color "green" "Sudo без пароля настроен для '$new_user'."

        # Приведение оболочки входа к /bin/bash, как при создании нового пользователя
        current_shell="$(getent passwd "$new_user" | awk -F: '{print $7}')"
        if [ "$current_shell" != "/bin/bash" ]; then
            usermod -s /bin/bash "$new_user" && \
                print_color "green" "Оболочка входа изменена на /bin/bash для '$new_user'" || \
                print_color "yellow" "Не удалось изменить оболочку входа для '$new_user'"
        fi

        # Гарантируем наличие домашней директории
        home_dir="$(getent passwd "$new_user" | cut -d: -f6)"
        if [ -n "$home_dir" ] && [ ! -d "$home_dir" ]; then
            mkdir -p "$home_dir"
            chown -R "$new_user":"$new_user" "$home_dir"
            print_color "yellow" "Создана домашняя директория: $home_dir"
        fi
    
    else
        print_color "yellow" "Создаем пользователя '$new_user' с оболочкой /bin/bash..."
        useradd -m -G sudo -s /bin/bash "$new_user"

        if [ "$NONINTERACTIVE" = true ]; then
            if [ -n "$NEW_PASSWORD" ]; then
                echo "$new_user:$NEW_PASSWORD" | chpasswd || true
            else
                print_color "yellow" "Пароль не задан (NEW_PASSWORD пуст). Пользователь создан без изменения пароля."
            fi
        else
            print_color "yellow" "Установите пароль для пользователя '$new_user':"
            passwd "$new_user" < /dev/tty
        fi

        print_color "yellow" "Настраиваем sudo без пароля для '$new_user'..."
        mkdir -p /etc/sudoers.d
        echo "$new_user ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$new_user"
        chmod 440 "/etc/sudoers.d/$new_user"

        print_color "green" "Пользователь '$new_user' успешно создан."
    fi

    print_color "yellow" "Теперь вы можете запустить для него настройку Fish Shell."
}

# 2. Обновление системы и репозиториев
update_system() {
    step "2. Обновление системы и репозиториев"
    print_color "yellow" "Включаем компоненты contrib, non-free, non-free-firmware в APT (во всех списках)..."
    enrich_all_apt_components
    print_color "yellow" "Проверяем и добавляем базовые репозитории Debian (main/updates/security) для ${DEBIAN_CODENAME}..."
    ensure_debian_base_repos

    print_color "yellow" "Обновляем список пакетов и систему..."
    apt-get update
    apt-get upgrade -y
    apt-get full-upgrade -y
    apt-get autoremove -y
    apt-get clean

    print_color "yellow" "Устанавливаем базовые пакеты для работы с репозиториями..."
    apt-get install -y ca-certificates curl gnupg apt-transport-https lsb-release
    print_color "green" "Система успешно обновлена."
}

# 3a. Настройка локалей
setup_locales_only() {
    step "3a. Настройка локалей"
    print_color "yellow" "Устанавливаем пакет locales..."
    apt-get install -y locales
    print_color "yellow" "Добавляем локали ru_RU.UTF-8 и en_US.UTF-8..."
    ensure_locale "ru_RU.UTF-8"
    ensure_locale "en_US.UTF-8"
    if [ "$NONINTERACTIVE" = true ]; then
        local chosen="${LOCALE_DEFAULT}"; chosen="${chosen:-en_US.UTF-8}"
        case "${chosen}" in
            ru|ru_RU|ru_RU.UTF-8|ru_RU.utf8)
                update-locale LANG=ru_RU.UTF-8 LC_ALL=ru_RU.UTF-8
                ;;
            *)
                update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
                ;;
        esac
    else
        echo
        print_color "yellow" "Выберите локаль по умолчанию:"
        echo "  1) ru_RU.UTF-8"
        echo "  2) en_US.UTF-8"
        read -r -p "Выбор (1/2) [2]: " locale_choice < /dev/tty
        case "$locale_choice" in
            1)
                update-locale LANG=ru_RU.UTF-8 LC_ALL=ru_RU.UTF-8
                ;;
            *)
                update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
                ;;
        esac
    fi
    print_color "green" "Локали настроены."
}

# 3b. Настройка часового пояса
setup_timezone_only() {
    step "3b. Настройка часового пояса"
    print_color "yellow" "Устанавливаем пакет tzdata..."
    apt-get install -y tzdata
    local TZ_TO_SET_VAL
    if [ "$NONINTERACTIVE" = true ] && [ -n "$TIMEZONE" ]; then
        TZ_TO_SET_VAL="$TIMEZONE"
        print_color "yellow" "Установка часового пояса: $TZ_TO_SET_VAL"
    else
        echo
        print_color "yellow" "Пример формата: Europe/Moscow"
        read -r -p "Введите часовой пояс (Enter — пропустить): " TZ_TO_SET_VAL < /dev/tty
    fi
    if [ -n "$TZ_TO_SET_VAL" ]; then
        if command -v timedatectl >/dev/null 2>&1; then
            if timedatectl set-timezone "$TZ_TO_SET_VAL" 2>/dev/null; then
                print_color "green" "Часовой пояс установлен через timedatectl: $TZ_TO_SET_VAL"
            else
                print_color "yellow" "timedatectl не применил часовой пояс. Пробуем через ссылку..."
                if [ -f "/usr/share/zoneinfo/$TZ_TO_SET_VAL" ]; then
                    ln -sf "/usr/share/zoneinfo/$TZ_TO_SET_VAL" /etc/localtime
                    dpkg-reconfigure -f noninteractive tzdata
                    print_color "green" "Часовой пояс установлен: $TZ_TO_SET_VAL"
                else
                    print_color "red" "Зона времени не найдена: $TZ_TO_SET_VAL"
                fi
            fi
        else
            if [ -f "/usr/share/zoneinfo/$TZ_TO_SET_VAL" ]; then
                ln -sf "/usr/share/zoneinfo/$TZ_TO_SET_VAL" /etc/localtime
                dpkg-reconfigure -f noninteractive tzdata
                print_color "green" "Часовой пояс установлен: $TZ_TO_SET_VAL"
            else
                print_color "red" "Зона времени не найдена: $TZ_TO_SET_VAL"
            fi
        fi
    else
        print_color "yellow" "Пропуск изменения часового пояса."
    fi
}

# 9. Автоматические обновления безопасности
setup_auto_updates() {
    step "9. Настройка автоматических обновлений безопасности"
    apt-get install -y unattended-upgrades apt-listchanges
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
    cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    print_color "green" "Автоматические обновления безопасности настроены."
}

# 4. Настройка /etc/wsl.conf
setup_wsl_conf() {
    step "4. Настройка /etc/wsl.conf"
    local wsl_user
    if [ "$NONINTERACTIVE" = true ]; then
        wsl_user="${WSL_DEFAULT_USER:-$DEFAULT_USER}"
        print_color "yellow" "Будет установлен пользователь по умолчанию: $wsl_user"
    else
        print_color "yellow" "Введите имя пользователя по умолчанию для WSL (например, $DEFAULT_USER):"
        read -r wsl_user < /dev/tty
        if [ -z "$wsl_user" ]; then
            wsl_user=$DEFAULT_USER
        fi
    fi

    print_color "yellow" "Создаем /etc/wsl.conf с пользователем '$wsl_user'..."
    cat > /etc/wsl.conf << EOL
[user]
default=$wsl_user

[interop]
enabled=true
appendWindowsPath=true

[boot]
systemd=true

[network]
generateResolvConf = true
EOL
    print_color "green" "Файл /etc/wsl.conf успешно создан."
    print_color "yellow" "Не забудьте перезапустить WSL командой 'wsl --shutdown' в PowerShell."
}

# 5. Установка компонентов NVIDIA
install_nvidia() {
    step "5. Установка компонентов NVIDIA для WSL"
    print_color "yellow" "Добавляем GPG-ключ и репозиторий NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

    apt-get update
    print_color "yellow" "Устанавливаем NVIDIA Container Toolkit..."
    apt-get install -y nvidia-container-toolkit

    # Опционально: установить CUDA Toolkit, если доступен в текущем дистрибутиве
    if apt-cache policy nvidia-cuda-toolkit 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vq "(none)"; then
        print_color "yellow" "Устанавливаем NVIDIA CUDA Toolkit (библиотеки и утилиты)..."
        if apt-get install -y nvidia-cuda-toolkit; then
            print_color "green" "CUDA Toolkit установлен."
        else
            print_color "yellow" "Не удалось установить nvidia-cuda-toolkit. Продолжаем с Container Toolkit."
        fi
    else
        print_color "yellow" "Пакет nvidia-cuda-toolkit недоступен для ${DEBIAN_CODENAME}. Пропускаем установку CUDA."
    fi

    # Если Docker уже установлен, настроим рантайм NVIDIA сразу
    if command -v nvidia-ctk >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
        print_color "yellow" "Конфигурируем Docker для использования NVIDIA runtime..."
        nvidia-ctk runtime configure --runtime=docker || true
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart docker || true
        fi
    fi

    print_color "green" "NVIDIA Container Toolkit установлен."
    print_color "yellow" "Для проверки GPU в контейнерах: docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi"
}

# 6. Установка базовых утилит
install_base_utils() {
    step "6. Установка базовых утилит"
    apt-get install -y \
        nano \
        python3 \
        python3-pip \
        python3-venv \
        htop \
        wget \
        unzip \
        git \
        build-essential \
        pkg-config \
        fzf \
        fd-find \
        bat
    print_color "green" "Базовые утилиты установлены."
}

# 7. Настройка Fish Shell
setup_fish() {
    step "7. Настройка Fish Shell для пользователя и root"
    local target_user
    if [ "$NONINTERACTIVE" = true ]; then
        target_user="${FISH_USER:-$DEFAULT_USER}"
        print_color "yellow" "Настройка Fish для пользователя: $target_user"
    else
        print_color "yellow" "Введите имя пользователя для настройки Fish (например, $DEFAULT_USER):"
        read -r target_user < /dev/tty
        if [ -z "$target_user" ]; then
            target_user=$DEFAULT_USER
        fi
    fi

    if ! id "$target_user" &>/dev/null; then
        print_color "red" "Пользователь '$target_user' не найден. Пропускаем настройку для пользователя."
        return 1
    fi

    print_color "yellow" "Устанавливаем Fish..."
    apt-get install -y fish

    # Настройка для пользователя
    print_color "yellow" "Настраиваем Fish для пользователя '$target_user'..."
    runuser -u $target_user -- bash -c "\
        mkdir -p ~/.config/fish/{functions,completions}; \
        echo '# --- Fish Shell Config ---' > ~/.config/fish/config.fish; \
        echo 'set -U fish_greeting' >> ~/.config/fish/config.fish; \
        echo \"alias ll='ls -la'\" >> ~/.config/fish/config.fish; \
        echo \"alias cat='batcat --paging=never'\" >> ~/.config/fish/config.fish; \
        echo \"alias fd='fdfind'\" >> ~/.config/fish/config.fish; \
        echo 'starship init fish | source' >> ~/.config/fish/config.fish; \
        curl -sS https://starship.rs/install.sh | sh -s -- -y; \
        fish -c 'curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher'; \
        fish -c 'fisher install jethrokuan/z PatrickF1/fzf.fish jorgebucaran/autopair.fish franciscolourenco/done edc/bass'; \
    "
    chsh -s /usr/bin/fish $target_user

    # Настройка для root
    print_color "yellow" "Настраиваем Fish для root..."
    mkdir -p /root/.config/fish/functions
    cp -r /home/$target_user/.config/fish/ /root/.config/
    chsh -s /usr/bin/fish root

    print_color "green" "Fish Shell настроен для '$target_user' и root."
}

# 8. Установка Docker
install_docker() {
    step "8. Установка Docker с поддержкой GPU"
    print_color "yellow" "Добавляем GPG-ключ Docker..."
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    # Добавление репозитория Docker с поддержкой fallback для trixie -> bookworm
    docker_key="/etc/apt/keyrings/docker.gpg"
    docker_list="/etc/apt/sources.list.d/docker.list"
    try_docker_codename() {
        local codename="$1"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=${docker_key}] https://download.docker.com/linux/debian ${codename} stable" > "${docker_list}"
        apt-get update -o Dir::Etc::sourcelist="${docker_list}" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
    }

    CHOSEN_DOCKER_CODENAME=""
    if try_docker_codename "$DEBIAN_CODENAME"; then
        CHOSEN_DOCKER_CODENAME="$DEBIAN_CODENAME"
    elif [ "$DEBIAN_CODENAME" != "bookworm" ] && try_docker_codename "bookworm"; then
        CHOSEN_DOCKER_CODENAME="bookworm"
        print_color "yellow" "Репозиторий Docker для ${DEBIAN_CODENAME} недоступен. Используем bookworm как fallback."
    else
        print_color "red" "Не удалось настроить репозиторий Docker ни для ${DEBIAN_CODENAME}, ни для bookworm."
        print_color "yellow" "Пропускаем установку Docker."
        return 1
    fi

    print_color "yellow" "Устанавливаем Docker..."
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Настраиваем Docker для использования NVIDIA GPU, если доступен nvidia-ctk
    if command -v nvidia-ctk >/dev/null 2>&1; then
        print_color "yellow" "Настраиваем Docker для NVIDIA runtime..."
        nvidia-ctk runtime configure --runtime=docker || true
    fi

    # Перезапуск/включение службы Docker (при активном systemd в WSL после перезапуска)
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable docker || true
        systemctl restart docker || systemctl start docker || true
    fi

    # Добавляем пользователя в группу docker
    if getent passwd "$DEFAULT_USER" >/dev/null 2>&1; then
        print_color "yellow" "Добавляем пользователя $DEFAULT_USER в группу docker..."
        usermod -aG docker $DEFAULT_USER || true
    fi

    print_color "green" "Docker успешно установлен и (по возможности) настроен."
    print_color "yellow" "Перезайдите в систему, чтобы использовать docker без sudo."
}

# --- Интерактивное меню ---
select_components() {
    # Удалено PS3-меню. Вызываем новое меню и выходим.
    select_components_v2
    return
    clear
    print_color "blue" "╔══════════════════════════════════════╗"
    print_color "blue" "║  Скрипт настройки ${DEBIAN_VERSION_HUMAN} (WSL)  ║"
    print_color "blue" "╚══════════════════════════════════════╝"
    echo
    print_color "yellow" "Этот скрипт поможет вам настроить основные компоненты системы."
    print_color "yellow" "Перед началом убедитесь, что в PowerShell выполнены команды:"
    print_color "yellow" "1. wsl --update"
    print_color "yellow" "2. wsl --set-default-version 2"
    print_color "yellow" "3. Создан файл C:\Users\<USER>\.wslconfig с настройками памяти/CPU."
    echo

}

# Меню в стиле VPS (Y/N по каждой опции)
select_components_v2() {
    clear
    print_color "blue" "╔═════════════════════════════════════════╗"
    print_color "blue" "$(printf '║ %-37s ║' "НАСТРОЙКА: ${DEBIAN_VERSION_HUMAN}")"
    print_color "blue" "╚═════════════════════════════════════════╝"
    echo
    print_color "yellow" "Перед началом в PowerShell:"
    print_color "yellow" "1) wsl --update; 2) wsl --set-default-version 2;"
    print_color "yellow" "3) Проверьте C:\\Users\\<USER>\\.wslconfig (RAM/CPU)."
    echo

    select_option() {
        local option="$1"; local var_name="$2"; local already="$3"
        if [ "$already" = true ]; then
            echo -e "\033[0;32m✓ $option (уже настроено)\033[0m"; return 0
        fi
        if [ "${!var_name}" = true ]; then
            echo -ne "\033[0;32m✓\033[0m $option (y/n): "
        else
            echo -ne "\033[0;33m○\033[0m $option (y/n): "
        fi
        read -r choice < /dev/tty
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            eval "$var_name=true"; echo -e "  \033[0;32m✓ Выбрано\033[0m"
        else
            eval "$var_name=false"; echo "  ○ Пропущено"
        fi
    }

    print_color "blue" "═════════════════════════════════════════"
    print_color "blue" "  ВЫБОР КОМПОНЕНТОВ"
    print_color "blue" "═════════════════════════════════════════"
    echo

    # Обновление системы
    apt_update_time=$(stat -c %Y /var/cache/apt/pkgcache.bin 2>/dev/null || echo 0)
    current_time=$(date +%s)
    time_diff=$((current_time - apt_update_time))
    if [ $time_diff -lt 86400 ]; then
        echo -e "\033[0;32m✓ Обновление системы (менее 24ч назад)\033[0m"
    else
        select_option "Обновление системы" "UPDATE_SYSTEM" "false"
    fi

    # Базовые утилиты
    base_utils_installed=true
    for util in curl wget htop git nano; do if ! is_installed $util; then base_utils_installed=false; break; fi; done
    if [ "$base_utils_installed" = true ]; then
        echo -e "\033[0;32m✓ Базовые утилиты (уже установлены)\033[0m"
    else
        select_option "Базовые утилиты (git, build-essential, fzf, bat и др.)" "INSTALL_BASE_UTILS" "false"
    fi

    # Создание пользователя
    select_option "Создать нового пользователя с правами sudo" "CREATE_USER" "false"

    # Локали
    if locale -a 2>/dev/null | grep -qi '^ru_RU\.utf8$'; then
        echo -e "\033[0;32m✓ Локали (ru_RU уже есть)\033[0m"
    else
        select_option "Настроить локали (ru_RU, en_US)" "SETUP_LOCALES" "false"
    fi

    # Часовой пояс
    current_tz="$(timedatectl show --property=Timezone --value 2>/dev/null)"
    [ -n "$current_tz" ] && echo -e "  Текущий часовой пояс: \033[1;34m$current_tz\033[0m"
    select_option "Настроить часовой пояс" "SETUP_TIMEZONE" "false"

    # wsl.conf (systemd)
    if [ -f /etc/wsl.conf ] && grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
        echo -e "\033[0;32m✓ wsl.conf (systemd включен)\033[0m"
    else
        select_option "Создать /etc/wsl.conf (systemd, пользователь по умолчанию)" "SETUP_WSL_CONF" "false"
    fi

    # NVIDIA
    select_option "Установить компоненты NVIDIA (Container Toolkit, CUDA)" "INSTALL_NVIDIA" "false"

    # Fish
    if is_installed fish; then
        echo -e "\033[0;32m✓ Fish shell (уже установлен)\033[0m"
    else
        select_option "Настроить Fish Shell (Fisher, Starship, плагины)" "SETUP_FISH" "false"
    fi

    # Docker
    if is_installed docker-ce; then
        echo -e "\033[0;32m✓ Docker (уже установлен)\033[0m"
    else
        select_option "Установить Docker с поддержкой GPU" "INSTALL_DOCKER" "false"
    fi

    # Автообновления
    if grep -qs 'APT::Periodic::Unattended-Upgrade\s*"1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        echo -e "\033[0;32m✓ Автообновления безопасности (уже включены)\033[0m"
    else
        select_option "Включить автообновления безопасности (unattended-upgrades)" "SETUP_AUTO_UPDATES" "false"
    fi

    echo
    print_color "yellow" "═════════════════════════════════════════"
    print_color "yellow" "  Начинаем установку выбранных компонентов"
    print_color "yellow" "═════════════════════════════════════════"
    echo

    # Запуск выбранных функций
    if [ "$CREATE_USER" = true ]; then create_user; fi
    if [ "$UPDATE_SYSTEM" = true ]; then update_system; fi
    if [ "$SETUP_LOCALES" = true ]; then setup_locales_only; fi
    if [ "$SETUP_TIMEZONE" = true ]; then setup_timezone_only; fi
    if [ "$SETUP_WSL_CONF" = true ]; then setup_wsl_conf; fi
    if [ "$INSTALL_NVIDIA" = true ]; then install_nvidia; fi
    if [ "$INSTALL_BASE_UTILS" = true ]; then install_base_utils; fi
    if [ "$SETUP_FISH" = true ]; then setup_fish; fi
    if [ "$INSTALL_DOCKER" = true ]; then install_docker; fi
    if [ "$SETUP_AUTO_UPDATES" = true ]; then setup_auto_updates; fi

    print_color "green" "\nГотово!"
    print_color "yellow" "Важно: выполните 'wsl --shutdown' в PowerShell, затем запустите Debian."
}

# Неинтерактивный режим: отображение выбранных флагов
select_components_noninteractive() {
    echo
    print_color "blue" "╔═════════════════════════════════════════╗"
    print_color "blue" "$(printf '║ %-37s ║' "НАСТРОЙКА: ${DEBIAN_VERSION_HUMAN}")"
    print_color "blue" "$(printf '║ %-37s ║' "НЕИНТЕРАКТИВНЫЙ РЕЖИМ")"
    print_color "blue" "╚═════════════════════════════════════════╝"
    echo
    show_flag() { local title="$1"; local var="$2"; if [ "${!var}" = true ]; then echo -e "\033[0;32m✓ $title (включено)\033[0m"; else echo -e "\033[0;33m○ $title (отключено)\033[0m"; fi; }
    show_flag "Обновление системы" UPDATE_SYSTEM
    show_flag "Базовые утилиты" INSTALL_BASE_UTILS
    show_flag "Создание пользователя (NEW_USERNAME=$NEW_USERNAME)" CREATE_USER
    show_flag "Настройка локалей (LOCALE_DEFAULT=$LOCALE_DEFAULT)" SETUP_LOCALES
    show_flag "Часовой пояс (TIMEZONE=$TIMEZONE)" SETUP_TIMEZONE
    show_flag "wsl.conf (WSL_DEFAULT_USER=$WSL_DEFAULT_USER)" SETUP_WSL_CONF
    show_flag "Компоненты NVIDIA" INSTALL_NVIDIA
    show_flag "Fish Shell (FISH_USER=$FISH_USER)" SETUP_FISH
    show_flag "Docker" INSTALL_DOCKER
    show_flag "Автообновления безопасности" SETUP_AUTO_UPDATES
    echo
}
# --- Точка входа в скрипт ---
if [ "$NONINTERACTIVE" = true ]; then
    select_components_noninteractive
else
    # Используем новое меню в стиле VPS
    select_components_v2
fi
