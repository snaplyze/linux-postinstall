#!/bin/bash

# mini-pc-arch-setup.sh - Оптимизированный скрипт настройки Arch Linux для мини-ПК
# Версия: 1.6 (Интерактивная установка Steam, Ext4 для 2го диска, улучшенное форматирование)
# Цель: Дополнительная настройка системы, установленной с помощью installer.sh

# ==============================================================================
# Цвета и Функции вывода
# ==============================================================================
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m" # Сброс цвета

print_header() {
    echo -e "\n${BLUE}===== $1 =====${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# ==============================================================================
# Вспомогательные Функции
# ==============================================================================

# Запрос подтверждения у пользователя
confirm() {
    local prompt="$1 (y/N): "
    local response
    read -p "$prompt" response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# Запуск команды с базовой проверкой ошибок
run_command() {
    echo -e "${YELLOW}Выполняется:${NC} $1"
    if eval "$1"; then
        print_success "Успешно"
    else
        print_error "Ошибка при выполнении команды"
        # Если команда помечена как критическая, выходим из скрипта
        if [ "$2" = "critical" ]; then
            print_error "Критическая ошибка! Выход из скрипта."
            exit 1
        fi
    fi
}

# Проверка, установлен ли пакет
check_package() {
    if pacman -Q "$1" &> /dev/null; then
        return 0  # Пакет установлен
    else
        return 1  # Пакет не установлен
    fi
}

# Проверка, доступна ли команда
check_command() {
    if command -v "$1" &> /dev/null; then
        return 0  # Команда найдена
    else
        return 1  # Команда не найдена
    fi
}

# Проверка и установка пакетов (автоматически с --noconfirm)
# Используется для зависимостей, не для самого Steam
check_and_install_packages() {
    local category=$1
    shift
    local packages=("$@")
    local missing_packages=()

    echo -e "${BLUE}Проверка пакетов для: $category${NC}"

    # Собираем список отсутствующих пакетов
    for pkg in "${packages[@]}"; do
        if ! check_package "$pkg"; then
            # Проверяем наличие в репозиториях перед добавлением
            if pacman -Si "$pkg" &> /dev/null; then
                missing_packages+=("$pkg")
            else
                print_warning "Пакет '$pkg' не найден в репозиториях. Пропускаем."
            fi
        fi
    done

    # Если есть отсутствующие пакеты, предлагаем установить
    if [ ${#missing_packages[@]} -gt 0 ]; then
        echo -e "${YELLOW}Отсутствуют: ${missing_packages[*]}${NC}"
        if confirm "Установить эти пакеты?"; then
            run_command "sudo pacman -S --needed --noconfirm ${missing_packages[*]}" "critical"

            # Дополнительная проверка после установки
            local failed_install=()
            for pkg in "${missing_packages[@]}"; do
                if ! check_package "$pkg"; then
                    failed_install+=("$pkg")
                fi
            done
            if [ ${#failed_install[@]} -gt 0 ]; then
                print_error "Не удалось установить: ${failed_install[*]}. Операция может быть неполной."
                return 1 # Ошибка установки
            else
                print_success "Пакеты успешно установлены."
                return 0 # Успех
            fi
        else
            print_warning "Пропуск установки пакетов."
            return 1 # Пользователь отказался
        fi
    else
        echo -e "${GREEN}Все необходимые пакеты уже установлены${NC}"
        return 0 # Успех, все уже есть
    fi
}

# ==============================================================================
# Предварительные Проверки Системы
# ==============================================================================
print_header "Проверка системных требований"

# Проверка запуска от обычного пользователя
if [ "$EUID" -eq 0 ]; then
    print_error "Этот скрипт должен быть запущен от имени обычного пользователя, не root!"
    exit 1
fi

# Проверка базовых команд
base_deps=("bash" "sed" "grep" "awk")
missing_deps=()
for cmd in "${base_deps[@]}"; do
    if ! check_command "$cmd"; then
        missing_deps+=("$cmd")
    fi
done
if [ ${#missing_deps[@]} -gt 0 ]; then
    print_error "Отсутствуют необходимые базовые команды: ${missing_deps[*]}"
    exit 1
fi

# Проверка ZRAM (устанавливается инсталлятором)
if [ -e "/dev/zram0" ] && systemctl is-enabled --quiet systemd-zram-setup@zram0.service; then
    print_success "ZRAM настроен и включен установщиком"
else
    print_warning "ZRAM не обнаружен или не включен. Проверьте логи установщика."
fi

# ==============================================================================
# Информация о Системе
# ==============================================================================
print_header "Информация о системе"
echo "Ядро Linux: $(uname -r)"
echo "Дистрибутив: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "Процессор: $(lscpu | grep "Model name" | sed 's/Model name: *//')"
echo "Память: $(free -h | awk '/^Mem:/ {print $2}')"
ROOT_DEVICE=$(findmnt -no SOURCE / | sed 's/\[.*\]//')
echo "Системный диск: $ROOT_DEVICE (ФС: BTRFS - установлено installer.sh)"
echo "Опции монтирования '/': $(grep "[[:space:]]/[[:space:]]" /etc/fstab | awk '{print $4}')"
echo "BTRFS подтома на '/':"
sudo btrfs subvolume list / || echo " (Не удалось получить список подтомов)"
echo -e "\nВсе доступные блочные устройства:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE

# Проверка загрузчика (systemd-boot устанавливается инсталлятором)
if [ -d "/boot/loader" ] && [ -f "/boot/loader/loader.conf" ]; then
    print_success "Обнаружена конфигурация systemd-boot"
else
    print_error "Не найдена конфигурация systemd-boot. Скрипт может работать некорректно."
    if ! confirm "Продолжить выполнение скрипта?"; then exit 1; fi
fi

# Определение ядра (linux-zen устанавливается инсталлятором)
if [ -f "/boot/vmlinuz-linux-zen" ]; then
    KERNEL_NAME="linux-zen"
    print_success "Обнаружено ядро: $KERNEL_NAME"
else
    print_warning "Ядро linux-zen не найдено. Скрипт настроен для linux-zen."
    KERNEL_NAME="linux" # Fallback
    if ! confirm "Продолжить с ядром '$KERNEL_NAME'?"; then exit 1; fi
fi

# ==============================================================================
# Основное Меню
# ==============================================================================
while true; do
    print_header "Выберите операцию для выполнения"
    echo " 1. Обновление системы"
    echo " 2. Доп. настройка Intel графики (Wayland)"
    echo " 3. Доп. оптимизация BTRFS (системный диск)"
    echo " 4. Форматирование и монтирование второго SSD в Ext4 (/mnt/ssd)"
    echo " 5. Уточнение настройки скрытия логов при загрузке"
    echo " 6. Настройка пользовательского Paru"
    echo " 7. Настройка Flathub и GNOME Software"
    echo " 8. Настройка управления питанием (TLP)"
    echo " 9. Настройка Firewall и Core Dumps"
    echo "10. Установка доп. утилит и Seahorse"
    echo "11. Установка Timeshift (системный диск)"
    echo "12. Тонкая настройка PipeWire (Low Latency)"
    echo "13. Доп. оптимизация производительности"
    echo "14. Настройка Fn-клавиш (Apple Keyboard)"
    echo "15. Установка Steam (Intel графика)"
    echo " 0. Выход"

    read -p "Введите номер операции: " choice

    case $choice in
        0) # Выход
            echo "Выход из скрипта."
            exit 0
            ;;

        1) # Обновление системы
            print_header "1. Обновление системы"
            run_command "sudo pacman -Syu --noconfirm" "critical"
            print_success "Система обновлена"
            ;;

        2) # Доп. настройка Intel графики
            print_header "2. Дополнительная настройка Intel графики (Wayland)"
            if check_and_install_packages "Intel графика (доп.)" "intel-media-driver" "qt6-wayland" "qt5-wayland"; then
                # Оптимизация модуля i915
                I915_CONF="/etc/modprobe.d/i915.conf"
                I915_OPTS="options i915 enable_fbc=1 enable_guc=2 enable_dc=4"
                echo "Проверка $I915_CONF..."
                if [ ! -f "$I915_CONF" ] || ! grep -qF "$I915_OPTS" "$I915_CONF"; then
                    echo "Обновление $I915_CONF..."
                    echo "# Opts (mini-pc.sh)" | sudo tee "$I915_CONF" > /dev/null
                    echo "$I915_OPTS" | sudo tee -a "$I915_CONF" > /dev/null
                    print_success "Настройка $I915_CONF применена."
                    print_warning "Требуется перестроение initramfs (sudo mkinitcpio -P) и перезагрузка."
                else
                    print_success "$I915_CONF уже настроен."
                fi
                # Системные переменные окружения для Wayland
                ENV_FILE="/etc/environment"
                echo "Проверка $ENV_FILE..."
                ENV_CONTENT=$(cat <<EOF
# Wayland (mini-pc.sh)
LIBVA_DRIVER_NAME=iHD
MOZ_ENABLE_WAYLAND=1
QT_QPA_PLATFORM=wayland
EOF
)
                if [ ! -f "$ENV_FILE" ] || ! grep -q "LIBVA_DRIVER_NAME=iHD" "$ENV_FILE"; then
                    echo "Обновление $ENV_FILE..."
                    echo "$ENV_CONTENT" | sudo tee "$ENV_FILE" > /dev/null
                    print_success "$ENV_FILE настроен для Wayland."
                else
                    print_success "$ENV_FILE уже содержит настройки Wayland."
                fi
                print_success "Дополнительная настройка Intel графики завершена."
            else
                print_warning "Пропуск доп. настройки Intel графики (не установлены пакеты)."
            fi
            ;;

        3) # Доп. оптимизация BTRFS
            print_header "3. Дополнительная оптимизация BTRFS (системный диск)"
            print_success "TRIM и опции монтирования системного диска настроены установщиком."
            echo "Текущие опции монтирования '/': $(grep "[[:space:]]/[[:space:]]" /etc/fstab | awk '{print $4}')"
            # Настройка кэша метаданных
            SYSCTL_CONF="/etc/sysctl.d/60-btrfs-performance.conf"
            echo "Проверка sysctl для BTRFS ($SYSCTL_CONF)..."
            if [ ! -f "$SYSCTL_CONF" ]; then
                echo "Создание $SYSCTL_CONF..."
                cat << EOF | sudo tee "$SYSCTL_CONF" > /dev/null
# BTRFS Cache (mini-pc.sh)
vm.dirty_bytes = 4294967296
vm.dirty_background_bytes = 1073741824
EOF
                run_command "sudo sysctl --system"
                print_success "Настройки sysctl для BTRFS применены."
            else
                print_success "Настройки sysctl для BTRFS уже существуют."
            fi
            print_success "Дополнительная оптимизация BTRFS для системного диска завершена."
            ;;

        4) # Форматирование второго SSD в Ext4
            print_header "4. Форматирование и монтирование второго SSD в Ext4 (/mnt/ssd)"
            if check_and_install_packages "Форматирование дисков (Ext4)" "parted" "e2fsprogs" "gvfs"; then
                print_warning "ВНИМАНИЕ! Все данные на выбранном диске будут УНИЧТОЖЕНЫ!"
                echo "Текущие диски и разделы:"
                lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE
                ROOT_DISK=$(echo $ROOT_DEVICE | grep -o '^/dev/[a-z0-9]*')

                # Получаем список дисков для выбора
                mapfile -t available_disks < <(lsblk -dpno NAME,SIZE,TYPE | grep "disk" | grep -v "$ROOT_DISK" | awk '{print $1" ("$2")"}')
                if [ ${#available_disks[@]} -eq 0 ]; then print_warning "Дополнительные диски не найдены."; continue; fi

                echo "Доступные диски для форматирования:"
                select disk_choice in "${available_disks[@]}" "Отмена"; do
                    if [ "$disk_choice" == "Отмена" ]; then
                         print_warning "Операция отменена."
                         break # Выход из select, возврат в главное меню
                    elif [ -n "$disk_choice" ]; then
                         second_disk=$(echo "$disk_choice" | awk '{print $1}')
                         break # Диск выбран
                    else
                         print_warning "Неверный выбор."
                    fi
                done
                # Если была выбрана отмена, пропускаем остаток шага
                if [ "$disk_choice" == "Отмена" ]; then continue; fi

                if confirm "Точно форматировать $second_disk в Ext4 (метка 'SSD', точка /mnt/ssd)?"; then
                    # Размонтирование, если нужно
                    if mount | grep -q "^$second_disk"; then
                        print_warning "Размонтирование $second_disk..."
                        run_command "sudo umount ${second_disk}*" || { print_error "Не удалось размонтировать. Пропускаем."; continue; }
                    fi
                    # Очистка, разметка
                    run_command "sudo wipefs -af $second_disk" "critical"
                    run_command "sudo sgdisk --zap-all $second_disk" "critical"
                    run_command "sudo parted -s $second_disk mklabel gpt" "critical"
                    run_command "sudo parted -s -a optimal $second_disk mkpart primary ext4 0% 100%" "critical"
                    sleep 2 # Даем время
                    # Определение раздела
                    new_partition_name=$(lsblk -lno NAME $second_disk | grep -E "${second_disk##*/}[p]?1$") # Ищем sda1 или nvme0n1p1
                    if [ -z "$new_partition_name" ]; then print_error "Не удалось определить раздел на $second_disk."; continue; fi
                    new_partition="/dev/$new_partition_name"
                    if [ ! -b "$new_partition" ]; then print_error "'$new_partition' не блочное устройство."; continue; fi
                    print_success "Создан раздел: $new_partition"
                    # Форматирование
                    print_info "Форматирование $new_partition в Ext4 (метка 'SSD')..."
                    run_command "sudo mkfs.ext4 -L SSD $new_partition" "critical"
                    # Точка монтирования
                    mount_point="/mnt/ssd"
                    run_command "sudo mkdir -p $mount_point"
                    # fstab
                    DATA_UUID=$(sudo blkid -s UUID -o value $new_partition)
                    if [ -z "$DATA_UUID" ]; then print_error "Не удалось получить UUID для $new_partition."; continue; fi
                    print_info "Добавление записи в /etc/fstab для $mount_point..."
                    run_command "sudo cp /etc/fstab /etc/fstab.backup.$(date +%F_%T)"
                    sudo sed -i "/UUID=$DATA_UUID/d" /etc/fstab # Удаляем старые записи с этим UUID
                    fstab_line="UUID=$DATA_UUID  $mount_point  ext4  defaults,noatime,x-gvfs-show  0 2"
                    echo "# Второй SSD - (Ext4, SSD, /mnt/ssd, mini-pc.sh)" | sudo tee -a /etc/fstab > /dev/null
                    echo "$fstab_line" | sudo tee -a /etc/fstab > /dev/null
                    print_success "Строка добавлена в fstab: $fstab_line"
                    # Монтирование и права
                    run_command "sudo systemctl daemon-reload"
                    run_command "sudo mount -a" "critical"
                    print_info "Установка прав доступа для $mount_point..."
                    run_command "sudo chown $(whoami):$(whoami) $mount_point"
                    print_success "Диск $second_disk отформатирован и примонтирован в $mount_point."
                    print_info "Диск должен появиться в Nautilus (может потребоваться перезапуск)."
                fi # Конец confirm
            else
                print_warning "Пропуск форматирования (нет необходимых пакетов)."
            fi # Конец check_and_install_packages
            ;;

        5) # Скрытие логов
            print_header "5. Уточнение настройки скрытия логов при загрузке"
            print_success "Plymouth и базовые параметры 'quiet splash' настроены установщиком."
            # Доп. параметры ядра
            QUIET_PARAMS="loglevel=3 rd.systemd.show_status=auto rd.udev.log_priority=3"
            CMDLINE_FILE="/etc/kernel/cmdline.d/quiet-extra.conf"
            echo "Проверка $CMDLINE_FILE..."
            if [ ! -f "$CMDLINE_FILE" ] || ! grep -q "loglevel=3" "$CMDLINE_FILE"; then
                echo "Добавление доп. параметров тихой загрузки..."
                echo "$QUIET_PARAMS" | sudo tee "$CMDLINE_FILE" > /dev/null
                print_success "Дополнительные параметры добавлены."
                run_command "sudo bootctl update"
            else
                print_success "Дополнительные параметры тихой загрузки уже установлены."
            fi
            # Отключение журнала на TTY
            JOURNALD_CONF="/etc/systemd/journald.conf.d/quiet.conf"
            echo "Проверка $JOURNALD_CONF..."
            if [ ! -f "$JOURNALD_CONF" ]; then
                if confirm "Отключить вывод журнала systemd на TTY?"; then
                    run_command "sudo mkdir -p /etc/systemd/journald.conf.d/"
                    cat << EOF | sudo tee "$JOURNALD_CONF" > /dev/null
[Journal]
TTYPath=/dev/null
EOF
                    print_success "Вывод журнала на TTY отключен."
                fi
            else
                print_success "Настройка журнала TTY уже существует ($JOURNALD_CONF)."
            fi
            print_success "Настройка тихой загрузки завершена."
            ;;

        6) # Настройка Paru
            print_header "6. Настройка пользовательского Paru"
            if ! check_command "paru"; then print_error "Paru не найден."; continue; fi
            print_success "Paru установлен системно (/usr/bin/paru)."
            # Пользовательский конфиг
            PARU_USER_CONF="$HOME/.config/paru/paru.conf"
            echo "Проверка $PARU_USER_CONF..."
            if [ ! -f "$PARU_USER_CONF" ]; then
                echo "Создание $PARU_USER_CONF..."
                run_command "mkdir -p ~/.config/paru"
                cat << EOF > "$PARU_USER_CONF"
# Пользовательский конфиг Paru
[options]
BottomUp
Devel               # Показывать пакеты в разработке при поиске обновлений
CleanAfter          # Очищать кэш сборки после установки
NewsOnUpgrade       # Показывать новости Arch перед обновлением
# UpgradeMenu       # Показывать меню выбора пакетов для обновления (можно раскомментировать)
CombinedUpgrade     # Показывать пакеты из репо и AUR вместе
# RemoveMake        # Удалять зависимости сборки после установки (экономит место, но может мешать пересборке)
# KeepRepoCache     # Не удалять кэш скачанных пакетов из репозиториев
# SudoLoop          # Периодически обновлять sudo timestamp (системный конфиг уже может это делать)
# BatchInstall      # Устанавливать пакеты без подтверждения каждого (рискованно)
# Redownload        # Всегда скачивать исходники AUR заново

# Папка для временных файлов сборки (если нужно изменить)
# CloneDir = ~/.cache/paru/clone
EOF
                print_success "Создан пользовательский конфиг: $PARU_USER_CONF"
                print_warning "Отредактируйте его при необходимости (настройки SudoLoop/RemoveMake/BatchInstall)."
            else
                print_success "Пользовательский конфиг Paru уже существует: $PARU_USER_CONF"
            fi
            ;;

        7) # Настройка Flathub
            print_header "7. Настройка Flathub и GNOME Software"
            if ! check_command "flatpak" || ! check_package "gnome-software"; then print_error "Нет Flatpak или GNOME Software."; continue; fi
            print_success "Flatpak и GNOME Software установлены."
            # Репозиторий Flathub
            if ! flatpak remote-list | grep -q flathub; then
                print_info "Добавление репозитория Flathub..."
                run_command "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo" "critical"
            else
                print_success "Репозиторий Flathub уже добавлен."
            fi
            # GNOME Platform
            echo "Проверка наличия GNOME Platform Runtime..."
            GNOME_PLATFORM_ID="org.gnome.Platform"
            if ! flatpak list --runtime | grep -q "$GNOME_PLATFORM_ID"; then
                echo "Определение последней версии GNOME Platform..."
                # Получаем все версии, сортируем по номеру, берем последнюю
                latest_gnome_version=$(flatpak remote-info --log flathub $GNOME_PLATFORM_ID 2>/dev/null | grep -oP "Version: \K[0-9\.]+" | sort -V | tail -n 1)
                if [ -z "$latest_gnome_version" ]; then
                    latest_gnome_version="48" # Безопасный fallback
                    print_warning "Не удалось определить последнюю версию GNOME Platform, используем версию $latest_gnome_version"
                else
                    print_success "Определена последняя версия GNOME Platform: $latest_gnome_version"
                fi
                if confirm "Установить Flatpak GNOME Platform $latest_gnome_version?"; then
                    run_command "flatpak install -y flathub ${GNOME_PLATFORM_ID}//$latest_gnome_version"
                fi
            else
                print_success "Flatpak GNOME Platform Runtime уже установлен."
            fi
            print_success "Настройка Flathub завершена."
            ;;

        8) # Настройка TLP
            print_header "8. Настройка управления питанием (TLP)"
            print_warning "Установщик включил 'tuned'. TLP/power-profiles-daemon могут с ним конфликтовать."
            if systemctl is-active --quiet tuned; then
                if confirm "Отключить службу 'tuned', чтобы использовать TLP?"; then
                    run_command "sudo systemctl disable --now tuned"
                else
                    print_warning "Пропускаем настройку TLP/PPD, т.к. 'tuned' активен."
                    continue
                fi
            fi
            # Установка Thermald и TLP
            if check_and_install_packages "Управление питанием (доп.)" "thermald" "tlp" "tlp-rdw"; then
                # Thermald
                if ! systemctl is-enabled --quiet thermald; then
                    print_info "Включение thermald..."
                    run_command "sudo systemctl enable --now thermald"
                else
                    print_success "Thermald уже включен."
                fi
                # TLP Config
                TLP_CONF="/etc/tlp.conf.d/01-mini-pc.conf"
                echo "Проверка $TLP_CONF..."
                if [ ! -f "$TLP_CONF" ]; then
                    echo "Создание $TLP_CONF..."
                    cat << EOF | sudo tee "$TLP_CONF" > /dev/null
# TLP mini-pc (mini-pc.sh) - Performance oriented
TLP_ENABLE=1
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=performance
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=performance
PCIE_ASPM_ON_AC=performance
PCIE_ASPM_ON_BAT=performance
USB_AUTOSUSPEND=0
WIFI_PWR_ON_AC=on
WIFI_PWR_ON_BAT=on
WOL_DISABLE=Y
SOUND_POWER_SAVE_ON_AC=0
SOUND_POWER_SAVE_ON_BAT=0
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=on
EOF
                    print_success "$TLP_CONF создан."
                else
                    print_success "$TLP_CONF уже существует."
                fi
                # Enable TLP Services
                if ! systemctl is-enabled --quiet tlp; then
                    print_info "Включение служб TLP..."
                    run_command "sudo systemctl enable --now tlp"
                    run_command "sudo systemctl enable NetworkManager-dispatcher.service" # Needed for tlp-rdw
                    run_command "sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket" # Recommended by TLP
                else
                    print_success "Служба TLP уже включена."
                fi
                # Swappiness (Installer уже настроил sysctl для zram, эта настройка может быть избыточна)
                SWAPPINESS_CONF="/etc/sysctl.d/99-swappiness-zram.conf"
                echo "Проверка swappiness ($SWAPPINESS_CONF)..."
                if [ ! -f "$SWAPPINESS_CONF" ]; then
                    echo "Настройка vm.swappiness для ZRAM..."
                    echo "vm.swappiness=100 # High value for active ZRAM usage" | sudo tee "$SWAPPINESS_CONF" > /dev/null
                    run_command "sudo sysctl --system"
                    print_success "Swappiness настроен."
                else
                    print_success "Настройка swappiness уже существует: $(sudo sysctl vm.swappiness)"
                fi
            else
                print_warning "Пропуск настройки управления питанием (нет пакетов)."
            fi
            ;;

        9) # Firewall / Core Dumps
            print_header "9. Настройка Firewall и Core Dumps"
            # UFW
            if check_and_install_packages "Безопасность (UFW)" "ufw"; then
                if ! systemctl is-enabled --quiet ufw; then
                    print_info "Настройка и включение UFW..."
                    run_command "sudo ufw default deny incoming"
                    run_command "sudo ufw default allow outgoing"
                    run_command "sudo ufw allow ssh" # Важно для удаленного доступа
                    # run_command "sudo ufw allow Samba" # Пример для Samba
                    run_command "sudo ufw enable" # Включает и добавляет в автозагрузку
                    print_success "UFW настроен и включен."
                else
                    print_success "UFW уже включен. Текущие правила:"
                    sudo ufw status verbose
                fi
            else
                print_warning "Пропуск настройки UFW (нет пакетов)."
            fi
            # Core Dumps Disable
            LIMITS_CONF="/etc/security/limits.d/nocore.conf"
            SYSCTL_CORE_CONF="/etc/sysctl.d/51-coredump-disable.conf"
            echo "Проверка отключения Core Dumps..."
            if [ ! -f "$LIMITS_CONF" ] || [ ! -f "$SYSCTL_CORE_CONF" ]; then
                print_info "Отключение Core Dumps..."
                echo "* hard core 0" | sudo tee "$LIMITS_CONF" > /dev/null
                echo "* soft core 0" | sudo tee -a "$LIMITS_CONF" > /dev/null
                echo "kernel.core_pattern=/dev/null" | sudo tee "$SYSCTL_CORE_CONF" > /dev/null
                run_command "sudo sysctl -p $SYSCTL_CORE_CONF"
                print_success "Core Dumps отключены."
            else
                print_success "Core Dumps уже отключены."
            fi
            print_success "Настройка безопасности завершена."
            ;;

        10) # Доп. утилиты / Seahorse
            print_header "10. Установка доп. утилит и Seahorse"
            cli_utils=("neofetch" "bat" "exa" "ripgrep" "fd" "htop")
            check_and_install_packages "Доп. утилиты CLI" "${cli_utils[@]}"
            # Seahorse для управления ключами (Gnome Keyring уже установлен)
            check_and_install_packages "Seahorse (GUI для ключей)" "seahorse"
            print_success "Проверка/установка дополнительных программ завершена."
            ;;

        11) # Timeshift
            print_header "11. Установка Timeshift (системный диск)"
            if check_and_install_packages "Резервное копирование" "timeshift"; then
                # Проверяем, настроен ли уже Timeshift (хотя бы пытается ли он монтировать снапшоты)
                if ! grep -q "/run/timeshift/backup" /etc/fstab; then
                    print_warning "Timeshift не настроен. Рекомендуется запустить 'sudo timeshift-gtk'."
                    echo "В настройках выберите:"
                    echo "  - Тип снапшотов: BTRFS"
                    echo "  - Местоположение BTRFS: выберите ваш системный раздел ($ROOT_DEVICE)"
                    echo "  - Уровни снапшотов (по желанию)"
                    if confirm "Запустить графический конфигуратор timeshift-gtk сейчас?"; then
                        timeshift-launcher # Используем launcher для правильного запуска с правами
                    fi
                else
                    print_success "Timeshift (BTRFS) уже настроен в /etc/fstab (или пытается монтировать)."
                    print_info "Запустите 'sudo timeshift-gtk' для управления снапшотами."
                fi
            else
                print_warning "Пропуск установки Timeshift (нет пакетов)."
            fi
            ;;

        12) # PipeWire Low Latency
            print_header "12. Тонкая настройка PipeWire (Low Latency)"
            print_success "PipeWire и Wireplumber установлены и настроены установщиком."
            PW_CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
            LOWLATENCY_CONF="$PW_CONF_DIR/10-lowlatency.conf"
            echo "Проверка конфигурации PipeWire Low Latency ($LOWLATENCY_CONF)..."
            if [ ! -f "$LOWLATENCY_CONF" ]; then
                print_info "Создание конфигурации PipeWire Low Latency..."
                run_command "mkdir -p $PW_CONF_DIR"
                # Настройки для низкой задержки
                cat << EOF > "$LOWLATENCY_CONF"
context.properties = {
    # default.clock.rate          = 48000
    # default.clock.allowed-rates = [ 44100, 48000, 88200, 96000 ] # Пример
    default.clock.quantum       = 256  # Buffer size (lower = less latency)
    default.clock.min-quantum   = 32   # Minimal buffer size
    default.clock.max-quantum   = 1024 # Maximal buffer size (default 8192)
}
EOF
                print_success "Конфигурация PipeWire Low Latency создана: $LOWLATENCY_CONF"
                print_warning "Перезапустите PipeWire/Wireplumber или перезагрузите сеанс для применения:"
                echo "  systemctl --user restart pipewire pipewire-pulse wireplumber"
            else
                print_success "Конфигурация PipeWire Low Latency уже существует ($LOWLATENCY_CONF)."
            fi
            ;;

        13) # Доп. оптимизация производительности
             print_header "13. Дополнительная оптимизация производительности"
             # Sysctl tweaks
             SYSCTL_PERF_CONF="/etc/sysctl.d/99-performance-tweaks.conf"
             echo "Проверка sysctl для производительности ($SYSCTL_PERF_CONF)..."
             if [ ! -f "$SYSCTL_PERF_CONF" ]; then
                 print_info "Применение дополнительных настроек sysctl..."
                 cat << EOF | sudo tee "$SYSCTL_PERF_CONF" > /dev/null
# Performance Tweaks (mini-pc.sh)
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
fs.file-max = 100000
fs.inotify.max_user_watches = 524288
EOF
                 run_command "sudo sysctl --system"
                 print_success "Дополнительные настройки sysctl применены."
             else
                 print_success "Дополнительные настройки sysctl уже существуют ($SYSCTL_PERF_CONF)."
             fi
             # Systemd timeouts
             SYSTEMD_TIMEOUT_CONF="/etc/systemd/system.conf.d/timeout.conf"
             echo "Проверка таймаутов systemd ($SYSTEMD_TIMEOUT_CONF)..."
             if [ ! -f "$SYSTEMD_TIMEOUT_CONF" ]; then
                 print_info "Уменьшение таймаутов systemd..."
                 run_command "sudo mkdir -p /etc/systemd/system.conf.d/"
                 cat << EOF | sudo tee "$SYSTEMD_TIMEOUT_CONF" > /dev/null
[Manager]
DefaultTimeoutStartSec=10s
DefaultTimeoutStopSec=10s
EOF
                 run_command "sudo systemctl daemon-reload"
                 print_success "Таймауты systemd настроены."
             else
                 print_success "Настройка таймаутов systemd уже существует ($SYSTEMD_TIMEOUT_CONF)."
             fi
             # Disable unused services
            echo "Проверка статуса служб для возможного отключения..."
            unused_services=("bluetooth.service" "avahi-daemon.service" "cups.socket") # cups - socket activated
            for service in "${unused_services[@]}"; do
                # Проверяем и активен ли, и включен ли
                is_active=$(systemctl is-active --quiet "$service"; echo $?)
                is_enabled=$(systemctl is-enabled --quiet "$service"; echo $?)
                if [ "$is_active" -eq 0 ] || [ "$is_enabled" -eq 0 ]; then
                    if confirm "Служба '$service' активна или включена. Отключить её?"; then
                        run_command "sudo systemctl disable --now $service"
                    fi
                else
                    print_info "Служба '$service' неактивна и не включена."
                fi
            done
            print_success "Дополнительная оптимизация производительности завершена."
            ;;

        14) # Настройка Fn-клавиш
            print_header "14. Настройка Fn-клавиш (Apple Keyboard)"
            print_warning "Эта настройка актуальна в основном для клавиатур Apple."
            # Modprobe config
            HID_APPLE_CONF="/etc/modprobe.d/hid_apple.conf"
            echo "Проверка $HID_APPLE_CONF..."
            if ! grep -q "options hid_apple fnmode=2" "$HID_APPLE_CONF" 2>/dev/null; then
                echo "Настройка драйвера hid_apple для стандартного поведения F-клавиш..."
                echo "options hid_apple fnmode=2" | sudo tee "$HID_APPLE_CONF" > /dev/null
                print_success "Настройка $HID_APPLE_CONF создана."
                print_warning "Требуется перестроение initramfs (sudo mkinitcpio -P) и перезагрузка."
            else
                 print_success "Настройка hid_apple fnmode=2 уже существует в $HID_APPLE_CONF."
            fi
            # Kernel cmdline parameter
            CMDLINE_KBD_CONF="/etc/kernel/cmdline.d/keyboard-fnmode.conf"
            echo "Проверка параметра ядра в $CMDLINE_KBD_CONF..."
             if [ ! -f "$CMDLINE_KBD_CONF" ] || ! grep -q "hid_apple.fnmode=2" "$CMDLINE_KBD_CONF"; then
                 echo "Добавление параметра ядра hid_apple.fnmode=2..."
                 echo "hid_apple.fnmode=2" | sudo tee "$CMDLINE_KBD_CONF" > /dev/null
                 run_command "sudo bootctl update" # Обновляем загрузчик
                 print_success "Параметр ядра добавлен."
             else
                 print_success "Параметр ядра hid_apple.fnmode=2 уже установлен."
             fi
            print_success "Настройка функциональных клавиш завершена (если используется hid_apple)."
            print_warning "Изменения вступят в силу после перестроения initramfs и перезагрузки."
            ;;

        15) # Установка Steam
            print_header "15. Установка Steam (Intel графика)"
            print_info "Убедитесь, что репозиторий [multilib] включен в /etc/pacman.conf (должен быть включен установщиком)."

            # Зависимости ставим автоматически ДО Steam
            steam_deps=(
                "vulkan-intel"          # Intel Vulkan driver (64-bit)
                "lib32-vulkan-intel"    # Intel Vulkan driver (32-bit)
                "mesa"                  # OpenGL drivers (64-bit) - скорее всего уже есть
                "lib32-mesa"            # OpenGL drivers (32-bit) - скорее всего уже есть
                "xorg-mkfontscale"      # Font utilities
                "xorg-fonts-cyrillic"   # Cyrillic fonts for Xorg
                "xorg-fonts-misc"       # Misc fonts for Xorg
            )

            if check_and_install_packages "Зависимости Steam для Intel" "${steam_deps[@]}"; then
                print_success "Зависимости Steam установлены/проверены."

                # Установка самого Steam - ИНТЕРАКТИВНО
                if ! check_package "steam"; then
                    print_warning "Сейчас будет запущена ИНТЕРАКТИВНАЯ установка Steam."
                    print_warning "Когда появится список 'провайдеров', выберите опцию с 'intel',"
                    print_warning "скорее всего это будет 'lib32-vulkan-intel' или подобное."
                    read -p "Нажмите Enter для запуска 'sudo pacman -S steam'..."

                    if sudo pacman -S steam; then
                        print_success "Steam успешно установлен (интерактивно)."
                    else
                        print_error "Ошибка во время интерактивной установки Steam."
                        continue # Возврат в главное меню
                    fi
                else
                    print_success "Пакет Steam уже установлен."
                fi
                print_info "Для первого запуска Steam может потребоваться перезагрузка сеанса или системы."
            else
                print_warning "Установка зависимостей Steam не удалась или была отменена. Steam не установлен."
            fi
            ;;

        *) # Некорректный выбор
            print_warning "Некорректный выбор. Введите число от 0 до 15."
            ;;
    esac

    # Пауза перед возвратом в меню
    echo ""
    read -p "Нажмите Enter для продолжения..."

done

# --- Конец скрипта ---
