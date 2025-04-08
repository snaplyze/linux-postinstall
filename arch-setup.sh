#!/bin/bash

# arch-setup.sh - Optimized setup script for Arch Linux with GNOME (Interactive Mode)
# To be run AFTER initial installation via installer.sh
# Based on analysis of installer.sh v1.1.0 logs and config.
# Version: 1.9.4 (Add Fish Shell setup)

# Цвета для вывода
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m" # Сброс цвета

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
        return 0 # Возвращаем успех
    else
        print_error "Ошибка при выполнении команды"
        if [ "$2" = "critical" ]; then
            print_error "Критическая ошибка, выход из скрипта"
            exit 1
        fi
        return 1 # Возвращаем ошибку
    fi
}

# Функция для проверки наличия пакета
check_package() {
    if pacman -Q "$1" &> /dev/null; then
        return 0  # Пакет установлен
    else
        return 1  # Пакет не установлен
    fi
}

# Функция для проверки наличия команды
check_command() {
    if command -v "$1" &> /dev/null; then
        return 0  # Команда найдена
    else
        return 1  # Команда не найдена
    fi
}

# Функция для проверки и установки пакетов
check_and_install_packages() {
    local category=$1
    shift
    local packages=("$@")
    local missing_packages=()

    echo -e "${BLUE}Проверка необходимых пакетов для: $category${NC}"

    for pkg in "${packages[@]}"; do
        if ! check_package "$pkg"; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -gt 0 ]; then
        echo -e "${YELLOW}Отсутствуют следующие пакеты:${NC} ${missing_packages[*]}"
        if confirm "Установить отсутствующие пакеты?"; then
            run_command "sudo pacman -S --needed --noconfirm ${missing_packages[*]}"
            # Проверяем еще раз после попытки установки
            for pkg in "${missing_packages[@]}"; do
                if ! check_package "$pkg"; then
                    print_error "Не удалось установить пакет $pkg. Операция может быть неполной."
                    return 1 # Возвращаем ошибку, если установка не удалась
                fi
            done
            return 0 # Все необходимые пакеты установлены
        else
            echo -e "${YELLOW}Пропускаем установку пакетов. Операция может быть неполной.${NC}"
            return 1 # Возвращаем ошибку, так как пакеты не установлены
        fi
    else
        echo -e "${GREEN}Все необходимые пакеты для '${category}' установлены${NC}"
        return 0 # Все пакеты уже были установлены
    fi
}

# --- Script Start ---

# Проверка системных требований и предварительных условий
print_header "Проверка системных требований"

# Проверка, запущен ли скрипт от имени обычного пользователя (не root)
if [ "$EUID" -eq 0 ]; then
    print_error "Этот скрипт должен быть запущен от имени обычного пользователя, а не root"
    exit 1
fi

# Проверка базовых зависимостей
base_deps=("bash" "sed" "grep" "awk" "sudo" "pacman" "lsblk" "findmnt" "lscpu" "free" "cat" "uname" "tee" "mktemp" "read" "command" "lsmod")
missing_deps=()
for cmd in "${base_deps[@]}"; do
    if ! check_command "$cmd"; then
        missing_deps+=("$cmd")
    fi
done
if [ ${#missing_deps[@]} -gt 0 ]; then
    print_error "Отсутствуют необходимые базовые команды: ${missing_deps[*]}"
    print_error "Установите их перед запуском скрипта"
    exit 1
fi
print_success "Базовые зависимости проверены."

# Проверка ZRAM (установлен инсталлером)
if lsmod | grep -q zram || [ -e "/dev/zram0" ]; then
    print_success "ZRAM настроен инсталлером"
else
    print_warning "ZRAM не обнаружен. Инсталлер должен был его настроить."
fi

# Вывод информации о системе (один раз при запуске)
print_header "Информация о системе"
echo "Ядро Linux: $(uname -r)"
echo "Дистрибутив: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "Процессор: $(lscpu | grep "Model name" | sed 's/Model name: *//')"
echo "Память: $(free -h | awk '/^Mem:/ {print $2}')"
ROOT_DEVICE=$(findmnt -no SOURCE / | sed 's/\[.*\]//')
ROOT_DEVICE_BASE=$(echo "$ROOT_DEVICE" | sed 's/p[0-9]\+$//')
echo "Системный диск: $ROOT_DEVICE_BASE"
echo "Смонтированные диски:"
findmnt -t btrfs,ext4,vfat -no SOURCE,TARGET,FSTYPE,OPTIONS | grep -v "zram"
echo "Все доступные блочные устройства:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE

# Проверка systemd-boot и ядра (установлены инсталлером)
if [ ! -d "/boot/loader" ]; then
    print_warning "Не найдена директория /boot/loader. Инсталлер должен был настроить systemd-boot."
fi
if [ ! -f "/boot/vmlinuz-linux-zen" ]; then
    print_warning "Не найдено ядро linux-zen. Инсталлер должен был его установить."
fi

# --- Main Loop ---
while true; do
    # Вывод меню выбора действий
    print_header "Выберите операцию для выполнения"
    echo " 1. Обновление системы и базовая настройка"
    echo " 2. Дополнительная настройка драйверов NVIDIA (включая фикс 'серого экрана')"
    echo " 3. Оптимизация NVMe и BTRFS (sysctl)"
    echo " 4. Форматирование ДОПОЛНИТЕЛЬНЫХ дисков"
    echo " 5. Настройка тихой загрузки (kernel cmdline, journald)"
    echo " 6. Проверка/Настройка Paru"
    echo " 7. Настройка Flathub"
    echo " 8. Установка Steam и библиотек"
    echo " 9. Установка Proton GE"
    echo "10. Дополнительная оптимизация для Wayland (env, Mutter)"
    echo "11. Настройка управления питанием (Power Profiles Daemon, HDD sleep, I/O schedulers)"
    echo "12. Настройка безопасности (UFW, core dumps)"
    echo "13. Установка дополнительных программ (CLI utils, Keyring check)"
    echo "14. Установка Timeshift для резервного копирования"
    echo "15. Дополнительная настройка PipeWire (Low-latency, user services)"
    echo "16. Оптимизация памяти и особенности для игр"
    echo "17. Настройка функциональных клавиш (F1-F12)"
    echo "18. Установка и настройка Fish Shell (для \$USER, root и новых пользователей)"
    echo " 0. Выход"

    read -p "Введите номер операции (0-18): " choice

    case "$choice" in
        1)
            print_header "1. Обновление системы и базовая настройка"
            # Проверка/Установка базовых утилит (на всякий случай)
            if check_and_install_packages "Базовые утилиты (проверка)" "base-devel" "git" "curl" "wget" "bash-completion"; then
                # Обновление системы
                run_command "sudo pacman -Syu --noconfirm"
            fi
            ;;
        2)
            print_header "2. Дополнительная настройка NVIDIA"
            # Проверяем, что драйвер NVIDIA установлен инсталлером
            if ! check_package "nvidia-dkms"; then
                 print_error "Драйвер nvidia-dkms не найден. Установка/настройка пропущена."
                 print_error "Запустите инсталлер с опцией драйвера NVIDIA."
                 # Если базовый драйвер не найден, выходим из этого пункта меню
                 echo
                 read -p "Нажмите Enter для возврата в меню..."
                 continue
            fi

            # Если базовый драйвер есть, проверяем/устанавливаем cuda и cuda-tools
            if ! check_and_install_packages "CUDA и CUDA Tools" "cuda" "cuda-tools"; then
                 print_warning "Установка CUDA/CUDA Tools не удалась или была пропущена. Пропускаем дальнейшую настройку NVIDIA."
                 # Если установка пакетов не удалась, выходим из этого пункта меню
                 echo
                 read -p "Нажмите Enter для возврата в меню..."
                 continue
            fi

            # Если все пакеты установлены, продолжаем настройку
            # Блокировка nouveau (дополнительная мера)
            if [ ! -f /etc/modprobe.d/blacklist-nouveau.conf ]; then
                echo "blacklist nouveau" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf > /dev/null
                    print_success "Модуль nouveau заблокирован (дополнительно)"
                else
                    print_success "Модуль nouveau уже заблокирован"
                fi

                # Дополнительная опция модуля NVIDIA
                if ! grep -q "NVreg_PreserveVideoMemoryAllocations=1" /etc/modprobe.d/nvidia.conf 2>/dev/null; then
                     echo "options nvidia NVreg_PreserveVideoMemoryAllocations=1" | sudo tee /etc/modprobe.d/nvidia.conf > /dev/null
                     print_success "Добавлена опция NVreg_PreserveVideoMemoryAllocations=1"
                else
                     print_success "Опция NVreg_PreserveVideoMemoryAllocations=1 уже установлена"
                fi

                # Включение сервисов NVIDIA для suspend/resume (может помочь с серым экраном)
                print_header "Включение сервисов NVIDIA suspend/resume..."
                run_command "sudo systemctl enable nvidia-suspend.service"
                run_command "sudo systemctl enable nvidia-resume.service"
                run_command "sudo systemctl enable nvidia-hibernate.service"
                print_success "Сервисы NVIDIA для suspend/resume включены"
            # fi # Удаляем лишний fi
            ;;
        3)
            print_header "3. Оптимизация NVMe и BTRFS (sysctl)"
            if check_and_install_packages "Утилиты дисков (проверка)" "nvme-cli" "hdparm"; then
                # Проверка текущих параметров NVMe
                echo "Список NVMe устройств:"
                run_command "sudo nvme list"
                if [ -e "/dev/nvme0n1" ]; then # Проверяем только первый для примера
                     print_header "SMART лог для /dev/nvme0n1:"
                     run_command "sudo nvme smart-log /dev/nvme0n1"
                fi

                # Настройка кэша метаданных BTRFS (если не существует)
                if [ ! -f /etc/sysctl.d/60-btrfs-performance.conf ]; then
                     cat << EOF | sudo tee /etc/sysctl.d/60-btrfs-performance.conf > /dev/null
# Увеличение лимита кэша метаданных для BTRFS
vm.dirty_bytes = 4294967296
vm.dirty_background_bytes = 1073741824
EOF
                     run_command "sudo sysctl --system"
                     print_success "Параметры sysctl для BTRFS применены"
                else
                     print_success "Параметры sysctl для BTRFS уже существуют"
                fi
            else
                print_warning "Пропускаем оптимизацию NVMe/BTRFS из-за отсутствия пакетов"
            fi
            ;;
        4)
            print_header "4. Форматирование ДОПОЛНИТЕЛЬНЫХ дисков"
            # Добавляем gptfdisk в проверку пакетов
            if check_and_install_packages "Форматирование дисков" "parted" "e2fsprogs" "gptfdisk"; then
                print_warning "ВНИМАНИЕ! Эта операция необратимо уничтожит все данные на выбранных ДОПОЛНИТЕЛЬНЫХ дисках!"
                echo "Состояние дисков в системе:"
                lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,LABEL

                # Определяем системный диск, чтобы его не трогать
                ROOT_DEVICE_BASE_NAME=$(basename "$ROOT_DEVICE_BASE")

                # Форматирование NVMe
                if confirm "Форматировать ДОПОЛНИТЕЛЬНЫЕ NVMe диски?"; then
                    nvme_disks=$(lsblk -ndo NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/ && $1 != "'"$ROOT_DEVICE_BASE_NAME"'" {print $1}')
                    if [ -z "$nvme_disks" ]; then
                        print_warning "Дополнительные NVMe диски не найдены"
                    else
                        echo "Найдены следующие ДОПОЛНИТЕЛЬНЫЕ NVMe диски для форматирования:"
                        echo "$nvme_disks"
                        nvme_count=1
                        for disk in $nvme_disks; do
                            if confirm "Форматировать /dev/$disk?"; then
                                run_command "sudo umount /dev/$disk* || true" # Размонтируем на всякий случай
                                run_command "sudo wipefs -af /dev/${disk}" # Очистка перед разметкой
                                run_command "sudo sgdisk --zap-all /dev/$disk"
                                run_command "sudo parted /dev/$disk mklabel gpt"
                                run_command "sudo parted -a optimal /dev/$disk mkpart primary ext4 0% 100%"
                                label="NVMe${nvme_count}" # Убираем DATA_
                                mount_point="/data/NVMe${nvme_count}" # Изменено с /mnt
                                run_command "sudo mkfs.ext4 -L $label /dev/${disk}p1"
                                run_command "sudo mkdir -p $mount_point"
                                if ! grep -q "LABEL=$label" /etc/fstab; then
                                    echo "LABEL=$label  $mount_point  ext4  defaults,noatime,x-gvfs-show  0 2" | sudo tee -a /etc/fstab
                                fi
                                run_command "sudo mount $mount_point"
                                print_success "Диск /dev/$disk успешно отформатирован и примонтирован в $mount_point"
                                nvme_count=$((nvme_count + 1))
                            fi
                        done
                    fi
                fi

                # Форматирование HDD
                if confirm "Форматировать ДОПОЛНИТЕЛЬНЫЕ HDD диски?"; then
                    hdd_disks=$(lsblk -ndo NAME,TYPE | awk '$2=="disk" && $1 ~ /^sd/ && $1 != "'"$ROOT_DEVICE_BASE_NAME"'" {print $1}') # Исключаем системный, если он вдруг sda
                    if [ -z "$hdd_disks" ]; then
                        print_warning "Дополнительные HDD диски не найдены"
                    else
                        echo "Найдены следующие ДОПОЛНИТЕЛЬНЫЕ HDD диски для форматирования:"
                        echo "$hdd_disks"
                        hdd_count=1
                        for disk in $hdd_disks; do
                            if confirm "Форматировать /dev/$disk?"; then
                                run_command "sudo umount /dev/$disk* || true"
                                run_command "sudo wipefs -af /dev/${disk}"
                                run_command "sudo sgdisk --zap-all /dev/$disk"
                                run_command "sudo parted /dev/$disk mklabel gpt"
                                run_command "sudo parted -a optimal /dev/$disk mkpart primary ext4 0% 100%"
                                label="HDD${hdd_count}" # Убираем DATA_
                                mount_point="/data/HDD${hdd_count}" # Изменено с /mnt
                                run_command "sudo mkfs.ext4 -L $label /dev/${disk}1"
                                run_command "sudo mkdir -p $mount_point"
                                if ! grep -q "LABEL=$label" /etc/fstab; then
                                    echo "LABEL=$label  $mount_point  ext4  defaults,noatime,x-gvfs-show  0 2" | sudo tee -a /etc/fstab
                                fi
                                run_command "sudo mount $mount_point"
                                print_success "Диск /dev/$disk успешно отформатирован и примонтирован в $mount_point"
                                hdd_count=$((hdd_count + 1))
                            fi
                        done
                    fi
                fi
                print_success "Форматирование и монтирование ДОПОЛНИТЕЛЬНЫХ дисков завершено"
            else
                print_warning "Пропускаем форматирование дисков из-за отсутствия пакетов"
            fi
            ;;
        5)
            print_header "5. Настройка тихой загрузки"
            kernel_cmdline_changed=false # Убираем local
            # Установка параметров ядра через cmdline.d (надежнее)
            run_command "sudo mkdir -p /etc/kernel/cmdline.d/"
            # Параметры для тихой загрузки, Plymouth и NVIDIA KMS
            # (Частично дублируют установленные инсталлером, но cmdline.d имеет приоритет)
            kernel_params="quiet loglevel=3 rd.systemd.show_status=false rd.udev.log_level=3 vt.global_cursor_default=0 splash plymouth.enable=1 nvidia_drm.modeset=1 nvidia.NVreg_PreserveVideoMemoryAllocations=1"
            local cmdline_file="/etc/kernel/cmdline.d/90-quiet-nvidia-plymouth.conf"
            if [ ! -f "$cmdline_file" ] || [ "$(cat "$cmdline_file")" != "$kernel_params" ]; then
                echo "$kernel_params" | sudo tee "$cmdline_file" > /dev/null
                print_success "Параметры ядра для тихой загрузки установлены/обновлены в $cmdline_file"
                kernel_cmdline_changed=true
            else
                print_success "Параметры ядра для тихой загрузки в $cmdline_file уже актуальны."
            fi

            if [ "$kernel_cmdline_changed" = true ]; then
                 print_warning "Параметры ядра, установленные в этом файле, переопределят существующие."
                 print_warning "Убедитесь, что критические параметры (root, rootflags и т.д.) не удалены из /boot/loader/entries/arch.conf или добавлены сюда."
                 # Автоматически обновляем загрузчик
                 print_header "Обновление конфигурации загрузчика..."
                 run_command "sudo bootctl update"
            fi

            # Отключение журналирования на tty
            run_command "sudo mkdir -p /etc/systemd/journald.conf.d/"
            if [ ! -f /etc/systemd/journald.conf.d/90-quiet-tty.conf ]; then
                cat << EOF | sudo tee /etc/systemd/journald.conf.d/90-quiet-tty.conf > /dev/null
[Journal]
TTYPath=/dev/null
EOF
                print_success "Вывод журнала systemd на TTY отключен"
            else
                print_success "Вывод журнала systemd на TTY уже отключен"
            fi
            print_success "Настройка тихой загрузки завершена"
            if [ "$kernel_cmdline_changed" = true ]; then
                print_warning "Изменения параметров ядра вступят в силу после перезагрузки."
            fi
            ;;
        6)
            print_header "6. Проверка/Настройка Paru"
            if ! check_command "paru"; then
                print_warning "Paru не найден. Попытка установки..."
                if check_and_install_packages "Сборка Paru" "base-devel" "git"; then
                    paru_build_dir=$(mktemp -d -p "$HOME" paru-build.XXXXXX)
                    run_command "git clone https://aur.archlinux.org/paru.git '$paru_build_dir'"
                    (cd "$paru_build_dir" && makepkg -si --noconfirm)
                    rm -rf "$paru_build_dir"
                    if ! check_command "paru"; then
                         print_error "Не удалось установить Paru."
                    fi
                else
                    print_error "Необходимые пакеты для сборки Paru отсутствуют."
                fi
            else
                print_success "Paru найден."
            fi

            # Настройка Paru (создаст или перезапишет, если пользователь согласится)
            if check_command "paru"; then
                run_command "mkdir -p ~/.config/paru"
                paru_conf_path="$HOME/.config/paru/paru.conf"
                if [ -f "$paru_conf_path" ]; then
                     if confirm "Файл конфигурации Paru ($paru_conf_path) уже существует. Перезаписать?"; then
                         create_paru_conf=true
                     else
                         create_paru_conf=false
                         print_warning "Пропускаем перезапись конфигурации Paru."
                     fi
                else
                     create_paru_conf=true
                fi

                if [ "$create_paru_conf" = true ]; then
                     cat << EOF > "$paru_conf_path"
[options]
BottomUp
SudoLoop
Devel
CleanAfter
# BatchInstall # Закомментировано для безопасности
# NewsOnUpgrade # Может быть навязчивым
RemoveMake
UpgradeMenu
CombinedUpgrade
#KeepRepoCache # Может занимать место
#Redownload # Не всегда нужно

# Папка для скачивания/сборки
BuildDir = ~/.cache/paru/clone
CloneDir = ~/.cache/paru/clone
PgpFetch
DevelSuffix = -git

[bin]
FileManager = nnn
MFlags = --noconfirm
EOF
                     print_success "Файл конфигурации Paru создан/обновлен."
                fi
            fi
            ;;
        7)
            print_header "7. Настройка Flathub"
            if ! check_package "flatpak"; then
                print_error "Пакет flatpak не найден. Пропускаем настройку."
            else
                # Добавление репозитория Flathub
                run_command "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"

                # Определение и установка платформы GNOME
                echo "Определение последней версии GNOME Platform..."
                latest_gnome_version=$(flatpak remote-info --log flathub org.gnome.Platform 2>/dev/null | grep -oP "Version: \K[0-9]+" | head -1)
                if [ -z "$latest_gnome_version" ]; then
                    latest_gnome_version="48" # Установите актуальное значение по умолчанию
                    print_warning "Не удалось определить версию GNOME Platform, используем $latest_gnome_version"
                else
                    print_success "Определена версия GNOME Platform: $latest_gnome_version"
                fi
                run_command "flatpak install -y flathub org.gnome.Platform//$latest_gnome_version"

                print_success "Настройка Flathub завершена"
            fi
            ;;
        8)
            print_header "8. Установка Steam и библиотек"
            # Проверка multilib (инсталлер должен был включить)
            if ! grep -q "^\s*\[multilib\]" /etc/pacman.conf; then
                print_warning "Репозиторий multilib не включен в /etc/pacman.conf!"
            fi
            # Пакеты (инсталлер ставит многие, но steam - нет)
            steam_packages=("steam") # Добавляем только сам steam, остальное ставит инсталлер
            if check_and_install_packages "Steam" "${steam_packages[@]}"; then
                print_success "Установка Steam завершена"
            else
                print_warning "Пропускаем установку Steam"
            fi
            ;;
        9)
            print_header "9. Установка Proton GE"
            if [ ! -d "$HOME/.steam/root" ] && [ ! -d "$HOME/.var/app/com.valvesoftware.Steam/.steam/root" ]; then
                print_warning "Не найдена стандартная директория Steam. Возможно, Steam не установлен или не запускался."
                print_warning "Создаю директорию ~/.steam/root/compatibilitytools.d/ для Proton GE."
                proton_path="$HOME/.steam/root/compatibilitytools.d/"
            elif [ -d "$HOME/.var/app/com.valvesoftware.Steam/.steam/root" ]; then
                 proton_path="$HOME/.var/app/com.valvesoftware.Steam/.steam/root/compatibilitytools.d/"
                 print_success "Обнаружен Flatpak Steam."
            else
                 proton_path="$HOME/.steam/root/compatibilitytools.d/"
                 print_success "Обнаружен нативный Steam."
            fi

            run_command "mkdir -p '$proton_path'"

            if check_command "paru"; then
                if paru -Qs proton-ge-custom-bin &> /dev/null; then
                     print_success "Proton GE (proton-ge-custom-bin) уже установлен через paru."
                elif paru -Qs protonup-qt &> /dev/null; then
                     print_success "ProtonUp-Qt установлен. Используйте его для управления Proton GE."
                else
                     echo "Выберите способ установки Proton GE:"
                     echo "1) Установить protonup-qt через paru (рекомендуется, графический менеджер)"
                     echo "2) Установить proton-ge-custom-bin через paru (автоматическое обновление)"
                     echo "3) Скачать последнюю версию вручную"
                     read -p "Ваш выбор (1/2/3): " ge_choice

                     case "$ge_choice" in
                         1) run_command "paru -S --noconfirm protonup-qt";;
                         2) run_command "paru -S --noconfirm proton-ge-custom-bin";;
                         3) print_warning "Выбран ручной метод. Будет скачана последняя версия."
                            if check_and_install_packages "Загрузка Proton GE" "wget" "tar" "curl"; then
                                PROTON_URL=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | grep "browser_download_url.*\.tar\.gz" | cut -d '"' -f 4)
                                if [ -n "$PROTON_URL" ]; then
                                     PROTON_FILENAME=$(basename "$PROTON_URL")
                                     print_header "Скачивание $PROTON_FILENAME..."
                                     run_command "wget -O '/tmp/$PROTON_FILENAME' '$PROTON_URL'"
                                     print_header "Распаковка Proton GE в $proton_path ..."
                                     run_command "tar -xzf '/tmp/$PROTON_FILENAME' -C '$proton_path'"
                                     run_command "rm '/tmp/$PROTON_FILENAME'"
                                     print_success "Proton GE установлен вручную."
                                else
                                     print_error "Не удалось получить URL для скачивания Proton GE."
                                fi
                            fi
                            ;;
                         *) print_warning "Неверный выбор, установка Proton GE пропущена.";;
                     esac
                fi
            else
                print_warning "Paru не установлен. Предлагается ручная установка."
                if confirm "Скачать и установить последнюю версию Proton GE вручную?"; then
                     if check_and_install_packages "Загрузка Proton GE" "wget" "tar" "curl"; then
                          PROTON_URL=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | grep "browser_download_url.*\.tar\.gz" | cut -d '"' -f 4)
                          if [ -n "$PROTON_URL" ]; then
                               PROTON_FILENAME=$(basename "$PROTON_URL")
                               print_header "Скачивание $PROTON_FILENAME..."
                               run_command "wget -O '/tmp/$PROTON_FILENAME' '$PROTON_URL'"
                               print_header "Распаковка Proton GE в $proton_path ..."
                               run_command "tar -xzf '/tmp/$PROTON_FILENAME' -C '$proton_path'"
                               run_command "rm '/tmp/$PROTON_FILENAME'"
                               print_success "Proton GE установлен вручную."
                          else
                               print_error "Не удалось получить URL для скачивания Proton GE."
                          fi
                     fi
                else
                    print_warning "Установка Proton GE пропущена."
                fi
            fi
            ;;
        10)
            print_header "10. Дополнительная оптимизация для Wayland"
            # Проверка базовых пакетов (инсталлер должен был поставить)
            if check_and_install_packages "Wayland (проверка)" "qt6-wayland" "qt5-wayland" "xorg-xwayland" "egl-wayland" "mesa-utils"; then

                # Глобальные переменные окружения (дополняют пользовательские из инсталлера)
                if [ ! -f /etc/environment ]; then
                    cat << EOF | sudo tee /etc/environment > /dev/null
# Глобальные настройки Wayland и NVIDIA
LIBVA_DRIVER_NAME=nvidia
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
MOZ_ENABLE_WAYLAND=1
QT_QPA_PLATFORM=wayland
#WLR_NO_HARDWARE_CURSORS=1 # Раскомментируйте, если есть проблемы с курсором
#QT_QPA_PLATFORMTHEME=qt5ct # Если используете qt5ct для Qt тем
EOF
                    print_success "Глобальные переменные окружения для Wayland настроены в /etc/environment"
                else
                    print_warning "/etc/environment уже существует. Проверьте его содержимое вручную."
                    print_warning "Рекомендуемые переменные: LIBVA_DRIVER_NAME=nvidia, GBM_BACKEND=nvidia-drm, __GLX_VENDOR_LIBRARY_NAME=nvidia, MOZ_ENABLE_WAYLAND=1, QT_QPA_PLATFORM=wayland"
                fi

                # Настройка Mutter для KMS Modifiers (NVIDIA)
                if check_package "mutter"; then # Проверяем, что Mutter установлен
                    mutter_autostart_file="$HOME/.config/autostart/nvidia-mutter-kms.desktop"
                    if [ ! -f "$mutter_autostart_file" ]; then
                        mkdir -p ~/.config/autostart
                        cat << EOF > "$mutter_autostart_file"
[Desktop Entry]
Type=Application
Name=NVIDIA Mutter KMS Modifiers
Exec=gsettings set org.gnome.mutter experimental-features "['kms-modifiers']"
Comment=Enable KMS Modifiers for NVIDIA Wayland sessions
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
EOF
                        print_success "Создан файл автозапуска для включения KMS Modifiers в Mutter."
                    else
                        print_success "Файл автозапуска для KMS Modifiers в Mutter уже существует."
                    fi
                fi
            fi
            ;;
        11)
            print_header "11. Настройка управления питанием"
            if check_and_install_packages "Управление питанием" "power-profiles-daemon" "hdparm"; then

                # Отключаем tuned, если включен (т.к. ставим PPD)
                if systemctl is-enabled tuned.service &>/dev/null; then
                     print_warning "Служба 'tuned' (установленная инсталлером) активна. Отключаем её, т.к. выбран Power Profiles Daemon."
                      run_command "sudo systemctl disable tuned.service --now"
                 fi
 
                 # Перезагружаем демона systemd после проверки/установки пакета
                 print_header "Перезагрузка демона systemd..."
                 run_command "sudo systemctl daemon-reload" "critical" # Make daemon-reload critical
 
                 # Активация tuned-ppd (замена для power-profiles-daemon)
                 print_header "Активация tuned-ppd..."
                 # Make enable/start critical to catch errors
                 # Используем правильное имя службы: tuned-ppd.service
                 if run_command "sudo systemctl enable tuned-ppd.service" "critical"; then
                     if ! systemctl is-active tuned-ppd.service &>/dev/null; then
                          run_command "sudo systemctl start tuned-ppd.service" "critical"
                     fi
                     print_success "Служба tuned-ppd включена и запущена." # This line is now more reliable
                 else
                     print_error "Не удалось включить службу tuned-ppd. Пропускаем дальнейшую настройку питания."
                     # Skip the rest of the power settings if enable failed
                     # Add a pause before returning to menu
                     echo
                     read -p "Нажмите Enter для возврата в меню..."
                     continue # Go back to the main menu loop
                 fi
 
                 # Правила для перевода HDD в спящий режим
                if [ ! -f /etc/udev/rules.d/69-hdparm-sleep.rules ]; then
                     cat << EOF | sudo tee /etc/udev/rules.d/69-hdparm-sleep.rules > /dev/null
# Перевод HDD в спящий режим после 10 минут простоя (S=120 -> 120*5 = 600 сек = 10 мин)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", RUN+="/usr/bin/hdparm -B 127 -S 120 /dev/%k"
EOF
                     print_success "Создано правило udev для сна HDD."
                     # Применяем к текущим устройствам
                     print_header "Применение настроек энергосбережения к текущим HDD..."
                     for disk in /dev/sd?; do
                         if [ -b "$disk" ] && [ "$(cat /sys/block/$(basename "$disk")/queue/rotational)" = "1" ]; then
                             run_command "sudo hdparm -B 127 -S 120 $disk"
                         fi
                     done
                else
                    print_success "Правило udev для сна HDD уже существует."
                fi

                # Настройка планировщика I/O
                if [ ! -f /etc/udev/rules.d/60-ioschedulers.rules ]; then
                     cat << EOF | sudo tee /etc/udev/rules.d/60-ioschedulers.rules > /dev/null
# Планировщик для NVMe (нет планировщика)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
# Планировщик для SSD/HDD (bfq)
ACTION=="add|change", KERNEL=="sd[a-z]|hd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]|hd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="bfq"
EOF
                     print_success "Создано правило udev для планировщиков I/O."
                     run_command "sudo udevadm control --reload-rules && sudo udevadm trigger"
                else
                    print_success "Правило udev для планировщиков I/O уже существует."
                fi

                # Настройка swappiness (дополняет ZRAM)
                if [ ! -f /etc/sysctl.d/99-swappiness.conf ]; then
                     cat << EOF | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null
vm.swappiness=10
EOF
                     run_command "sudo sysctl vm.swappiness=10"
                     print_success "Параметр vm.swappiness=10 применен."
                else
                     print_success "Параметр vm.swappiness уже настроен."
                fi

                # Настройка автоматической очистки кэша (опционально, может влиять на производительность)
                if confirm "Настроить автоматическую очистку кэша памяти (раз в час)?"; then
                     if [ ! -f /etc/systemd/system/clear-cache.timer ]; then
                          cat << EOF | sudo tee /etc/systemd/system/clear-cache.service > /dev/null
[Unit]
Description=Clear PageCache, dentries and inodes

[Service]
Type=oneshot
ExecStart=/usr/bin/sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"
EOF
                          cat << EOF | sudo tee /etc/systemd/system/clear-cache.timer > /dev/null
[Unit]
Description=Clear Memory Cache Hourly

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF
                          run_command "sudo systemctl enable clear-cache.timer"
                          run_command "sudo systemctl start clear-cache.timer"
                          print_success "Таймер очистки кэша настроен и запущен."
                     else
                         print_success "Таймер очистки кэша уже настроен."
                     fi
                fi
            else
                print_warning "Пропускаем настройку управления питанием из-за отсутствия пакетов"
            fi
            ;;
        12)
            print_header "12. Настройка безопасности"

            # Настройка базового файрвола UFW
            if check_and_install_packages "Безопасность (UFW)" "ufw"; then
                if ! systemctl is-enabled ufw.service &>/dev/null; then
                     run_command "sudo ufw limit ssh" # Ограничение попыток подключения по SSH
                     run_command "sudo ufw default deny incoming"
                     run_command "sudo ufw default allow outgoing"
                     run_command "sudo ufw enable" # Спросит подтверждение y/n
                     run_command "sudo systemctl enable ufw.service"
                     run_command "sudo systemctl start ufw.service"
                     print_success "UFW настроен, включен и запущен."
                else
                     print_success "UFW уже включен."
                     run_command "sudo ufw status verbose" # Показать текущие правила
                fi
            else
                print_warning "Пропускаем настройку UFW из-за отсутствия пакетов"
            fi

            # Отключение core dumps
            if [ ! -f /etc/security/limits.d/50-disable-coredumps.conf ]; then
                 cat << EOF | sudo tee /etc/security/limits.d/50-disable-coredumps.conf > /dev/null
* hard core 0
* soft core 0
EOF
                 print_success "Создан файл для отключения core dumps через limits.conf."
            else
                print_success "Файл limits.conf для отключения core dumps уже существует."
            fi
            if [ ! -f /etc/sysctl.d/51-disable-coredumps.conf ]; then
                 echo "kernel.core_pattern=/dev/null" | sudo tee /etc/sysctl.d/51-disable-coredumps.conf > /dev/null
                 run_command "sudo sysctl -p /etc/sysctl.d/51-disable-coredumps.conf"
                 print_success "Core dumps отключены через sysctl."
            else
                print_success "Отключение core dumps через sysctl уже настроено."
            fi
            ;;
        13)
            print_header "13. Установка дополнительных программ"
            # Утилиты командной строки
            utils=("htop" "neofetch" "bat" "exa" "ripgrep" "fd")
            check_and_install_packages "Утилиты командной строки" "${utils[@]}"

            # Проверка/Установка Seahorse для управления ключами
            check_and_install_packages "Управление ключами (проверка)" "seahorse"
            # Настройка .bash_profile не требуется для GDM/Wayland
            ;;
        14)
            print_header "14. Установка Timeshift"
            if check_and_install_packages "Резервное копирование" "timeshift"; then
                print_warning "Timeshift установлен. Запустите 'sudo timeshift-gtk' для настройки."
                print_warning "Для BTRFS выберите тип снапшотов 'BTRFS'."
            else
                print_warning "Пропускаем установку Timeshift"
            fi
            ;;
        15)
            print_header "15. Дополнительная настройка PipeWire"
            # Пакеты ставит инсталлер
            if ! check_package "pipewire"; then
                print_error "PipeWire не установлен. Пропускаем настройку."
            else
                # Остановка PulseAudio (на всякий случай)
                run_command "systemctl --user stop pulseaudio.socket pulseaudio.service || true"
                run_command "systemctl --user disable pulseaudio.socket pulseaudio.service || true"
                run_command "systemctl --user mask pulseaudio.socket pulseaudio.service || true"
                print_success "Сервисы PulseAudio остановлены/отключены/замаскированы (если были)."

                # Включение пользовательских сервисов PipeWire
                run_command "systemctl --user enable pipewire pipewire-pulse wireplumber"
                run_command "systemctl --user restart pipewire pipewire-pulse wireplumber" # Используем restart вместо start
                print_success "Пользовательские сервисы PipeWire включены и перезапущены."

                # Настройка Low-latency (если не существует)
                lowlatency_conf="$HOME/.config/pipewire/pipewire.conf.d/10-lowlatency.conf"
                if [ ! -f "$lowlatency_conf" ]; then
                     mkdir -p "$(dirname "$lowlatency_conf")"
                     cat << EOF > "$lowlatency_conf"
context.properties = {
  #default.clock.rate          = 48000
  #default.clock.allowed-rates = [ 44100 48000 ]
  default.clock.quantum       = 1024 # увеличено для стабильности
  default.clock.min-quantum   = 32
  default.clock.max-quantum   = 2048 # уменьшено
  #core.daemon                 = true
  #core.name                   = pipewire-0
}
EOF
                    print_success "Создана конфигурация PipeWire для low-latency (с调整된 quantum)."
                    print_warning "Перезапустите PipeWire для применения: systemctl --user restart pipewire pipewire-pulse"
                else
                    print_success "Конфигурация PipeWire low-latency уже существует."
                fi
            fi
            ;;
        16)
            print_header "16. Оптимизация памяти для игр"
            # Sysctl параметры
            if [ ! -f /etc/sysctl.d/99-gaming-performance.conf ]; then
                cat << EOF | sudo tee /etc/sysctl.d/99-gaming-performance.conf > /dev/null
# Уменьшение задержки обмена данными для улучшения отзывчивости в играх
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
# Увеличение лимитов для файловых дескрипторов (полезно для Steam и некоторых игр)
fs.file-max = 100000
# Оптимизация файловой системы
fs.inotify.max_user_watches = 524288
# Увеличение максимального количества соединений для сетевых игр
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_fastopen = 3
EOF
                run_command "sudo sysctl --system"
                print_success "Параметры sysctl для игр применены."
            else
                print_success "Параметры sysctl для игр уже настроены."
            fi

            # Лимиты для игровых процессов
            if [ ! -f /etc/security/limits.d/10-gaming-limits.conf ]; then
                cat << EOF | sudo tee /etc/security/limits.d/10-gaming-limits.conf > /dev/null
# Увеличение приоритета для улучшения игрового опыта
*               -       rtprio          95 # Уменьшено с 98 для стабильности
*               -       nice            -15 # Увеличено с -10
EOF
                print_success "Создан файл лимитов для игровых процессов."
            else
                print_success "Файл лимитов для игровых процессов уже существует."
            fi

            # Конфигурация Steam
            steam_path_native="$HOME/.local/share/Steam"
            steam_path_flatpak="$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
            steam_cfg_file="steam_dev.cfg"

            target_steam_path=""
            if [ -d "$steam_path_native" ]; then
                target_steam_path=$steam_path_native
            elif [ -d "$steam_path_flatpak" ]; then
                target_steam_path=$steam_path_flatpak
            fi

            if [ -n "$target_steam_path" ]; then
                if [ ! -f "$target_steam_path/$steam_cfg_file" ]; then
                    cat << EOF > "$target_steam_path/$steam_cfg_file"
@NoForceMinimizeOnFocusLoss 1
@AllowGameOverlays 1
@SkipStoreAndNewsInBigPictureMode 1
@UseDISCORD_RPC 0
@DisableWriteOverlayCache 1 # Может помочь с производительностью диска
@DisableFSOWatch 1 # Может уменьшить нагрузку CPU
EOF
                    print_success "Создана оптимизированная конфигурация Steam в $target_steam_path."
                else
                    print_success "Оптимизированная конфигурация Steam уже существует."
                fi
            else
                print_warning "Директория Steam не найдена, конфигурация не создана."
            fi
            ;;
        17)
             print_header "17. Настройка функциональных клавиш (F1-F12)"
             print_warning "Эта настройка специфична для Apple клавиатур или клавиатур с переключаемым режимом Fn."
             if confirm "Применить настройку fnmode=2 для hid_apple?"; then
                 modprobe_changed=false # Убираем local
                 # На уровне модуля
                 if ! grep -q "fnmode=2" /etc/modprobe.d/hid_apple.conf 2>/dev/null; then
                     echo "options hid_apple fnmode=2" | sudo tee /etc/modprobe.d/hid_apple.conf > /dev/null
                     print_success "Добавлена опция fnmode=2 в /etc/modprobe.d/hid_apple.conf."
                     modprobe_changed=true # Флаг, что файл изменен
                 else
                     print_success "Опция fnmode=2 уже установлена в /etc/modprobe.d/hid_apple.conf."
                 fi

                 kernel_param_changed=false # Убираем local
                 # На уровне параметра ядра (дополнительно)
                 if ! grep -q "hid_apple.fnmode=2" /etc/kernel/cmdline.d/91-keyboard-fnmode.conf 2>/dev/null; then
                     sudo mkdir -p /etc/kernel/cmdline.d/
                     echo "hid_apple.fnmode=2" | sudo tee /etc/kernel/cmdline.d/91-keyboard-fnmode.conf > /dev/null
                     print_success "Добавлен параметр ядра hid_apple.fnmode=2."
                     kernel_param_changed=true # Флаг, что файл изменен
                 else
                     print_success "Параметр ядра hid_apple.fnmode=2 уже установлен."
                 fi

                 # Выполняем команды только если были изменения
                 if [ "$modprobe_changed" = true ]; then
                     print_header "Пересборка initramfs..."
                     run_command "sudo mkinitcpio -P linux-zen"
                 fi
                 if [ "$kernel_param_changed" = true ]; then
                     print_header "Обновление конфигурации загрузчика..."
                     run_command "sudo bootctl update"
                 fi

                 # Обновляем финальное сообщение
                 if [ "$modprobe_changed" = true ] || [ "$kernel_param_changed" = true ]; then
                     print_warning "Изменения полностью вступят в силу после перезагрузки."
                 fi
             fi
             ;;
        18)
            print_header "18. Установка и настройка Fish Shell"
            # Пакеты: fish, curl (для fisher), git (для fisher/плагинов), fzf (для плагина)
            if check_and_install_packages "Fish Shell и утилиты" "fish" "curl" "git" "fzf"; then

                # --- Настройка для текущего пользователя ($USER) ---
                print_header "Настройка Fish для пользователя $USER"
                run_command "mkdir -p ~/.config/fish/functions" # Ensure functions dir exists

                # Установка Fisher (менеджер плагинов)
                if [ ! -f ~/.config/fish/functions/fisher.fish ]; then
                    print_header "Установка Fisher для $USER..."
                    # Запускаем от имени текущего пользователя, sudo не нужен
                    run_command "curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | fish -c 'source -; fisher install jorgebucaran/fisher'"
                else
                    print_success "Fisher уже установлен для $USER."
                fi

                # Установка плагинов для $USER
                print_header "Установка плагинов Fish для $USER..."
                run_command "fish -c 'fisher install jorgebucaran/fish-syntax-highlighting PatrickF1/fzf.fish jethrokuan/z'" # Убрали dracula/fish

                # --- Настройка для root ---
                print_header "Настройка Fish для root"
                run_command "sudo mkdir -p /root/.config/fish/functions" # Ensure functions dir exists for root

                # Установка Fisher для root
                if [ ! -f /root/.config/fish/functions/fisher.fish ]; then
                     print_header "Установка Fisher для root..."
                     run_command "sudo fish -c 'curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source -; fisher install jorgebucaran/fisher'"
                else
                     print_success "Fisher уже установлен для root."
                fi

                # Установка плагинов для root
                print_header "Установка плагинов Fish для root..."
                run_command "sudo fish -c 'fisher install jorgebucaran/fish-syntax-highlighting PatrickF1/fzf.fish jethrokuan/z'" # Убрали dracula/fish

                # --- Настройка для новых пользователей (/etc/skel) ---
                print_header "Настройка Fish для новых пользователей (/etc/skel)"
                run_command "sudo mkdir -p /etc/skel/.config/fish"
                # Копируем конфигурацию fisher и список плагинов
                if [ -f ~/.config/fish/config.fish ]; then
                    run_command "sudo cp ~/.config/fish/config.fish /etc/skel/.config/fish/"
                    run_command "sudo chown root:root /etc/skel/.config/fish/config.fish"
                else
                    print_warning "Файл ~/.config/fish/config.fish не найден, не копируем в /etc/skel."
                fi
                 if [ -f ~/.config/fish/fish_plugins ]; then
                    run_command "sudo cp ~/.config/fish/fish_plugins /etc/skel/.config/fish/"
                    run_command "sudo chown root:root /etc/skel/.config/fish/fish_plugins"
                 else
                    print_warning "Файл ~/.config/fish/fish_plugins не найден, не копируем в /etc/skel."
                 fi
                 print_success "Базовая конфигурация Fish скопирована в /etc/skel."
                 print_warning "Новым пользователям может потребоваться запустить 'fisher update' для установки плагинов."

                # --- Смена оболочки (опционально) ---
                if confirm "Сделать Fish оболочкой по умолчанию для пользователя $USER?"; then
                    run_command "chsh -s /usr/bin/fish $USER"
                    print_warning "Изменения вступят в силу после следующего входа пользователя $USER."
                fi

                print_warning "ВНИМАНИЕ: Установка Fish как оболочки для root НЕ РЕКОМЕНДУЕТСЯ из соображений совместимости и безопасности."
                if confirm "Все равно сделать Fish оболочкой по умолчанию для root? (НЕ РЕКОМЕНДУЕТСЯ)"; then
                    run_command "sudo chsh -s /usr/bin/fish root"
                    print_warning "Изменения вступят в силу после следующего входа пользователя root."
                fi

            else
                print_warning "Пропускаем установку Fish из-за отсутствия базовых пакетов."
            fi
            ;;
        0)
            print_header "Выход из скрипта"
            break
            ;;
        *)
            print_error "Неверный выбор. Пожалуйста, введите число от 0 до 18."
            ;;
    esac

    # Пауза перед показом меню снова, если не выходим
    if [ "$choice" != "0" ]; then
        echo # Добавляем пустую строку для лучшего разделения
        read -p "Нажмите Enter для возврата в меню..."
    fi

done

print_success "Работа скрипта завершена."
exit 0
</final_file_content>

IMPORTANT: For any future changes to this file, use the final_file_content shown above as your reference. This content reflects the current state of the file, including any auto-formatting (e.g., if you used single quotes but the formatter converted them to double quotes). Always base your SEARCH/REPLACE operations on this final version to ensure accuracy.

<environment_details>
# VSCode Visible Files
arch-setup.sh

# VSCode Open Tabs
arch-setup.sh

# Current Time
08.04.2025, 9:05:40 PM (Europe/Moscow, UTC+3:00)

# Current Mode
ACT MODE
</environment_details>
