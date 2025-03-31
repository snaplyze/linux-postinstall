#!/bin/bash

# mini-pc-arch-setup.sh - Оптимизированный скрипт настройки Arch Linux для мини-ПК
# Версия: 1.7 (Добавлены проверки зависимостей для всех шагов)
# Цель: Дополнительная настройка системы, установленной с помощью installer.sh

# ==============================================================================
# Цвета и Функции вывода
# ==============================================================================
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m" # Сброс цвета

print_header() { echo -e "\n${BLUE}===== $1 =====${NC}\n"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }

# ==============================================================================
# Вспомогательные Функции
# ==============================================================================

confirm() {
    local prompt="$1 (y/N): "
    local response
    read -p "$prompt" response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

run_command() {
    echo -e "${YELLOW}Выполняется:${NC} $1"
    # Используем subshell для eval, чтобы ошибки не прерывали скрипт неожиданно
    (eval "$1")
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        print_success "Успешно"
        return 0
    else
        print_error "Ошибка при выполнении команды (код: $exit_code)"
        if [ "$2" = "critical" ]; then
            print_error "Критическая ошибка! Выход из скрипта."
            exit 1
        fi
        return $exit_code # Возвращаем код ошибки
    fi
}

check_package() {
    if pacman -Q "$1" &> /dev/null; then return 0; else return 1; fi
}

check_command() {
    if command -v "$1" &> /dev/null; then return 0; else return 1; fi
}

# Функция проверки базовых утилит, необходимых для многих шагов
# Если чего-то нет, выводит ошибку и возвращает 1
check_essentials() {
    local missing_cmds=()
    # Добавляем команды, которые точно должны быть после installer.sh
    local essentials=("grep" "tee" "mkdir" "cat" "systemctl" "sysctl" "awk" "sed" "mount" "umount" "lsblk" "chown")
    for cmd in "${essentials[@]}"; do
        if ! check_command "$cmd"; then
            missing_cmds+=("$cmd")
        fi
    done

    # Проверяем специфичные для шагов команды, переданные как аргументы
    for cmd in "$@"; do
         if ! check_command "$cmd"; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        print_error "Отсутствуют необходимые команды для этой операции: ${missing_cmds[*]}"
        print_warning "Установите их (обычно пакеты coreutils, systemd, util-linux и т.д.) или проверьте PATH."
        return 1
    else
        return 0
    fi
}


# Проверка и установка пакетов (автоматически с --noconfirm)
# Возвращает 0 при успехе, 1 при отказе/ошибке
check_and_install_packages() {
    local category=$1
    shift
    local packages=("$@")
    local missing_packages=()

    echo -e "${BLUE}Проверка пакетов для: $category${NC}"
    for pkg in "${packages[@]}"; do
        if ! check_package "$pkg"; then
            if pacman -Si "$pkg" &> /dev/null; then
                missing_packages+=("$pkg")
            else
                print_warning "Пакет '$pkg' не найден в репозиториях. Пропускаем."
            fi
        fi
    done

    if [ ${#missing_packages[@]} -gt 0 ]; then
        echo -e "${YELLOW}Отсутствуют: ${missing_packages[*]}${NC}"
        if confirm "Установить эти пакеты?"; then
            # Используем run_command для установки
            if ! run_command "sudo pacman -S --needed --noconfirm ${missing_packages[*]}"; then
                 print_error "Не удалось завершить установку пакетов."
                 return 1 # Ошибка установки
            fi
            # Дополнительная проверка после попытки установки
            local failed_install=()
            for pkg in "${missing_packages[@]}"; do
                if ! check_package "$pkg"; then
                    failed_install+=("$pkg")
                fi
            done
            if [ ${#failed_install[@]} -gt 0 ]; then
                print_error "Пакеты не установились: ${failed_install[*]}. Операция не может быть продолжена."
                return 1 # Ошибка, пакеты не установились
            else
                print_success "Пакеты успешно установлены."
                return 0 # Успех
            fi
        else
            print_warning "Пропуск установки пакетов. Операция отменена."
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
if [ "$EUID" -eq 0 ]; then print_error "Запустите от обычного пользователя."; exit 1; fi
# Проверяем только базовые для самого скрипта, остальное проверят check_essentials
base_deps=("bash" "pacman" "command"); missing_deps=();
for cmd in "${base_deps[@]}"; do if ! check_command "$cmd"; then missing_deps+=("$cmd"); fi; done
if [ ${#missing_deps[@]} -gt 0 ]; then print_error "Отсутствуют критические команды: ${missing_deps[*]}"; exit 1; fi
if [ -e "/dev/zram0" ] && systemctl is-enabled --quiet systemd-zram-setup@zram0.service; then print_success "ZRAM настроен"; else print_warning "ZRAM не обнаружен/не включен."; fi

# ==============================================================================
# Информация о Системе
# ==============================================================================
print_header "Информация о системе"
# Проверяем команды перед использованием
if ! check_essentials "uname" "lscpu" "free" "findmnt" "btrfs" "lsblk"; then
    print_error "Не могу собрать информацию о системе. Пропускаю."
else
    echo "Ядро Linux: $(uname -r)"
    echo "Дистрибутив: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "Процессор: $(lscpu | grep "Model name" | sed 's/Model name: *//')"
    echo "Память: $(free -h | awk '/^Mem:/ {print $2}')"
    ROOT_DEVICE=$(findmnt -no SOURCE / | sed 's/\[.*\]//')
    echo "Системный диск: $ROOT_DEVICE (ФС: BTRFS)"
    echo "Опции монтирования '/': $(grep "[[:space:]]/[[:space:]]" /etc/fstab | awk '{print $4}')"
    echo "BTRFS подтома на '/':"
    sudo btrfs subvolume list / || echo " (Не удалось получить список подтомов)"
    echo -e "\nВсе доступные блочные устройства:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE
fi
# Проверка загрузчика
if ! check_command "bootctl"; then
     print_warning "Команда bootctl не найдена. Проверка systemd-boot невозможна."
elif [ -d "/boot/loader" ] && [ -f "/boot/loader/loader.conf" ]; then
    print_success "Обнаружена конфигурация systemd-boot"
else
    print_error "Не найдена конфигурация systemd-boot."
    if ! confirm "Продолжить?"; then exit 1; fi
fi
# Определение ядра
if [ -f "/boot/vmlinuz-linux-zen" ]; then KERNEL_NAME="linux-zen"; print_success "Ядро: $KERNEL_NAME";
elif [ -f "/boot/vmlinuz-linux" ]; then KERNEL_NAME="linux"; print_success "Ядро: $KERNEL_NAME";
else print_warning "Стандартное ядро или linux-zen не найдено."; KERNEL_NAME="linux"; if ! confirm "Попробовать с '$KERNEL_NAME'?"; then exit 1; fi; fi

# ==============================================================================
# Основное Меню
# ==============================================================================
while true; do
    # Очистка экрана для лучшей читаемости меню
    clear
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
            # pacman должен быть всегда
            run_command "sudo pacman -Syu --noconfirm" "critical"
            print_success "Система обновлена."
            ;;

        2) # Доп. настройка Intel графики
            print_header "2. Дополнительная настройка Intel графики (Wayland)"
            # Проверка базовых команд и пакетов
            if ! check_essentials "mkinitcpio"; then continue; fi
            if ! check_and_install_packages "Intel графика (доп.)" "intel-media-driver" "qt6-wayland" "qt5-wayland"; then continue; fi

            # Оптимизация модуля i915
            I915_CONF="/etc/modprobe.d/i915.conf"
            I915_OPTS="options i915 enable_fbc=1 enable_guc=2 enable_dc=4"
            echo "Проверка $I915_CONF..."
            # Используем sudo для чтения, на случай если у пользователя нет прав
            if [ ! -f "$I915_CONF" ] || ! sudo grep -qF "$I915_OPTS" "$I915_CONF"; then
                echo "Обновление $I915_CONF..."
                echo "# Opts (mini-pc.sh)" | sudo tee "$I915_CONF" > /dev/null
                echo "$I915_OPTS" | sudo tee -a "$I915_CONF" > /dev/null
                print_success "Настройка $I915_CONF применена."
                print_warning "Требуется перестроение initramfs (sudo mkinitcpio -P) и перезагрузка."
                # Предложить перестроить initramfs
                if confirm "Перестроить initramfs сейчас?"; then
                    run_command "sudo mkinitcpio -P"
                fi
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
)         # Убрал точку с запятой в конце строк
            if [ ! -f "$ENV_FILE" ] || ! sudo grep -q "LIBVA_DRIVER_NAME=iHD" "$ENV_FILE"; then
                echo "Обновление $ENV_FILE..."
                echo "$ENV_CONTENT" | sudo tee "$ENV_FILE" > /dev/null
                print_success "$ENV_FILE настроен для Wayland."
            else
                print_success "$ENV_FILE уже содержит настройки Wayland."
            fi
            print_success "Дополнительная настройка Intel графики завершена."
            ;;

        3) # Доп. оптимизация BTRFS
            print_header "3. Дополнительная оптимизация BTRFS (системный диск)"
            if ! check_essentials "btrfs"; then continue; fi # Проверяем btrfs команду
            print_success "TRIM и опции монтирования системного диска настроены установщиком."
            echo "Текущие опции монтирования '/': $(grep "[[:space:]]/[[:space:]]" /etc/fstab | awk '{print $4}')"
            # Настройка кэша метаданных
            SYSCTL_CONF="/etc/sysctl.d/60-btrfs-performance.conf"
            echo "Проверка sysctl для BTRFS ($SYSCTL_CONF)..."
            if [ ! -f "$SYSCTL_CONF" ]; then
                echo "Создание $SYSCTL_CONF..."
                # Убрал точку с запятой
                cat << EOF | sudo tee "$SYSCTL_CONF" > /dev/null
# BTRFS Cache (mini-pc.sh)
vm.dirty_bytes = 4294967296
vm.dirty_background_bytes = 1073741824
EOF
                if run_command "sudo sysctl --system"; then
                    print_success "Настройки sysctl для BTRFS применены."
                else
                    print_warning "Не удалось применить sysctl."
                fi
            else
                print_success "Настройки sysctl для BTRFS уже существуют."
            fi
            print_success "Дополнительная оптимизация BTRFS для системного диска завершена."
            ;;

        4) # Форматирование второго SSD в Ext4
            print_header "4. Форматирование и монтирование второго SSD в Ext4 (/mnt/ssd)"
            # Проверяем утилиты форматирования/разметки
            if ! check_essentials "parted" "mkfs.ext4" "wipefs" "sgdisk" "blkid"; then continue; fi
            # Проверяем пакет gvfs для интеграции с Nautilus
            if ! check_and_install_packages "GVFS (для отображения диска)" "gvfs"; then continue; fi

            print_warning "ВНИМАНИЕ! Все данные на выбранном диске будут УНИЧТОЖЕНЫ!"
            echo "Текущие диски и разделы:"; lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE
            ROOT_DISK=$(echo $ROOT_DEVICE | grep -o '^/dev/[a-z0-9]*')

            mapfile -t available_disks < <(lsblk -dpno NAME,SIZE,TYPE | grep "disk" | grep -v "$ROOT_DISK" | awk '{print $1" ("$2")"}')
            if [ ${#available_disks[@]} -eq 0 ]; then print_warning "Дополнительные диски не найдены."; continue; fi

            echo "Доступные диски для форматирования:"
            # Используем select для выбора диска
            select disk_choice in "${available_disks[@]}" "Отмена"; do
                if [ "$disk_choice" == "Отмена" ]; then
                     print_warning "Операция отменена."
                     break # Выход из select
                elif [ -n "$disk_choice" ]; then
                     second_disk=$(echo "$disk_choice" | awk '{print $1}')
                     break # Диск выбран
                else
                     print_warning "Неверный выбор. Попробуйте еще раз."
                fi
            done
            if [ "$disk_choice" == "Отмена" ]; then continue; fi # Если отменили, в главное меню

            # Подтверждение
            if confirm "Точно форматировать $second_disk в Ext4 (метка 'SSD', точка /mnt/ssd)?"; then
                if mount | grep -q "^$second_disk"; then print_warning "Размонтирование $second_disk..."; if ! run_command "sudo umount ${second_disk}*"; then print_error "Не удалось размонтировать."; continue; fi; fi
                # Форматирование
                if ! run_command "sudo wipefs -af $second_disk" "critical"; then continue; fi
                if ! run_command "sudo sgdisk --zap-all $second_disk" "critical"; then continue; fi
                if ! run_command "sudo parted -s $second_disk mklabel gpt" "critical"; then continue; fi
                if ! run_command "sudo parted -s -a optimal $second_disk mkpart primary ext4 0% 100%" "critical"; then continue; fi
                sleep 2
                new_partition_name=$(lsblk -lno NAME $second_disk | grep -E "${second_disk##*/}[p]?1$")
                if [ -z "$new_partition_name" ]; then print_error "Не удалось определить раздел."; continue; fi
                new_partition="/dev/$new_partition_name"
                if [ ! -b "$new_partition" ]; then print_error "'$new_partition' не блочное устройство."; continue; fi
                print_success "Создан раздел: $new_partition"
                print_info "Форматирование $new_partition в Ext4 (метка 'SSD')..."
                if ! run_command "sudo mkfs.ext4 -L SSD $new_partition" "critical"; then continue; fi
                # Монтирование
                mount_point="/mnt/ssd"
                if ! run_command "sudo mkdir -p $mount_point"; then continue; fi
                DATA_UUID=$(sudo blkid -s UUID -o value $new_partition)
                if [ -z "$DATA_UUID" ]; then print_error "Не удалось получить UUID."; continue; fi
                print_info "Добавление записи в /etc/fstab..."
                if ! run_command "sudo cp /etc/fstab /etc/fstab.backup.$(date +%F_%T)"; then print_warning "Не удалось создать бэкап fstab."; fi
                sudo sed -i "/UUID=$DATA_UUID/d" /etc/fstab
                fstab_line="UUID=$DATA_UUID  $mount_point  ext4  defaults,noatime,x-gvfs-show  0 2"
                echo "# Второй SSD - (Ext4, SSD, /mnt/ssd, mini-pc.sh)" | sudo tee -a /etc/fstab > /dev/null
                if ! echo "$fstab_line" | sudo tee -a /etc/fstab > /dev/null; then print_error "Не удалось записать в fstab."; continue; fi
                print_success "Строка добавлена в fstab: $fstab_line"
                if ! run_command "sudo systemctl daemon-reload"; then continue; fi
                if ! run_command "sudo mount -a" "critical"; then print_warning "Не удалось смонтировать все разделы. Проверьте fstab."; continue; fi
                print_info "Установка прав доступа для $mount_point..."
                if ! run_command "sudo chown $(whoami):$(whoami) $mount_point"; then print_warning "Не удалось изменить владельца $mount_point."; fi
                print_success "Диск $second_disk отформатирован и примонтирован."
                print_info "Должен отображаться в Nautilus."
            fi # Конец confirm
            ;;

        5) # Скрытие логов
            print_header "5. Уточнение настройки скрытия логов при загрузке"
            # Plymouth установлен инсталлятором
            if ! check_essentials "bootctl"; then continue; fi
            print_success "Plymouth и 'quiet splash' настроены установщиком."
            QUIET_PARAMS="loglevel=3 rd.systemd.show_status=auto rd.udev.log_priority=3"
            CMDLINE_FILE="/etc/kernel/cmdline.d/quiet-extra.conf"
            echo "Проверка $CMDLINE_FILE..."
            if [ ! -f "$CMDLINE_FILE" ] || ! sudo grep -q "loglevel=3" "$CMDLINE_FILE"; then
                echo "Добавление доп. параметров тихой загрузки..."
                echo "$QUIET_PARAMS" | sudo tee "$CMDLINE_FILE" > /dev/null
                print_success "Дополнительные параметры добавлены."
                run_command "sudo bootctl update"
            else
                print_success "Дополнительные параметры уже установлены."
            fi
            JOURNALD_CONF="/etc/systemd/journald.conf.d/quiet.conf"
            echo "Проверка $JOURNALD_CONF..."
            if [ ! -f "$JOURNALD_CONF" ]; then
                if confirm "Отключить вывод журнала systemd на TTY?"; then
                    if run_command "sudo mkdir -p /etc/systemd/journald.conf.d/"; then
                        cat << EOF | sudo tee "$JOURNALD_CONF" > /dev/null
[Journal]
TTYPath=/dev/null
EOF
                        print_success "Вывод журнала на TTY отключен."
                    fi
                fi
            else
                print_success "Настройка журнала TTY уже существует."
            fi
            print_success "Настройка тихой загрузки завершена."
            ;;

        6) # Настройка Paru
            print_header "6. Настройка пользовательского Paru"
            if ! check_command "paru"; then print_error "Paru не найден. Установите его (опция 15 в installer.sh)."; continue; fi
            print_success "Paru установлен системно (/usr/bin/paru)."
            PARU_USER_CONF="$HOME/.config/paru/paru.conf"
            echo "Проверка $PARU_USER_CONF..."
            if [ ! -f "$PARU_USER_CONF" ]; then
                echo "Создание $PARU_USER_CONF..."
                if run_command "mkdir -p ~/.config/paru"; then
                    cat << EOF > "$PARU_USER_CONF"
# Пользовательский конфиг Paru (~/.config/paru/paru.conf)
[options]
BottomUp
Devel
CleanAfter
NewsOnUpgrade
CombinedUpgrade
# Опции ниже можно раскомментировать по желанию
# UpgradeMenu       # Меню выбора при обновлении
# RemoveMake        # Удалять зависимости сборки
# KeepRepoCache     # Не удалять кэш pacman
# SudoLoop          # Обновлять sudo timestamp
# BatchInstall      # Установка без подтверждения (рискованно)
# Redownload        # Всегда скачивать исходники
# CloneDir = ~/.cache/paru/clone # Папка для сборки
EOF
                    print_success "Создан пользовательский конфиг: $PARU_USER_CONF"
                    print_warning "Рекомендуется просмотреть и отредактировать его."
                fi
            else
                print_success "Пользовательский конфиг Paru уже существует."
            fi
            ;;

        7) # Настройка Flathub
            print_header "7. Настройка Flathub и GNOME Software"
            if ! check_command "flatpak"; then print_error "Команда flatpak не найдена."; continue; fi
            if ! check_package "gnome-software"; then print_warning "Пакет gnome-software не найден."; fi # Не критично для Flathub
            print_success "Flatpak установлен."

            if ! flatpak remote-list | grep -q flathub; then
                print_info "Добавление репозитория Flathub..."
                if ! run_command "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo" "critical"; then continue; fi
            else
                print_success "Репозиторий Flathub уже добавлен."
            fi
            # GNOME Platform (опционально, для ускорения запуска)
            echo "Проверка GNOME Platform Runtime..."
            GNOME_PLATFORM_ID="org.gnome.Platform"
            if ! flatpak list --runtime | grep -q "$GNOME_PLATFORM_ID"; then
                echo "Определение последней версии GNOME Platform..."
                latest_gnome_version=$(flatpak remote-info --log flathub $GNOME_PLATFORM_ID 2>/dev/null | grep -oP "Version: \K[0-9\.]+" | sort -V | tail -n 1)
                if [ -z "$latest_gnome_version" ]; then latest_gnome_version="46"; print_warning "Не удалось определить версию, используем $latest_gnome_version"; else print_success "Последняя версия: $latest_gnome_version"; fi
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
            if ! check_essentials; then continue; fi # Проверка systemctl, tee, sysctl
            print_warning "Установщик включил 'tuned'. TLP/power-profiles-daemon могут конфликтовать."
            if systemctl is-active --quiet tuned; then
                if confirm "Отключить службу 'tuned', чтобы использовать TLP?"; then
                    if ! run_command "sudo systemctl disable --now tuned"; then print_warning "Не удалось отключить tuned."; fi
                else
                    print_warning "Пропускаем настройку TLP, т.к. 'tuned' активен."
                    continue
                fi
            fi
            # Установка Thermald и TLP
            if ! check_and_install_packages "Питание (TLP)" "thermald" "tlp" "tlp-rdw"; then continue; fi
            # Thermald
            if ! systemctl is-enabled --quiet thermald; then print_info "Включение thermald..."; run_command "sudo systemctl enable --now thermald"; else print_success "Thermald включен."; fi
            # TLP Config
            TLP_CONF="/etc/tlp.conf.d/01-mini-pc.conf"; echo "Проверка $TLP_CONF...";
            if [ ! -f "$TLP_CONF" ]; then echo "Создание $TLP_CONF..."; cat << EOF | sudo tee "$TLP_CONF" > /dev/null
# TLP mini-pc Performance (mini-pc.sh)
TLP_ENABLE=1
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=performance
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=performance
PCIE_ASPM_ON_AC=performance
PCIE_ASPM_ON_BAT=performance
USB_AUTOSUSPEND=0
SOUND_POWER_SAVE_ON_AC=0
SOUND_POWER_SAVE_ON_BAT=0
EOF
; print_success "$TLP_CONF создан."; else print_success "$TLP_CONF уже есть."; fi
            # Enable TLP Services
            if ! systemctl is-enabled --quiet tlp; then print_info "Включение служб TLP..."; run_command "sudo systemctl enable --now tlp"; run_command "sudo systemctl enable NetworkManager-dispatcher.service"; run_command "sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket"; else print_success "Служба TLP включена."; fi
            # Swappiness
            SWAPPINESS_CONF="/etc/sysctl.d/99-swappiness-zram.conf"; echo "Проверка swappiness...";
            if [ ! -f "$SWAPPINESS_CONF" ]; then echo "Настройка vm.swappiness..."; echo "vm.swappiness=100" | sudo tee "$SWAPPINESS_CONF" > /dev/null; run_command "sudo sysctl --system"; print_success "Swappiness настроен."; else print_success "Swappiness уже настроен: $(sudo sysctl -n vm.swappiness)"; fi
            print_success "Настройка управления питанием завершена."
            ;;

        9) # Firewall / Core Dumps
            print_header "9. Настройка Firewall и Core Dumps"
            if ! check_essentials "ufw"; then continue; fi # Проверяем ufw команду
            # UFW
            if check_and_install_packages "Безопасность (UFW)" "ufw"; then # Проверяем пакет
                if ! systemctl is-enabled --quiet ufw; then
                    print_info "Настройка и включение UFW..."; run_command "sudo ufw default deny incoming"; run_command "sudo ufw default allow outgoing"; run_command "sudo ufw allow ssh"; run_command "sudo ufw enable"; print_success "UFW настроен и включен."
                else
                    print_success "UFW уже включен. Текущие правила:"; sudo ufw status verbose
                fi
            else
                 print_warning "Пропуск настройки UFW (пакет не установлен)."
            fi
            # Core Dumps Disable
            LIMITS_CONF="/etc/security/limits.d/nocore.conf"
            SYSCTL_CORE_CONF="/etc/sysctl.d/51-coredump-disable.conf"
            echo "Проверка отключения Core Dumps..."
            if [ ! -f "$LIMITS_CONF" ] || [ ! -f "$SYSCTL_CORE_CONF" ]; then
                print_info "Отключение Core Dumps..."; echo "* hard core 0" | sudo tee "$LIMITS_CONF" > /dev/null; echo "* soft core 0" | sudo tee -a "$LIMITS_CONF" > /dev/null; echo "kernel.core_pattern=/dev/null" | sudo tee "$SYSCTL_CORE_CONF" > /dev/null
                if run_command "sudo sysctl -p $SYSCTL_CORE_CONF"; then print_success "Core Dumps отключены."; else print_warning "Не удалось применить sysctl для Core Dumps."; fi
            else
                print_success "Core Dumps уже отключены."
            fi
            print_success "Настройка безопасности завершена."
            ;;

        10) # Доп. утилиты / Seahorse
            print_header "10. Установка доп. утилит и Seahorse"
            cli_utils=("neofetch" "bat" "exa" "ripgrep" "fd" "htop")
            check_and_install_packages "Доп. утилиты CLI" "${cli_utils[@]}" # Функция вернет 1 при отказе/ошибке
            check_and_install_packages "Seahorse (GUI для ключей)" "seahorse"
            print_success "Проверка/установка дополнительных программ завершена."
            ;;

        11) # Timeshift
            print_header "11. Установка Timeshift (системный диск)"
            if ! check_command "timeshift-launcher"; then # Проверяем команду запуска GUI
                 if ! check_and_install_packages "Резервное копирование" "timeshift"; then continue; fi
            fi
            # Проверяем настройку fstab
            if ! grep -q "/run/timeshift/backup" /etc/fstab; then
                print_warning "Timeshift не настроен для BTRFS снапшотов."
                echo "Рекомендуется запустить 'sudo timeshift-gtk' и выбрать:"
                echo "  - Тип снапшотов: BTRFS"
                echo "  - Местоположение BTRFS: выберите ваш системный раздел ($ROOT_DEVICE)"
                if confirm "Запустить timeshift-launcher сейчас?"; then
                    if ! timeshift-launcher; then print_error "Не удалось запустить timeshift-launcher."; fi
                fi
            else
                print_success "Timeshift (BTRFS) уже настроен в /etc/fstab."
                print_info "Запустите 'sudo timeshift-gtk' для управления снапшотами."
            fi
            ;;

        12) # PipeWire Low Latency
            print_header "12. Тонкая настройка PipeWire (Low Latency)"
            if ! check_essentials; then continue; fi # mkdir, cat
            print_success "PipeWire и Wireplumber установлены и настроены установщиком."
            PW_CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
            LOWLATENCY_CONF="$PW_CONF_DIR/10-lowlatency.conf"
            echo "Проверка $LOWLATENCY_CONF..."
            if [ ! -f "$LOWLATENCY_CONF" ]; then
                print_info "Создание конфигурации PipeWire Low Latency..."
                if run_command "mkdir -p $PW_CONF_DIR"; then
                    cat << EOF > "$LOWLATENCY_CONF"
context.properties = {
    default.clock.quantum       = 256
    default.clock.min-quantum   = 32
    default.clock.max-quantum   = 1024
}
EOF
                    print_success "Конфигурация создана: $LOWLATENCY_CONF"
                    print_warning "Перезапустите PipeWire/Wireplumber или сеанс для применения."
                    echo "  systemctl --user restart pipewire pipewire-pulse wireplumber"
                fi
            else
                print_success "Конфигурация PipeWire Low Latency уже существует."
            fi
            ;;

        13) # Доп. оптимизация производительности
             print_header "13. Дополнительная оптимизация производительности"
             if ! check_essentials; then continue; fi # sysctl, systemctl, tee, mkdir, grep
             # Sysctl
             SYSCTL_PERF_CONF="/etc/sysctl.d/99-performance-tweaks.conf"; echo "Проверка sysctl...";
             if [ ! -f "$SYSCTL_PERF_CONF" ]; then print_info "Применение sysctl..."; cat << EOF | sudo tee "$SYSCTL_PERF_CONF" > /dev/null
# Perf Tweaks (mini-pc.sh)
vm.dirty_ratio=10
vm.dirty_background_ratio=5
fs.file-max=100000
fs.inotify.max_user_watches=524288
EOF
; if run_command "sudo sysctl --system"; then print_success "Sysctl применены."; fi; else print_success "$SYSCTL_PERF_CONF уже есть."; fi
             # Systemd timeouts
             SYSTEMD_TIMEOUT_CONF="/etc/systemd/system.conf.d/timeout.conf"; echo "Проверка таймаутов systemd...";
             if [ ! -f "$SYSTEMD_TIMEOUT_CONF" ]; then print_info "Уменьшение таймаутов..."; if run_command "sudo mkdir -p /etc/systemd/system.conf.d/"; then cat << EOF | sudo tee "$SYSTEMD_TIMEOUT_CONF" > /dev/null
[Manager]
DefaultTimeoutStartSec=10s
DefaultTimeoutStopSec=10s
EOF
; run_command "sudo systemctl daemon-reload"; print_success "Таймауты настроены."; fi; else print_success "Настройка таймаутов есть."; fi
             # Disable unused services
            echo "Проверка служб для возможного отключения..."; unused_services=("bluetooth.service" "avahi-daemon.service" "cups.socket")
            for service in "${unused_services[@]}"; do is_active=$(systemctl is-active --quiet "$service"; echo $?); is_enabled=$(systemctl is-enabled --quiet "$service"; echo $?); if [ "$is_active" -eq 0 ] || [ "$is_enabled" -eq 0 ]; then if confirm "Служба '$service' активна/включена. Отключить?"; then run_command "sudo systemctl disable --now $service"; fi; else print_info "'$service' неактивна/не включена."; fi; done
            print_success "Дополнительная оптимизация производительности завершена."
            ;;

        14) # Настройка Fn-клавиш
            print_header "14. Настройка Fn-клавиш (Apple Keyboard)"
            # Проверяем mkinitcpio и bootctl
            if ! check_essentials "mkinitcpio" "bootctl"; then continue; fi
            print_warning "Эта настройка актуальна в основном для клавиатур Apple."
            # Modprobe
            HID_APPLE_CONF="/etc/modprobe.d/hid_apple.conf"; echo "Проверка $HID_APPLE_CONF...";
            if ! sudo grep -q "options hid_apple fnmode=2" "$HID_APPLE_CONF" 2>/dev/null; then echo "Настройка hid_apple..."; echo "options hid_apple fnmode=2" | sudo tee "$HID_APPLE_CONF" > /dev/null; print_success "$HID_APPLE_CONF создан."; print_warning "Требуется 'sudo mkinitcpio -P' и перезагрузка."; if confirm "Перестроить initramfs сейчас?"; then run_command "sudo mkinitcpio -P"; fi; else print_success "Настройка fnmode=2 уже есть."; fi
            # Kernel cmdline
            CMDLINE_KBD_CONF="/etc/kernel/cmdline.d/keyboard-fnmode.conf"; echo "Проверка параметра ядра...";
            if [ ! -f "$CMDLINE_KBD_CONF" ] || ! sudo grep -q "hid_apple.fnmode=2" "$CMDLINE_KBD_CONF"; then echo "Добавление параметра ядра..."; echo "hid_apple.fnmode=2" | sudo tee "$CMDLINE_KBD_CONF" > /dev/null; if run_command "sudo bootctl update"; then print_success "Параметр ядра добавлен."; fi; else print_success "Параметр ядра уже установлен."; fi
            print_success "Настройка функциональных клавиш завершена (если используется hid_apple)."
            print_warning "Может потребоваться перезагрузка."
            ;;

        15) # Установка Steam
            print_header "15. Установка Steam (Intel графика)"
            if ! check_essentials; then continue; fi # pacman
            print_info "Убедитесь, что [multilib] включен в /etc/pacman.conf."

            # Зависимости
            steam_deps=(
                "vulkan-intel" "lib32-vulkan-intel" "mesa" "lib32-mesa"
                "xorg-mkfontscale" "xorg-fonts-cyrillic" "xorg-fonts-misc"
            )
            if ! check_and_install_packages "Зависимости Steam для Intel" "${steam_deps[@]}"; then
                 print_warning "Установка зависимостей Steam отменена/не удалась. Steam не будет установлен."
                 continue # Возврат в меню
            fi
            print_success "Зависимости Steam установлены/проверены."

            # Установка Steam интерактивно
            if ! check_package "steam"; then
                print_warning "Сейчас будет запущена ИНТЕРАКТИВНАЯ установка Steam."
                print_warning "Когда появится список 'провайдеров', выберите опцию с 'intel'."
                read -p "Нажмите Enter для запуска 'sudo pacman -S steam'..."
                # Запускаем без run_command, т.к. нужна интерактивность
                if sudo pacman -S steam; then
                    print_success "Steam успешно установлен."
                else
                    print_error "Ошибка во время интерактивной установки Steam."
                    continue # Возврат в меню
                fi
            else
                print_success "Пакет Steam уже установлен."
            fi
            print_info "Для первого запуска Steam может потребоваться перезагрузка сеанса."
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
