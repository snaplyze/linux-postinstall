#!/bin/bash
# Проверка, что скрипт запущен с правами root

if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен с правами root. Выполните: sudo $0"
    exit 1
fi

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

# --- Переменные для выбора компонентов ---
UPDATE_SYSTEM=false
CREATE_USER=false
SETUP_LOCALES_TIME=false
SETUP_WSL_CONF=false
INSTALL_NVIDIA=false
INSTALL_BASE_UTILS=false
SETUP_FISH=false
INSTALL_DOCKER=false

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
    print_color "yellow" "Введите имя нового пользователя:"
    read -r new_user < /dev/tty
    if [ -z "$new_user" ]; then
        print_color "red" "Имя пользователя не может быть пустым. Пропуск."
        return 1
    fi

    if id "$new_user" &>/dev/null; then
        print_color "yellow" "Пользователь '$new_user' уже существует. Пропуск."
        return 0
    fi

    print_color "yellow" "Создаем пользователя '$new_user' с оболочкой /bin/bash..."
    useradd -m -G sudo -s /bin/bash "$new_user"

    print_color "yellow" "Установите пароль для пользователя '$new_user':"
    passwd "$new_user" < /dev/tty

    print_color "yellow" "Настраиваем sudo без пароля для '$new_user'..."
    echo "$new_user ALL=(ALL) NOPASSWD: ALL" | tee "/etc/sudoers.d/$new_user" > /dev/null
    chmod 440 "/etc/sudoers.d/$new_user"

    print_color "green" "Пользователь '$new_user' успешно создан."
    print_color "yellow" "Теперь вы можете запустить для него настройку Fish Shell."
}

# 2. Обновление системы и репозиториев
update_system() {
    step "2. Обновление системы и репозиториев"
    print_color "yellow" "Включаем репозитории contrib, non-free и non-free-firmware..."
    sed -i 's/main/main contrib non-free non-free-firmware/g' /etc/apt/sources.list
    
    print_color "yellow" "Обновляем список пакетов и систему..."
    apt-get update && apt-get upgrade -y
    
    print_color "yellow" "Устанавливаем базовые пакеты для работы с репозиториями..."
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
    print_color "green" "Система успешно обновлена."
}

# 3. Настройка локализации и времени
setup_locales_time() {
    step "3. Настройка локализации и времени"
    print_color "yellow" "Устанавливаем пакеты locales и tzdata..."
    apt-get install -y locales tzdata

    print_color "yellow" "Настраиваем русскую и английскую локали..."
    sed -i 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
    sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen

    print_color "yellow" "Устанавливаем системный язык по умолчанию..."
    update-locale LANG=ru_RU.UTF-8

    print_color "yellow" "Настраиваем глобальные переменные окружения в /etc/environment..."
    cat > /etc/environment << EOL
LANG=ru_RU.UTF-8
LC_ALL=ru_RU.UTF-8
LANGUAGE=ru_RU:ru
EOL

    print_color "yellow" "Устанавливаем часовой пояс Europe/Moscow..."
    ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
    dpkg-reconfigure -f noninteractive tzdata
    print_color "green" "Локализация и время настроены."
}

# 4. Настройка /etc/wsl.conf
setup_wsl_conf() {
    step "4. Настройка /etc/wsl.conf"
    print_color "yellow" "Введите имя пользователя по умолчанию для WSL (например, $DEFAULT_USER):"
    read -r wsl_user
    if [ -z "$wsl_user" ]; then
        wsl_user=$DEFAULT_USER
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

    print_color "yellow" "Устанавливаем NVIDIA CUDA Toolkit (библиотеки и утилиты)..."
    apt-get install -y nvidia-cuda-toolkit
    print_color "green" "Компоненты NVIDIA успешно установлены."
    print_color "yellow" "Проверьте работу командой 'nvidia-smi' после перезапуска WSL."
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
    print_color "yellow" "Введите имя пользователя для настройки Fish (например, $DEFAULT_USER):"
    read -r target_user
    if [ -z "$target_user" ]; then
        target_user=$DEFAULT_USER
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
    print_color "yellow" "Добавляем GPG-ключ и репозиторий Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update
    print_color "yellow" "Устанавливаем Docker..."
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    print_color "yellow" "Настраиваем Docker для использования NVIDIA GPU..."
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    print_color "yellow" "Добавляем пользователя $DEFAULT_USER в группу docker..."
    usermod -aG docker $DEFAULT_USER

    print_color "yellow" "Включаем службу Docker..."
    systemctl enable docker
    systemctl start docker

    print_color "green" "Docker успешно установлен и настроен."
    print_color "yellow" "Перезайдите в систему, чтобы использовать docker без sudo."
}

# --- Интерактивное меню ---
select_components() {
    clear
    print_color "blue" "╔══════════════════════════════════════╗"
    print_color "blue" "║    Скрипт настройки Debian для WSL   ║"
    print_color "blue" "╚══════════════════════════════════════╝"
    echo
    print_color "yellow" "Этот скрипт поможет вам настроить основные компоненты системы."
    print_color "yellow" "Перед началом убедитесь, что в PowerShell выполнены команды:"
    print_color "yellow" "1. wsl --update"
    print_color "yellow" "2. wsl --set-default-version 2"
    print_color "yellow" "3. Создан файл C:\Users\<USER>\.wslconfig с настройками памяти/CPU."
    echo

    PS3='Выберите опцию (номер) и нажмите Enter: '
    options=(
        "Создать нового пользователя с правами sudo"
        "Обновить систему и репозитории"
        "Настроить локализацию и время"
        "Создать /etc/wsl.conf (для systemd и пользователя по умолчанию)"
        "Установить компоненты NVIDIA (CUDA Toolkit, Container Toolkit)"
        "Установить базовые утилиты (git, build-essential, fzf, bat и др.)"
        "Настроить Fish Shell (Fisher, Starship, плагины) для пользователя и root"
        "Установить Docker с поддержкой GPU"
        "Выполнить все шаги"
        "Выход"
    )
    select opt in "${options[@]}"
    do
        case $opt in
            "Создать нового пользователя с правами sudo") CREATE_USER=true; break;;
            "Обновить систему и репозитории") UPDATE_SYSTEM=true; break;;
            "Настроить локализацию и время") SETUP_LOCALES_TIME=true; break;; 
            "Создать /etc/wsl.conf (для systemd и пользователя по умолчанию)") SETUP_WSL_CONF=true; break;; 
            "Установить компоненты NVIDIA (CUDA Toolkit, Container Toolkit)") INSTALL_NVIDIA=true; break;; 
            "Установить базовые утилиты (git, build-essential, fzf, bat и др.)") INSTALL_BASE_UTILS=true; break;; 
            "Настроить Fish Shell (Fisher, Starship, плагины) для пользователя и root") SETUP_FISH=true; break;; 
            "Установить Docker с поддержкой GPU") INSTALL_DOCKER=true; break;; 
            "Выполнить все шаги") 
                CREATE_USER=true; UPDATE_SYSTEM=true; SETUP_LOCALES_TIME=true; SETUP_WSL_CONF=true; 
                INSTALL_NVIDIA=true; INSTALL_BASE_UTILS=true; SETUP_FISH=true; INSTALL_DOCKER=true; 
                break;;
            "Выход") exit 0;; 
            *) echo "Неверная опция $REPLY";;
        esac
    done < /dev/tty

    # Запуск выбранных функций
    if [ "$CREATE_USER" = true ]; then create_user; fi
    if [ "$UPDATE_SYSTEM" = true ]; then update_system; fi
    if [ "$SETUP_LOCALES_TIME" = true ]; then setup_locales_time; fi
    if [ "$SETUP_WSL_CONF" = true ]; then setup_wsl_conf; fi
    if [ "$INSTALL_NVIDIA" = true ]; then install_nvidia; fi
    if [ "$INSTALL_BASE_UTILS" = true ]; then install_base_utils; fi
    if [ "$SETUP_FISH" = true ]; then setup_fish; fi
    if [ "$INSTALL_DOCKER" = true ]; then install_docker; fi

    print_color "green" "\n🎉 Настройка завершена! 🎉"
    print_color "yellow" "КРИТИЧЕСКИ ВАЖНО: для применения всех изменений (WSL.conf, группы Docker)"
    print_color "yellow" "выполните команду 'wsl --shutdown' в PowerShell и запустите Debian заново."
}

# --- Точка входа в скрипт ---
select_components
