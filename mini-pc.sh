#!/bin/bash

# mini-pc-arch-setup.sh - Скрипт настройки Arch Linux для мини-ПК
# Разработан для: Intel Celeron N5095, 16 ГБ ОЗУ, SATA3 SSD (btrfs) + SATA3 SSD 2ТБ
# Версия: 1.0 (Март 2025)

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
echo "Системный диск: $ROOT_DEVICE"

echo "Смонтированные диски:"
findmnt -t btrfs,ext4,vfat -no SOURCE,TARGET,FSTYPE,OPTIONS | grep -v "zram"

echo "BTRFS подтома:"
sudo btrfs subvolume list / || echo "Не удалось получить список подтомов"

echo "Все доступные блочные устройства:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE

# Проверка, установлена ли система с использованием systemd-boot
if [ ! -d "/boot/loader" ]; then
    print_warning "Не найдена директория /boot/loader. Возможно, systemd-boot не используется."
    if ! confirm "Продолжить выполнение скрипта?"; then
        exit 1
    fi
fi

# Проверка, используется ли основное ядро linux или linux-zen
if [ ! -f "/boot/vmlinuz-linux" ] && [ ! -f "/boot/vmlinuz-linux-zen" ]; then
    print_warning "Не найдено стандартное ядро linux или linux-zen. Скрипт настроен для стандартного ядра."
    if ! confirm "Продолжить выполнение скрипта?"; then
        exit 1
    fi
fi

# Определение используемого ядра для последующих операций
if [ -f "/boot/vmlinuz-linux-zen" ]; then
    KERNEL_NAME="linux-zen"
else
    KERNEL_NAME="linux"
fi
echo "Используемое ядро: $KERNEL_NAME"

# Меню для выбора операций
while true; do
    print_header "Выберите операцию для выполнения"
    echo "1. Обновление системы и базовая настройка"
    echo "2. Настройка Intel графики для Wayland"
    echo "3. Оптимизация SSD и настройка BTRFS"
    echo "4. Форматирование и монтирование второго SSD (2ТБ)"
    echo "5. Настройка ZRAM"
    echo "6. Скрытие логов при загрузке"
    echo "7. Установка Paru в скрытую папку"
    echo "8. Настройка Flathub и GNOME Software"
    echo "9. Настройка управления питанием"
    echo "10. Настройка локализации и безопасности"
    echo "11. Установка дополнительных программ"
    echo "12. Установка Timeshift для резервного копирования"
    echo "13. Настройка современного аудио-стека (PipeWire)"
    echo "14. Оптимизация памяти и производительности"
    echo "15. Настройка функциональных клавиш (F1-F12)"
    echo "0. Выход"
    
    read -p "Введите номер операции: " choice
    
    case $choice in
        0)
            echo "Выход из скрипта."
            exit 0
            ;;
        1)
            # 1. Обновление системы и базовая настройка
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
            ;;
        2)
            # 2. Настройка Intel графики для Wayland
            print_header "2. Настройка Intel графики для Wayland"
            
            # Проверка необходимых пакетов
            if check_and_install_packages "Intel графика" "mesa" "intel-media-driver" "vulkan-intel" "libva-intel-driver"; then
                # Оптимизация для Intel графики
                cat << EOF | sudo tee /etc/modprobe.d/i915.conf > /dev/null
# Оптимизация для Intel графики
options i915 enable_fbc=1 enable_guc=2 enable_dc=4
EOF
                
                # Добавление модуля i915 в initramfs
                run_command "sudo mkdir -p /etc/mkinitcpio.conf.d/"
                echo "MODULES=(i915)" | sudo tee /etc/mkinitcpio.conf.d/i915.conf > /dev/null
                print_success "Настройка модулей i915 для Intel графики завершена"
                
                # Перестроение initramfs
                run_command "sudo mkinitcpio -P"
                
                # Настройка для Wayland
                if check_and_install_packages "Wayland" "qt6-wayland" "qt5-wayland" "xorg-xwayland"; then
                    # Добавляем минимальные переменные окружения для Wayland
                    cat << EOF | sudo tee /etc/environment > /dev/null
# Настройки Wayland для Intel графики
LIBVA_DRIVER_NAME=iHD
MOZ_ENABLE_WAYLAND=1
QT_QPA_PLATFORM=wayland
EOF
                    print_success "Переменные окружения для Wayland настроены"
                    
                    # Настройка GDM для Wayland
                    run_command "sudo mkdir -p /etc/gdm"
                    cat << EOF | sudo tee /etc/gdm/custom.conf > /dev/null
[daemon]
WaylandEnable=true

[security]

[xdmcp]

[chooser]

[debug]
EOF
                    print_success "GDM настроен для использования Wayland"
                fi
                
                print_success "Настройка Intel графики для Wayland завершена"
            else
                print_warning "Пропускаем настройку Intel графики из-за отсутствия необходимых пакетов"
            fi
            ;;
        3)
            # 3. Оптимизация SSD и настройка BTRFS
            print_header "3. Оптимизация SSD и настройка BTRFS"
            
            # Проверка наличия необходимых утилит
            if check_and_install_packages "Утилиты SSD и BTRFS" "btrfs-progs" "hdparm" "smartmontools"; then
                # Включение TRIM для SSD
                run_command "sudo systemctl enable fstrim.timer"
                run_command "sudo systemctl start fstrim.timer"
                
                # Настройка монтирования для BTRFS
                echo "Текущие опции монтирования root:"
                findmnt -no OPTIONS / | tr , '\n'
                
                if confirm "Оптимизировать опции монтирования BTRFS для SSD?"; then
                    # Получаем UUID корневого раздела
                    ROOT_UUID=$(sudo blkid -s UUID -o value $ROOT_DEVICE)
                    
                    # Определяем текущий корневой subvolume
                    ROOT_SUBVOL=$(findmnt -no OPTIONS / | tr , '\n' | grep subvol= | cut -d= -f2)
                    
                    # Резервная копия fstab
                    run_command "sudo cp /etc/fstab /etc/fstab.backup"
                    
                    # Обновляем опции монтирования с оптимизацией для SSD
                    run_command "sudo sed -i '/ \/ /s/defaults/defaults,noatime,compress=zstd:1,space_cache=v2,discard=async/' /etc/fstab"
                    
                    echo "Обновленные опции монтирования в /etc/fstab:"
                    grep " / " /etc/fstab
                    
                    print_success "Опции монтирования BTRFS оптимизированы для SSD"
                fi
                
                # Настройка кэша метаданных BTRFS
                cat << EOF | sudo tee /etc/sysctl.d/60-btrfs-performance.conf > /dev/null
# Увеличение лимита кэша метаданных для BTRFS
vm.dirty_bytes = 4294967296
vm.dirty_background_bytes = 1073741824
EOF
                
                run_command "sudo sysctl --system"
                
                print_success "Оптимизация SSD и BTRFS завершена"
            else
                print_warning "Пропускаем оптимизацию SSD и BTRFS из-за отсутствия необходимых пакетов"
            fi
            ;;
        4)
            # 4. Форматирование и монтирование второго SSD (2ТБ)
            print_header "4. Форматирование и монтирование второго SSD (2ТБ)"
            
            # Проверка наличия необходимых пакетов
            if check_and_install_packages "Форматирование дисков" "parted" "e2fsprogs" "gvfs" "btrfs-progs"; then
                # Предупреждение
                print_warning "ВНИМАНИЕ! Эта операция необратимо уничтожит все данные на выбранном диске!"
                echo "Состояние дисков в системе:"
                lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE
                
                # Получение корневого диска для исключения из списка
                ROOT_DISK=$(echo $ROOT_DEVICE | grep -o '^/dev/[a-z0-9]*')
                
                # Получение списка доступных дисков, исключая корневой
                available_disks=$(lsblk -lno NAME,SIZE,TYPE | grep "disk" | grep -v "$(basename $ROOT_DISK)" | awk '{print "/dev/"$1" ("$2")"}')
                
                if [ -z "$available_disks" ]; then
                    print_warning "Дополнительные диски не найдены"
                    continue
                fi
                
                echo "Найдены следующие диски для форматирования:"
                echo "$available_disks"
                
                read -p "Введите путь к диску для форматирования (например, /dev/sdb): " second_disk
                
                if [ ! -b "$second_disk" ]; then
                    print_error "Устройство $second_disk не найдено или не является блочным устройством"
                    continue
                fi
                
                if [ "$second_disk" = "$ROOT_DISK" ]; then
                    print_error "Нельзя форматировать системный диск!"
                    continue
                fi
                
                if confirm "Форматировать $second_disk в BTRFS?"; then
                    # Проверяем, смонтирован ли диск
                    if grep -q "$second_disk" /proc/mounts; then
                        print_warning "Диск $second_disk смонтирован. Размонтируем его."
                        run_command "sudo umount ${second_disk}*"
                    fi
                    
                    # Создание GPT таблицы разделов
                    run_command "sudo parted $second_disk mklabel gpt"
                    
                    # Создание одного большого раздела
                    run_command "sudo parted -a optimal $second_disk mkpart primary btrfs 0% 100%"
                    
                    # Определяем созданный раздел
                    sleep 1
                    new_partition="${second_disk}1"
                    if [[ "$second_disk" == *"nvme"* ]]; then
                        new_partition="${second_disk}p1"
                    fi
                    
                    # Форматирование в BTRFS
                    run_command "sudo mkfs.btrfs -L DATA $new_partition"
                    
                    # Создание точки монтирования
                    mount_point="/mnt/data"
                    run_command "sudo mkdir -p $mount_point"
                    
                    # Временное монтирование
                    run_command "sudo mount $new_partition $mount_point"
                    
                    # Создание подтомов
                    run_command "sudo btrfs subvolume create $mount_point/@data"
                    run_command "sudo btrfs subvolume create $mount_point/@downloads"
                    run_command "sudo btrfs subvolume create $mount_point/@media"
                    
                    # Размонтирование
                    run_command "sudo umount $mount_point"
                    
                    # Добавление записей в fstab для подтомов
                    DATA_UUID=$(sudo blkid -s UUID -o value $new_partition)
                    
                    # Добавление записей в fstab, если их еще нет
                    if ! grep -q "UUID=$DATA_UUID" /etc/fstab; then
                        echo "# Второй SSD - DATA" | sudo tee -a /etc/fstab
                        echo "UUID=$DATA_UUID  $mount_point  btrfs  defaults,noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@data  0 0" | sudo tee -a /etc/fstab
                        echo "UUID=$DATA_UUID  /home/\$(whoami)/Downloads  btrfs  defaults,noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@downloads  0 0" | sudo tee -a /etc/fstab
                        echo "UUID=$DATA_UUID  /home/\$(whoami)/Media  btrfs  defaults,noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@media  0 0" | sudo tee -a /etc/fstab
                    fi
                    
                    # Создание директорий для монтирования подтомов
                    run_command "mkdir -p ~/Downloads ~/Media"
                    
                    # Монтирование всех точек
                    run_command "sudo mount -a"
                    
                    print_success "Диск $second_disk успешно отформатирован с подтомами BTRFS и примонтирован"
                fi
            else
                print_warning "Пропускаем форматирование диска из-за отсутствия необходимых пакетов"
            fi
            ;;
        5)
            # 5. Настройка ZRAM
            print_header "5. Настройка ZRAM"
            
            # Обнаружение ZRAM
            if lsmod | grep -q zram || [ -e "/dev/zram0" ]; then
                print_success "ZRAM уже настроен в системе. Проверка конфигурации..."
                if [ -f "/etc/systemd/zram-generator.conf" ]; then
                    echo "Содержимое /etc/systemd/zram-generator.conf:"
                    cat /etc/systemd/zram-generator.conf
                fi
            else
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
            ;;
        6)
            # 6. Скрытие логов при загрузке
            print_header "6. Скрытие логов при загрузке"
            
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
                echo "$combined_params" | sudo tee /etc/kernel/cmdline.d/quiet.conf > /dev/null
                print_success "Параметры загрузки установлены: $combined_params"
                
                # Отключение журналирования на tty
                run_command "sudo mkdir -p /etc/systemd/journald.conf.d/"
                cat << EOF | sudo tee /etc/systemd/journald.conf.d/quiet.conf > /dev/null
[Journal]
TTYPath=/dev/null
EOF
                
                # Добавление plymouth в HOOKS
                if ! grep -q "plymouth" /etc/mkinitcpio.conf; then
                    run_command "sudo sed -i 's/^HOOKS=.*/HOOKS=(base udev plymouth autodetect modconf keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf"
                else
                    print_success "Plymouth уже добавлен в HOOKS mkinitcpio.conf"
                fi
                
                # Перестроение initramfs
                run_command "sudo mkinitcpio -P"
                
                # Настройка systemd-boot
                run_command "sudo mkdir -p /boot/loader/"
                
                # Создание конфигурации systemd-boot
                cat << EOF | sudo tee /boot/loader/loader.conf > /dev/null
default arch.conf
timeout 0
console-mode max
editor no
EOF
                
                # Создание загрузочной записи
                run_command "sudo mkdir -p /boot/loader/entries/"
                cat << EOF | sudo tee /boot/loader/entries/arch.conf > /dev/null
title Arch Linux
linux /vmlinuz-$KERNEL_NAME
initrd /intel-ucode.img
initrd /initramfs-$KERNEL_NAME.img
options $(cat /etc/kernel/cmdline.d/quiet.conf)
EOF
                
                # Обновление загрузчика
                run_command "sudo bootctl update"
                
                print_success "Настройка тихой загрузки завершена"
            else
                print_warning "Пропускаем настройку тихой загрузки из-за отсутствия необходимых пакетов"
            fi
            ;;
        7)
            # 7. Установка Paru в скрытую папку
            print_header "7. Установка Paru в скрытую папку"
            
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
            ;;
        8)
            # 8. Настройка Flathub и GNOME Software
            print_header "8. Настройка Flathub и GNOME Software"
            
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
            ;;
        9)
            # 9. Настройка управления питанием
            print_header "9. Настройка управления питанием"
            
            # Проверка необходимых пакетов
            if check_and_install_packages "Управление питанием" "power-profiles-daemon" "thermald" "tlp"; then
                # Активация необходимых служб
                run_command "sudo systemctl enable power-profiles-daemon.service"
                run_command "sudo systemctl start power-profiles-daemon.service"
                
                # Thermald для управления температурой
                run_command "sudo systemctl enable thermald"
                run_command "sudo systemctl start thermald"
                
                # Настройка TLP для мобильных устройств
                cat << EOF | sudo tee /etc/tlp.conf.d/01-custom.conf > /dev/null
# TLP настройки для энергоэффективности
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave

CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power

PLATFORM_PROFILE_ON_AC=performance
PLATFORM_PROFILE_ON_BAT=low-power

PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave
EOF
                
                run_command "sudo systemctl enable tlp.service"
                run_command "sudo systemctl start tlp.service"
                
                # Настройка swappiness для оптимизации использования ОЗУ
                cat << EOF | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null
vm.swappiness=10
EOF
                
                run_command "sudo sysctl vm.swappiness=10"
                
                print_success "Настройка управления питанием завершена"
            else
                print_warning "Пропускаем настройку управления питанием из-за отсутствия необходимых пакетов"
            fi
            ;;
        10)
            # 10. Настройка локализации и безопасности
            print_header "10. Настройка локализации и безопасности"
            
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
            ;;
        11)
            # 11. Установка дополнительных программ
            print_header "11. Установка дополнительных программ"
            
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
            ;;
        12)
            # 12. Установка Timeshift для резервного копирования
            print_header "12. Установка Timeshift для резервного копирования"
            
            # Проверка необходимых пакетов
            if check_and_install_packages "Резервное копирование" "timeshift"; then
                # Базовая настройка Timeshift для BTRFS
                if [ -d "$HOME/.config/timeshift" ]; then
                    print_warning "Конфигурация Timeshift уже существует"
                    print_warning "Запустите 'sudo timeshift-gtk' для ручной настройки"
                else
                    print_warning "После установки рекомендуется запустить 'sudo timeshift-gtk' для настройки"
                    print_warning "Выберите тип снапшотов 'BTRFS'"
                    run_command "sudo timeshift --btrfs"
                fi
            else
                print_warning "Пропускаем установку Timeshift из-за отсутствия необходимых пакетов"
            fi
            
            print_success "Установка Timeshift завершена"
            ;;
        13)
            # 13. Настройка современного аудио-стека (PipeWire)
            print_header "13. Настройка современного аудио-стека (PipeWire)"
            
            # Проверка необходимых пакетов
            audio_packages=("pipewire" "pipewire-alsa" "pipewire-pulse" "pipewire-jack" "wireplumber" "gst-plugin-pipewire")
            if check_and_install_packages "Аудио" "${audio_packages[@]}"; then
                # Остановка PulseAudio, если запущен
                systemctl --user stop pulseaudio.socket pulseaudio.service || true
                systemctl --user disable pulseaudio.socket pulseaudio.service || true
                
                # Включение сервиса и установка как замены PulseAudio
                run_command "systemctl --user enable pipewire pipewire-pulse wireplumber"
                run_command "systemctl --user start pipewire pipewire-pulse wireplumber"
                
                # Оптимизация для профессионального аудио
                mkdir -p ~/.config/pipewire/pipewire.conf.d
                cat << EOF > ~/.config/pipewire/pipewire.conf.d/10-lowlatency.conf
context.properties = {
  default.clock.rate = 48000
  default.clock.allowed-rates = [ 44100 48000 88200 96000 192000 ]
  default.clock.quantum = 256
  default.clock.min-quantum = 32
  default.clock.max-quantum = 8192
}
EOF
                print_success "Настройка PipeWire завершена"
            else
                print_warning "Пропускаем настройку PipeWire из-за отсутствия необходимых пакетов"
            fi
            ;;
        14)
            # 14. Оптимизация памяти и производительности
            print_header "14. Оптимизация памяти и производительности"
            
            cat << EOF | sudo tee /etc/sysctl.d/99-performance.conf > /dev/null
# Уменьшение задержки обмена данными для улучшения отзывчивости системы
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5

# Увеличение лимитов для файловых дескрипторов
fs.file-max = 100000

# Оптимизация файловой системы
fs.inotify.max_user_watches = 524288

# Оптимизация сети
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_fastopen = 3
EOF

            run_command "sudo sysctl --system"
            
            # Оптимизация сервисов systemd
            if [ -d "/etc/systemd" ]; then
                cat << EOF | sudo tee /etc/systemd/system.conf.d/timeout.conf > /dev/null
[Manager]
DefaultTimeoutStartSec=15s
DefaultTimeoutStopSec=15s
EOF
                
                cat << EOF | sudo tee /etc/systemd/system.conf.d/memory.conf > /dev/null
[Manager]
DefaultMemoryAccounting=yes
DefaultTasksAccounting=yes
EOF
                
                run_command "sudo systemctl daemon-reload"
            fi
            
            # Отключение неиспользуемых служб
            unused_services=("bluetooth.service" "avahi-daemon.service" "cups.service")
            
            for service in "${unused_services[@]}"; do
                if systemctl is-enabled --quiet "$service" 2>/dev/null; then
                    if confirm "Отключить $service?"; then
                        run_command "sudo systemctl disable $service"
                        run_command "sudo systemctl stop $service"
                    fi
                fi
            done
            
            print_success "Оптимизация производительности завершена"
            ;;
        15)
            # 15. Настройка функциональных клавиш (F1-F12)
            print_header "15. Настройка функциональных клавиш (F1-F12)"
            
            # Системная настройка на уровне ядра
            grep -q "fnmode=2" /etc/modprobe.d/hid_apple.conf 2>/dev/null || { 
                echo "Настройка драйвера клавиатуры..."; 
                echo "options hid_apple fnmode=2" | sudo tee /etc/modprobe.d/hid_apple.conf > /dev/null && 
                sudo mkinitcpio -P && 
                echo "Настройка драйвера клавиатуры завершена"; 
            }
            
            # Также добавим параметр загрузки ядра (для более широкой совместимости)
            if ! grep -q "hid_apple.fnmode=2" /etc/kernel/cmdline.d/keyboard.conf 2>/dev/null; then
                echo "hid_apple.fnmode=2" | sudo tee /etc/kernel/cmdline.d/keyboard.conf > /dev/null
                # Обновление загрузчика
                run_command "sudo bootctl update"
            fi
            
            print_success "Настройка функциональных клавиш завершена"
            print_warning "Изменения вступят в силу после перезагрузки"
            
            # Инструкция для пользователя как временно переключаться
            echo "Примечание: Для временного переключения между функциональными и мультимедийными клавишами"
            echo "вы можете использовать комбинацию Fn+Esc (на большинстве клавиатур) или Fn+F1-F12 для"
            echo "доступа к мультимедийным функциям."
            ;;
        *)
            print_warning "Некорректный выбор. Пожалуйста, введите число от 0 до 15."
            ;;
    esac
    
    # Пауза перед возвратом в меню
    echo ""
    read -p "Нажмите Enter, чтобы продолжить..."
done
