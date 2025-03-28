#!/bin/bash

# arch-setup.sh - Полный скрипт настройки Arch Linux с GNOME 48
# Разработан для: Intel Core i7 13700k, RTX 4090, 32 ГБ ОЗУ, 4 NVME Gen4, 2 HDD
# Версия: 1.0 (Март 2025)

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Сброс цвета

# Функция для печати заголовков
print_header() {
    echo -e "\n${BLUE}===== $1 =====${NC}\n"
}

# Функция для печати успешных операций
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Функция для печати предупреждений
print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Функция для печати ошибок
print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Функция для запроса подтверждения
confirm() {
    local prompt="$1 (y/N): "
    local response
    read -p "$prompt" response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# Функция для запуска команды с проверкой ошибок
run_command() {
    echo -e "${YELLOW}Выполняется:${NC} $1"
    if eval "$1"; then
        print_success "Команда успешно выполнена"
    else
        print_error "Ошибка при выполнении команды"
        if [ "$2" = "critical" ]; then
            print_error "Критическая ошибка, выход из скрипта"
            exit 1
        fi
    fi
}

# Проверка, запущен ли скрипт от имени обычного пользователя (не root)
if [ "$EUID" -eq 0 ]; then
    print_error "Этот скрипт должен быть запущен от имени обычного пользователя, а не root"
    exit 1
fi

# Вывод информации о системе
print_header "Информация о системе"
echo "Ядро Linux: $(uname -r)"
echo "Дистрибутив: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "Процессор: $(lscpu | grep "Model name" | sed 's/Model name: *//')"
echo "Память: $(free -h | awk '/^Mem:/ {print $2}')"
echo "Диски:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS

# Проверка, установлена ли система с использованием systemd-boot
if [ ! -d "/boot/loader" ]; then
    print_warning "Не найдена директория /boot/loader. Возможно, systemd-boot не используется."
    if ! confirm "Продолжить выполнение скрипта?"; then
        exit 1
    fi
fi

# Проверка, используется ли ядро linux-zen
if [ ! -f "/boot/vmlinuz-linux-zen" ]; then
    print_warning "Не найдено ядро linux-zen. Скрипт настроен для linux-zen."
    if ! confirm "Продолжить выполнение скрипта?"; then
        exit 1
    fi
fi

# Вывод меню выбора действий
print_header "Выберите операции для выполнения"
echo "1. Обновление системы и базовая настройка"
echo "2. Установка драйверов NVIDIA и настройка для Wayland"
echo "3. Оптимизация NVMe и HDD"
echo "4. Форматирование дополнительных дисков"
echo "5. Скрытие логов при загрузке"
echo "6. Установка Paru в скрытую папку"
echo "7. Настройка Flathub и GNOME Software"
echo "8. Установка Steam и библиотек"
echo "9. Установка Proton GE"
echo "10. Оптимизация для Wayland"
echo "11. Настройка управления питанием"
echo "12. Настройка локализации и безопасности"
echo "13. Установка дополнительных программ"
echo "14. Установка Timeshift для резервного копирования"
echo "15. Все операции (1-14)"
echo "0. Выход"

read -p "Введите номера операций через пробел (например: 1 2 3): " choices

# Преобразуем выбор в массив
IFS=' ' read -r -a selected_options <<< "$choices"

# Если выбрана опция "Все операции", устанавливаем все опции
if [[ " ${selected_options[@]} " =~ " 15 " ]]; then
    selected_options=(1 2 3 4 5 6 7 8 9 10 11 12 13 14)
fi

# Проверяем, содержит ли массив определенную опцию
contains() {
    local n=$1
    shift
    for i; do
        if [ "$i" = "$n" ]; then
            return 0
        fi
    done
    return 1
}

# 1. Обновление системы и базовая настройка
if contains 1 "${selected_options[@]}"; then
    print_header "1. Обновление системы и базовая настройка"
    
    # Обновление системы
    run_command "sudo pacman -Syu --noconfirm"
    
    # Установка intel-ucode (микрокод процессора Intel)
    if ! pacman -Qi intel-ucode &> /dev/null; then
        run_command "sudo pacman -S --noconfirm intel-ucode"
    else
        print_success "intel-ucode уже установлен"
    fi
    
    # Установка базовых утилит
    run_command "sudo pacman -S --needed --noconfirm base-devel git curl wget bash-completion"
fi

# 2. Установка драйверов NVIDIA и настройка для Wayland
if contains 2 "${selected_options[@]}"; then
    print_header "2. Установка драйверов NVIDIA и настройка для Wayland"
    
    # Установка драйверов NVIDIA
    run_command "sudo pacman -S --needed --noconfirm nvidia-dkms nvidia-utils nvidia-settings libva-nvidia-driver"
    
    # Создание конфигурационного файла для NVIDIA
    run_command "sudo mkdir -p /etc/modprobe.d/"
    
    # Проверка существования файла
    if [ -f "/etc/modprobe.d/nvidia.conf" ]; then
        print_warning "Файл /etc/modprobe.d/nvidia.conf уже существует"
        cat /etc/modprobe.d/nvidia.conf
    else
        run_command "cat << EOF | sudo tee /etc/modprobe.d/nvidia.conf
options nvidia-drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF"
    fi
    
    # Добавление модулей NVIDIA в initramfs
    if ! grep -q "nvidia" /etc/mkinitcpio.conf; then
        run_command "sudo sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf"
        run_command "sudo mkinitcpio -P linux-zen" "critical"
    else
        print_success "Модули NVIDIA уже добавлены в mkinitcpio.conf"
    fi
fi

# 3. Оптимизация NVMe и HDD
if contains 3 "${selected_options[@]}"; then
    print_header "3. Оптимизация NVMe и HDD"
    
    # Установка утилит для NVMe и HDD
    run_command "sudo pacman -S --needed --noconfirm nvme-cli hdparm smartmontools"
    
    # Включение TRIM для NVMe
    run_command "sudo systemctl enable fstrim.timer"
    run_command "sudo systemctl start fstrim.timer"
    
    # Проверка текущих параметров NVMe
    echo "Список NVMe устройств:"
    run_command "sudo nvme list"
    
    # Проверяем SMART для первого NVMe
    if [ -e "/dev/nvme0n1" ]; then
        run_command "sudo nvme smart-log /dev/nvme0n1"
    fi
    
    # Настройка кэша метаданных BTRFS
    cat << EOF | sudo tee /etc/sysctl.d/60-btrfs-performance.conf > /dev/null
# Увеличение лимита кэша метаданных для BTRFS
vm.dirty_bytes = 4294967296
vm.dirty_background_bytes = 1073741824
EOF
    
    run_command "sudo sysctl --system"
    
    print_success "Оптимизация NVMe и параметров системы выполнена"
fi

# 4. Форматирование дополнительных дисков
if contains 4 "${selected_options[@]}"; then
    print_header "4. Форматирование дополнительных дисков"
    
    # Предупреждение
    print_warning "ВНИМАНИЕ! Эта операция необратимо уничтожит все данные на выбранных дисках!"
    echo "Состояние дисков в системе:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,LABEL
    
    # Спрашиваем про NVMe диски
    if confirm "Форматировать NVMe диски (кроме системного)?"; then
        # Получаем список всех NVMe дисков, кроме системного (nvme0n1)
        nvme_disks=$(lsblk -o NAME,TYPE | grep "nvme" | grep "disk" | grep -v "nvme0n1" | awk '{print $1}')
        
        if [ -z "$nvme_disks" ]; then
            print_warning "Дополнительные NVMe диски не найдены"
        else
            echo "Найдены следующие NVMe диски для форматирования:"
            echo "$nvme_disks"
            
            for disk in $nvme_disks; do
                if confirm "Форматировать /dev/$disk?"; then
                    # Создание GPT таблицы разделов
                    run_command "sudo parted /dev/$disk mklabel gpt"
                    
                    # Создание одного большого раздела
                    run_command "sudo parted -a optimal /dev/$disk mkpart primary ext4 0% 100%"
                    
                    # Форматирование в ext4
                    label=$(echo "$disk" | tr -d "0123456789/")
                    run_command "sudo mkfs.ext4 -L $label /dev/$disk"
                    
                    # Создание точки монтирования
                    run_command "sudo mkdir -p /mnt/$label"
                    
                    # Добавление записи в fstab, если её ещё нет
                    if ! grep -q "LABEL=$label" /etc/fstab; then
                        echo "LABEL=$label  /mnt/$label  ext4  defaults,noatime,x-gvfs-show  0 2" | sudo tee -a /etc/fstab
                    fi
                    
                    # Монтирование диска
                    run_command "sudo mount /mnt/$label"
                    
                    print_success "Диск /dev/$disk успешно отформатирован и примонтирован"
                fi
            done
        fi
    fi
    
    # Спрашиваем про HDD диски
    if confirm "Форматировать HDD диски (sda, sdb)?"; then
        # Получаем список всех HDD дисков
        hdd_disks=$(lsblk -o NAME,TYPE | grep "sd" | grep "disk" | awk '{print $1}')
        
        if [ -z "$hdd_disks" ]; then
            print_warning "HDD диски не найдены"
        else
            echo "Найдены следующие HDD диски для форматирования:"
            echo "$hdd_disks"
            
            for disk in $hdd_disks; do
                if confirm "Форматировать /dev/$disk?"; then
                    # Оптимизация HDD перед форматированием
                    run_command "sudo hdparm -W 1 /dev/$disk"  # Включение кэша записи
                    run_command "sudo hdparm -B 127 -S 120 /dev/$disk"  # Настройка энергосбережения
                    
                    # Создание GPT таблицы разделов
                    run_command "sudo parted /dev/$disk mklabel gpt"
                    
                    # Создание одного большого раздела
                    run_command "sudo parted -a optimal /dev/$disk mkpart primary ext4 0% 100%"
                    
                    # Форматирование в ext4
                    label="hdd$(echo "$disk" | grep -o '[a-z]$')"
                    run_command "sudo mkfs.ext4 -L $label /dev/${disk}1"
                    
                    # Создание точки монтирования
                    run_command "sudo mkdir -p /mnt/$label"
                    
                    # Добавление записи в fstab, если её ещё нет
                    if ! grep -q "LABEL=$label" /etc/fstab; then
                        echo "LABEL=$label  /mnt/$label  ext4  defaults,noatime,x-gvfs-show  0 2" | sudo tee -a /etc/fstab
                    fi
                    
                    # Монтирование диска
                    run_command "sudo mount /mnt/$label"
                    
                    print_success "Диск /dev/$disk успешно отформатирован и примонтирован"
                fi
            done
        fi
    fi
    
    # Установка gvfs для отображения дисков в файловом менеджере
    run_command "sudo pacman -S --needed --noconfirm gvfs gvfs-mtp gvfs-smb gvfs-nfs"
    
    print_success "Форматирование и монтирование дисков завершено"
fi

# 5. Скрытие логов при загрузке
if contains 5 "${selected_options[@]}"; then
    print_header "5. Скрытие логов при загрузке"
    
    # Создаем или обновляем параметры ядра
    run_command "sudo mkdir -p /etc/kernel/cmdline.d/"
    
    # Конфигурация для тихой загрузки
    cat << EOF | sudo tee /etc/kernel/cmdline.d/quiet.conf > /dev/null
quiet loglevel=3 rd.systemd.show_status=false rd.udev.log_level=3 vt.global_cursor_default=0 splash plymouth.enable=1
EOF
    
    # Отключение журналирования на tty
    run_command "sudo mkdir -p /etc/systemd/journald.conf.d/"
    cat << EOF | sudo tee /etc/systemd/journald.conf.d/quiet.conf > /dev/null
[Journal]
TTYPath=/dev/null
EOF
    
    # Установка и настройка Plymouth для красивой загрузки
    run_command "sudo pacman -S --needed --noconfirm plymouth"
    
    # Добавление plymouth в HOOKS
    if ! grep -q "plymouth" /etc/mkinitcpio.conf; then
        run_command "sudo sed -i 's/^HOOKS=.*/HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf"
        run_command "sudo mkinitcpio -P linux-zen"
    else
        print_success "Plymouth уже добавлен в HOOKS mkinitcpio.conf"
    fi
    
    # Настройка systemd-boot
    run_command "sudo mkdir -p /boot/loader/"
    
    # Создание конфигурации systemd-boot
    cat << EOF | sudo tee /boot/loader/loader.conf > /dev/null
default arch-zen.conf
timeout 0
console-mode max
editor no
EOF
    
    # Создание загрузочной записи
    run_command "sudo mkdir -p /boot/loader/entries/"
    cat << EOF | sudo tee /boot/loader/entries/arch-zen.conf > /dev/null
title Arch Linux Zen
linux /vmlinuz-linux-zen
initrd /intel-ucode.img
initrd /initramfs-linux-zen.img
options $(cat /etc/kernel/cmdline.d/quiet.conf)
EOF
    
    # Обновление загрузчика
    run_command "sudo bootctl update"
    
    print_success "Настройка тихой загрузки завершена"
fi

# 6. Установка Paru в скрытую папку
if contains 6 "${selected_options[@]}"; then
    print_header "6. Установка Paru в скрытую папку"
    
    # Проверка, установлен ли paru
    if command -v paru &> /dev/null; then
        print_success "Paru уже установлен. Пропускаем установку."
    else
        # Создание скрытой папки для Paru
        run_command "mkdir -p ~/.local/paru"
        
        # Клонирование репозитория Paru
        run_command "git clone https://aur.archlinux.org/paru.git ~/.local/paru/build"
        run_command "cd ~/.local/paru/build && makepkg -si --noconfirm"
    fi
    
    # Настройка Paru
    run_command "mkdir -p ~/.config/paru"
    
    # Создание конфигурации paru
    cat << EOF > ~/.config/paru/paru.conf
[options]
BottomUp
SudoLoop
Devel
CleanAfter
BatchInstall
NewVersion
UpgradeMenu
CombinedUpgrade
RemoveMake
KeepRepoCache
Redownload 
NewsOnUpgrade

# Папка для скачивания
CloneDir = ~/.local/paru/packages
EOF
    
    print_success "Установка и настройка Paru завершена"
fi

# 7. Настройка Flathub и GNOME Software
if contains 7 "${selected_options[@]}"; then
    print_header "7. Настройка Flathub и GNOME Software"
    
    # Установка Flatpak
    run_command "sudo pacman -S --needed --noconfirm flatpak"
    
    # Добавление репозитория Flathub
    run_command "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
    
    # Установка GNOME Software
    run_command "sudo pacman -S --needed --noconfirm gnome-software"
    
    # Установка платформы GNOME
    run_command "flatpak install -y flathub org.gnome.Platform//45"
    
    print_success "Настройка Flathub и GNOME Software завершена"
fi

# 8. Установка Steam и библиотек
if contains 8 "${selected_options[@]}"; then
    print_header "8. Установка Steam и библиотек"
    
    # Включение multilib репозитория
    if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
        run_command "sudo sed -i \"/\[multilib\]/,/Include/\"'s/^#//' /etc/pacman.conf"
        run_command "sudo pacman -Syu --noconfirm"
    else
        print_success "Репозиторий multilib уже включен"
    fi
    
    # Установка Steam и зависимостей
    run_command "sudo pacman -S --needed --noconfirm steam lib32-nvidia-utils \
      lib32-vulkan-icd-loader vulkan-icd-loader \
      lib32-vulkan-intel vulkan-intel \
      lib32-mesa vulkan-tools \
      lib32-libva-mesa-driver lib32-mesa-vdpau \
      libva-mesa-driver mesa-vdpau \
      lib32-openal lib32-alsa-plugins \
      xorg-mkfontscale xorg-fonts-cyrillic xorg-fonts-misc"
    
    print_success "Установка Steam и необходимых библиотек завершена"
fi

# 9. Установка Proton GE
if contains 9 "${selected_options[@]}"; then
    print_header "9. Установка Proton GE"
    
    # Создание директории для Proton GE
    run_command "mkdir -p ~/.steam/root/compatibilitytools.d/"
    
    # Проверка, установлен ли proton-ge-custom
    if paru -Qs proton-ge-custom-bin &> /dev/null; then
        print_success "Proton GE уже установлен через paru"
    else
        echo "Установить Proton GE через:"
        echo "1) paru (рекомендуется, автоматическое обновление)"
        echo "2) ручная загрузка (последняя версия)"
        read -p "Выберите метод (1/2): " ge_method
        
        if [ "$ge_method" = "1" ] || [ -z "$ge_method" ]; then
            run_command "paru -S --noconfirm proton-ge-custom-bin"
        else
            # Ручная установка последней версии
            print_header "Скачивание последней версии Proton GE..."
            PROTON_VERSION=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | grep "tag_name" | cut -d'"' -f4)
            run_command "wget -O /tmp/proton-ge.tar.gz https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${PROTON_VERSION}/GE-Proton${PROTON_VERSION:1}.tar.gz"
            
            print_header "Распаковка Proton GE..."
            run_command "tar -xzf /tmp/proton-ge.tar.gz -C ~/.steam/root/compatibilitytools.d/"
            run_command "rm /tmp/proton-ge.tar.gz"
        fi
    fi
    
    print_success "Установка Proton GE завершена"
fi

# 10. Оптимизация для Wayland
if contains 10 "${selected_options[@]}"; then
    print_header "10. Оптимизация для Wayland"
    
    # Добавляем переменные окружения для Wayland и NVIDIA
    cat << EOF | sudo tee -a /etc/environment > /dev/null
# Настройки Wayland и NVIDIA
LIBVA_DRIVER_NAME=nvidia
XDG_SESSION_TYPE=wayland
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
WLR_NO_HARDWARE_CURSORS=1
MOZ_ENABLE_WAYLAND=1
MOZ_WEBRENDER=1
QT_QPA_PLATFORM=wayland
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
EOF
    
    # Установка дополнительных пакетов для Wayland
    run_command "sudo pacman -S --needed --noconfirm qt6-wayland qt5-wayland xorg-xwayland"
    
    # Установка xwaylandvideobridge из AUR (опционально)
    if confirm "Установить xwaylandvideobridge для захвата экрана XWayland-приложений?"; then
        run_command "paru -S --noconfirm xwaylandvideobridge"
    fi
    
    print_success "Оптимизация для Wayland завершена"
fi

# 11. Настройка управления питанием
if contains 11 "${selected_options[@]}"; then
    print_header "11. Настройка управления питанием"
    
    # Установка power-profiles-daemon
    run_command "sudo pacman -S --needed --noconfirm power-profiles-daemon"
    run_command "sudo systemctl enable power-profiles-daemon.service"
    run_command "sudo systemctl start power-profiles-daemon.service"
    
    # Настройка автоматического перехода HDD в спящий режим
    run_command "sudo pacman -S --needed --noconfirm hdparm"
    
    # Создание правил для перевода HDD в спящий режим
    cat << EOF | sudo tee /etc/udev/rules.d/69-hdparm.rules > /dev/null
# Правила для перевода HDD в спящий режим при простое
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", RUN+="/usr/bin/hdparm -B 127 -S 120 /dev/%k"
EOF
    
    # Настройка systemd timer для регулярного применения настроек
    cat << EOF | sudo tee /etc/systemd/system/hdparm-idle.service > /dev/null
[Unit]
Description=Set hard disk spindown timeout

[Service]
Type=oneshot
ExecStart=/usr/bin/hdparm -B 127 -S 120 /dev/sda
ExecStart=/usr/bin/hdparm -B 127 -S 120 /dev/sdb
EOF
    
    cat << EOF | sudo tee /etc/systemd/system/hdparm-idle.timer > /dev/null
[Unit]
Description=Run hdparm spindown setting regularly

[Timer]
OnBootSec=1min
OnUnitActiveSec=60min

[Install]
WantedBy=timers.target
EOF
    
    run_command "sudo systemctl enable hdparm-idle.timer"
    run_command "sudo systemctl start hdparm-idle.timer"
    
    # Настройка планировщика для NVMe и HDD
    cat << EOF | sudo tee /etc/udev/rules.d/60-ioschedulers.rules > /dev/null
# Планировщик для NVMe
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"

# Планировщик для HDD
ACTION=="add|change", KERNEL=="sd[a-z]|hd[a-z]", ATTR{queue/scheduler}="bfq"
EOF
    
    # Настройка swappiness для оптимизации использования ОЗУ
    cat << EOF | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null
vm.swappiness=10
EOF
    
    run_command "sudo sysctl vm.swappiness=10"
    
    # Настройка автоматической очистки кэша
    cat << EOF | sudo tee /etc/systemd/system/clear-cache.service > /dev/null
[Unit]
Description=Clear Memory Cache

[Service]
Type=oneshot
ExecStart=/usr/bin/sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"
EOF
    
    cat << EOF | sudo tee /etc/systemd/system/clear-cache.timer > /dev/null
[Unit]
Description=Clear Memory Cache Timer

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF
    
    run_command "sudo systemctl enable clear-cache.timer"
    run_command "sudo systemctl start clear-cache.timer"
    
    print_success "Настройка управления питанием завершена"
fi

# 12. Настройка локализации и безопасности
if contains 12 "${selected_options[@]}"; then
    print_header "12. Настройка локализации и безопасности"
    
    # Настройка русской локали
    if ! grep -q "ru_RU.UTF-8 UTF-8" /etc/locale.gen; then
        echo "ru_RU.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen > /dev/null
        run_command "sudo locale-gen"
    fi
    
    # Установка системной локали
    echo "LANG=ru_RU.UTF-8" | sudo tee /etc/locale.conf > /dev/null
    
    # Настройка часового пояса
    if confirm "Установить часовой пояс для Москвы?"; then
        run_command "sudo ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime"
        run_command "sudo hwclock --systohc"
    fi
    
    # Настройка базового файрвола
    run_command "sudo pacman -S --needed --noconfirm ufw"
    run_command "sudo systemctl enable ufw"
    run_command "sudo systemctl start ufw"
    run_command "sudo ufw default deny incoming"
    run_command "sudo ufw default allow outgoing"
    run_command "sudo ufw allow ssh"
    run_command "sudo ufw enable"
    
    # Отключение core dumps
    echo "* hard core 0" | sudo tee -a /etc/security/limits.conf > /dev/null
    echo "* soft core 0" | sudo tee -a /etc/security/limits.conf > /dev/null
    echo "kernel.core_pattern=/dev/null" | sudo tee -a /etc/sysctl.d/51-coredump.conf > /dev/null
    run_command "sudo sysctl -p /etc/sysctl.d/51-coredump.conf"
    
    print_success "Настройка локализации и безопасности завершена"
fi

# 13. Установка дополнительных программ
if contains 13 "${selected_options[@]}"; then
    print_header "13. Установка дополнительных программ"
    
    # Установка популярных утилит
    run_command "sudo pacman -S --needed --noconfirm htop neofetch bat exa ripgrep fd"
    
    # Настройка gnome-keyring
    run_command "sudo pacman -S --needed --noconfirm gnome-keyring seahorse"
    
    # Добавление настроек gnome-keyring в bash_profile
    if ! grep -q "gnome-keyring-daemon" ~/.bash_profile; then
        echo "eval \$(gnome-keyring-daemon --start)" >> ~/.bash_profile
        echo "export SSH_AUTH_SOCK" >> ~/.bash_profile
        print_success "Настройки gnome-keyring добавлены в bash_profile"
    fi
    
    print_success "Установка дополнительных программ завершена"
fi

# 14. Установка Timeshift для резервного копирования
if contains 14 "${selected_options[@]}"; then
    print_header "14. Установка Timeshift для резервного копирования"
    
    # Установка Timeshift из официальных репозиториев
    if command -v timeshift &> /dev/null; then
        print_success "Timeshift уже установлен"
    else
        run_command "sudo pacman -S --needed --noconfirm timeshift"
    fi
    
    # Установка интеграции для BTRFS (через paru, так как этот пакет в AUR)
    run_command "paru -S --noconfirm timeshift-autosnap"
    
    # Базовая настройка Timeshift
    if [ -d "$HOME/.config/timeshift" ]; then
        print_warning "Конфигурация Timeshift уже существует"
        print_warning "Запустите 'sudo timeshift-gtk' для ручной настройки"
    else
        print_warning "После установки рекомендуется запустить 'sudo timeshift-gtk' для настройки"
        print_warning "Для BTRFS выберите тип снапшотов 'BTRFS'"
    fi
    
    print_success "Установка Timeshift завершена"
fi

# Финальная проверка и перезагрузка
print_header "Все операции завершены"

# Проверка критических компонентов
errors=0

# Проверка инициализации
if [ ! -f /boot/initramfs-linux-zen.img ]; then
    print_error "Отсутствует образ initramfs. Выполните: sudo mkinitcpio -P linux-zen"
    errors=$((errors+1))
fi

# Проверка загрузчика
if [ ! -f /boot/loader/entries/arch-zen.conf ]; then
    print_error "Отсутствует конфигурация загрузчика systemd-boot"
    errors=$((errors+1))
fi

# Проверка fstab
if ! sudo findmnt -n -o SOURCE / &> /dev/null; then
    print_error "Проблема с fstab. Проверьте монтирование корневого раздела."
    errors=$((errors+1))
fi

if [ $errors -eq 0 ]; then
    print_success "Все проверки пройдены успешно!"
    
    if confirm "Перезагрузить систему для применения всех изменений?"; then
        run_command "sudo reboot"
    else
        print_warning "Для применения всех изменений рекомендуется перезагрузка"
        print_warning "Выполните 'sudo reboot' вручную, когда будете готовы"
    fi
else
    print_error "Обнаружены ошибки ($errors). Рекомендуется исправить их перед перезагрузкой."
fi
