#!/bin/bash

# arch-setup.sh - Полный скрипт настройки Arch Linux с GNOME 48
# Разработан для: Intel Core i7 13700k, RTX 4090, 32 ГБ ОЗУ, 4 NVME Gen4, 2 HDD
# Версия: 1.2 (Март 2025)

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
    else
        print_error "Ошибка при выполнении команды"
        if [ "$2" = "critical" ]; then
            print_error "Критическая ошибка, выход из скрипта"
            exit 1
        fi
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
            return 0
        else
            echo -e "${YELLOW}Пропускаем установку пакетов. Операция может быть неполной.${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}Все необходимые пакеты установлены${NC}"
        return 0
    fi
}

# Проверка системных требований и предварительных условий
print_header "Проверка системных требований"

# Проверка, запущен ли скрипт от имени обычного пользователя (не root)
if [ "$EUID" -eq 0 ]; then
    print_error "Этот скрипт должен быть запущен от имени обычного пользователя, а не root"
    exit 1
fi

# Проверка базовых зависимостей
base_deps=("bash" "sed" "grep" "awk" "sudo")
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

# Проверка наличия zram
if lsmod | grep -q zram || [ -e "/dev/zram0" ]; then
    print_success "ZRAM уже настроен в системе"
    ZRAM_CONFIGURED=true
else
    print_warning "ZRAM не обнаружен. Рекомендуется для улучшения производительности"
    ZRAM_CONFIGURED=false
fi

# Вывод информации о системе
print_header "Информация о системе"
echo "Ядро Linux: $(uname -r)"
echo "Дистрибутив: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "Процессор: $(lscpu | grep "Model name" | sed 's/Model name: *//')"
echo "Память: $(free -h | awk '/^Mem:/ {print $2}')"

# Определение корневого раздела
ROOT_DEVICE=$(findmnt -no SOURCE / | sed 's/\[.*\]//')
ROOT_DEVICE_BASE=$(echo "$ROOT_DEVICE" | sed 's/p[0-9]\+$//')
echo "Системный диск: $ROOT_DEVICE_BASE"

echo "Смонтированные диски:"
findmnt -t btrfs,ext4,vfat -no SOURCE,TARGET,FSTYPE,OPTIONS | grep -v "zram"

echo "Все доступные блочные устройства:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE

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

# Проверка необходимых пакетов по выбранным операциям
print_header "Предварительная проверка необходимых пакетов"

all_required_packages=()

if contains 1 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("base-devel" "git" "curl" "wget")
fi

if contains 2 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("nvidia-dkms" "nvidia-utils" "nvidia-settings" "libva-nvidia-driver")
fi

if contains 3 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("nvme-cli" "hdparm" "smartmontools")
    if [ "$ZRAM_CONFIGURED" = "false" ]; then
        all_required_packages+=("zram-generator")
    fi
fi

if contains 4 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("parted" "gvfs" "util-linux" "e2fsprogs")
fi

if contains 5 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("plymouth")
fi

if contains 7 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("flatpak" "gnome-software")
fi

if contains 8 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("steam" "lib32-nvidia-utils" "lib32-vulkan-icd-loader" "vulkan-tools" 
                           "xorg-mkfontscale" "xorg-fonts-cyrillic" "xorg-fonts-misc")
fi

if contains 10 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("qt6-wayland" "qt5-wayland" "xorg-xwayland")
fi

if contains 11 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("power-profiles-daemon" "hdparm")
fi

if contains 12 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("ufw")
fi

if contains 13 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("htop" "neofetch" "bat" "exa" "ripgrep" "fd" "gnome-keyring" "seahorse")
fi

if contains 14 "${selected_options[@]}" || contains 15 "${selected_options[@]}"; then
    all_required_packages+=("timeshift")
fi

# Удаление дубликатов
readarray -t unique_packages < <(printf '%s\n' "${all_required_packages[@]}" | sort -u)

# Проверка наличия пакетов
missing_packages=()
for pkg in "${unique_packages[@]}"; do
    if ! check_package "$pkg"; then
        missing_packages+=("$pkg")
    fi
done

if [ ${#missing_packages[@]} -gt 0 ]; then
    print_warning "Для выполнения выбранных операций требуются следующие пакеты:"
    for pkg in "${missing_packages[@]}"; do
        echo "  - $pkg"
    done
    
    if confirm "Установить все необходимые пакеты сейчас?"; then
        run_command "sudo pacman -Sy --needed --noconfirm ${missing_packages[*]}"
    else
        print_warning "Пакеты будут установлены по мере необходимости в процессе выполнения скрипта"
    fi
else
    print_success "Все необходимые пакеты для выбранных операций уже установлены!"
fi

# 1. Обновление системы и базовая настройка
if contains 1 "${selected_options[@]}"; then
    print_header "1. Обновление системы и базовая настройка"
    
    # Проверка необходимых пакетов
    if check_and_install_packages "Базовые утилиты" "base-devel" "git" "curl" "wget" "bash-completion"; then
        # Обновление системы
        run_command "sudo pacman -Syu --noconfirm"
        
        # Установка intel-ucode (микрокод процессора Intel)
        if ! pacman -Qi intel-ucode &> /dev/null; then
            run_command "sudo pacman -S --noconfirm intel-ucode"
        else
            print_success "intel-ucode уже установлен"
        fi
    else
        print_warning "Пропускаем базовую настройку из-за отсутствия необходимых пакетов"
    fi
fi

# 2. Установка драйверов NVIDIA и настройка для Wayland
if contains 2 "${selected_options[@]}"; then
    print_header "2. Установка драйверов NVIDIA и настройка для Wayland"
    
    # Проверка необходимых пакетов
    if check_and_install_packages "Драйверы NVIDIA" "nvidia-dkms" "nvidia-utils" "nvidia-settings" "libva-nvidia-driver"; then
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
options nvidia NVreg_RegistryDwords=RMCleanupInSmoMode=0x1
EOF"
        fi

        # Блокировка nouveau
        run_command "cat << EOF | sudo tee /etc/modprobe.d/blacklist-nvidia-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF"
        
        # Добавление модулей NVIDIA в initramfs в правильном порядке
        if ! grep -q "nvidia" /etc/mkinitcpio.conf; then
            # Важно: правильный порядок модулей имеет значение
            run_command "sudo sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf"
            
            # Добавление KMS в hooks для раннего запуска 
            if ! grep -q "kms" /etc/mkinitcpio.conf; then
                run_command "sudo sed -i '/^HOOKS=/ s/udev/udev kms/' /etc/mkinitcpio.conf"
            fi
            
            run_command "sudo mkinitcpio -P linux-zen" "critical"
        else
            print_success "Модули NVIDIA уже добавлены в mkinitcpio.conf"
        fi
        
        # Добавляем параметр ядра для nvidia_drm.modeset
        run_command "echo 'nvidia_drm.modeset=1' | sudo tee /etc/kernel/cmdline.d/nvidia-drm.conf"
    else
        print_warning "Пропускаем настройку NVIDIA из-за отсутствия необходимых пакетов"
    fi
fi

# 3. Оптимизация NVMe и HDD
if contains 3 "${selected_options[@]}"; then
    print_header "3. Оптимизация NVMe и HDD"
    
    # Проверка наличия необходимых утилит
    if check_and_install_packages "Утилиты NVMe и HDD" "nvme-cli" "hdparm" "smartmontools"; then
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
    else
        print_warning "Пропускаем оптимизацию NVMe и HDD из-за отсутствия необходимых пакетов"
    fi
fi

# Добавляем раздел для настройки ZRAM, если он не настроен
if contains 3 "${selected_options[@]}" && [ "$ZRAM_CONFIGURED" = "false" ]; then
    print_header "Настройка ZRAM"
    
    # Проверка наличия необходимых пакетов
    if check_and_install_packages "ZRAM" "zram-generator"; then
        # Создание конфигурации ZRAM
        cat << EOF | sudo tee /etc/systemd/zram-generator.conf > /dev/null
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF
        
        # Перезапуск службы
        run_command "sudo systemctl daemon-reload"
        run_command "sudo systemctl restart systemd-zram-setup@zram0.service"
        
        print_success "ZRAM настроен. Будет активирован после перезагрузки."
    else
        print_warning "Пропускаем настройку ZRAM из-за отсутствия необходимых пакетов"
    fi
fi

# 4. Форматирование дополнительных дисков
if contains 4 "${selected_options[@]}"; then
    print_header "4. Форматирование дополнительных дисков"
    
    # Проверка наличия необходимых пакетов
    if check_and_install_packages "Форматирование дисков" "parted" "e2fsprogs" "gvfs" "gvfs-mtp" "gvfs-smb"; then
        # Предупреждение
        print_warning "ВНИМАНИЕ! Эта операция необратимо уничтожит все данные на выбранных дисках!"
        echo "Состояние дисков в системе:"
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,LABEL
        
        # Спрашиваем про NVMe диски
        if confirm "Форматировать NVMe диски (кроме системного)?"; then
            # Получаем список всех NVMe дисков, кроме системного
            ROOT_DEVICE=$(findmnt -no SOURCE / | sed 's/\[.*\]//')
            ROOT_DEVICE_BASE=$(echo "$ROOT_DEVICE" | sed 's/p[0-9]\+$//')
            nvme_disks=$(lsblk -o NAME,TYPE | grep "nvme" | grep "disk" | grep -v "$(basename $ROOT_DEVICE_BASE)" | awk '{print $1}')
            
            if [ -z "$nvme_disks" ]; then
                print_warning "Дополнительные NVMe диски не найдены"
            else
                echo "Найдены следующие NVMe диски для форматирования:"
                echo "$nvme_disks"
                
                # Счетчик для нумерации папок NVMe, начиная с 1
                nvme_count=1
                
                for disk in $nvme_disks; do
                    if confirm "Форматировать /dev/$disk?"; then
                        # Создание GPT таблицы разделов
                        run_command "sudo parted /dev/$disk mklabel gpt"
                        
                        # Создание одного большого раздела
                        run_command "sudo parted -a optimal /dev/$disk mkpart primary ext4 0% 100%"
                        
                        # Использование последовательной нумерации с большой буквы, начиная с 1
                        label="NVME$nvme_count"
                        mount_point="/mnt/$label"
                        
                        echo "Форматирование $disk (метка: $label, точка монтирования: $mount_point)"
                        
                        # Форматирование в ext4
                        run_command "sudo mkfs.ext4 -L $label /dev/$disk"
                        
                        # Создание точки монтирования
                        run_command "sudo mkdir -p $mount_point"
                        
                        # Добавление записи в fstab, если её ещё нет
                        if ! grep -q "LABEL=$label" /etc/fstab; then
                            echo "LABEL=$label  $mount_point  ext4  defaults,noatime,x-gvfs-show  0 2" | sudo tee -a /etc/fstab
                        fi
                        
                        # Монтирование диска
                        run_command "sudo mount $mount_point"
                        
                        print_success "Диск /dev/$disk успешно отформатирован и примонтирован"
                        
                        # Увеличиваем счетчик для следующего диска
                        nvme_count=$((nvme_count + 1))
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
                        
                        # Преобразуем букву в номер (a->1, b->2, и т.д.) и используем большие буквы
                        hdd_letter=$(echo "$disk" | grep -o '[a-z]$')
                        hdd_index=$(printf "%d" "'$hdd_letter")
                        hdd_index=$((hdd_index - 96)) # 'a' имеет ASCII код 97, поэтому а->1, b->2 и т.д.
                        
                        label="HDD$hdd_index"
                        mount_point="/mnt/$label"
                        
                        # Форматирование в ext4
                        run_command "sudo mkfs.ext4 -L $label /dev/${disk}1"
                        
                        # Создание точки монтирования
                        run_command "sudo mkdir -p $mount_point"
                        
                        # Добавление записи в fstab, если её ещё нет
                        if ! grep -q "LABEL=$label" /etc/fstab; then
                            echo "LABEL=$label  $mount_point  ext4  defaults,noatime,x-gvfs-show  0 2" | sudo tee -a /etc/fstab
                        fi
                        
                        # Монтирование диска
                        run_command "sudo mount $mount_point"
                        
                        print_success "Диск /dev/$disk успешно отформатирован и примонтирован"
                    fi
                done
            fi
        fi
        
        print_success "Форматирование и монтирование дисков завершено"
    else
        print_warning "Пропускаем форматирование дисков из-за отсутствия необходимых пакетов"
    fi
fi

# 5. Скрытие логов при загрузке
if contains 5 "${selected_options[@]}"; then
    print_header "5. Скрытие логов при загрузке"
    
    # Проверка наличия необходимых пакетов
    if check_and_install_packages "Plymouth" "plymouth"; then
        # Создаем или обновляем параметры ядра
        run_command "sudo mkdir -p /etc/kernel/cmdline.d/"
        
        # Извлекаем текущие параметры загрузки
        current_cmdline=$(cat /proc/cmdline)
        echo "Текущие параметры загрузки: $current_cmdline"
        
        # Извлекаем критические параметры для BTRFS
        root_param=$(echo "$current_cmdline" | grep -o "root=[^ ]*" || echo "")
        rootflags=$(echo "$current_cmdline" | grep -o "rootflags=[^ ]*" || echo "")
        rootfstype=$(echo "$current_cmdline" | grep -o "rootfstype=[^ ]*" || echo "")
        
        # Параметры тихой загрузки
        quiet_params="quiet loglevel=3 rd.systemd.show_status=false rd.udev.log_level=3 vt.global_cursor_default=0 splash plymouth.enable=1"
        
        # Комбинируем критические параметры с параметрами тихой загрузки
        combined_params="$root_param $rootflags $rootfstype $quiet_params"
        
        # Создаем файл с параметрами
        cat << EOF | sudo tee /etc/kernel/cmdline.d/quiet.conf > /dev/null
$combined_params
EOF
        
        echo "Установлены параметры загрузки: $combined_params"
        
        # Отключение журналирования на tty
        run_command "sudo mkdir -p /etc/systemd/journald.conf.d/"
        cat << EOF | sudo tee /etc/systemd/journald.conf.d/quiet.conf > /dev/null
[Journal]
TTYPath=/dev/null
EOF
        
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
options $combined_params
EOF
        
        # Обновление загрузчика
        run_command "sudo bootctl update"
        
        print_success "Настройка тихой загрузки завершена"
    else
        print_warning "Пропускаем настройку тихой загрузки из-за отсутствия необходимых пакетов"
    fi
fi

# 6. Установка Paru в скрытую папку
if contains 6 "${selected_options[@]}"; then
    print_header "6. Установка Paru в скрытую папку"
    
    # Проверка необходимых пакетов
    if check_and_install_packages "Сборка пакетов" "base-devel" "git"; then
        # Проверка, установлен ли paru
        if check_command "paru"; then
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
    else
        print_warning "Пропускаем установку Paru из-за отсутствия необходимых пакетов"
    fi
fi

# 7. Настройка Flathub и GNOME Software
if contains 7 "${selected_options[@]}"; then
    print_header "7. Настройка Flathub и GNOME Software"
    
    # Проверка необходимых пакетов
    if check_and_install_packages "Flatpak" "flatpak" "gnome-software"; then
        # Добавление репозитория Flathub
        run_command "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
        
        # Определение последней доступной версии GNOME Platform
        echo "Определение последней версии GNOME Platform..."
        # Пробуем получить последнюю версию из доступных в репозитории
        latest_gnome_version=$(flatpak remote-info --log flathub org.gnome.Platform 2>/dev/null | grep -oP "Version: \K[0-9]+" | head -1)
        
        # Устанавливаем версию по умолчанию, если не удалось получить
        if [ -z "$latest_gnome_version" ]; then
            latest_gnome_version=48  # Используем актуальную версию по состоянию на март 2025
            print_warning "Не удалось определить последнюю версию GNOME Platform, используем версию $latest_gnome_version"
        else
            print_success "Определена последняя версия GNOME Platform: $latest_gnome_version"
        fi
        
        # Установка платформы GNOME последней версии
        run_command "flatpak install -y flathub org.gnome.Platform//$latest_gnome_version"
        
        print_success "Настройка Flathub и GNOME Software завершена"
    else
        print_warning "Пропускаем настройку Flathub из-за отсутствия необходимых пакетов"
    fi
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
    
    # Проверка необходимых пакетов
    steam_packages=(
        "steam" "lib32-nvidia-utils" "lib32-vulkan-icd-loader" "vulkan-icd-loader"
        "lib32-vulkan-intel" "vulkan-intel" "lib32-mesa" "vulkan-tools"
        "lib32-libva-mesa-driver" "lib32-mesa-vdpau" "libva-mesa-driver" "mesa-vdpau"
        "lib32-openal" "lib32-alsa-plugins" "xorg-mkfontscale" "xorg-fonts-cyrillic" "xorg-fonts-misc"
    )
    
    if check_and_install_packages "Steam и библиотеки" "${steam_packages[@]}"; then
        print_success "Установка Steam и необходимых библиотек завершена"
    else
        print_warning "Пропускаем установку Steam из-за отсутствия необходимых пакетов"
    fi
fi

# 9. Установка Proton GE
if contains 9 "${selected_options[@]}"; then
    print_header "9. Установка Proton GE"
    
    # Проверяем наличие пути Steam
    if [ ! -d "$HOME/.steam" ]; then
        print_warning "Не найдена директория Steam. Возможно, Steam не установлен или не запускался."
        if ! confirm "Продолжить установку Proton GE?"; then
            print_warning "Пропускаем установку Proton GE"
        else
            run_command "mkdir -p ~/.steam/root/compatibilitytools.d/"
        fi
    fi
    
    # Создание директории для Proton GE
    run_command "mkdir -p ~/.steam/root/compatibilitytools.d/"
    
    # Проверка наличия paru
    if check_command "paru"; then
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
                # Проверка наличия curl и wget
                if check_and_install_packages "Загрузка файлов" "curl" "wget"; then
                    # Ручная установка последней версии
                    print_header "Скачивание последней версии Proton GE..."
                    PROTON_VERSION=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | grep "tag_name" | cut -d'"' -f4)
                    run_command "wget -O /tmp/proton-ge.tar.gz https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${PROTON_VERSION}/GE-Proton${PROTON_VERSION:1}.tar.gz"
                    
                    print_header "Распаковка Proton GE..."
                    run_command "tar -xzf /tmp/proton-ge.tar.gz -C ~/.steam/root/compatibilitytools.d/"
                    run_command "rm /tmp/proton-ge.tar.gz"
                else
                    print_warning "Пропускаем ручную установку Proton GE из-за отсутствия необходимых пакетов"
                fi
            fi
        fi
    else
        print_warning "Paru не установлен. Невозможно установить Proton GE из AUR. Рекомендуется сначала выполнить шаг 6."
        # Предлагаем ручную установку
        if check_and_install_packages "Загрузка файлов" "curl" "wget"; then
            if confirm "Установить Proton GE вручную?"; then
                print_header "Скачивание последней версии Proton GE..."
                PROTON_VERSION=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | grep "tag_name" | cut -d'"' -f4)
                run_command "wget -O /tmp/proton-ge.tar.gz https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${PROTON_VERSION}/GE-Proton${PROTON_VERSION:1}.tar.gz"
                
                print_header "Распаковка Proton GE..."
                run_command "tar -xzf /tmp/proton-ge.tar.gz -C ~/.steam/root/compatibilitytools.d/"
                run_command "rm /tmp/proton-ge.tar.gz"
            fi
        else
            print_warning "Пропускаем установку Proton GE из-за отсутствия необходимых пакетов"
        fi
    fi
    
    print_success "Установка Proton GE завершена"
fi

# 10. Оптимизация для Wayland
if contains 10 "${selected_options[@]}"; then
    print_header "10. Оптимизация для Wayland"
    
    # Проверка необходимых пакетов
    if check_and_install_packages "Wayland" "qt6-wayland" "qt5-wayland" "xorg-xwayland"; then
        # Добавляем переменные окружения для Wayland и NVIDIA (безопасная конфигурация)
        cat << EOF | sudo tee -a /etc/environment > /dev/null
# Настройки Wayland и NVIDIA
LIBVA_DRIVER_NAME=nvidia
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
MOZ_ENABLE_WAYLAND=1
MOZ_WEBRENDER=1
QT_QPA_PLATFORM=wayland
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
EOF

        # Настройка egl-wayland для NVIDIA (необходимо для корректной работы)
        run_command "sudo pacman -S --needed --noconfirm egl-wayland"
        
        # Создание конфигурации для GDM
        run_command "sudo mkdir -p /etc/gdm"
        if [ ! -f /etc/gdm/custom.conf ]; then
            cat << EOF | sudo tee /etc/gdm/custom.conf > /dev/null
# GDM configuration
[daemon]
# Automatically enable Wayland
WaylandEnable=true

[security]

[xdmcp]

[chooser]

[debug]
EOF
        fi
        
        print_success "Оптимизация для Wayland завершена"
    else
        print_warning "Пропускаем оптимизацию для Wayland из-за отсутствия необходимых пакетов"
    fi
fi

# 11. Настройка управления питанием
if contains 11 "${selected_options[@]}"; then
    print_header "11. Настройка управления питанием"
    
    # Проверка необходимых пакетов
    if check_and_install_packages "Управление питанием" "power-profiles-daemon" "hdparm"; then
        # Активация power-profiles-daemon
        run_command "sudo systemctl enable power-profiles-daemon.service"
        run_command "sudo systemctl start power-profiles-daemon.service"
        
        # Создание правил для перевода HDD в спящий режим
        cat << EOF | sudo tee /etc/udev/rules.d/69-hdparm.rules > /dev/null
# Правила для перевода HDD в спящий режим при простое
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", RUN+="/usr/bin/hdparm -B 127 -S 120 /dev/%k"
EOF
        
        # Применяем правила к текущим устройствам
        for disk in /dev/sd?; do
            if [ -b "$disk" ]; then
                print_header "Применение настроек энергосбережения для $disk"
                run_command "sudo hdparm -B 127 -S 120 $disk"
            fi
        done
        
        print_success "Настройка автоматического перехода HDD в спящий режим завершена"
        
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
    else
        print_warning "Пропускаем настройку управления питанием из-за отсутствия необходимых пакетов"
    fi
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
    if check_and_install_packages "Безопасность" "ufw"; then
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
    else
        print_warning "Пропускаем настройку файрвола из-за отсутствия необходимых пакетов"
    fi
    
    print_success "Настройка локализации и безопасности завершена"
fi

# 13. Установка дополнительных программ
if contains 13 "${selected_options[@]}"; then
    print_header "13. Установка дополнительных программ"
    
    # Проверка необходимых пакетов
    utils=("htop" "neofetch" "bat" "exa" "ripgrep" "fd")
    if check_and_install_packages "Утилиты командной строки" "${utils[@]}"; then
        print_success "Установка утилит командной строки завершена"
    fi
    
    # Настройка gnome-keyring
    if check_and_install_packages "Хранение паролей" "gnome-keyring" "seahorse"; then
        # Добавление настроек gnome-keyring в bash_profile
        if ! grep -q "gnome-keyring-daemon" ~/.bash_profile; then
            echo "eval \$(gnome-keyring-daemon --start)" >> ~/.bash_profile
            echo "export SSH_AUTH_SOCK" >> ~/.bash_profile
            print_success "Настройки gnome-keyring добавлены в bash_profile"
        fi
    else
        print_warning "Пропускаем настройку gnome-keyring из-за отсутствия необходимых пакетов"
    fi
    
    print_success "Установка дополнительных программ завершена"
fi

# 14. Установка Timeshift для резервного копирования
if contains 14 "${selected_options[@]}"; then
    print_header "14. Установка Timeshift для резервного копирования"
    
    # Проверка необходимых пакетов
    if check_and_install_packages "Резервное копирование" "timeshift"; then
        # Базовая настройка Timeshift
        if [ -d "$HOME/.config/timeshift" ]; then
            print_warning "Конфигурация Timeshift уже существует"
            print_warning "Запустите 'sudo timeshift-gtk' для ручной настройки"
        else
            print_warning "После установки рекомендуется запустить 'sudo timeshift-gtk' для настройки"
            print_warning "Для BTRFS выберите тип снапшотов 'BTRFS'"
        fi
    else
        print_warning "Пропускаем установку Timeshift из-за отсутствия необходимых пакетов"
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
