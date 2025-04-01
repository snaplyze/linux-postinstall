#!/bin/bash

# mini-pc-arch-setup.sh - Оптимизированный скрипт настройки Arch Linux для мини-ПК
# Версия: 1.8.0 (Обновлены параметры для актуальных версий Arch Linux)
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

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
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
    # Основные команды, которые должны быть всегда после базовой установки Arch
    local essentials=(
        "grep" "tee" "mkdir" "cat" "systemctl" "sysctl" "awk" "sed"
        "mount" "umount" "lsblk" "chown" "blkid" "uname" "lscpu" "free"
        "findmnt" "date" "read" "sudo" "rm" "cp" "basename" "dirname" "mktemp"
        "true" "false" "echo" "printf" "test" "[" "[[" "cut" "sort" "uniq" "head" "tail"
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
            # Флаг critical здесь важен, чтобы скрипт не продолжался с отсутствующими зависимостями
            if ! run_command "sudo pacman -S --needed --noconfirm ${missing_packages[*]}" "critical"; then
                 print_error "Не удалось завершить команду установки пакетов."
                 # Run_command с critical уже выйдет из скрипта, но оставим return на всякий случай
                 return 1
            fi
            # Дополнительная проверка после попытки установки (run_command уже проверил код возврата pacman)
            # Эта проверка нужна на случай, если pacman завершился с 0, но пакеты по какой-то причине не установились
            local failed_install=()
            for pkg in "${missing_packages[@]}"; do
                if ! check_package "$pkg"; then
                    failed_install+=("$pkg")
                fi
            done
            if [ ${#failed_install[@]} -gt 0 ]; then
                print_error "Пакеты НЕ установились (хотя pacman завершился успешно?): ${failed_install[*]}. Операция не может быть продолжена."
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
        echo -e "${GREEN}Все необходимые пакеты уже установлены.${NC}"
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
# pacman для check_package, command для check_command, read для меню/confirm
base_deps=("bash" "pacman" "command" "read" "sudo")
missing_deps=()
for cmd in "${base_deps[@]}"; do
    if ! check_command "$cmd"; then
        missing_deps+=("$cmd")
    fi
done
if [ ${#missing_deps[@]} -gt 0 ]; then
    print_error "Отсутствуют критические для работы скрипта команды: ${missing_deps[*]}"
    print_error "Установите пакеты, предоставляющие эти команды (coreutils, bash, pacman)."
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

# Проверяем команды перед использованием для вывода информации
if ! check_essentials "uname" "lscpu" "free" "findmnt" "btrfs" "lsblk" "grep" "awk" "cat" "cut" "sed"; then
    print_error "Не могу собрать полную информацию о системе из-за отсутствия команд."
else
    echo "Ядро Linux:      $(uname -r)"
    distro_name=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    echo "Дистрибутив:    ${distro_name:-Не определен}"
    cpu_model=$(grep "Model name" /proc/cpuinfo | uniq | sed 's/Model name\s*:\s*//')
    echo "Процессор:      ${cpu_model:-Не определен}"
    mem_total=$(free -h | awk '/^Mem:/ {print $2}')
    echo "Память (RAM):   ${mem_total:-Не определено}"
    ROOT_DEVICE=$(findmnt -no SOURCE / | sed 's/\[.*\]//') # Пример: /dev/sda2[/@]
    ROOT_PART_ONLY=$(echo "$ROOT_DEVICE" | sed 's/\[.*\]//') # Пример: /dev/sda2
    echo "Системный диск: ${ROOT_PART_ONLY:-Не определен} (ФС: BTRFS)"
    fstab_root_opts=$(grep "[[:space:]]/[[:space:]]" /etc/fstab | awk '{print $4}')
    echo "Опции '/'(fstab): ${fstab_root_opts:-Не найдены}"
    echo "BTRFS подтома на '/':"
    # Используем sudo для btrfs, может понадобиться пароль
    if check_command "btrfs"; then
        sudo btrfs subvolume list / || echo "   (Не удалось получить список подтомов - ошибка btrfs или нужны права)"
    else
        echo "   (Команда btrfs не найдена)"
    fi
    echo -e "\nБлочные устройства:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
fi

# Проверка загрузчика (systemd-boot установлен инсталлятором)
if ! check_command "bootctl"; then
     print_warning "Команда bootctl не найдена. Проверка systemd-boot невозможна."
elif [ -d "/boot/loader" ] && [ -f "/boot/loader/loader.conf" ]; then
    print_success "Обнаружена конфигурация systemd-boot"
else
    print_warning "Конфигурация systemd-boot (/boot/loader/loader.conf) не найдена."
    # Не критично для большинства шагов, но важно для шага 5 и 14
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
    KERNEL_NAME="linux" # Fallback, может быть неверным
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
            if ! check_essentials; then continue; fi # Проверка базовых команд sudo, pacman
            run_command "sudo pacman -Syu --noconfirm" "critical"
            print_success "Система обновлена."
            ;;

        2) # Доп. настройка Intel графики
            print_header "2. Дополнительная настройка Intel графики (Wayland)"
            if ! check_essentials "mkinitcpio" "grep" "tee"; then continue; fi
            if ! check_and_install_packages "Intel графика (доп.)" "intel-media-driver" "qt6-wayland" "qt5-wayland"; then continue; fi

            I915_CONF="/etc/modprobe.d/i915.conf"
            I915_OPTS="options i915 enable_fbc=1 enable_guc=3 enable_dc=4 enable_psr=1"
            echo "Проверка $I915_CONF..."
            # Используем sudo для чтения, если у пользователя нет прав
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
            # Проверяем наличие ключевых переменных
            if [ ! -f "$ENV_FILE" ] || ! sudo grep -q "LIBVA_DRIVER_NAME=iHD" "$ENV_FILE" 2>/dev/null || ! sudo grep -q "MOZ_ENABLE_WAYLAND=1" "$ENV_FILE" 2>/dev/null ; then
                echo "Обновление $ENV_FILE..."
                cat << EOF | sudo tee "$ENV_FILE" > /dev/null
# Wayland Env Vars (mini-pc.sh)
LIBVA_DRIVER_NAME=iHD
MOZ_ENABLE_WAYLAND=1
QT_QPA_PLATFORM=wayland
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=gnome
EOF
                print_success "$ENV_FILE настроен для Wayland."
            else
                print_success "$ENV_FILE уже содержит настройки Wayland."
            fi
            print_success "Дополнительная настройка Intel графики завершена."
            ;;

        3) # Доп. оптимизация BTRFS
            print_header "3. Дополнительная оптимизация BTRFS (системный диск)"
            if ! check_essentials "btrfs" "sysctl" "grep" "awk" "tee"; then continue; fi
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

            # --- НАЧАЛО ИСПРАВЛЕНИЯ ---
            # 1. Проверяем и устанавливаем ВСЕ необходимые пакеты СНАЧАЛА
            #    parted - для parted
            #    e2fsprogs - для mkfs.ext4
            #    gptfdisk - для sgdisk <--- Добавлен пакет для sgdisk
            #    util-linux - для wipefs, blkid, lsblk, findmnt, mount, umount, realpath
            #    gvfs - для интеграции с файловым менеджером
            #    coreutils - для basename, chown, mkdir, tee и др. (обычно уже есть)
            local required_pkgs=("parted" "e2fsprogs" "gptfdisk" "util-linux" "gvfs" "coreutils")
            print_info "Проверка и установка пакетов для форматирования..."
            # Используем флаг "critical", т.к. без этих пакетов операция невозможна
            if ! check_and_install_packages "Утилиты для форматирования дисков" "${required_pkgs[@]}"; then
                 print_error "Не удалось установить необходимые пакеты или установка отменена. Операция не может быть продолжена."
                 read -p "Нажмите Enter для возврата в меню..."
                 continue
            fi
            print_success "Необходимые пакеты установлены или уже присутствуют."

            # 2. Теперь проверяем наличие самих КОМАНД после попытки установки пакетов
            #    Убедимся, что sgdisk есть в списке
            local required_cmds=("parted" "mkfs.ext4" "wipefs" "sgdisk" "blkid" "lsblk" "mount" "umount" "chown" "basename" "awk" "grep" "sed" "findmnt" "realpath" "mkdir" "tee")
            print_info "Проверка наличия необходимых команд..."
            if ! check_essentials "${required_cmds[@]}"; then
                # Если check_essentials не прошел ДАЖЕ ПОСЛЕ установки, что-то не так
                print_error ">>> DEBUG: check_essentials failed even after attempting package installation."
                print_error "Хотя пакеты (${required_pkgs[*]}) должны были установиться, команды (${required_cmds[*]}) не найдены. Проверьте \$PATH или вывод установки пакетов."
                read -p "Нажмите Enter для возврата в меню..."
                continue
            fi
            print_success "Все необходимые команды на месте."
            # --- КОНЕЦ ИСПРАВЛЕНИЯ ---

            # --- Далее идет остальная часть кода пункта 4 ---
            print_warning "ВНИМАНИЕ! Все данные на выбранном диске будут БЕЗВОЗВРАТНО УНИЧТОЖЕНЫ!"
            echo "Текущие диски и разделы:"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

            # --- Начало логики определения диска ---
            print_info ">>> DEBUG: Определяем корневое устройство..."
            ROOT_DEV_NODE=$(findmnt -no SOURCE /)
            if [ -z "$ROOT_DEV_NODE" ]; then
                print_error "Не удалось определить устройство корневой файловой системы с помощью findmnt."
                read -p "Нажмите Enter для возврата в меню..."
                continue
            fi
            print_info ">>> DEBUG: Корневая ФС найдена на: $ROOT_DEV_NODE"

            print_info ">>> DEBUG: Определяем реальный путь..."
            ROOT_REAL_PATH=$(realpath "$ROOT_DEV_NODE")
             if [ -z "$ROOT_REAL_PATH" ] || [ ! -b "$ROOT_REAL_PATH" ]; then
                print_warning ">>> DEBUG: realpath не сработал для '$ROOT_DEV_NODE', пробуем глобальную переменную ROOT_DEVICE=$ROOT_DEVICE..."
                # ROOT_DEVICE была определена ранее в скрипте
                ROOT_REAL_PATH=$(realpath "$ROOT_DEVICE")
                if [ -z "$ROOT_REAL_PATH" ] || [ ! -b "$ROOT_REAL_PATH" ]; then
                    print_error "Не удалось определить реальный путь к блочному устройству для корня ФС ($ROOT_DEV_NODE / $ROOT_DEVICE)."
                    read -p "Нажмите Enter для возврата в меню..."
                    continue
                fi
            fi
            print_info ">>> DEBUG: Реальный путь к устройству корня: $ROOT_REAL_PATH"

            print_info ">>> DEBUG: Определяем родительский диск..."
            ROOT_DISK_NAME=$(lsblk -no pkname "$ROOT_REAL_PATH")
            if [ -z "$ROOT_DISK_NAME" ]; then
                 print_warning ">>> DEBUG: Не удалось определить родительский диск через 'lsblk -no pkname'. Используем старый метод из ROOT_DEVICE=$ROOT_DEVICE..."
                 ROOT_DISK_BASE_PATH=$(basename "$ROOT_DEVICE" | sed 's/[0-9]*$//; s/p[0-9]*$//')
                 ROOT_DISK_NAME=$(basename "$ROOT_DISK_BASE_PATH")
                 if [ -z "$ROOT_DISK_NAME" ]; then
                      print_error "Не удалось определить имя родительского диска для корня ФС."
                      read -p "Нажмите Enter для возврата в меню..."
                      continue
                 fi
            fi
            print_info ">>> DEBUG: Системный диск определен как: /dev/$ROOT_DISK_NAME"

            print_info ">>> DEBUG: Получаем список дисков для форматирования (исключая /dev/$ROOT_DISK_NAME)..."
            temp_lsblk_output=$(mktemp)
            lsblk -dnpo NAME,SIZE,TYPE > "$temp_lsblk_output"
            print_info ">>> DEBUG: Полный вывод lsblk -dnpo NAME,SIZE,TYPE сохранен в $temp_lsblk_output"
            mapfile_cmd="mapfile -t disk_options < <(awk -v sys_disk=\"/dev/${ROOT_DISK_NAME}\" '\$3 == \"disk\" && \$1 != sys_disk {print \$1 \" (\" \$2 \")\"}' '$temp_lsblk_output')"
            print_info ">>> DEBUG: Выполняем: $mapfile_cmd"
            eval "$mapfile_cmd"
            local mapfile_exit_code=$?
            print_info ">>> DEBUG: mapfile завершился с кодом: $mapfile_exit_code"
            print_info ">>> DEBUG: Найденные диски (disk_options): [${disk_options[*]}]"
            print_info ">>> DEBUG: Количество найденных дисков: ${#disk_options[@]}"

            # --- Конец логики определения диска ---

            if [ ${#disk_options[@]} -eq 0 ]; then
                print_warning "Дополнительные диски (кроме системного /dev/${ROOT_DISK_NAME}), подходящие для форматирования, не найдены."
                print_warning ">>> DEBUG: Массив disk_options пуст. Проверьте вывод в $temp_lsblk_output и имя системного диска."
                read -p "Нажмите Enter для возврата в меню..."
                rm "$temp_lsblk_output" # Удаляем временный файл
                continue
            fi

            echo "Доступные диски для форматирования (системный /dev/${ROOT_DISK_NAME} исключен):"
            disk_choice="" # Сбрасываем выбор
            select opt in "${disk_options[@]}" "Отмена"; do
                if [[ "$REPLY" == $((${#disk_options[@]} + 1)) ]]; then
                    disk_choice="Отмена"
                    print_info ">>> DEBUG: Пользователь выбрал 'Отмена' в select."
                    break
                elif [[ "$REPLY" -ge 1 && "$REPLY" -le ${#disk_options[@]} ]]; then
                    disk_choice="${disk_options[$REPLY-1]}"
                    second_disk=$(echo "$disk_choice" | awk '{print $1}')
                    print_info ">>> DEBUG: Пользователь выбрал диск: $second_disk (опция: $disk_choice)"
                    break
                else
                    print_warning "Неверный выбор. Введите номер из списка."
                fi
            done

            [ -f "$temp_lsblk_output" ] && rm "$temp_lsblk_output" # Удаляем временный файл, если он еще существует

            if [ "$disk_choice" == "Отмена" ]; then
                print_warning "Операция отменена."
                continue # Возврат в главное меню
            fi

            # --- Начало основной логики форматирования ---
            print_info ">>> DEBUG: Запрос подтверждения на форматирование $second_disk..."
            if confirm "Точно форматировать $second_disk в Ext4 (метка 'SSD', точка /mnt/ssd)?"; then
                print_info ">>> DEBUG: Подтверждение получено."

                print_info ">>> DEBUG: Проверяем монтирование $second_disk..."
                if mount | grep -q "$second_disk"; then
                    print_warning "Обнаружены смонтированные разделы на $second_disk. Попытка размонтирования..."
                    mapfile -t mounts_to_umount < <(findmnt -nr -o TARGET --source "$second_disk")
                    umount_failed=false
                    if [ ${#mounts_to_umount[@]} -gt 0 ]; then
                        print_info ">>> DEBUG: Найдены точки монтирования для размонтирования: ${mounts_to_umount[*]}"
                        for mp in "${mounts_to_umount[@]}"; do
                            print_info ">>> DEBUG: Пытаемся размонтировать '$mp'..."
                            # Используем run_command без "critical" для размонтирования
                            if ! run_command "sudo umount '$mp'"; then
                                print_error "Не удалось размонтировать '$mp'"
                                umount_failed=true
                            fi
                        done
                    else
                       print_info ">>> DEBUG: Активных точек монтирования для $second_disk не найдено findmnt."
                    fi
                    if [ "$umount_failed" = true ]; then
                         print_error "Не удалось размонтировать все разделы на $second_disk. Форматирование отменено."
                         continue
                    fi
                else
                    print_info ">>> DEBUG: $second_disk не найден в выводе mount."
                fi

                print_info ">>> DEBUG: Очистка и разметка $second_disk..."
                # Теперь команды должны выполняться, т.к. пакеты установлены
                if ! run_command "sudo wipefs -af $second_disk" "critical"; then continue; fi
                if ! run_command "sudo sgdisk --zap-all $second_disk" "critical"; then continue; fi
                if ! run_command "sudo parted -s $second_disk mklabel gpt" "critical"; then continue; fi
                if ! run_command "sudo parted -s -a optimal $second_disk mkpart primary ext4 0% 100%" "critical"; then continue; fi

                print_info ">>> DEBUG: Пауза 5 секунд для распознавания раздела..."
                sleep 5 # Увеличенная пауза
                print_info ">>> DEBUG: Определяем имя нового раздела для $second_disk..."
                # Пытаемся найти раздел вида /dev/sda1 или /dev/nvme0n1p1
                new_partition_name=$(lsblk -lno NAME $second_disk | grep -E "${second_disk##*/}[p]?[0-9]+$" | head -n 1)

                if [ -z "$new_partition_name" ]; then
                    print_error ">>> DEBUG: Не удалось определить имя нового раздела на $second_disk стандартным методом."
                    # Резервный метод: ищем любой раздел, который не является самим диском
                    new_partition_name=$(lsblk -lno NAME $second_disk | grep -v "${second_disk##*/}" | head -n 1)
                     if [ -z "$new_partition_name" ]; then
                          print_error "Резервный метод определения раздела тоже не сработал. Проверьте вывод 'lsblk $second_disk' вручную."
                          continue
                     fi
                     print_warning ">>> DEBUG: Использован резервный метод определения раздела: $new_partition_name"
                fi
                print_info ">>> DEBUG: Имя раздела определено как: $new_partition_name"

                new_partition="/dev/$new_partition_name"
                if [ ! -b "$new_partition" ]; then
                    print_error "Определенное имя раздела '$new_partition' не является блочным устройством."
                    continue
                fi
                print_success "Создан раздел: $new_partition"

                print_info ">>> DEBUG: Форматирование $new_partition..."
                if ! run_command "sudo mkfs.ext4 -F -L SSD $new_partition" "critical"; then continue; fi # -F принудительно

                mount_point="/mnt/ssd"
                print_info ">>> DEBUG: Создание точки монтирования $mount_point..."
                # -p создаст /mnt, если его нет
                if ! run_command "sudo mkdir -p $mount_point"; then continue; fi

                print_info ">>> DEBUG: Получение UUID для $new_partition..."
                DATA_UUID=$(sudo blkid -s UUID -o value $new_partition)
                if [ -z "$DATA_UUID" ]; then
                    print_error "Не удалось получить UUID для раздела $new_partition."
                    continue
                fi
                print_info ">>> DEBUG: UUID нового раздела: $DATA_UUID"

                print_info ">>> DEBUG: Добавление записи в /etc/fstab..."
                if ! run_command "sudo cp /etc/fstab /etc/fstab.backup.$(date +%F_%T)"; then
                    print_warning "Не удалось создать резервную копию /etc/fstab."
                fi
                # Удаляем старую запись для этого UUID на всякий случай
                sudo sed -i "/UUID=$DATA_UUID/d" /etc/fstab
                fstab_line="UUID=$DATA_UUID  $mount_point  ext4  defaults,noatime,x-gvfs-show  0 2"
                echo "# Второй SSD - (Ext4, SSD, /mnt/ssd, mini-pc.sh)" | sudo tee -a /etc/fstab > /dev/null
                if ! echo "$fstab_line" | sudo tee -a /etc/fstab > /dev/null; then
                    print_error "Не удалось записать строку в /etc/fstab."
                    continue
                fi
                print_success "Строка добавлена в fstab: $fstab_line"

                print_info ">>> DEBUG: Перезагрузка демонов systemd..."
                if ! run_command "sudo systemctl daemon-reload"; then continue; fi

                print_info ">>> DEBUG: Монтирование всего из fstab..."
                # Используем "critical", так как если не монтируется, то что-то не так с fstab
                if ! run_command "sudo mount -a" "critical"; then
                    # run_command с critical уже выйдет, но оставим на всякий случай
                    print_error "Критическая ошибка при монтировании из fstab. Проверьте '/etc/fstab' и вывод 'sudo mount -a'."
                    continue
                fi

                print_info ">>> DEBUG: Проверяем, смонтирован ли $mount_point..."
                if findmnt --mountpoint "$mount_point" > /dev/null; then
                    print_success "$mount_point успешно смонтирован."
                    print_info ">>> DEBUG: Установка прав доступа для $mount_point..."
                    # Меняем владельца на текущего пользователя и его основную группу
                    if ! run_command "sudo chown $(whoami):$(id -gn) $mount_point"; then
                        print_warning "Не удалось сменить владельца $mount_point."
                    else
                         print_success "Владелец $mount_point изменен на $(whoami):$(id -gn)."
                    fi
                else
                     # Это не должно происходить, если mount -a прошло успешно с critical
                    print_error "$mount_point НЕ смонтирован после 'mount -a'. Неожиданная ошибка."
                fi

                print_success "Операция с диском $second_disk завершена."
            else
                print_info ">>> DEBUG: Пользователь отменил форматирование."
            fi # Конец confirm
            # --- Конец основной логики форматирования ---
            ;; # Конец case 4)

        5) # Скрытие логов
            print_header "5. Уточнение настройки скрытия логов при загрузке"
            if ! check_essentials "bootctl" "mkdir" "tee" "grep" "mkinitcpio" "find"; then continue; fi
            print_success "Plymouth и 'quiet splash' настроены установщиком."
            QUIET_PARAMS="loglevel=3 rd.systemd.show_status=auto rd.udev.log_priority=3"
            
            # Проверим версию systemd для определения метода настройки
            systemd_version=$(systemctl --version | head -n 1 | awk '{print $2}')
            echo "Версия systemd: $systemd_version"
            
            need_initramfs_update=false
            kernel_entries_updated=false
            
            # Современный метод для systemd 250+
            if [ "$systemd_version" -ge 250 ]; then
                CMDLINE_DIR="/etc/kernel/cmdline.d"
                CMDLINE_FILE="$CMDLINE_DIR/01-quiet-params.conf"
                echo "Используем новый метод параметров ядра через $CMDLINE_FILE (systemd 250+)"
                
                # Создаем директорию если нужно
                if [ ! -d "$CMDLINE_DIR" ]; then
                    echo "Создание директории $CMDLINE_DIR..."
                    if ! run_command "sudo mkdir -p $CMDLINE_DIR"; then
                        print_error "Не удалось создать директорию $CMDLINE_DIR."
                        read -p "Нажмите Enter для продолжения..." temp
                        continue
                    fi
                fi
                
                # Записываем параметры в файл
                if [ ! -f "$CMDLINE_FILE" ] || ! sudo grep -q "loglevel=3" "$CMDLINE_FILE" 2>/dev/null; then
                    echo "Добавление доп. параметров в $CMDLINE_FILE..."
                    if echo "$QUIET_PARAMS" | sudo tee "$CMDLINE_FILE" > /dev/null; then 
                        print_success "Параметры добавлены."
                        need_initramfs_update=true
                        run_command "sudo bootctl update"
                        kernel_entries_updated=true
                    else 
                        print_error "Не удалось записать в $CMDLINE_FILE."
                    fi
                else 
                    print_success "Доп. параметры уже есть в $CMDLINE_FILE."
                fi
            fi
            
            # Традиционный метод - редактирование файлов в /boot/loader/entries
            if [ "$systemd_version" -lt 250 ] || [ "$kernel_entries_updated" = false ]; then
                echo "Используем традиционный метод: редактирование файлов загрузчика..."
                ENTRIES_DIR="/boot/loader/entries"
                
                if [ ! -d "$ENTRIES_DIR" ]; then
                    print_error "Директория $ENTRIES_DIR не найдена. systemd-boot не настроен?"
                    read -p "Нажмите Enter для продолжения..." temp
                    continue
                fi
                
                # Находим все файлы конфигурации загрузчика
                conf_files=$(sudo find "$ENTRIES_DIR" -name "*.conf")
                if [ -z "$conf_files" ]; then
                    print_error "Файлы конфигурации не найдены в $ENTRIES_DIR"
                    read -p "Нажмите Enter для продолжения..." temp
                    continue
                fi
                
                # Для каждого файла проверяем и обновляем параметры
                for conf_file in $conf_files; do
                    echo "Проверка файла $conf_file..."
                    quiet_params_exist=false
                    
                    # Проверяем, есть ли уже loglevel=3
                    if sudo grep -q "loglevel=3" "$conf_file"; then
                        quiet_params_exist=true
                        print_success "Параметры тихой загрузки уже есть в $conf_file"
                        continue
                    fi
                    
                    # Проверяем строку options
                    options_line=$(sudo grep "^options" "$conf_file")
                    if [ -n "$options_line" ]; then
                        # Добавляем наши параметры к существующим
                        echo "Обновление параметров в $conf_file..."
                        new_options_line=$(echo "$options_line" | sed "s/\(options .*\)/\1 $QUIET_PARAMS/")
                        sudo sed -i "s|^options.*|$new_options_line|" "$conf_file"
                        print_success "Параметры загрузки обновлены в $conf_file"
                        need_initramfs_update=true
                    else
                        print_warning "Строка options не найдена в $conf_file"
                    fi
                done
            fi
            
            # Настройка журнала systemd
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
                        run_command "sudo systemctl restart systemd-journald"
                    fi
                fi
            else 
                print_success "Настройка журнала TTY уже есть."
            fi
            
            # Перестраиваем образ initramfs если были изменения
            if [ "$need_initramfs_update" = true ]; then
                print_info "Требуется обновление образа initramfs для применения параметров загрузки..."
                if confirm "Выполнить sudo mkinitcpio -P сейчас?"; then
                    if run_command "sudo mkinitcpio -P"; then
                        print_success "Образ initramfs успешно обновлен."
                    else
                        print_error "Ошибка при обновлении образа initramfs."
                    fi
                else
                    print_warning "Обновление образа initramfs пропущено. Параметры загрузки не будут применены до выполнения 'sudo mkinitcpio -P'."
                fi
            fi
            
            print_success "Настройка тихой загрузки завершена."
            ;;

        6) # Настройка Paru
            print_header "6. Настройка пользовательского Paru"
            if ! check_command "paru"; then print_error "Команда paru не найдена."; continue; fi
            if ! check_essentials "mkdir" "cat"; then continue; fi
            print_success "Paru установлен системно."
            PARU_USER_CONF="$HOME/.config/paru/paru.conf"
            echo "Проверка $PARU_USER_CONF..."
            if [ ! -f "$PARU_USER_CONF" ]; then
                echo "Создание $PARU_USER_CONF..."
                if run_command "mkdir -p '$HOME/.config/paru'"; then
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
                sudo tee "$TLP_CONF" > /dev/null << EOF
# TLP mini-pc Performance (mini-pc.sh)
TLP_ENABLE=1
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=performance
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=performance
PLATFORM_PROFILE_ON_AC=performance
PLATFORM_PROFILE_ON_BAT=performance
PCIE_ASPM_ON_AC=performance
PCIE_ASPM_ON_BAT=default
USB_AUTOSUSPEND=0
WOL_DISABLE=Y
SOUND_POWER_SAVE_ON_AC=0
SOUND_POWER_SAVE_ON_BAT=0
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on
EOF
                if [ $? -eq 0 ]; then 
                    print_success "$TLP_CONF создан."
                else 
                    print_error "Не удалось создать $TLP_CONF."
                fi
            else 
                print_success "$TLP_CONF уже существует."
            fi
            if ! systemctl is-enabled --quiet tlp; then print_info "Включение TLP..."; run_command "sudo systemctl enable --now tlp"; run_command "sudo systemctl enable NetworkManager-dispatcher.service"; run_command "sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket"; else print_success "TLP включен."; fi
            SWAPPINESS_CONF="/etc/sysctl.d/99-swappiness-zram.conf"; echo "Проверка swappiness...";
            if [ ! -f "$SWAPPINESS_CONF" ]; then echo "Настройка vm.swappiness..."; echo "vm.swappiness=100 # High value for ZRAM" | sudo tee "$SWAPPINESS_CONF" > /dev/null; run_command "sudo sysctl --system"; print_success "Swappiness настроен."; else print_success "Swappiness уже настроен: $(sudo sysctl -n vm.swappiness)"; fi
            print_success "Настройка управления питанием завершена."
            ;;

        9) # Firewall / Core Dumps
            print_header "9. Настройка Firewall и Core Dumps"
            if ! check_essentials "ufw" "sysctl" "tee" "grep"; then continue; fi
            if check_and_install_packages "Безопасность (UFW)" "ufw"; then
                if ! systemctl is-enabled --quiet ufw; then
                    print_info "Настройка и включение UFW..."; run_command "sudo ufw default deny incoming"; run_command "sudo ufw default allow outgoing"; run_command "sudo ufw allow ssh"
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
            # check_essentials не нужен, т.к. только установка пакетов
            cli_utils=("neofetch" "bat" "eza" "ripgrep" "fd" "btop")
            check_and_install_packages "Доп. утилиты CLI" "${cli_utils[@]}"
            check_and_install_packages "Seahorse (GUI для ключей)" "seahorse"
            print_success "Проверка/установка дополнительных программ завершена."
            ;;

        11) # Timeshift
            print_header "11. Установка Timeshift (системный диск)"
            if ! check_command "timeshift-launcher"; then if ! check_and_install_packages "Резервное копирование" "timeshift"; then continue; fi; fi
            if ! check_essentials "grep"; then continue; fi
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
                print_info "Создание Low Latency конфига..."
                if run_command "mkdir -p '$PW_CONF_DIR'"; then 
                    cat << EOF > "$LOWLATENCY_CONF"
context.properties = {
    # Значения в микросекундах (1 мс = 1000 мкс)
    default.clock.rate          = 48000
    default.clock.quantum       = 256    # 5.3 мс при 48000 Гц
    default.clock.min-quantum   = 32     # 0.7 мс при 48000 Гц
    default.clock.max-quantum   = 1024   # 21.3 мс при 48000 Гц
}
EOF
                    print_success "$LOWLATENCY_CONF создан."
                    print_warning "Перезапустите PipeWire/сеанс."
                    echo "  systemctl --user restart pipewire pipewire-pulse wireplumber"
                else 
                    print_error "Не удалось создать '$PW_CONF_DIR'."
                fi
            else 
                print_success "$LOWLATENCY_CONF уже существует."
            fi
            ;;

        13) # Доп. оптимизация производительности
             print_header "13. Дополнительная оптимизация производительности"
             if ! check_essentials "sysctl" "systemctl" "tee" "mkdir" "grep"; then continue; fi
             SYSCTL_PERF_CONF="/etc/sysctl.d/99-performance-tweaks.conf"; echo "Проверка sysctl...";
             if [ ! -f "$SYSCTL_PERF_CONF" ]; then 
                 print_info "Применение sysctl..."
                 cat << EOF | sudo tee "$SYSCTL_PERF_CONF" > /dev/null
# Perf Tweaks (mini-pc.sh)
vm.dirty_ratio=10
vm.dirty_background_ratio=5
fs.file-max=100000
fs.inotify.max_user_watches=524288
EOF
                 if run_command "sudo sysctl --system"; then 
                     print_success "Sysctl применены."
                 fi
             else 
                 print_success "$SYSCTL_PERF_CONF уже есть."
             fi
             
             SYSTEMD_TIMEOUT_CONF="/etc/systemd/system.conf.d/timeout.conf"; echo "Проверка таймаутов...";
             if [ ! -f "$SYSTEMD_TIMEOUT_CONF" ]; then 
                 print_info "Уменьшение таймаутов..."
                 if run_command "sudo mkdir -p /etc/systemd/system.conf.d/"; then 
                     cat << EOF | sudo tee "$SYSTEMD_TIMEOUT_CONF" > /dev/null
[Manager]
DefaultTimeoutStartSec=10s
DefaultTimeoutStopSec=10s
EOF
                     run_command "sudo systemctl daemon-reload"
                     print_success "Таймауты настроены."
                 fi
             else 
                 print_success "Настройка таймаутов есть."
             fi
             
             echo "Проверка служб..."
             unused_services=("bluetooth.service" "avahi-daemon.service" "cups.socket")
             for service in "${unused_services[@]}"; do 
                 is_active=$(systemctl is-active --quiet "$service"; echo $?)
                 is_enabled=$(systemctl is-enabled --quiet "$service"; echo $?)
                 if [ "$is_active" -eq 0 ] || [ "$is_enabled" -eq 0 ]; then 
                     if confirm "Отключить '$service'?"; then 
                         run_command "sudo systemctl disable --now $service"
                     fi
                 else 
                     print_info "'$service' неактивна/не включена."
                 fi
             done
             print_success "Дополнительная оптимизация завершена."
             ;;

        14) # Настройка Fn-клавиш
            print_header "14. Настройка Fn-клавиш (Apple Keyboard)"
            if ! check_essentials "mkinitcpio" "bootctl" "grep" "tee"; then continue; fi
            print_warning "Актуально для клавиатур Apple.";
            HID_APPLE_CONF="/etc/modprobe.d/hid_apple.conf"; echo "Проверка $HID_APPLE_CONF...";
            if ! sudo grep -q "options hid_apple fnmode=2" "$HID_APPLE_CONF" 2>/dev/null; then echo "Настройка hid_apple..."; echo "options hid_apple fnmode=2" | sudo tee "$HID_APPLE_CONF" > /dev/null; print_success "$HID_APPLE_CONF создан."; print_warning "Требуется 'sudo mkinitcpio -P' и перезагрузка."; if confirm "Перестроить initramfs?"; then run_command "sudo mkinitcpio -P"; fi; else print_success "Настройка fnmode=2 уже есть."; fi
            CMDLINE_KBD_CONF="/etc/kernel/cmdline.d/keyboard-fnmode.conf"; echo "Проверка параметра ядра...";
            if [ ! -f "$CMDLINE_KBD_CONF" ] || ! sudo grep -q "hid_apple.fnmode=2" "$CMDLINE_KBD_CONF" 2>/dev/null; then echo "Добавление параметра ядра..."; echo "hid_apple.fnmode=2" | sudo tee "$CMDLINE_KBD_CONF" > /dev/null; if run_command "sudo bootctl update"; then print_success "Параметр ядра добавлен."; fi; else print_success "Параметр ядра уже установлен."; fi
            print_success "Настройка Fn-клавиш завершена."; print_warning "Может потребоваться перезагрузка."
            ;;

        15) # Установка Steam
            print_header "15. Установка Steam (Intel графика)"
            if ! check_essentials; then continue; fi # Нужен pacman
            print_info "Убедитесь, что [multilib] включен в /etc/pacman.conf (проверьте сами)."
            steam_deps=(
                "vulkan-intel" "lib32-vulkan-intel" "mesa" "lib32-mesa"
                "xorg-mkfontscale" "xorg-fonts-cyrillic" "xorg-fonts-misc"
                "gamescope" "gamemode" "lib32-gamemode" "mangohud" "lib32-mangohud"
            )
            if ! check_and_install_packages "Зависимости Steam для Intel" "${steam_deps[@]}"; then
                 print_warning "Установка зависимостей Steam отменена/не удалась. Steam не будет установлен."
                 continue
            fi
            print_success "Зависимости Steam установлены/проверены."

            if ! check_package "steam"; then
                print_warning "Сейчас будет запущена ИНТЕРАКТИВНАЯ установка Steam."
                print_warning "Когда появится список 'провайдеров', выберите номер опции с 'intel',"
                print_warning "(например, 'lib32-vulkan-intel')."
                read -p "Нажмите Enter для запуска 'sudo pacman -S steam'..."
                # Выполняем pacman интерактивно, без run_command
                if sudo pacman -S steam; then
                    print_success "Steam успешно установлен."
                else
                    # Код возврата pacman может быть > 0 даже при успешной установке (ошибки хуков и т.п.)
                    print_error "Команда установки Steam завершилась с ошибкой (код $?). Проверьте вывод выше."
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
