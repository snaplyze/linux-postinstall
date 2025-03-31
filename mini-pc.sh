#!/bin/bash

# mini-pc-arch-setup.sh - Оптимизированный скрипт настройки Arch Linux для мини-ПК
# Версия: 1.7 (Исправлена синтаксическая ошибка в шаге 8, добавлены проверки)
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
    # Добавляем пустую строку перед заголовком для лучшего разделения
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

# Запрос подтверждения у пользователя (y/N)
confirm() {
    local prompt="$1 (y/N): "
    local response
    # Читаем ответ, -r для raw input, -p для вывода prompt
    read -r -p "$prompt" response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;; # Возвращаем 0 (успех) при 'y' или 'yes'
        *) return 1 ;;                # Возвращаем 1 (неудача) в остальных случаях
    esac
}

# Запуск команды с базовой проверкой ошибок
run_command() {
    local cmd="$1"
    local critical="$2" # Второй аргумент - флаг критичности

    echo -e "${YELLOW}Выполняется:${NC} $cmd"
    # Используем subshell для eval, чтобы ошибки не прерывали скрипт неожиданно (если set -e включен)
    (eval "$cmd")
    local exit_code=$? # Получаем код возврата выполненной команды

    if [ $exit_code -eq 0 ]; then
        print_success "Успешно"
        return 0 # Успешное выполнение
    else
        print_error "Ошибка при выполнении команды (код: $exit_code)"
        # Если команда помечена как критическая, выходим из скрипта
        if [ "$critical" = "critical" ]; then
            print_error "Критическая ошибка! Выход из скрипта."
            exit 1
        fi
        return $exit_code # Возвращаем код ошибки для возможной обработки
    fi
}

# Проверка, установлен ли пакет через pacman
check_package() {
    # -Q для запроса установленного пакета, &> /dev/null для подавления вывода
    if pacman -Q "$1" &> /dev/null; then
        return 0 # Пакет установлен
    else
        return 1 # Пакет не установлен
    fi
}

# Проверка, доступна ли команда в $PATH
check_command() {
    # command -v проверяет наличие команды/функции/алиаса
    if command -v "$1" &> /dev/null; then
        return 0 # Команда найдена
    else
        return 1 # Команда не найдена
    fi
}

# Функция проверки базовых утилит, необходимых для многих шагов
# Принимает список дополнительных команд для проверки
# Если чего-то нет, выводит ошибку и возвращает 1, иначе 0
check_essentials() {
    local missing_cmds=()
    # Основные команды, которые должны быть всегда после базовой установки
    local essentials=(
        "grep" "tee" "mkdir" "cat" "systemctl" "sysctl" "awk" "sed"
        "mount" "umount" "lsblk" "chown" "blkid" "uname" "lscpu" "free"
        "findmnt" "date" "read" "sudo" "rm" "cp"
    )
    for cmd in "${essentials[@]}"; do
        if ! check_command "$cmd"; then
            missing_cmds+=("$cmd")
        fi
    done

    # Проверяем специфичные для шагов команды, переданные как аргументы
    for cmd in "$@"; do
         if ! check_command "$cmd"; then
            # Добавляем только если еще не в списке
            [[ " ${missing_cmds[*]} " =~ " ${cmd} " ]] || missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        print_error "Отсутствуют необходимые команды для этой операции: ${missing_cmds[*]}"
        print_warning "Установите их (обычно пакеты coreutils, systemd, util-linux и т.д.) или проверьте \$PATH."
        return 1 # Неудача - команды отсутствуют
    else
        return 0 # Успех - все команды на месте
    fi
}


# Проверка и установка пакетов (автоматически с --noconfirm)
# Используется для зависимостей, не для самого Steam
# Возвращает 0 при успехе (или если все уже было), 1 при отказе/ошибке
check_and_install_packages() {
    local category=$1
    shift
    local packages=("$@")
    local missing_packages=()

    echo -e "${BLUE}Проверка пакетов для: $category${NC}"
    # Собираем список отсутствующих пакетов, проверяя их наличие в репо
    for pkg in "${packages[@]}"; do
        if ! check_package "$pkg"; then
            if pacman -Si "$pkg" &> /dev/null; then
                missing_packages+=("$pkg")
            else
                print_warning "Пакет '$pkg' не найден в репозиториях. Пропускаем."
            fi
        fi
    done

    # Если есть что устанавливать
    if [ ${#missing_packages[@]} -gt 0 ]; then
        echo -e "${YELLOW}Отсутствуют: ${missing_packages[*]}${NC}"
        if confirm "Установить эти пакеты?"; then
            # Используем run_command для установки с флагом critical
            if ! run_command "sudo pacman -S --needed --noconfirm ${missing_packages[*]}" "critical"; then
                 print_error "Не удалось завершить команду установки пакетов."
                 return 1 # Ошибка выполнения pacman
            fi
            # Дополнительная проверка после попытки установки
            local failed_install=()
            for pkg in "${missing_packages[@]}"; do
                if ! check_package "$pkg"; then
                    failed_install+=("$pkg")
                fi
            done
            if [ ${#failed_install[@]} -gt 0 ]; then
                print_error "Пакеты НЕ установились: ${failed_install[*]}. Операция не может быть продолжена."
                return 1 # Ошибка, пакеты фактически не установились
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
clear # Очистим экран перед началом
print_header "Проверка системных требований"

# Проверка запуска от обычного пользователя
if [ "$EUID" -eq 0 ]; then
    print_error "Этот скрипт должен быть запущен от имени обычного пользователя, не root!"
    exit 1
fi

# Проверка только самых базовых команд для самого скрипта
base_deps=("bash" "pacman" "command" "read" "sudo")
missing_deps=()
for cmd in "${base_deps[@]}"; do
    if ! check_command "$cmd"; then
        missing_deps+=("$cmd")
    fi
done
if [ ${#missing_deps[@]} -gt 0 ]; then
    print_error "Отсутствуют критические для работы скрипта команды: ${missing_deps[*]}"
    exit 1
fi

# Проверка ZRAM (установлен инсталлятором)
if ! check_essentials "systemctl"; then
    print_warning "Не могу проверить статус ZRAM (нет systemctl)."
elif [ -e "/dev/zram0" ] && systemctl is-enabled --quiet systemd-zram-setup@zram0.service; then
    print_success "ZRAM настроен и включен установщиком"
else
    print_warning "ZRAM не обнаружен или не включен. Проверьте логи установщика."
fi

# ==============================================================================
# Информация о Системе
# ==============================================================================
print_header "Информация о системе"

# Проверяем команды перед использованием
if ! check_essentials "uname" "lscpu" "free" "findmnt" "btrfs" "lsblk" "grep" "awk" "cat"; then
    print_error "Не могу собрать полную информацию о системе из-за отсутствия команд."
else
    echo "Ядро Linux:      $(uname -r)"
    distro_name=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    echo "Дистрибутив:    ${distro_name:-Не определен}"
    cpu_model=$(grep "Model name" /proc/cpuinfo | uniq | sed 's/Model name\s*:\s*//')
    echo "Процессор:      ${cpu_model:-Не определен}"
    mem_total=$(free -h | awk '/^Mem:/ {print $2}')
    echo "Память (RAM):   ${mem_total:-Не определено}"
    ROOT_DEVICE=$(findmnt -no SOURCE / | sed 's/\[.*\]//')
    echo "Системный диск: ${ROOT_DEVICE:-Не определен} (ФС: BTRFS)"
    fstab_root_opts=$(grep "[[:space:]]/[[:space:]]" /etc/fstab | awk '{print $4}')
    echo "Опции '/'(fstab): ${fstab_root_opts:-Не найдены}"
    echo "BTRFS подтома на '/':"
    sudo btrfs subvolume list / || echo "   (Не удалось получить список подтомов)"
    echo -e "\nБлочные устройства:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
fi

# Проверка загрузчика (systemd-boot установлен инсталлятором)
if ! check_command "bootctl"; then
     print_warning "Команда bootctl не найдена. Проверка systemd-boot невозможна."
elif [ -d "/boot/loader" ] && [ -f "/boot/loader/loader.conf" ]; then
    print_success "Обнаружена конфигурация systemd-boot"
else
    print_error "Не найдена конфигурация systemd-boot (/boot/loader/loader.conf)."
    # Не критично для работы скрипта, но важно для пользователя
    if ! confirm "Продолжить выполнение скрипта?"; then exit 1; fi
fi

# Определение ядра (linux-zen установлен инсталлятором)
if [ -f "/boot/vmlinuz-linux-zen" ]; then
    KERNEL_NAME="linux-zen"
    print_success "Обнаружено ядро: $KERNEL_NAME"
elif [ -f "/boot/vmlinuz-linux" ]; then
    KERNEL_NAME="linux"
    print_success "Обнаружено ядро: $KERNEL_NAME (не -zen)"
else
    print_warning "Стандартное ядро (linux) или linux-zen не найдено в /boot."
    # Попробуем угадать, но это может быть неправильно
    KERNEL_NAME="linux"
    if ! confirm "Попробовать продолжить, предполагая имя ядра '$KERNEL_NAME'?"; then exit 1; fi
fi

# ==============================================================================
# Основное Меню
# ==============================================================================
while true; do
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

    read -p "Введите номер операции [0-15]: " choice

    case $choice in
        0) # Выход
            echo "Выход из скрипта."
            exit 0
            ;;

        1) # Обновление системы
            print_header "1. Обновление системы"
            if ! check_essentials; then continue; fi
            run_command "sudo pacman -Syu --noconfirm" "critical"
            # Проверка результата не нужна, т.к. critical
            print_success "Система обновлена."
            ;;

        2) # Доп. настройка Intel графики
            print_header "2. Дополнительная настройка Intel графики (Wayland)"
            if ! check_essentials "mkinitcpio"; then continue; fi
            if ! check_and_install_packages "Intel графика (доп.)" "intel-media-driver" "qt6-wayland" "qt5-wayland"; then continue; fi

            I915_CONF="/etc/modprobe.d/i915.conf"
            I915_OPTS="options i915 enable_fbc=1 enable_guc=2 enable_dc=4"
            echo "Проверка $I915_CONF..."
            if [ ! -f "$I915_CONF" ] || ! sudo grep -qF "$I915_OPTS" "$I915_CONF" 2>/dev/null; then
                echo "Обновление $I915_CONF..."
                echo "# Intel Graphics Opts (mini-pc.sh)" | sudo tee "$I915_CONF" > /dev/null
                echo "$I915_OPTS" | sudo tee -a "$I915_CONF" > /dev/null
                print_success "Настройка $I915_CONF применена."
                print_warning "Требуется перестроение initramfs (sudo mkinitcpio -P) и перезагрузка."
                if confirm "Перестроить initramfs сейчас?"; then
                    run_command "sudo mkinitcpio -P"
                fi
            else
                print_success "$I915_CONF уже настроен."
            fi

            ENV_FILE="/etc/environment"
            echo "Проверка $ENV_FILE..."
            if [ ! -f "$ENV_FILE" ] || ! sudo grep -q "LIBVA_DRIVER_NAME=iHD" "$ENV_FILE" 2>/dev/null || ! sudo grep -q "MOZ_ENABLE_WAYLAND=1" "$ENV_FILE" 2>/dev/null ; then
                echo "Обновление $ENV_FILE..."
                cat << EOF | sudo tee "$ENV_FILE" > /dev/null
# Wayland Env Vars (mini-pc.sh)
LIBVA_DRIVER_NAME=iHD
MOZ_ENABLE_WAYLAND=1
QT_QPA_PLATFORM=wayland
EOF
                print_success "$ENV_FILE настроен для Wayland."
            else
                print_success "$ENV_FILE уже содержит настройки Wayland."
            fi
            print_success "Дополнительная настройка Intel графики завершена."
            ;;

        3) # Доп. оптимизация BTRFS
            print_header "3. Дополнительная оптимизация BTRFS (системный диск)"
            if ! check_essentials "btrfs" "sysctl"; then continue; fi
            print_success "TRIM и базовые опции монтирования системного диска настроены установщиком."
            echo "Текущие опции монтирования '/': $(grep "[[:space:]]/[[:space:]]" /etc/fstab | awk '{print $4}')"

            SYSCTL_CONF="/etc/sysctl.d/60-btrfs-performance.conf"
            echo "Проверка sysctl для BTRFS ($SYSCTL_CONF)..."
            if [ ! -f "$SYSCTL_CONF" ]; then
                echo "Создание $SYSCTL_CONF..."
                cat << EOF | sudo tee "$SYSCTL_CONF" > /dev/null
# BTRFS Metadata Cache Limits (mini-pc.sh)
vm.dirty_bytes = 4294967296
vm.dirty_background_bytes = 1073741824
EOF
                if run_command "sudo sysctl --system"; then
                    print_success "Настройки sysctl для BTRFS применены."
                else
                    print_warning "Не удалось применить sysctl."
                fi
            else
                print_success "Настройки sysctl для BTRFS уже существуют ($SYSCTL_CONF)."
            fi
            print_success "Дополнительная оптимизация BTRFS завершена."
            ;;

        4) # Форматирование второго SSD в Ext4
            print_header "4. Форматирование и монтирование второго SSD в Ext4 (/mnt/ssd)"
            if ! check_essentials "parted" "mkfs.ext4" "wipefs" "sgdisk" "blkid" "lsblk" "mount" "umount" "chown"; then continue; fi
            if ! check_and_install_packages "GVFS (для отображения диска)" "gvfs"; then continue; fi

            print_warning "ВНИМАНИЕ! Все данные на выбранном диске будут БЕЗВОЗВРАТНО УНИЧТОЖЕНЫ!"
            echo "Текущие диски и разделы:"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
            ROOT_DISK_BASE=$(basename "$ROOT_DEVICE" | sed 's/[0-9]*$//; s/p[0-9]*$//')
            mapfile -t disk_options < <(lsblk -dpno NAME,SIZE,TYPE | grep 'disk' | grep -v "^/dev/${ROOT_DISK_BASE}" | awk '{print $1" ("$2")"}')

            if [ ${#disk_options[@]} -eq 0 ]; then print_warning "Дополнительные диски не найдены."; continue; fi

            echo "Доступные диски для форматирования:"
            disk_choice="" # Сбрасываем выбор
            select opt in "${disk_options[@]}" "Отмена"; do
                # $REPLY содержит номер выбора
                if [[ "$REPLY" == $((${#disk_options[@]} + 1)) ]]; then # Номер опции "Отмена"
                    disk_choice="Отмена"
                    break
                elif [[ "$REPLY" -ge 1 && "$REPLY" -le ${#disk_options[@]} ]]; then # Корректный номер диска
                    disk_choice="${disk_options[$REPLY-1]}"
                    second_disk=$(echo "$disk_choice" | awk '{print $1}')
                    print_info "Выбран диск: $second_disk"
                    break
                else
                    print_warning "Неверный выбор. Введите номер из списка."
                fi
            done
            if [ "$disk_choice" == "Отмена" ]; then print_warning "Операция отменена."; continue; fi

            if confirm "Точно форматировать $second_disk в Ext4 (метка 'SSD', точка /mnt/ssd)?"; then
                if mount | grep -q "^$second_disk"; then print_warning "Размонтирование..."; if ! run_command "sudo umount ${second_disk}*"; then continue; fi; fi
                print_info "Очистка и разметка $second_disk..."
                if ! run_command "sudo wipefs -af $second_disk" "critical"; then continue; fi
                if ! run_command "sudo sgdisk --zap-all $second_disk" "critical"; then continue; fi
                if ! run_command "sudo parted -s $second_disk mklabel gpt" "critical"; then continue; fi
                if ! run_command "sudo parted -s -a optimal $second_disk mkpart primary ext4 0% 100%" "critical"; then continue; fi
                sleep 2
                new_partition_name=$(lsblk -lno NAME $second_disk | grep -E "${second_disk##*/}[p]?1$")
                if [ -z "$new_partition_name" ]; then print_error "Не удалось определить раздел."; continue; fi
                new_partition="/dev/$new_partition_name"
                if [ ! -b "$new_partition" ]; then print_error "'$new_partition' не блок."; continue; fi
                print_success "Создан раздел: $new_partition"
                print_info "Форматирование Ext4 (метка 'SSD')..."
                if ! run_command "sudo mkfs.ext4 -L SSD $new_partition" "critical"; then continue; fi
                mount_point="/mnt/ssd"
                if ! run_command "sudo mkdir -p $mount_point"; then continue; fi
                DATA_UUID=$(sudo blkid -s UUID -o value $new_partition)
                if [ -z "$DATA_UUID" ]; then print_error "Не удалось получить UUID."; continue; fi
                print_info "Добавление записи в /etc/fstab...";
                if ! run_command "sudo cp /etc/fstab /etc/fstab.backup.$(date +%F_%T)"; then print_warning "Бэкап fstab не создан."; fi
                sudo sed -i "/UUID=$DATA_UUID/d" /etc/fstab
                fstab_line="UUID=$DATA_UUID  $mount_point  ext4  defaults,noatime,x-gvfs-show  0 2"
                echo "# Второй SSD (Ext4, /mnt/ssd, mini-pc.sh)" | sudo tee -a /etc/fstab > /dev/null
                if ! echo "$fstab_line" | sudo tee -a /etc/fstab > /dev/null; then print_error "Запись в fstab не удалась."; continue; fi
                print_success "Строка добавлена в fstab: $fstab_line"
                if ! run_command "sudo systemctl daemon-reload"; then continue; fi
                if ! run_command "sudo mount -a" "critical"; then print_warning "Не удалось смонтировать (проверьте 'sudo findmnt --verify')."; continue; fi
                print_info "Установка прав для $mount_point..."
                if ! run_command "sudo chown $(whoami):$(whoami) $mount_point"; then print_warning "Не удалось сменить владельца $mount_point."; fi
                print_success "Диск $second_disk отформатирован и примонтирован."
            fi # Конец confirm
            ;;

        5) # Скрытие логов
            print_header "5. Уточнение настройки скрытия логов при загрузке"
            if ! check_essentials "bootctl"; then continue; fi
            print_success "Plymouth и 'quiet splash' настроены установщиком."
            QUIET_PARAMS="loglevel=3 rd.systemd.show_status=auto rd.udev.log_priority=3"
            CMDLINE_FILE="/etc/kernel/cmdline.d/quiet-extra.conf"
            echo "Проверка $CMDLINE_FILE..."
            if [ ! -f "$CMDLINE_FILE" ] || ! sudo grep -q "loglevel=3" "$CMDLINE_FILE" 2>/dev/null; then
                echo "Добавление доп. параметров..."
                if echo "$QUIET_PARAMS" | sudo tee "$CMDLINE_FILE" > /dev/null; then print_success "Параметры добавлены."; run_command "sudo bootctl update"; else print_error "Не удалось записать в $CMDLINE_FILE."; fi
            else print_success "Доп. параметры уже есть."; fi
            JOURNALD_CONF="/etc/systemd/journald.conf.d/quiet.conf"
            echo "Проверка $JOURNALD_CONF..."
            if [ ! -f "$JOURNALD_CONF" ]; then
                if confirm "Отключить журнал на TTY?"; then
                    if run_command "sudo mkdir -p /etc/systemd/journald.conf.d/"; then
                        cat << EOF | sudo tee "$JOURNALD_CONF" > /dev/null
[Journal]
TTYPath=/dev/null
EOF
                        print_success "Журнал на TTY отключен."
                    fi
                fi
            else print_success "Настройка журнала TTY уже есть."; fi
            print_success "Настройка тихой загрузки завершена."
            ;;

        6) # Настройка Paru
            print_header "6. Настройка пользовательского Paru"
            if ! check_command "paru"; then print_error "Команда paru не найдена."; continue; fi
            print_success "Paru установлен системно."
            PARU_USER_CONF="$HOME/.config/paru/paru.conf"
            echo "Проверка $PARU_USER_CONF..."
            if [ ! -f "$PARU_USER_CONF" ]; then
                echo "Создание $PARU_USER_CONF..."
                if run_command "mkdir -p '$HOME/.config/paru'"; then # Кавычки для ~
                    cat << EOF > "$PARU_USER_CONF"
# ~/.config/paru/paru.conf
[options]
BottomUp
Devel
CleanAfter
NewsOnUpgrade
CombinedUpgrade
# UpgradeMenu
# RemoveMake
# KeepRepoCache
# SudoLoop
# BatchInstall
# Redownload
# CloneDir = ~/.cache/paru/clone
EOF
                    if [ -f "$PARU_USER_CONF" ]; then print_success "$PARU_USER_CONF создан."; print_warning "Отредактируйте его."; else print_error "Не удалось создать $PARU_USER_CONF."; fi
                fi
            else print_success "$PARU_USER_CONF уже существует."; fi
            ;;

        7) # Настройка Flathub
            print_header "7. Настройка Flathub и GNOME Software"
            if ! check_command "flatpak"; then print_error "Команда flatpak не найдена."; continue; fi
            if ! check_package "gnome-software"; then print_warning "Пакет gnome-software не найден."; fi
            print_success "Flatpak установлен."
            if ! flatpak remote-list | grep -q flathub; then
                print_info "Добавление Flathub..."; if ! run_command "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo" "critical"; then continue; fi
            else print_success "Flathub уже добавлен."; fi
            echo "Проверка GNOME Platform Runtime..."; GNOME_PLATFORM_ID="org.gnome.Platform"
            if ! flatpak list --runtime | grep -q "$GNOME_PLATFORM_ID"; then
                echo "Определение версии..."; latest_gnome_version=$(flatpak remote-info --log flathub $GNOME_PLATFORM_ID 2>/dev/null | grep -oP "Version: \K[0-9\.]+" | sort -V | tail -n 1)
                if [ -z "$latest_gnome_version" ]; then latest_gnome_version="46"; print_warning "Используем v$latest_gnome_version"; else print_success "Версия: $latest_gnome_version"; fi
                if confirm "Установить GNOME Platform $latest_gnome_version?"; then run_command "flatpak install -y flathub ${GNOME_PLATFORM_ID}//$latest_gnome_version"; fi
            else print_success "GNOME Platform Runtime уже установлен."; fi
            print_success "Настройка Flathub завершена."
            ;;

        8) # Настройка TLP
            print_header "8. Настройка управления питанием (TLP)"
            if ! check_essentials "systemctl" "tee" "sysctl"; then continue; fi
            print_warning "Установщик включил 'tuned'. TLP может конфликтовать."
            if systemctl is-active --quiet tuned; then
                if confirm "Отключить службу 'tuned', чтобы использовать TLP?"; then
                    if ! run_command "sudo systemctl disable --now tuned"; then print_warning "Не удалось отключить tuned."; fi
                else print_warning "Пропуск TLP."; continue; fi
            fi
            if ! check_and_install_packages "Питание (TLP)" "thermald" "tlp" "tlp-rdw"; then continue; fi
            if ! systemctl is-enabled --quiet thermald; then print_info "Включение thermald..."; run_command "sudo systemctl enable --now thermald"; else print_success "Thermald включен."; fi
            TLP_CONF="/etc/tlp.conf.d/01-mini-pc.conf"; echo "Проверка $TLP_CONF...";
            if [ ! -f "$TLP_CONF" ]; then
                echo "Создание $TLP_CONF..."
                # ИСПРАВЛЕНО: Перенос print_success после EOF
                cat << EOF | sudo tee "$TLP_CONF" > /dev/null
# TLP mini-pc Performance (mini-pc.sh)
TLP_ENABLE=1
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=performance
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=performance
PCIE_ASPM_ON_AC=performance
PCIE_ASPM_ON_BAT=performance
USB_AUTOSUSPEND=0
WOL_DISABLE=Y
SOUND_POWER_SAVE_ON_AC=0
SOUND_POWER_SAVE_ON_BAT=0
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=on
EOF
                if [ $? -eq 0 ]; then print_success "$TLP_CONF создан."; else print_error "Не удалось создать $TLP_CONF."; fi
            else print_success "$TLP_CONF уже существует."; fi
            if ! systemctl is-enabled --quiet tlp; then print_info "Включение TLP..."; run_command "sudo systemctl enable --now tlp"; run_command "sudo systemctl enable NetworkManager-dispatcher.service"; run_command "sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket"; else print_success "TLP включен."; fi
            SWAPPINESS_CONF="/etc/sysctl.d/99-swappiness-zram.conf"; echo "Проверка swappiness...";
            if [ ! -f "$SWAPPINESS_CONF" ]; then echo "Настройка swappiness..."; echo "vm.swappiness=100 # High value for ZRAM" | sudo tee "$SWAPPINESS_CONF" > /dev/null; run_command "sudo sysctl --system"; print_success "Swappiness настроен."; else print_success "Swappiness уже настроен: $(sudo sysctl -n vm.swappiness)"; fi
            print_success "Настройка управления питанием завершена."
            ;;

        9) # Firewall / Core Dumps
            print_header "9. Настройка Firewall и Core Dumps"
            if ! check_essentials "ufw" "sysctl"; then continue; fi
            if check_and_install_packages "Безопасность (UFW)" "ufw"; then
                if ! systemctl is-enabled --quiet ufw; then
                    print_info "Настройка и включение UFW...";
                    run_command "sudo ufw default deny incoming"; run_command "sudo ufw default allow outgoing"; run_command "sudo ufw allow ssh"
                    if run_command "echo y | sudo ufw enable"; then print_success "UFW включен."; else print_error "Не удалось включить UFW."; fi
                else print_success "UFW уже включен."; sudo ufw status verbose; fi
            else print_warning "Пропуск UFW."; fi
            LIMITS_CONF="/etc/security/limits.d/nocore.conf"; SYSCTL_CORE_CONF="/etc/sysctl.d/51-coredump-disable.conf"; echo "Проверка Core Dumps...";
            if [ ! -f "$LIMITS_CONF" ] || [ ! -f "$SYSCTL_CORE_CONF" ]; then
                print_info "Отключение Core Dumps..."; echo "* hard core 0" | sudo tee "$LIMITS_CONF" > /dev/null; echo "* soft core 0" | sudo tee -a "$LIMITS_CONF" > /dev/null; echo "kernel.core_pattern=/dev/null" | sudo tee "$SYSCTL_CORE_CONF" > /dev/null
                if run_command "sudo sysctl -p $SYSCTL_CORE_CONF"; then print_success "Core Dumps отключены."; else print_warning "Не удалось применить sysctl для Core Dumps."; fi
            else print_success "Core Dumps уже отключены."; fi
            print_success "Настройка безопасности завершена."
            ;;

        10) # Доп. утилиты / Seahorse
            print_header "10. Установка доп. утилит и Seahorse"
            cli_utils=("neofetch" "bat" "exa" "ripgrep" "fd" "htop")
            check_and_install_packages "Доп. утилиты CLI" "${cli_utils[@]}"
            check_and_install_packages "Seahorse (GUI для ключей)" "seahorse"
            print_success "Проверка/установка дополнительных программ завершена."
            ;;

        11) # Timeshift
            print_header "11. Установка Timeshift (системный диск)"
            if ! check_command "timeshift-launcher"; then if ! check_and_install_packages "Резервное копирование" "timeshift"; then continue; fi; fi
            if ! grep -q "/run/timeshift/backup" /etc/fstab; then
                print_warning "Timeshift не настроен для BTRFS в fstab."; echo "Рекомендуется запустить 'sudo timeshift-gtk' (Тип: BTRFS, Раздел: $ROOT_DEVICE)."
                if confirm "Запустить timeshift-launcher сейчас?"; then if ! timeshift-launcher; then print_error "Не удалось запустить timeshift-launcher."; fi; fi
            else print_success "Timeshift (BTRFS) уже настроен."; print_info "Запустите 'sudo timeshift-gtk' для управления."; fi
            ;;

        12) # PipeWire Low Latency
            print_header "12. Тонкая настройка PipeWire (Low Latency)"
            if ! check_essentials "mkdir" "cat"; then continue; fi
            if ! check_command "pipewire"; then print_error "Pipewire не найден."; continue; fi
            print_success "PipeWire/Wireplumber установлены."
            PW_CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"; LOWLATENCY_CONF="$PW_CONF_DIR/10-lowlatency.conf"; echo "Проверка $LOWLATENCY_CONF...";
            if [ ! -f "$LOWLATENCY_CONF" ]; then
                print_info "Создание Low Latency конфига..."; if run_command "mkdir -p '$PW_CONF_DIR'"; then cat << EOF > "$LOWLATENCY_CONF"
context.properties = { default.clock.quantum=256; default.clock.min-quantum=32; default.clock.max-quantum=1024 }
EOF
; print_success "$LOWLATENCY_CONF создан."; print_warning "Перезапустите PipeWire/сеанс."; echo "  systemctl --user restart pipewire pipewire-pulse wireplumber"; else print_error "Не удалось создать '$PW_CONF_DIR'."; fi
            else print_success "$LOWLATENCY_CONF уже существует."; fi
            ;;

        13) # Доп. оптимизация производительности
             print_header "13. Дополнительная оптимизация производительности"
             if ! check_essentials "sysctl" "systemctl" "tee" "mkdir" "grep"; then continue; fi
             SYSCTL_PERF_CONF="/etc/sysctl.d/99-performance-tweaks.conf"; echo "Проверка sysctl...";
             if [ ! -f "$SYSCTL_PERF_CONF" ]; then print_info "Применение sysctl..."; cat << EOF | sudo tee "$SYSCTL_PERF_CONF" > /dev/null
# Perf Tweaks (mini-pc.sh)
vm.dirty_ratio=10; vm.dirty_background_ratio=5; fs.file-max=100000; fs.inotify.max_user_watches=524288
EOF
; if run_command "sudo sysctl --system"; then print_success "Sysctl применены."; fi; else print_success "$SYSCTL_PERF_CONF уже есть."; fi
             SYSTEMD_TIMEOUT_CONF="/etc/systemd/system.conf.d/timeout.conf"; echo "Проверка таймаутов...";
             if [ ! -f "$SYSTEMD_TIMEOUT_CONF" ]; then print_info "Уменьшение таймаутов..."; if run_command "sudo mkdir -p /etc/systemd/system.conf.d/"; then cat << EOF | sudo tee "$SYSTEMD_TIMEOUT_CONF" > /dev/null
[Manager]; DefaultTimeoutStartSec=10s; DefaultTimeoutStopSec=10s
EOF
; run_command "sudo systemctl daemon-reload"; print_success "Таймауты настроены."; fi; else print_success "Настройка таймаутов есть."; fi
             echo "Проверка служб..."; unused_services=("bluetooth.service" "avahi-daemon.service" "cups.socket");
             for service in "${unused_services[@]}"; do is_active=$(systemctl is-active --quiet "$service"; echo $?); is_enabled=$(systemctl is-enabled --quiet "$service"; echo $?); if [ "$is_active" -eq 0 ] || [ "$is_enabled" -eq 0 ]; then if confirm "Отключить '$service'?"; then run_command "sudo systemctl disable --now $service"; fi; else print_info "'$service' неактивна/не включена."; fi; done
             print_success "Дополнительная оптимизация завершена."
             ;;

        14) # Настройка Fn-клавиш
            print_header "14. Настройка Fn-клавиш (Apple Keyboard)"
            if ! check_essentials "mkinitcpio" "bootctl"; then continue; fi
            print_warning "Актуально для клавиатур Apple.";
            HID_APPLE_CONF="/etc/modprobe.d/hid_apple.conf"; echo "Проверка $HID_APPLE_CONF...";
            if ! sudo grep -q "options hid_apple fnmode=2" "$HID_APPLE_CONF" 2>/dev/null; then echo "Настройка hid_apple..."; echo "options hid_apple fnmode=2" | sudo tee "$HID_APPLE_CONF" > /dev/null; print_success "$HID_APPLE_CONF создан."; print_warning "Требуется 'sudo mkinitcpio -P' и перезагрузка."; if confirm "Перестроить initramfs?"; then run_command "sudo mkinitcpio -P"; fi; else print_success "Настройка fnmode=2 уже есть."; fi
            CMDLINE_KBD_CONF="/etc/kernel/cmdline.d/keyboard-fnmode.conf"; echo "Проверка параметра ядра...";
            if [ ! -f "$CMDLINE_KBD_CONF" ] || ! sudo grep -q "hid_apple.fnmode=2" "$CMDLINE_KBD_CONF" 2>/dev/null; then echo "Добавление параметра ядра..."; echo "hid_apple.fnmode=2" | sudo tee "$CMDLINE_KBD_CONF" > /dev/null; if run_command "sudo bootctl update"; then print_success "Параметр ядра добавлен."; fi; else print_success "Параметр ядра уже есть."; fi
            print_success "Настройка Fn-клавиш завершена."; print_warning "Может потребоваться перезагрузка."
            ;;

        15) # Установка Steam
            print_header "15. Установка Steam (Intel графика)"
            if ! check_essentials; then continue; fi
            print_info "Убедитесь, что [multilib] включен в /etc/pacman.conf."
            steam_deps=(
                "vulkan-intel" "lib32-vulkan-intel" "mesa" "lib32-mesa"
                "xorg-mkfontscale" "xorg-fonts-cyrillic" "xorg-fonts-misc"
            )
            if ! check_and_install_packages "Зависимости Steam для Intel" "${steam_deps[@]}"; then
                 print_warning "Установка зависимостей Steam отменена/не удалась. Steam не будет установлен."
                 continue
            fi
            print_success "Зависимости Steam установлены/проверены."

            if ! check_package "steam"; then
                print_warning "Сейчас будет запущена ИНТЕРАКТИВНАЯ установка Steam."
                print_warning "Выберите номер опции с 'intel' (напр., 'lib32-vulkan-intel')."
                read -p "Нажмите Enter для запуска 'sudo pacman -S steam'..."
                # Выполняем pacman интерактивно
                if sudo pacman -S steam; then
                    print_success "Steam успешно установлен."
                else
                    print_error "Команда установки Steam завершилась с ошибкой. Проверьте вывод выше."
                    # Не прерываем, пользователь мог прервать сам или были ошибки с хуками
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
    read -p "Нажмите Enter, чтобы вернуться в меню..."

done

# --- Конец скрипта ---
