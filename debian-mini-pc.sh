#!/usr/bin/env bash
# Скрипт оптимизации Debian 12/13 для мини-ПК (домашний сервер)
# Цель: безопасная и повторяемая настройка headless-сервера c упором на SSD, энергоэффективность и базовую безопасность

set -Eeuo pipefail
# Гарантируем наличие системных путей для утилит администрирования (usermod, etc.)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# -------- Проверки окружения --------
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен быть запущен с правами root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}

if [ -r /etc/os-release ]; then
  . /etc/os-release
else
  echo "Не удалось определить версию операционной системы" >&2
  exit 1
fi

if [ "${ID}" != "debian" ]; then
  echo "Этот скрипт предназначен для Debian 12 (Bookworm) и Debian 13 (Trixie)" >&2
  exit 1
fi

DEBIAN_VERSION_MAJOR="${VERSION_ID%%.*}"
case "${DEBIAN_VERSION_MAJOR}" in
  12) DEBIAN_CODENAME="${VERSION_CODENAME:-bookworm}" ;;
  13) DEBIAN_CODENAME="${VERSION_CODENAME:-trixie}" ;;
  *)  echo "Поддерживаются только Debian 12/13" >&2; exit 1 ;;
esac

DEBIAN_CODENAME_TITLE="${DEBIAN_CODENAME^}"
DEBIAN_VERSION_HUMAN="Debian ${DEBIAN_VERSION_MAJOR} (${DEBIAN_CODENAME_TITLE})"

# -------- Вывод --------
blue()  { printf "\033[0;34m%s\033[0m\n" "$*"; }
green() { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[0;33m%s\033[0m\n" "$*"; }
red()   { printf "\033[0;31m%s\033[0m\n" "$*"; }
step()  { echo; printf "\033[1;32m>>> %s\033[0m\n" "$*"; }
# Определение уровня x86-64 (точно по логике официального скрипта check_x86-64_psabi.sh)
psabi_level() {
  awk '
    BEGIN {
      level = 0
      while ((getline < "/proc/cpuinfo") > 0) {
        if ($0 ~ /flags/) { flags = $0; break }
      }
      if (flags ~ /lm/ && flags ~ /cmov/ && flags ~ /cx8/ && flags ~ /fpu/ && flags ~ /fxsr/ && flags ~ /mmx/ && flags ~ /syscall/ && flags ~ /sse2/) level = 1
      if (level == 1 && flags ~ /cx16/ && flags ~ /lahf/ && flags ~ /popcnt/ && flags ~ /sse4_1/ && flags ~ /sse4_2/ && flags ~ /ssse3/) level = 2
      if (level == 2 && flags ~ /avx/ && flags ~ /avx2/ && flags ~ /bmi1/ && flags ~ /bmi2/ && flags ~ /f16c/ && flags ~ /fma/ && flags ~ /abm/ && flags ~ /movbe/ && flags ~ /xsave/) level = 3
      if (level == 3 && flags ~ /avx512f/ && flags ~ /avx512bw/ && flags ~ /avx512cd/ && flags ~ /avx512dq/ && flags ~ /avx512vl/) level = 4
      if (level > 0) { printf("v%d\n", level); exit 0 }
      print "v1"; exit 0
    }
  '
}
# Безопасная смена пароля (скрытый ввод, с подтверждением)
set_user_password_interactive() {
  local user="$1" pw1 pw2 tries=0
  while [ $tries -lt 3 ]; do
    tries=$((tries+1))
    printf "Новый пароль: "
    read -rs pw1; echo
    printf "Повторите пароль: "
    read -rs pw2; echo
    if [ -z "$pw1" ]; then
      yellow "Пустой пароль не допускается."
      continue
    fi
    if [ "$pw1" = "$pw2" ]; then
      if echo "$user:$pw1" | chpasswd 2>/dev/null; then
        green "Пароль для пользователя $user обновлён."
        return 0
      else
        red "Не удалось обновить пароль. Попробуйте снова."
      fi
    else
      yellow "Пароли не совпадают. Попробуйте снова."
    fi
  done
  red "Превышено число попыток смены пароля."
  return 1
}
# Тихая подсказка серым цветом
hint()  { printf "\033[0;90m    — %s\033[0m\n" "$*"; }
thin()  { printf "\033[0;90m----------------------------------------\033[0m\n"; }

is_installed() { dpkg -l 2>/dev/null | awk '{print $1,$2}' | grep -q "^ii ${1}$"; }

# Безопасный запуск apt install
ensure_pkg() {
  local pkgs=("$@")
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

# -------- Переменные (интерактив/неинтерактив) --------
NONINTERACTIVE=${NONINTERACTIVE:-false}

UPDATE_SYSTEM=${UPDATE_SYSTEM:-false}
INSTALL_BASE_UTILS=${INSTALL_BASE_UTILS:-false}
SETUP_TIMEZONE=${SETUP_TIMEZONE:-false}
TIMEZONE=${TIMEZONE:-""}
SETUP_LOCALES=${SETUP_LOCALES:-false}
LOCALE_DEFAULT=${LOCALE_DEFAULT:-""}
SETUP_NTP=${SETUP_NTP:-false}

CHANGE_HOSTNAME=${CHANGE_HOSTNAME:-false}
NEW_HOSTNAME=${NEW_HOSTNAME:-""}
CREATE_USER=${CREATE_USER:-false}
NEW_USERNAME=${NEW_USERNAME:-""}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-""}

SETUP_BBR=${SETUP_BBR:-false}
SETUP_FIREWALL=${SETUP_FIREWALL:-false}
SETUP_ZRAM=${SETUP_ZRAM:-false}
SETUP_SSD=${SETUP_SSD:-false}           # TRIM, планировщик I/O
SETUP_CPU_GOVERNOR=${SETUP_CPU_GOVERNOR:-false}
CPU_GOVERNOR=${CPU_GOVERNOR:-"schedutil"} # варианты: performance|schedutil|powersave

SETUP_LOGROTATE=${SETUP_LOGROTATE:-false}
SETUP_AUTO_UPDATES=${SETUP_AUTO_UPDATES:-false}
INSTALL_MONITORING=${INSTALL_MONITORING:-false}
INSTALL_DOCKER=${INSTALL_DOCKER:-false}
SECURE_SSH=${SECURE_SSH:-false}
SETUP_SSH=${SETUP_SSH:-false}
SETUP_FAIL2BAN=${SETUP_FAIL2BAN:-false}
OPTIMIZE_SYSTEM=${OPTIMIZE_SYSTEM:-false}
SETUP_SWAP=${SETUP_SWAP:-false}
INSTALL_FISH=${INSTALL_FISH:-false}
INSTALL_XANMOD=${INSTALL_XANMOD:-false}

# Служебные переменные для XanMod
xanmod_installed=false
xanmod_installed_version=""
kernel_variant=""

AUTO_REBOOT=${AUTO_REBOOT:-false}

SYSTEM_LOCALE_DEFAULT="$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}' | tail -n1)"
if [ -z "$SYSTEM_LOCALE_DEFAULT" ] || [ "$SYSTEM_LOCALE_DEFAULT" = "C" ] || [ "$SYSTEM_LOCALE_DEFAULT" = "POSIX" ]; then
  SYSTEM_LOCALE_DEFAULT="en_US.UTF-8"
fi

locale_exists() {
  local candidate input="$1"
  [ -z "$input" ] && return 1
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

escape_sed_pattern() { printf '%s' "$1" | sed 's/[.[\*^$(){}?+|\\/-]/\\&/g'; }

ensure_locale() {
  local locale_name="$1" charset="${2:-UTF-8}" escaped
  [ -z "$locale_name" ] && return 1
  locale_exists "$locale_name" && return 0
  [ -f /etc/locale.gen ] || return 1
  escaped="$(escape_sed_pattern "$locale_name")"
  if grep -iq "^#? *${escaped}[[:space:]]" /etc/locale.gen; then
    sed -i -E "s/^# *${escaped}[[:space:]]+/${locale_name} /I" /etc/locale.gen
  else
    printf '%s %s\n' "$locale_name" "$charset" >> /etc/locale.gen
  fi
  locale-gen "$locale_name" >/dev/null 2>&1 || return 1
  locale_exists "$locale_name"
}

# -------- Меню выбора компонентов --------
prompt_yn() {
  local prompt="$1" default_yes=${2:-false} ans
  if $default_yes; then
    read -r -p " - $prompt [Y/n]: " ans || ans=""
    case "$ans" in n|N) return 1;; *) return 0;; esac
  else
    read -r -p " - $prompt [y/N]: " ans || ans=""
    case "$ans" in y|Y) return 0;; *) return 1;; esac
  fi
}

select_option() {
  local option="$1" var_name="$2" already="$3"
  if [ "$already" = true ]; then
    green "✓ $option (уже настроено)"; return 0
  fi
  if [ "${!var_name}" = true ]; then
    if prompt_yn "$option" true; then eval "$var_name=true"; green "  ✓ Выбрано"; else eval "$var_name=false"; echo "  ○ Пропущено"; fi
  else
    if prompt_yn "$option" false; then eval "$var_name=true"; green "  ✓ Выбрано"; else eval "$var_name=false"; echo "  ○ Пропущено"; fi
  fi
}

interactive_menu() {
  clear
  blue "╔═════════════════════════════════════════╗"
  printf "\033[0;34m║ %-37s ║\033[0m\n" "НАСТРОЙКА: ${DEBIAN_VERSION_HUMAN}"
  blue "╚═════════════════════════════════════════╝"
  echo

  # Визуальный разделитель для групп меню
  group() {
    echo
    printf "\033[0;34m════════ %s ════════\033[0m\n" "$*"
  }

  # Системные обновления недавние?
  local apt_update_time current_time time_diff sys_updated=false
  apt_update_time=$(stat -c %Y /var/cache/apt/pkgcache.bin 2>/dev/null || echo 0)
  current_time=$(date +%s)
  time_diff=$((current_time - apt_update_time))
  if [ $time_diff -lt 86400 ]; then
    sys_updated=true
    green "✓ Обновление системы (выполнено < 24ч назад)"
  else
    select_option "Обновление системы" "UPDATE_SYSTEM" "$sys_updated"
  fi

  # Базовые утилиты
  group "Базовые утилиты"
  local base_utils_installed=true util
  for util in curl wget htop git nano mc smartmontools lm-sensors; do
    if ! is_installed "$util"; then base_utils_installed=false; break; fi
  done
  if $base_utils_installed; then
    green "✓ Базовые утилиты (уже установлены)"
  else
    select_option "Базовые утилиты" "INSTALL_BASE_UTILS" "$base_utils_installed"
  fi

  # Пользователи и hostname — сразу после базовых утилит
  group "Пользователи и Hostname"
  echo "  Текущий hostname: $(hostname)"
  select_option "Изменить hostname" "CHANGE_HOSTNAME" false
  select_option "Создать пользователя с sudo" "CREATE_USER" false
  # Fish целесообразно выбирать рядом с пользователем
  hint "fish + Fisher + Starship + плагины"
  select_option "Установка и настройка fish shell (Fisher, Starship, fzf)" "INSTALL_FISH" false

  # Часовой пояс, локали, NTP
  group "Локали и Время"
  echo "  Текущий часовой пояс: $(timedatectl show --property=Timezone --value || true)"
  select_option "Настройка часового пояса" "SETUP_TIMEZONE" false
  select_option "Настройка локалей (включая ru_RU.UTF-8)" "SETUP_LOCALES" false
  if systemctl is-active --quiet systemd-timesyncd; then
    green "✓ NTP синхронизация (уже настроено)"
  else
    select_option "NTP синхронизация (systemd-timesyncd)" "SETUP_NTP" false
  fi

  # Сеть и безопасность
  group "Сеть и Безопасность"
  if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '')" = "bbr" ]; then
    green "✓ TCP BBR (уже включен)"
  else
    hint "рекомендуется для серверов/P2P; снижает задержки"
    select_option "Включить TCP BBR + fq (сетевые оптимизации)" "SETUP_BBR" false
  fi
  # SSH: базовая настройка (secure.conf; пароль разрешён)
  # Базовый SSH secure.conf уже присутствует?
  if { [ -f /etc/ssh/sshd_config ] && grep -q "prohibit-password" /etc/ssh/sshd_config; } || \
     grep -q "prohibit-password" /etc/ssh/sshd_config.d/secure.conf 2>/dev/null; then
    green "✓ SSH: базовая настройка (уже настроено)"
  else
    hint "безопасные defaults; вход по паролю пока разрешён"
    select_option "SSH: базовая настройка (secure.conf; пароль разрешён)" "SETUP_SSH" false
  fi
  # SSH: усиление (только ключи; отключить пароль)
  hint "только по ключам; убедитесь, что ключи добавлены"
  select_option "SSH: усиление (только ключи; отключить пароль)" "SECURE_SSH" false
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    green "✓ Fail2ban (уже настроен)"
  else
    hint "защита от брутфорса sshd; рекомендуется"
    select_option "Установить и настроить Fail2ban (sshd)" "SETUP_FAIL2BAN" false
  fi
  if is_installed ufw && systemctl is-active --quiet ufw; then
    green "✓ Firewall UFW (уже настроен)"
  else
    hint "deny incoming, allow outgoing; откроем 22/80/443"
    select_option "Настроить Firewall (UFW, разрешить SSH)" "SETUP_FIREWALL" false
  fi

  # XanMod ядро (как в debian-vps.sh)
  if uname -r | grep -q "xanmod"; then
    green "✓ Ядро XanMod (уже установлено)"
  else
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then
      hint "опционально: улучшенная отзывчивость/производительность"
      select_option "Установка оптимизированного ядра XanMod" "INSTALL_XANMOD" false
    fi
  fi

  # Диски/память/энергосбережение
  group "Диски и Память"
  if systemctl is-enabled --quiet fstrim.timer; then
    green "✓ SSD оптимизации: fstrim.timer включен"
  else
    hint "включает регулярный TRIM; на SATA — mq-deadline"
    select_option "SSD оптимизации: включить fstrim.timer, I/O планировщик" "SETUP_SSD" false
  fi
  # Обнаружение уже настроенных ZRAM/swap
  local zram_active=false swap_active=false
  if grep -qE '^/dev/zram[0-9]+\s' /proc/swaps 2>/dev/null || \
     systemctl is-active --quiet systemd-zram-setup@zram0.service 2>/dev/null || \
     systemctl is-active --quiet zramswap 2>/dev/null; then
    zram_active=true
  fi
  # Проверим своп через /proc/swaps (без зависимости от утилит)
  local swap_file_in_proc swap_file_in_fstab swaps_any
  swap_file_in_proc=$(grep -qE '^/swapfile\s' /proc/swaps 2>/dev/null && echo 1 || echo 0)
  swap_file_in_fstab=$(grep -qs '/swapfile' /etc/fstab 2>/dev/null && echo 1 || echo 0)
  swaps_any=$(awk 'NR>1{f=1} END{print f?1:0}' /proc/swaps 2>/dev/null || echo 0)
  if { [ "$swap_file_in_proc" -eq 1 ] || { [ -f /swapfile ] && [ "$swap_file_in_fstab" -eq 1 ]; }; } then
    swap_active=true
    swap_is_file=true
  elif [ "$swaps_any" -eq 1 ]; then
    swap_active=true
    swap_is_file=false
  fi

  # Взаимоисключающий выбор ZRAM и swap
  if $zram_active; then
    green "✓ ZRAM активен (уже настроено)"
    SETUP_ZRAM=false
    SETUP_SWAP=false
  else
    if $swap_active; then
      if ${swap_is_file:-false}; then
        green "✓ Swap-файл активен (уже настроено)"
      else
        green "✓ Swap активен (раздел/устройство)"
      fi
      SETUP_ZRAM=false
      SETUP_SWAP=false
    else
      hint "рекомендуется: ZRAM снижает износ SSD"
      select_option "Настройка ZRAM (снижение износа SSD)" "SETUP_ZRAM" false
      if $SETUP_ZRAM; then
        # Если выбран ZRAM, отключаем swap-файл
        SETUP_SWAP=false
      else
        hint "альтернатива ZRAM; медленнее, но совместимо везде"
        select_option "Создать swap-файл (50% ОЗУ; ≤3ГБ → 2ГБ)" "SETUP_SWAP" false
        $SETUP_SWAP && SETUP_ZRAM=false
      fi
    fi
  fi
  hint "schedutil — баланс производительности и энергопотребления"
  select_option "CPU governor для энергоэффективности (schedutil)" "SETUP_CPU_GOVERNOR" false
  hint "умеренные параметры сети/памяти"
  select_option "Оптимизация sysctl (сеть/память)" "OPTIMIZE_SYSTEM" false

  # Логи/обновления/мониторинг/Docker
  group "Логи и Обновления"
  hint "лимитирует размер журналов systemd"
  select_option "Настройка logrotate и journald (лимиты)" "SETUP_LOGROTATE" false
  if is_installed unattended-upgrades; then
    green "✓ Автообновления безопасности (уже настроено)"
  else
    hint "обновления безопасности без участия пользователя"
    select_option "Включить автообновления безопасности" "SETUP_AUTO_UPDATES" false
  fi
  group "Мониторинг и Docker"
  hint "sysstat, smartd, lm-sensors, iperf3, nmon"
  select_option "Инструменты мониторинга (sysstat, smartmontools, sensors)" "INSTALL_MONITORING" false
  if is_installed docker-ce && is_installed docker-compose-plugin; then
    green "✓ Docker и Docker Compose (уже установлены)"
  else
    hint "официальный репозиторий Docker CE + Compose"
    select_option "Установить Docker и Docker Compose" "INSTALL_DOCKER" false
  fi

  # Завершение выбора

  echo
  yellow "Выбранные компоненты будут установлены."
  read -r -p "Продолжить? (y/n): " continue_install
  case "$continue_install" in y|Y) ;; *) echo "Отменено"; exit 0 ;; esac
}

# -------- Действия --------

# 1. Обновление и базовые утилиты
if $NONINTERACTIVE; then
  : # ничего, флаги уже заданы окружением
else
  interactive_menu
fi

if $UPDATE_SYSTEM; then
  step "Обновление системы"
  apt-get update -y
  apt-get dist-upgrade -y
  apt-get autoremove -y --purge
fi

if $INSTALL_BASE_UTILS; then
  step "Установка базовых утилит"
  # Примечание: в Debian 12/13 apt-transport-https встроен в apt; software-properties-common может отсутствовать.
  ensure_pkg curl wget ca-certificates htop git nano mc smartmontools lm-sensors gnupg
fi

# 2. Пользователь и hostname (сразу после базовых утилит)
if $CHANGE_HOSTNAME; then
  step "Изменение hostname"
  if [ -z "$NEW_HOSTNAME" ]; then
    if $NONINTERACTIVE; then
      red "NEW_HOSTNAME не задан"; exit 1
    else
      # Интерактивный ввод hostname с проверкой
      while true; do
        read -r -p "Введите новое имя хоста: " NEW_HOSTNAME
        # Имя хоста: a-z0-9 и '-', начинается/заканчивается буквой/цифрой, длина <=63
        if [[ "$NEW_HOSTNAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] && [ ${#NEW_HOSTNAME} -le 63 ]; then
          break
        else
          yellow "Некорректное имя. Допустимы: строчные буквы, цифры, дефис; длина до 63."
        fi
      done
    fi
  fi
  hostnamectl set-hostname "$NEW_HOSTNAME"
  # Обновим /etc/hosts, как в debian-vps.sh
  if ! grep -q "$NEW_HOSTNAME" /etc/hosts; then
    sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts || true
    if ! grep -q "127.0.1.1" /etc/hosts; then
      echo "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
    fi
  fi
fi

if $CREATE_USER; then
  step "Создание пользователя с sudo"
  # Убедимся, что необходимые утилиты для управления пользователями установлены
  ensure_pkg adduser sudo passwd
  if [ -z "$NEW_USERNAME" ]; then
    if $NONINTERACTIVE; then
      red "NEW_USERNAME не задан"; exit 1
    else
      # Интерактивный ввод имени пользователя с проверкой
      while true; do
        read -r -p "Введите имя пользователя: " NEW_USERNAME
        if [[ "$NEW_USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] && [ ${#NEW_USERNAME} -le 32 ]; then
          break
        else
          yellow "Некорректное имя. Пример: admin, service_user, user1"
        fi
      done
    fi
  fi
  if id "$NEW_USERNAME" >/dev/null 2>&1; then
    yellow "Пользователь $NEW_USERNAME уже существует"
    # Предложить смену пароля для существующего пользователя (только интерактивно)
    if ! $NONINTERACTIVE; then
      read -r -p "Сменить пароль пользователя $NEW_USERNAME сейчас? (y/N): " change_pw
      case "$change_pw" in
        y|Y) set_user_password_interactive "$NEW_USERNAME" ;; 
      esac
    fi
  else
    adduser --gecos "" "$NEW_USERNAME"
  fi
  # Добавление в группу sudo (с учётом того, что usermod может быть в /usr/sbin)
  if command -v usermod >/dev/null 2>&1; then
    usermod -aG sudo "$NEW_USERNAME"
  else
    /usr/sbin/usermod -aG sudo "$NEW_USERNAME"
  fi
  mkdir -p "/home/$NEW_USERNAME/.ssh"
  touch "/home/$NEW_USERNAME/.ssh/authorized_keys"
  chown -R "$NEW_USERNAME:$NEW_USERNAME" "/home/$NEW_USERNAME/.ssh"
  chmod 700 "/home/$NEW_USERNAME/.ssh"
  chmod 600 "/home/$NEW_USERNAME/.ssh/authorized_keys"
  if [ -n "$SSH_PUBLIC_KEY" ]; then
    echo "$SSH_PUBLIC_KEY" >> "/home/$NEW_USERNAME/.ssh/authorized_keys"
  else
    if ! $NONINTERACTIVE; then
      read -r -p "Добавить SSH публичный ключ для $NEW_USERNAME сейчас? (y/N): " addkey
      case "$addkey" in
        y|Y)
          read -r -p "Вставьте ключ (ssh-ed25519/ssh-rsa ...): " input_key
          if [ -n "$input_key" ]; then echo "$input_key" >> "/home/$NEW_USERNAME/.ssh/authorized_keys"; fi
          ;;
      esac
    fi
  fi
  # Как в debian-vps.sh: NOPASSWD sudo для root и нового пользователя
  mkdir -p /etc/sudoers.d
  echo "$NEW_USERNAME ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/nopasswd-$NEW_USERNAME"
  echo "root ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/nopasswd-root
  chmod 440 "/etc/sudoers.d/nopasswd-$NEW_USERNAME" "/etc/sudoers.d/nopasswd-root"

  green "Параметры пользователя $NEW_USERNAME применены: добавлен в группу sudo (NOPASSWD), директория SSH подготовлена."
fi

# 3. Локали и часовой пояс, NTP
if $SETUP_LOCALES; then
  step "Настройка локалей"
  ensure_pkg locales
  # Включаем как минимум ru_RU.UTF-8 и en_US.UTF-8, плюс выбранную
  ensure_locale "ru_RU.UTF-8" || true
  ensure_locale "en_US.UTF-8" || true
  if [ -n "$LOCALE_DEFAULT" ] && ensure_locale "$LOCALE_DEFAULT"; then
    update-locale LANG="$LOCALE_DEFAULT"
  else
    update-locale LANG="$SYSTEM_LOCALE_DEFAULT"
  fi
fi

if $SETUP_TIMEZONE; then
  step "Настройка часового пояса"
  if [ -n "$TIMEZONE" ]; then
    timedatectl set-timezone "$TIMEZONE" && green "Часовой пояс установлен: $(timedatectl show --property=Timezone --value 2>/dev/null || echo "$TIMEZONE")"
  else
    if $NONINTERACTIVE; then
      echo "Переменная TIMEZONE не задана; оставляем текущий: $(timedatectl show --property=Timezone --value || true)"
    else
      echo "Выберите часовой пояс:"
      echo " 1) Europe/Moscow"
      echo " 2) Europe/Berlin"
      echo " 3) Europe/London"
      echo " 4) America/New_York"
      echo " 5) America/Los_Angeles"
      echo " 6) Asia/Tokyo"
      echo " 7) Asia/Shanghai"
      echo " 8) Australia/Sydney"
      echo " 9) Ввести свой"
      read -r -p "Ваш выбор [1-9]: " tz_choice
      case "$tz_choice" in
        1) TIMEZONE="Europe/Moscow" ;;
        2) TIMEZONE="Europe/Berlin" ;;
        3) TIMEZONE="Europe/London" ;;
        4) TIMEZONE="America/New_York" ;;
        5) TIMEZONE="America/Los_Angeles" ;;
        6) TIMEZONE="Asia/Tokyo" ;;
        7) TIMEZONE="Asia/Shanghai" ;;
        8) TIMEZONE="Australia/Sydney" ;;
        9) read -r -p "Введите TZ (например, Europe/Paris): " TIMEZONE ;;
        *) TIMEZONE="$(timedatectl show --property=Timezone --value 2>/dev/null || echo UTC)" ;;
      esac
      if [ -n "$TIMEZONE" ]; then
        if timedatectl set-timezone "$TIMEZONE"; then
          green "Часовой пояс установлен: $(timedatectl show --property=Timezone --value 2>/dev/null || echo "$TIMEZONE")"
        else
          yellow "Не удалось установить TIMEZONE=$TIMEZONE"
        fi
      fi
    fi
  fi
fi

if $SETUP_NTP; then
  step "Настройка NTP (systemd-timesyncd)"
  ensure_pkg systemd-timesyncd
  systemctl enable --now systemd-timesyncd
fi

## 3.1 Базовая настройка SSH (как в debian-vps.sh)
if $SETUP_SSH; then
  step "Настройка базовой безопасности SSH"
  ensure_pkg openssh-server
  [ -f /etc/ssh/sshd_config ] && cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak || true
  mkdir -p /etc/ssh/sshd_config.d/
  cat > /etc/ssh/sshd_config.d/secure.conf << 'EOF'
# Безопасные настройки SSH
PermitRootLogin prohibit-password
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
AllowTcpForwarding yes
AllowAgentForwarding yes
PrintMotd no
AcceptEnv LANG LC_*
EOF
  systemctl restart sshd || systemctl reload ssh || true
fi

## 3.2 Усиление SSH
if $SECURE_SSH; then
  step "Усиление SSH"
  ensure_pkg openssh-server
  # Проверим наличие SSH ключей, чтобы не запереть доступ
  ssh_key_exists=false
  if $CREATE_USER && [ -n "$NEW_USERNAME" ] && [ -s "/home/$NEW_USERNAME/.ssh/authorized_keys" ]; then
    ssh_key_exists=true
  elif [ -s "/root/.ssh/authorized_keys" ]; then
    ssh_key_exists=true
  elif [ -n "${SUDO_USER:-}" ] && [ -s "/home/$SUDO_USER/.ssh/authorized_keys" ]; then
    ssh_key_exists=true
  fi
  if ! $ssh_key_exists; then
    if $NONINTERACTIVE; then
      yellow "SECURE_SSH=true без SSH ключей — пропускаем, чтобы не потерять доступ"
      SECURE_SSH=false
    else
      read -r -p "Не найден SSH ключ. Всё равно отключить вход по паролю? (y/N): " ans
      case "$ans" in y|Y) ;; *) SECURE_SSH=false;; esac
    fi
  fi
  if $SECURE_SSH; then
    mkdir -p /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/security.conf <<'CONF'
PasswordAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
KbdInteractiveAuthentication no
CONF
    systemctl restart sshd || systemctl reload ssh || true
  fi
fi

# 4. Сетевые оптимизации
if $SETUP_BBR; then
  step "Включение BBR и планировщика fq"
  cat >/etc/sysctl.d/60-net-bbr-fq.conf <<'SYS'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# Дополнительно: ускорение открытия соединений и буфера
net.ipv4.tcp_fastopen=3
net.core.rmem_max=2500000
net.core.wmem_max=2500000
SYS
  sysctl --system >/dev/null 2>&1 || true
fi

# 4.1 Fail2ban
if $SETUP_FAIL2BAN; then
  step "Установка и настройка Fail2ban"
  ensure_pkg fail2ban
  systemctl enable --now fail2ban || true
  mkdir -p /etc/fail2ban
  cat >/etc/fail2ban/jail.local <<'JAIL'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

# Пример базового профиля nginx (отключён по умолчанию):
#[nginx-http-auth]
#enabled = true
#filter = nginx-http-auth
#port   = http,https
#logpath = /var/log/nginx/error.log
JAIL
  systemctl restart fail2ban || true
fi

# 5. SSD оптимизации
if $SETUP_SSD; then
  step "SSD оптимизации (TRIM, планировщик I/O)"
  # Включаем регулярный TRIM
  ensure_pkg util-linux
  systemctl enable --now fstrim.timer || true

  # Планировщик: mq-deadline для SATA SSD, none для NVMe
  mkdir -p /etc/udev/rules.d
  cat >/etc/udev/rules.d/60-io-scheduler.rules <<'UDEV'
# NVMe: без планировщика (none)
ACTION=="add|change", KERNEL=="nvme*[0-9]", ATTR{queue/scheduler}="none"
# SATA SSD (не-ротирующие): mq-deadline
ACTION=="add|change", KERNEL=="sd*[!0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
UDEV
  udevadm control --reload-rules && udevadm trigger || true
fi

# 6. ZRAM (уменьшение износа SSD, ускорение свопа)
if $SETUP_ZRAM; then
  step "Настройка ZRAM"
  # Пытаемся использовать systemd-zram-generator, иначе zram-tools
  if apt-cache policy systemd-zram-generator 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vq "(none)"; then
    ensure_pkg systemd-zram-generator
    mkdir -p /etc/systemd
    cat >/etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = min(max(2048MiB, ram / 4), 8192MiB)
compression-algorithm = zstd
swap-priority = 100
ZRAM
    systemctl daemon-reload
    # Активируется автоматически при следующей загрузке; применим сейчас, если возможно
    systemctl restart systemd-zram-setup@zram0.service || true
  else
    ensure_pkg zram-tools
    cat >/etc/default/zramswap <<'ZR'
ALGO=zstd
PERCENT=25
PRIORITY=100
ZR
    systemctl enable --now zramswap || true
  fi
  # Снижаем swappiness
  cat >/etc/sysctl.d/61-vm-swappiness.conf <<'SYS'
vm.swappiness=10
vm.vfs_cache_pressure=100
SYS
  sysctl --system >/dev/null 2>&1 || true
fi

# 6.1 Swap-файл (альтернатива ZRAM)
if $SETUP_SWAP; then
  step "Настройка swap (50% от ОЗУ, ≤3ГБ → 2ГБ)"
  if [ -f /swapfile ]; then
    swapoff /swapfile || true
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab || true
  fi
  total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  total_mem_mb=$((total_mem_kb / 1024))
  swap_size_mb=$((total_mem_mb / 2))
  if [ $total_mem_mb -le 3072 ]; then
    swap_size_mb=2048
  else
    swap_size_gb=$(((swap_size_mb + 512) / 1024))
    swap_size_mb=$((swap_size_gb * 1024))
  fi
  dd if=/dev/zero of=/swapfile bs=1M count=$swap_size_mb status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/60-swap.conf <<'SYS'
vm.swappiness=10
SYS
  sysctl --system >/dev/null 2>&1 || true
fi

# 6.2 Дополнительные sysctl-оптимизации
if $OPTIMIZE_SYSTEM; then
  step "Оптимизация sysctl (сеть/память)"
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/99-optimization.conf <<'EOF'
# Оптимизация сетевого стека
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=1200
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_timestamps=0
net.ipv4.tcp_tw_reuse=1
net.core.netdev_max_backlog=16384
net.core.somaxconn=4096

# Оптимизация использования памяти
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
  sysctl --system >/dev/null 2>&1 || true
fi

# 7. CPU governor для Intel Jasper Lake (N5095)
if $SETUP_CPU_GOVERNOR; then
  step "Установка CPU governor: ${CPU_GOVERNOR}"
  ensure_pkg linux-cpupower
  mkdir -p /etc/systemd/system
  cat >/etc/systemd/system/cpu-governor.service <<EOF
[Unit]
Description=Set CPU frequency governor
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
 ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do echo ${CPU_GOVERNOR} > "\$c" 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable --now cpu-governor.service || true
fi

# 8. Логи и автообновления
if $SETUP_LOGROTATE; then
  step "Настройка ограничений journald и logrotate"
  mkdir -p /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/limits.conf <<'J'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
MaxFileSec=1month
J
  systemctl restart systemd-journald || true

  ensure_pkg logrotate
  if [ ! -f /etc/logrotate.d/custom ]; then
    cat >/etc/logrotate.d/custom <<'L'
/var/log/*.log {
    weekly
    rotate 12
    missingok
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        systemctl reload rsyslog 2>/dev/null || true
    endscript
}
L
  fi
fi

if $SETUP_AUTO_UPDATES; then
  step "Включение автоматических обновлений безопасности"
  ensure_pkg unattended-upgrades apt-listchanges
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
fi

# 9. Мониторинг и Docker
if $INSTALL_MONITORING; then
  step "Установка инструментов мониторинга"
  ensure_pkg sysstat smartmontools lm-sensors nmon iperf3
  # Тихо включаем таймеры/сервисы (подавляем лишний вывод systemd-sysv-install)
  systemctl enable --now sysstat >/dev/null 2>&1 || true
  # smartd unit имя может отличаться; пробуем оба варианта и не шумим
  systemctl enable --now smartd >/dev/null 2>&1 || \
  systemctl enable --now smartmontools >/dev/null 2>&1 || true
  # Базовая конфигурация smartd (проверка ежедневно)
  if [ -f /etc/smartd.conf ]; then
    # Аккуратно заменим/добавим строку DEVICESCAN с расписанием на 02:00 ежедневно и уведомлением root
    if grep -qE '^[#\s]*DEVICESCAN' /etc/smartd.conf; then
      sed -i -E 's!^[#\s]*DEVICESCAN.*!DEVICESCAN -a -o on -S on -s (S/../.././02) -m root!' /etc/smartd.conf || true
    else
      printf '\nDEVICESCAN -a -o on -S on -s (S/../.././02) -m root\n' >> /etc/smartd.conf
    fi
    systemctl restart smartd >/dev/null 2>&1 || systemctl restart smartmontools >/dev/null 2>&1 || true
  fi
  sensors-detect --auto || true
fi

if $INSTALL_DOCKER; then
  step "Установка Docker CE и Docker Compose"
  # Официальный репозиторий Docker
  ensure_pkg ca-certificates curl gnupg
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${DEBIAN_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

if $SETUP_FIREWALL; then
  step "Настройка UFW"
  ensure_pkg ufw
  ufw default deny incoming || true
  ufw default allow outgoing || true
  ufw allow OpenSSH || ufw allow 22/tcp || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  yes | ufw enable || true
fi

# 9.1 Установка оптимизированного ядра XanMod (как в debian-vps.sh)
if $INSTALL_XANMOD; then
  step "Установка оптимизированного ядра XanMod"
  arch=$(dpkg --print-architecture)
  if [ "$arch" != "amd64" ]; then
    yellow "Архитектура $arch не поддерживается сборками linux-xanmod-x64v*. Пропуск."
  else
    mkdir -p /etc/apt/keyrings
    ensure_pkg wget gnupg
    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor | tee /etc/apt/keyrings/xanmod-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${DEBIAN_CODENAME} main" > /etc/apt/sources.list.d/xanmod-release.list
    apt-get update -y

    # Сформируем желаемые и доступные варианты пакетов
    desired_variants=()
    case "$(psabi_level)" in
      v3) desired_variants=(x64v3 x64v2 x64v1) ;;
      v2) desired_variants=(x64v2 x64v1) ;;
      *)  desired_variants=(x64v1) ;;
    esac
    # Полный список кандидатов в порядке приоритета на основе матрицы XanMod
    candidates=()
    for v in "${desired_variants[@]}"; do
      candidates+=(
        "linux-xanmod-${v}"
        "linux-xanmod-edge-${v}"
        "linux-xanmod-lts-${v}"
        "linux-xanmod-rt-${v}"
      )
    done
    # generic fallbacks
    candidates+=(linux-xanmod linux-xanmod-edge linux-xanmod-lts linux-xanmod-rt)

    chosen=""
    for pkg in "${candidates[@]}"; do
      cand=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}') || true
      if [ -n "$cand" ] && [ "$cand" != "(none)" ]; then chosen="$pkg"; break; fi
    done

    if [ -z "$chosen" ]; then
      lvl="$(psabi_level)"
      yellow "XanMod пакеты не найдены для ${DEBIAN_VERSION_HUMAN} (CPU x86-64-${lvl}). Пробовали: ${candidates[*]}. Пропуск установки XanMod."
    else
      if DEBIAN_FRONTEND=noninteractive apt-get install -y "$chosen"; then
        green "✓ Установлено ядро $chosen"
        xanmod_installed=true
        xanmod_installed_version=$(dpkg-query -W -f='${Version}' "$chosen" 2>/dev/null || true)
        kernel_variant="${chosen#linux-xanmod-}"
      else
        red "✗ Не удалось установить $chosen. Продолжаем с текущим ядром."
      fi
    fi
  fi
fi

# 10. Fish shell (Fisher, Starship, плагины, комплишены Docker)
if $INSTALL_FISH; then
  step "Установка и настройка fish shell"
  ensure_pkg fish fzf fd-find bat git curl
  # Совместимость бинарей Debian: fd-find -> fd, batcat -> bat
  if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd
  fi
  if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
    ln -sf "$(command -v batcat)" /usr/local/bin/bat
  fi

  # Starship
  if ! command -v starship >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --retry 3 https://starship.rs/install.sh | sh -s -- -y || true
  fi

  # Определим целевого пользователя (если создан NEW_USERNAME) и локаль
  fish_locale="${LOCALE_DEFAULT:-}"
  if [ -z "$fish_locale" ]; then
    fish_locale="$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}' | tail -n1)"
  fi
  [ -z "$fish_locale" ] || [ "$fish_locale" = "C" ] || [ "$fish_locale" = "POSIX" ] && fish_locale="en_US.UTF-8"

  # Конфиг для указанного пользователя (если есть)
  configure_user_fish() {
    local user="$1" home_dir
    home_dir=$(getent passwd "$user" | cut -d: -f6)
    [ -d "$home_dir" ] || return 0
    mkdir -p "$home_dir/.config/fish/functions" "$home_dir/.config/fish/completions"
    cat > /tmp/user_config.fish <<'USER_CONFIG_EOF'
set -gx LANG __FISH_LOCALE__
set -gx LC_ALL __FISH_LOCALE__
set -gx EDITOR nano
set -gx PAGER less

# Если bat установлен, сделать его пейджером
if type -q bat
  set -gx MANPAGER "sh -c 'col -bx | bat -l man -p'"
end

# Настройки fish
set -U fish_greeting
set fish_key_bindings fish_default_key_bindings
set fish_autosuggestion_enabled 1

# Утилиты для запуска bash-команд из fish
function b --description 'Run a command in bash'
  bash -lc "$argv"
end

# fzf (если установлен)
if type -q fzf
  set -gx FZF_DEFAULT_COMMAND 'fd --type f --hidden --follow --exclude .git || rg --files --hidden --follow --glob "!.git"'
end

# Starship prompt
if type -q starship
  starship init fish | source
end
USER_CONFIG_EOF
    sed -i "s|__FISH_LOCALE__|$fish_locale|g" /tmp/user_config.fish
    cat > /tmp/user_greeting.fish <<'USER_GREETING_EOF'
function fish_greeting
    echo "🐧 Debian - "(date '+%Y-%m-%d %H:%M')""
end
USER_GREETING_EOF
    cp /tmp/user_config.fish "$home_dir/.config/fish/config.fish"
    cp /tmp/user_greeting.fish "$home_dir/.config/fish/functions/fish_greeting.fish"
    chown -R "$user":"$user" "$home_dir/.config/fish"
    rm -f /tmp/user_config.fish /tmp/user_greeting.fish

    # Docker completions
    if command -v curl >/dev/null 2>&1; then
      sudo -u "$user" bash -lc "curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/docker/cli/master/contrib/completion/fish/docker.fish -o ~/.config/fish/completions/docker.fish || true"
      sudo -u "$user" bash -lc "curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/docker/compose/master/contrib/completion/fish/docker-compose.fish -o ~/.config/fish/completions/docker-compose.fish || true"
    fi

    # Fisher + плагины
    cat > /tmp/install_fisher_${user}.fish <<'FISHER_SCRIPT_EOF'
#!/usr/bin/env fish
curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
fisher install jorgebucaran/fisher
fisher install jethrokuan/z
fisher install PatrickF1/fzf.fish
fisher install jorgebucaran/autopair.fish
fisher install franciscolourenco/done
fisher install edc/bass
FISHER_SCRIPT_EOF
    chmod +x "/tmp/install_fisher_${user}.fish"
    sudo -u "$user" fish "/tmp/install_fisher_${user}.fish" || true
    rm -f "/tmp/install_fisher_${user}.fish"

    # Сделать fish логин-шеллом
    chsh -s /usr/bin/fish "$user" || true
  }

  # root
  mkdir -p /root/.config/fish/functions /root/.config/fish/completions
  cat > /root/.config/fish/config.fish <<'ROOT_CONFIG_EOF'
set -gx LANG __FISH_LOCALE__
set -gx LC_ALL __FISH_LOCALE__
set -gx EDITOR nano
set -gx PAGER less

if type -q bat
  set -gx MANPAGER "sh -c 'col -bx | bat -l man -p'"
end

set -U fish_greeting
set fish_key_bindings fish_default_key_bindings
set fish_autosuggestion_enabled 1

function b --description 'Run a command in bash'
  bash -lc "$argv"
end

if type -q fzf
  set -gx FZF_DEFAULT_COMMAND 'fd --type f --hidden --follow --exclude .git || rg --files --hidden --follow --glob "!.git"'
end

if type -q starship
  starship init fish | source
end
ROOT_CONFIG_EOF
  sed -i "s|__FISH_LOCALE__|$fish_locale|g" /root/.config/fish/config.fish
  cat > /root/.config/fish/functions/fish_greeting.fish <<'ROOT_GREETING_EOF'
function fish_greeting
    echo "🐧 Debian - "(date '+%Y-%m-%d %H:%M')""
end
ROOT_GREETING_EOF
  # Docker completions (root)
  curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/docker/cli/master/contrib/completion/fish/docker.fish -o /root/.config/fish/completions/docker.fish || true
  curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/docker/compose/master/contrib/completion/fish/docker-compose.fish -o /root/.config/fish/completions/docker-compose.fish || true

  # Fisher (root)
  cat > /tmp/install_fisher_root.fish <<'FISHER_ROOT_SCRIPT_EOF'
#!/usr/bin/env fish
curl -fsSL --connect-timeout 15 --retry 3 https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
fisher install jorgebucaran/fisher
fisher install jethrokuan/z
fisher install PatrickF1/fzf.fish
fisher install jorgebucaran/autopair.fish
fisher install franciscolourenco/done
fisher install edc/bass
FISHER_ROOT_SCRIPT_EOF
  chmod +x /tmp/install_fisher_root.fish
  fish /tmp/install_fisher_root.fish || true
  rm -f /tmp/install_fisher_root.fish

  # Пользователь, если создан
  if $CREATE_USER && [ -n "$NEW_USERNAME" ] && id "$NEW_USERNAME" >/dev/null 2>&1; then
    configure_user_fish "$NEW_USERNAME"
  fi

  # Если пользователь уже существовал (и мы его не создавали сейчас) — тоже настроим
  DEFAULT_USER=""
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    DEFAULT_USER="$SUDO_USER"
  else
    # Попробуем определить разумного пользователя
    CANDIDATE="$(logname 2>/dev/null || true)"
    if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "root" ]; then
      DEFAULT_USER="$CANDIDATE"
    else
      # Первый пользователь с UID >= 1000
      CANDIDATE="$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd)"
      [ -n "$CANDIDATE" ] && DEFAULT_USER="$CANDIDATE"
    fi
  fi
  if [ -n "$DEFAULT_USER" ] && [ "$DEFAULT_USER" != "root" ]; then
    if ! $CREATE_USER || [ "$DEFAULT_USER" != "$NEW_USERNAME" ]; then
      if id "$DEFAULT_USER" >/dev/null 2>&1; then
        configure_user_fish "$DEFAULT_USER"
      fi
    fi
  fi

  # Сделать fish оболочкой по умолчанию для root
  chsh -s /usr/bin/fish root || true
fi

## Итог
echo
green "Готово. ${DEBIAN_VERSION_HUMAN} настроен для мини-ПК (домашний сервер)."
if $INSTALL_XANMOD && $xanmod_installed; then
  echo
  yellow "Ядро XanMod установлено. Для активации требуется перезагрузка."
  if [ -n "$xanmod_installed_version" ]; then
    echo "  Версия ядра XanMod: $xanmod_installed_version${kernel_variant:+ ($kernel_variant)}"
  fi
fi
if $AUTO_REBOOT; then
  yellow "Перезагрузка..."
  reboot
else
  yellow "Рекомендуется перезагрузить систему, чтобы применить все изменения."
fi
