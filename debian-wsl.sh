#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 12/13 WSL bootstrap
# - Избегает ошибок systemctl/dbus, когда systemd не запущен в WSL
# - Устанавливает Docker CE и NVIDIA Container Toolkit с безопасными проверками
# - Опционально настраивает rootless Docker и /etc/wsl.conf
# - Опционально устанавливает CUDA Toolkit согласно рекомендациям NVIDIA для Debian

LOG_FILE=${LOG_FILE:-"$PWD/wsl.log"}
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# -------- helpers --------
section() { echo; printf '\n\e[1;34m════════ %s ════════\e[0m\n' "$*"; }
info()    { printf '\e[1;36m>>> %s\e[0m\n' "$*"; }
warn()    { printf '\e[1;33m[WARN] %s\e[0m\n' "$*"; }
ok()      { printf '\e[1;32m[ OK ] %s\e[0m\n' "$*"; }

sudo_or_su() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    su -c "$*"
  fi
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

has_user_systemd() {
  # Will succeed only if a user manager is available
  systemctl --user show-environment >/dev/null 2>&1
}

is_wsl() {
  grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]
}

ensure_pkg() {
  # Install packages if missing; tolerate already-installed
  local pkgs=("$@")
  sudo_or_su apt-get update -y
  DEBIAN_FRONTEND=noninteractive \
  sudo_or_su apt-get install -y --no-install-recommends "${pkgs[@]}"
}

run_as_user() {
  # Run command as the primary, non-root user when available
  local target_user
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    target_user="$SUDO_USER"
  else
    target_user="$(logname 2>/dev/null || whoami)"
  fi
  if [ "$target_user" = "root" ] || ! command -v sudo >/dev/null 2>&1; then
    "$@"
  else
    sudo -u "$target_user" "$@"
  fi
}

DEFAULT_USER=""
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  DEFAULT_USER="$SUDO_USER"
else
  DEFAULT_USER="$(logname 2>/dev/null || whoami)"
fi

apt_has_pkg() {
  local pkg="$1"
  apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vq "(none)"
}

latest_cuda_toolkit_pkg() {
  # Return best available cuda-toolkit-* version, or empty
  apt-cache search '^cuda-toolkit-[0-9][0-9]*-[0-9][0-9]*$' 2>/dev/null | \
    awk '{print $1}' | sort -t- -k3,3n -k4,4n | tail -1
}

gpu_status_wsl() {
  local ok_flag=0
  echo "Проверка GPU/WSL:"
  if [ -e /dev/dxg ]; then
    echo " - /dev/dxg: OK (WSL GPU доступен)"
  else
    echo " - /dev/dxg: отсутствует (GPU недоступен в WSL Core)"
    ok_flag=1
  fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo " - nvidia-smi: найден"
    nvidia-smi -L || true
  else
    echo " - nvidia-smi: не найден в Linux окружении"
    ok_flag=1
  fi
  if [ $ok_flag -ne 0 ]; then
    cat <<MSG
Подсказка:
 - Установите свежий драйвер NVIDIA для Windows с поддержкой WSL (Game Ready/Studio, Production Branch).
 - Включите GPU поддержку для вашего WSL дистрибутива в Windows.
 - После обновления драйвера выполните в PowerShell: wsl --shutdown
MSG
  fi
  return $ok_flag
}

usage() {
  cat <<EOF
Использование: $0 [опции]
Опции:
  --configure-wsl-conf     Автонастройка /etc/wsl.conf с systemd=true
  --rootless-docker        Включить rootless Docker для текущего пользователя
  --rootless-user NAME     Пользователь для rootless Docker (по умолчанию: NON-root $SUDO_USER)
  --install-cuda           Установить CUDA Toolkit из репозитория NVIDIA
  --cuda-version X.Y       Версия CUDA Toolkit (например, 12.5). По умолчанию авто.
  --cuda-auto-latest       Игнорировать --cuda-version и выбрать самую свежую cuda-toolkit-X-Y
  --check-gpu              Проверить доступность GPU в WSL и через Docker
  --no-menu                Не показывать интерактивное меню (по умолчанию меню, если TTY)
  --help                   Показать эту справку

Переменные окружения:
  ROOTLESS_USER            Пользователь для rootless Docker (не root). Приоритетнее, чем авто-определение.
EOF
}

# -------- args --------
CONFIGURE_WSL_CONF=false
ENABLE_ROOTLESS=false
INSTALL_CUDA=false
CUDA_VERSION=""
CHECK_GPU=false
CUDA_AUTO_LATEST=false
NO_MENU=false
DO_SSH_AGENT=true
DO_INSTALL_DOCKER=true
DO_NVIDIA_TOOLKIT=true
DO_UPDATE_SYSTEM=false
DO_BASE_UTILS=false
DO_CREATE_USER=false
DO_LOCALES=false
DO_TIMEZONE=false
DO_FISH=false
DO_UNATTENDED_UPDATES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --configure-wsl-conf) CONFIGURE_WSL_CONF=true ;;
    --rootless-docker)    ENABLE_ROOTLESS=true ;;
    --rootless-user)      ROOTLESS_USER=${2:-}; shift ;;
    --install-cuda)       INSTALL_CUDA=true ;;
    --cuda-version)       CUDA_VERSION=${2:-}; shift ;;
    --cuda-auto-latest)   CUDA_AUTO_LATEST=true ;;
    --check-gpu)          CHECK_GPU=true ;;
    --no-menu)            NO_MENU=true ;;
    --help|-h)            usage; exit 0 ;;
    *) warn "Неизвестная опция: $1"; usage; exit 1 ;;
  esac
  shift
done

# If stdin is a TTY and no explicit no-menu, allow interactive menu by default
interactive_default=false
if ! $NO_MENU; then
  if [ -t 0 ] || [ -r /dev/tty ]; then
    interactive_default=true
  fi
fi

is_installed() { dpkg -l 2>/dev/null | awk '{print $1,$2}' | grep -q "^ii ${1}$"; }

show_menu_and_set_flags() {
  clear
  local codename_title; codename_title="${VERSION_CODENAME^}"
  echo -e "\033[0;34m╔═════════════════════════════════════════╗\033[0m"
  printf "\033[0;34m║ %-37s ║\033[0m\n" "НАСТРОЙКА: Debian ${VERSION_ID:-?} (${codename_title:-?})"
  echo -e "\033[0;34m╚═════════════════════════════════════════╝\033[0m"
  echo
  echo -e "\033[0;33mПеред началом в PowerShell:\033[0m"
  echo -e "\033[0;33m1) wsl --update; 2) wsl --set-default-version 2;\033[0m"
  echo -e "\033[0;33m3) Проверьте C:\\Users\\<USER>\\.wslconfig (RAM/CPU).\033[0m"
  echo

  prompt_yn() {
    local prompt="$1" default_yes="$2"; local ans
    if $default_yes; then
      if [ -r /dev/tty ]; then read -r -p " - $prompt [Y/n]: " ans < /dev/tty || ans=""; else read -r ans || ans=""; fi
      case "$ans" in n|N) return 1;; *) return 0;; esac
    else
      if [ -r /dev/tty ]; then read -r -p " - $prompt [y/N]: " ans < /dev/tty || ans=""; else read -r ans || ans=""; fi
      case "$ans" in y|Y) return 0;; *) return 1;; esac
    fi
  }

  select_option() {
    local option="$1" var_name="$2" already="$3"
    if [ "$already" = true ]; then
      echo -e "\033[0;32m✓ $option (уже настроено)\033[0m"; return 0
    fi
    if [ "${!var_name}" = true ]; then
      if prompt_yn "$option" true; then eval "$var_name=true"; echo -e "  \033[0;32m✓ Выбрано\033[0m"; else eval "$var_name=false"; echo "  ○ Пропущено"; fi
    else
      if prompt_yn "$option" false; then eval "$var_name=true"; echo -e "  \033[0;32m✓ Выбрано\033[0m"; else eval "$var_name=false"; echo "  ○ Пропущено"; fi
    fi
  }

  echo -e "\033[0;34m═════════════════════════════════════════\033[0m"
  echo -e "\033[0;34m  ВЫБОР КОМПОНЕНТОВ\033[0m"
  echo -e "\033[0;34m═════════════════════════════════════════\033[0m"
  echo

  # Обновление системы — показать ✓ если обновлялось < 24ч назад
  local apt_update_time current_time time_diff
  apt_update_time=$(stat -c %Y /var/cache/apt/pkgcache.bin 2>/dev/null || echo 0)
  current_time=$(date +%s)
  time_diff=$((current_time - apt_update_time))
  if [ $time_diff -lt 86400 ]; then
    echo -e "\033[0;32m✓ Обновление системы (менее 24ч назад)\033[0m"
  else
    select_option "Обновление системы" DO_UPDATE_SYSTEM false
  fi

  # Базовые утилиты
  local base_utils_installed=true
  for util in curl wget htop git nano; do if ! is_installed "$util" && ! command -v "$util" >/dev/null 2>&1; then base_utils_installed=false; break; fi; done
  if [ "$base_utils_installed" = true ]; then
    echo -e "\033[0;32m✓ Базовые утилиты (уже установлены)\033[0m"
  else
    select_option "Базовые утилиты (git, build-essential, fzf, bat и др.)" DO_BASE_UTILS false
  fi

  # Создание пользователя
  select_option "Создать нового пользователя с правами sudo" DO_CREATE_USER false

  # Локали
  if locale -a 2>/dev/null | grep -qi '^ru_RU\.utf8$'; then
    echo -e "\033[0;32m✓ Локали (ru_RU уже есть)\033[0m"
  else
    select_option "Настроить локали (ru_RU, en_US)" DO_LOCALES false
  fi

  # Часовой пояс
  local current_tz; current_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
  [ -n "$current_tz" ] && echo -e "  Текущий часовой пояс: \033[1;34m$current_tz\033[0m"
  select_option "Настроить часовой пояс" DO_TIMEZONE false

  # wsl.conf (systemd)
  if [ -f /etc/wsl.conf ] && grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
    echo -e "\033[0;32m✓ wsl.conf (systemd включен)\033[0m"
  else
    select_option "Создать /etc/wsl.conf (systemd, пользователь по умолчанию)" CONFIGURE_WSL_CONF false
  fi

  # ssh-agent
  select_option "Настроить ssh-agent" DO_SSH_AGENT true

  # Docker
  if is_installed docker-ce || command -v docker >/dev/null 2>&1; then
    echo -e "\033[0;32m✓ Docker (уже установлен)\033[0m"
  else
    select_option "Установить Docker CE" DO_INSTALL_DOCKER false
  fi

  # Rootless Docker
  select_option "Включить Rootless Docker" ENABLE_ROOTLESS false

  # NVIDIA + CUDA (единый пункт как в старом меню)
  if prompt_yn "Установить компоненты NVIDIA (Container Toolkit, CUDA)" false; then
    DO_NVIDIA_TOOLKIT=true
    if prompt_yn "  → Установить также CUDA Toolkit" true; then
      INSTALL_CUDA=true
      if prompt_yn "    → Выбрать самую свежую версию CUDA (auto-latest)" true; then
        CUDA_AUTO_LATEST=true
      else
        if [ -r /dev/tty ]; then read -r -p "    → Укажите версию CUDA (например, 12.5): " CUDA_VERSION < /dev/tty; else read -r CUDA_VERSION; fi
      fi
    fi
  else
    DO_NVIDIA_TOOLKIT=false
  fi

  # Fish
  if command -v fish >/dev/null 2>&1; then
    echo -e "\033[0;32m✓ Fish shell (уже установлен)\033[0m"
  else
    select_option "Настроить Fish Shell (Fisher, Starship, плагины)" DO_FISH false
  fi

  # Автообновления
  if grep -qs 'APT::Periodic::Unattended-Upgrade\s*"1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
    echo -e "\033[0;32m✓ Автообновления безопасности (уже включены)\033[0m"
  else
    select_option "Включить автообновления безопасности (unattended-upgrades)" DO_UNATTENDED_UPDATES false
  fi

  # GPU check
  select_option "Выполнить проверку GPU (nvidia-smi и контейнер)" CHECK_GPU false

  echo
  echo -e "\033[0;33m═════════════════════════════════════════\033[0m"
  echo -e "\033[0;33m  Начинаем установку выбранных компонентов\033[0m"
  echo -e "\033[0;33m═════════════════════════════════════════\033[0m"
  echo
}

# -------- env detection --------
if [ -r /etc/os-release ]; then
  . /etc/os-release
else
  warn "/etc/os-release не найден. Продолжаю по умолчанию."
  ID=debian
  VERSION_CODENAME=trixie
fi

if ! is_wsl; then
  warn "Похоже, это не среда WSL. Скрипт рассчитан на WSL." 
fi

if $interactive_default; then
  section "0. Меню выбора"
  show_menu_and_set_flags
fi

section "1. Настройка WSL (опция)"
if $CONFIGURE_WSL_CONF; then
  info "Обновляем /etc/wsl.conf: включаем systemd=true и пользователя по умолчанию..."
  TMP_WSL=$(mktemp)
  if [ -f /etc/wsl.conf ]; then
    sudo_or_su cp /etc/wsl.conf "/etc/wsl.conf.bak.$(date +%s)" || true
    sudo_or_su cp /etc/wsl.conf "$TMP_WSL"
  fi
  # Гарантируем наличие секции [boot] и ключа systemd=true
  if ! grep -q '^\[boot\]' "$TMP_WSL" 2>/dev/null; then
    printf "[boot]\nsystemd=true\n" >>"$TMP_WSL"
  elif grep -q '^systemd=' "$TMP_WSL"; then
    sed -ri 's#^systemd=.*#systemd=true#' "$TMP_WSL"
  else
    awk '1; /^\[boot\]$/ { print "systemd=true" }' "$TMP_WSL" >"${TMP_WSL}.new" && mv "${TMP_WSL}.new" "$TMP_WSL"
  fi
  # Устанавливаем пользователя по умолчанию, если известен
  WSL_DEFAULT_USER=${WSL_DEFAULT_USER:-$DEFAULT_USER}
  if [ -n "$WSL_DEFAULT_USER" ] && [ "$WSL_DEFAULT_USER" != "root" ]; then
    if ! grep -q '^\[user\]' "$TMP_WSL" 2>/dev/null; then
      printf "\n[user]\ndefault=%s\n" "$WSL_DEFAULT_USER" >>"$TMP_WSL"
    else
      if grep -q '^default=' "$TMP_WSL"; then
        sed -ri "s#^default=.*#default=${WSL_DEFAULT_USER}#" "$TMP_WSL"
      else
        awk -v u="$WSL_DEFAULT_USER" '1; /^\[user\]$/ { print "default=" u }' "$TMP_WSL" >"${TMP_WSL}.new" && mv "${TMP_WSL}.new" "$TMP_WSL"
      fi
    fi
  fi
  sudo_or_su install -m 0644 "$TMP_WSL" /etc/wsl.conf
  rm -f "$TMP_WSL"
  ok "/etc/wsl.conf обновлён. Выполните в Windows: wsl --shutdown"
else
  info "Пропускаем автоконфигурацию /etc/wsl.conf (не запрошено)."
fi



section "2. Подготовка системы"
info "Обновляем индекс пакетов и устанавливаем базовые утилиты..."
ensure_pkg ca-certificates curl gnupg lsb-release apt-transport-https xdg-user-dirs
ok "Базовые пакеты готовы."

section "2a. Обновление системы (опция)"
if $DO_UPDATE_SYSTEM; then
  info "Обогащаем APT компонентами contrib non-free non-free-firmware..."
  enrich_apt_components_in_file() {
    local f="$1"; [ -f "$f" ] || return 0
    sed -i -E '/^\s*deb\s/ { /non-free-firmware/! s/(^deb\s+[^#]*\bmain)(\s|$)/\1 contrib non-free non-free-firmware\2/ }' "$f"
  }
  enrich_all_apt_components() {
    enrich_apt_components_in_file "/etc/apt/sources.list"
    for f in /etc/apt/sources.list.d/*.list; do [ -e "$f" ] && enrich_apt_components_in_file "$f"; done
  }
  ensure_debian_base_repos() {
    local codename="${VERSION_CODENAME:-$(. /etc/os-release; echo $VERSION_CODENAME)}"; local f="/etc/apt/sources.list"
    touch "$f"
    ensure_line() { local file="$1"; shift; local line="$*"; local pattern="^$(printf '%s' "$line" | sed -E 's/[[:space:]]+/\\s+/g')$"; grep -Eq "$pattern" "$file" 2>/dev/null || echo "$line" >> "$file"; }
    ensure_line "$f" "deb http://deb.debian.org/debian ${codename} main contrib non-free non-free-firmware"
    ensure_line "$f" "deb http://deb.debian.org/debian ${codename}-updates main contrib non-free non-free-firmware"
    ensure_line "$f" "deb http://security.debian.org/debian-security ${codename}-security main contrib non-free non-free-firmware"
  }
  enrich_all_apt_components
  ensure_debian_base_repos
  info "Выполняем apt update && apt upgrade -y"
  sudo_or_su apt-get update -y
  DEBIAN_FRONTEND=noninteractive sudo_or_su apt-get upgrade -y
  ok "Система обновлена."
else
  info "Пропускаем обновление системы (не выбрано)."
fi

section "3. Настройка ssh-agent в WSL"
if $DO_SSH_AGENT; then
  ensure_pkg openssh-client
  if has_user_systemd; then
    info "Обнаружен пользовательский systemd. Включаем ssh-agent.socket..."
    systemctl --user enable --now ssh-agent.socket || warn "Не удалось включить ssh-agent.socket"
    ok "ssh-agent (user) активирован через systemd."
  else
    warn "Пользовательский systemd недоступен. Настраиваем ssh-agent через профиль."
    PROFILE_SNIPPET='# WSL: автозапуск ssh-agent (без systemd)\nif ! pgrep -u "$USER" ssh-agent >/dev/null 2>&1; then\n  eval "$(ssh-agent -s)" >/dev/null\nfi\n'
    for f in "$HOME/.bash_profile" "$HOME/.profile"; do
      [ -f "$f" ] || touch "$f"
      if ! grep -F "WSL: автозапуск ssh-agent" "$f" >/dev/null 2>&1; then
        printf "%b\n" "$PROFILE_SNIPPET" >>"$f"
        ok "Добавлен автозапуск ssh-agent в ${f#${HOME}/}."
      fi
    done
    ok "ssh-agent будет подниматься при входе в оболочку."
  fi
else
  info "Пропускаем настройку ssh-agent (не выбрано)."
fi

section "3a. Базовые утилиты (опция)"
if $DO_BASE_UTILS; then
  info "Устанавливаем набор утилит: build-essential git wget curl htop nano vim unzip zip tar xz-utils fzf ripgrep fd-find tree jq bat"
  ensure_pkg build-essential git wget curl htop nano vim unzip zip tar xz-utils fzf ripgrep fd-find tree jq bat
  # Создаём alias bat -> batcat, если нужно (Debian называет bat как batcat)
  if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
    sudo_or_su ln -sf "$(command -v batcat)" /usr/local/bin/bat || true
  fi
  # Создаём alias fd -> fdfind, если нужно
  if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
    sudo_or_su ln -sf "$(command -v fdfind)" /usr/local/bin/fd || true
  fi
  ok "Базовые утилиты установлены."
else
  info "Пропускаем установку базовых утилит (не выбрано)."
fi

section "3b. Создание пользователя (опция)"
if $DO_CREATE_USER; then
  info "Создание/настройка пользователя с sudo..."
  NEW_USERNAME=${NEW_USERNAME:-}
  if [ -z "$NEW_USERNAME" ] && [ -r /dev/tty ]; then
    read -r -p "Введите имя нового пользователя: " NEW_USERNAME < /dev/tty
  fi
  if [ -z "$NEW_USERNAME" ]; then
    warn "Имя пользователя не задано. Пропускаем создание."
  else
    ensure_pkg sudo
    if id "$NEW_USERNAME" >/dev/null 2>&1; then
      info "Пользователь '$NEW_USERNAME' уже существует. Применяем параметры..."
      # Добавляем в группу sudo
      if ! id -nG "$NEW_USERNAME" | grep -qw sudo; then
        sudo_or_su usermod -aG sudo "$NEW_USERNAME" && ok "Добавлен в группу sudo." || warn "Не удалось добавить в sudo."
      else
        ok "Уже в группе sudo."
      fi
      # Настройка sudo без пароля
      sudo_or_su mkdir -p /etc/sudoers.d
      echo "$NEW_USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo_or_su tee "/etc/sudoers.d/$NEW_USERNAME" >/dev/null
      sudo_or_su chmod 440 "/etc/sudoers.d/$NEW_USERNAME"
      ok "Sudo без пароля настроен."
      # Смена оболочки входа на /bin/bash при необходимости
      current_shell="$(getent passwd "$NEW_USERNAME" | awk -F: '{print $7}')"
      if [ "$current_shell" != "/bin/bash" ]; then
        sudo_or_su usermod -s /bin/bash "$NEW_USERNAME" && ok "Оболочка входа изменена на /bin/bash." || warn "Не удалось изменить оболочку."
      fi
      # Гарантируем домашнюю директорию
      home_dir="$(getent passwd "$NEW_USERNAME" | cut -d: -f6)"
      if [ -n "$home_dir" ] && [ ! -d "$home_dir" ]; then
        sudo_or_su mkdir -p "$home_dir" && sudo_or_su chown -R "$NEW_USERNAME":"$NEW_USERNAME" "$home_dir"
        ok "Создана домашняя директория: $home_dir"
      fi
      # Предложить смену пароля
      if [ -r /dev/tty ]; then
        read -r -p "Сменить пароль для '$NEW_USERNAME'? (y/N): " chpass < /dev/tty || chpass=""
        if [[ "$chpass" =~ ^[yY]$ ]]; then
          attempts=0
          while true; do
            if passwd "$NEW_USERNAME" < /dev/tty; then break; fi
            attempts=$((attempts+1))
            [ $attempts -ge 3 ] && { warn "Пароль не изменен после 3 попыток."; break; }
            info "Ошибка изменения пароля. Повторите попытку."
          done
        fi
      fi
    else
      sudo_or_su useradd -m -G sudo -s /bin/bash "$NEW_USERNAME" || warn "Не удалось создать пользователя"
      if [ -r /dev/tty ]; then
        info "Установите пароль для '$NEW_USERNAME' (опционально). Нажмите Enter, чтобы пропустить."
        passwd "$NEW_USERNAME" < /dev/tty || true
      fi
      sudo_or_su mkdir -p /etc/sudoers.d
      echo "$NEW_USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo_or_su tee "/etc/sudoers.d/$NEW_USERNAME" >/dev/null
      sudo_or_su chmod 440 "/etc/sudoers.d/$NEW_USERNAME"
      ok "Пользователь '$NEW_USERNAME' создан и добавлен в sudo (NOPASSWD)."
    fi
  fi
else
  info "Пропускаем создание пользователя (не выбрано)."
fi

section "3c. Локали (опция)"
if $DO_LOCALES; then
  info "Добавляем локали ru_RU.UTF-8 и en_US.UTF-8, устанавливаем системную локаль..."
  ensure_pkg locales
  ensure_locale() {
    local name="$1"; [ -n "$name" ] || return 1
    if ! grep -qi "^#*\s*${name}\s\+UTF-8" /etc/locale.gen 2>/dev/null; then
      echo "${name} UTF-8" | sudo_or_su tee -a /etc/locale.gen >/dev/null
    else
      sudo_or_su sed -i -E "s/^#\s*(${name})\s+UTF-8/\1 UTF-8/I" /etc/locale.gen
    fi
  }
  ensure_locale "ru_RU"
  ensure_locale "en_US"
  sudo_or_su locale-gen
  LOCALE_DEFAULT=${LOCALE_DEFAULT:-ru_RU.UTF-8}
  echo "LANG=$LOCALE_DEFAULT" | sudo_or_su tee /etc/default/locale >/dev/null
  ok "Локали настроены (LANG=$LOCALE_DEFAULT)."
else
  info "Пропускаем настройку локалей (не выбрано)."
fi

section "3d. Часовой пояс (опция)"
if $DO_TIMEZONE; then
  TZ_INPUT=${TIMEZONE:-}
  if [ -z "$TZ_INPUT" ] && [ -r /dev/tty ]; then
    read -r -p "Укажите часовой пояс (например, Europe/Moscow): " TZ_INPUT < /dev/tty
  fi
  if [ -z "$TZ_INPUT" ]; then
    warn "Часовой пояс не задан. Пропускаем."
  else
    if has_systemd; then
      sudo_or_su timedatectl set-timezone "$TZ_INPUT" || warn "Не удалось установить таймзону"
    else
      [ -e "/usr/share/zoneinfo/$TZ_INPUT" ] && {
        sudo_or_su ln -sf "/usr/share/zoneinfo/$TZ_INPUT" /etc/localtime
        echo "$TZ_INPUT" | sudo_or_su tee /etc/timezone >/dev/null
      }
    fi
    ok "Часовой пояс настроен: $TZ_INPUT"
  fi
else
  info "Пропускаем настройку часового пояса (не выбрано)."
fi

section "4. Установка Docker CE"
info "Добавляем репозиторий Docker для ${VERSION_CODENAME}..."
sudo_or_su install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg | \
    sudo_or_su gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
sudo_or_su chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" | \
  sudo_or_su tee /etc/apt/sources.list.d/docker.list >/dev/null || true

info "Устанавливаем docker-ce, containerd и плагины..."
if $DO_INSTALL_DOCKER; then
  DEBIAN_FRONTEND=noninteractive \
  sudo_or_su apt-get update -y
  DEBIAN_FRONTEND=noninteractive \
  sudo_or_su apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
      warn "Не удалось установить docker из репозитория. Возможно, репозиторий ещё не выпустил пакеты для ${VERSION_CODENAME}."
      warn "Вы можете повторить позже или использовать Docker Desktop для Windows с интеграцией WSL."
    }

  if has_systemd; then
    info "Включаем сервисы Docker и containerd через systemd..."
    sudo_or_su systemctl enable --now containerd || warn "containerd не запущен"
    sudo_or_su systemctl enable --now docker || warn "docker не запущен"
    ok "Docker сервисы активированы."
  else
    warn "systemd в этой сессии не активен. Пропускаем enable/start сервисов."
    warn "Для WSL рекомендуется Docker Desktop (WSL integration)."
  fi
else
  info "Пропускаем установку Docker (не выбрано)."
fi

section "5. Rootless Docker (опция)"
if $ENABLE_ROOTLESS; then
  # Определяем целевого пользователя (не root)
  TARGET_USER=${ROOTLESS_USER:-$DEFAULT_USER}
  if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    if [ -r /dev/tty ]; then
      read -r -p "Укажите пользователя для rootless Docker (не root): " TARGET_USER < /dev/tty
    fi
  fi
  if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    warn "Отказываюсь настраивать rootless Docker для root. Пропуск."
  else
    # Проверим, существует ли пользователь; при интерактивном запуске предложим создать
    if ! id "$TARGET_USER" >/dev/null 2>&1; then
      if [ -r /dev/tty ]; then
        read -r -p "Пользователь '$TARGET_USER' не существует. Создать? (y/N): " create_it < /dev/tty || create_it=""
        if [[ "$create_it" =~ ^[yY]$ ]]; then
          info "Создаём пользователя '$TARGET_USER' с правами sudo..."
          ensure_pkg sudo
          sudo_or_su useradd -m -G sudo -s /bin/bash "$TARGET_USER" || { warn "Не удалось создать пользователя '$TARGET_USER'"; return 0; }
          sudo_or_su mkdir -p /etc/sudoers.d
          echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" | sudo_or_su tee "/etc/sudoers.d/$TARGET_USER" >/dev/null
          sudo_or_su chmod 440 "/etc/sudoers.d/$TARGET_USER"
          if [ -r /dev/tty ]; then
            read -r -p "Задать пароль для '$TARGET_USER'? (y/N): " setpw < /dev/tty || setpw=""
            if [[ "$setpw" =~ ^[yY]$ ]]; then
              passwd "$TARGET_USER" < /dev/tty || true
            fi
          fi
          ok "Пользователь '$TARGET_USER' создан."
        else
          warn "Пользователь не создан. Пропускаем настройку rootless Docker."
          return 0
        fi
      else
        warn "Пользователь '$TARGET_USER' не существует и нет TTY для подтверждения создания. Пропуск rootless."
        return 0
      fi
    fi
    info "Настраиваем rootless Docker для пользователя: $TARGET_USER"
    ensure_pkg uidmap dbus-user-session slirp4netns fuse-overlayfs docker-ce-rootless-extras
    if command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
      # Обеспечим XDG_RUNTIME_DIR для пользователя без systemd
      TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
      TARGET_XDG="$TARGET_HOME/.local/run"
      sudo_or_su mkdir -p "$TARGET_XDG" && sudo_or_su chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_XDG" && sudo_or_su chmod 700 "$TARGET_XDG"
      # Установим rootless как пользователь
      if sudo -u "$TARGET_USER" env XDG_RUNTIME_DIR="$TARGET_XDG" bash -lc 'dockerd-rootless-setuptool.sh install -f'; then
        setup_ok=true
      else
        setup_ok=false
        warn "Не удалось выполнить rootless setup для $TARGET_USER"
      fi
      # Переменные окружения в профиль пользователя
      RL_SNIPPET="# WSL: rootless Docker\nexport XDG_RUNTIME_DIR=\"\${XDG_RUNTIME_DIR:-$TARGET_XDG}\"\nexport DOCKER_HOST=\"unix://$TARGET_XDG/docker.sock\"\n"
      for f in "$TARGET_HOME/.bash_profile" "$TARGET_HOME/.profile"; do
        sudo -u "$TARGET_USER" bash -lc "[ -f '$f' ] || :"
        if ! grep -F "WSL: rootless Docker" "$f" >/dev/null 2>&1; then
          printf "%b\n" "$RL_SNIPPET" | sudo_or_su tee -a "$f" >/dev/null
          sudo_or_su chown "$TARGET_USER":"$TARGET_USER" "$f"
          ok "Добавлены переменные окружения rootless Docker в ${f#${TARGET_HOME}/}."
        fi
      done
      # Попытка запустить user unit, если доступен user systemd
      if has_user_systemd; then
        if sudo -u "$TARGET_USER" systemctl --user enable --now docker.service; then
          ok "user docker.service запущен."
        else
          warn "Не удалось запустить user docker.service"
        fi
      else
        warn "Пользовательский systemd недоступен. Добавляем автостарт dockerd-rootless.sh в профиль пользователя."
        START_SNIPPET="# WSL: запуск dockerd-rootless.sh при входе\nif ! pgrep -u \"$TARGET_USER\" -f dockerd-rootless.sh >/dev/null 2>&1; then\n  nohup dockerd-rootless.sh >/dev/null 2>&1 &\nfi\n"
        for f in "$TARGET_HOME/.bash_profile" "$TARGET_HOME/.profile"; do
          if ! grep -F "WSL: запуск dockerd-rootless.sh" "$f" >/dev/null 2>&1; then
            printf "%b\n" "$START_SNIPPET" | sudo_or_su tee -a "$f" >/dev/null
            sudo_or_su chown "$TARGET_USER":"$TARGET_USER" "$f"
            ok "Добавлен автостарт rootless демона в ${f#${TARGET_HOME}/}."
          fi
        done
      fi
      $setup_ok && ok "Rootless Docker настроен." || warn "Rootless Docker настроен частично."
    else
      warn "dockerd-rootless-setuptool.sh не найден — проверьте пакет docker-ce-rootless-extras."
    fi
  fi
else
  info "Пропускаем настройку rootless Docker (не запрошено)."
fi

section "6. NVIDIA Container Toolkit для WSL"
if $DO_NVIDIA_TOOLKIT; then
  info "Подготавливаем ключ и репозиторий NVIDIA..."
  gpu_status_wsl || warn "GPU может быть недоступен в WSL сейчас; установка продолжится."
  sudo_or_su install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo_or_su gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  # Официальный способ: использование distribution=IDVERSION_ID
  distribution=$(. /etc/os-release; echo ${ID}${VERSION_ID})
  curl -fsSL https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb [^ ]*#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg]#g' | \
    sudo_or_su tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

  DEBIAN_FRONTEND=noninteractive \
  sudo_or_su apt-get update -y
  DEBIAN_FRONTEND=noninteractive \
  sudo_or_su apt-get install -y --no-install-recommends nvidia-container-toolkit || warn "Не удалось установить NVIDIA Container Toolkit"

  if command -v nvidia-ctk >/dev/null 2>&1; then
    info "Конфигурируем NVIDIA runtime для Docker..."
    if $ENABLE_ROOTLESS; then
      mkdir -p "$HOME/.config/docker"
      nvidia-ctk runtime configure --runtime=docker --config="$HOME/.config/docker/daemon.json" || warn "Не удалось применить конфигурацию nvidia-ctk (user)"
      if has_user_systemd; then
        systemctl --user restart docker || warn "Не удалось перезапустить user docker"
      else
        warn "Перезапуск rootless docker пропущен (без systemd). Перезапустите демона при необходимости."
      fi
    else
      sudo_or_su nvidia-ctk runtime configure --runtime=docker || warn "Не удалось применить конфигурацию nvidia-ctk"
      if has_systemd; then
        sudo_or_su systemctl restart docker || warn "Не удалось перезапустить docker"
      else
        warn "systemd неактивен — перезапуск docker пропущен. Перезапустите демон вручную при необходимости."
      fi
    fi
    ok "NVIDIA Container Toolkit установлен."
  else
    warn "nvidia-ctk не найден — проверьте, установился ли пакет."
  fi
else
  info "Пропускаем NVIDIA Container Toolkit (не выбрано)."
fi

section "7. (Опционально) CUDA Toolkit"
if $INSTALL_CUDA; then
  info "Добавляем репозиторий CUDA от NVIDIA..."
  sudo_or_su install -m 0755 -d /usr/share/keyrings
  # Ключ репозитория CUDA (обновлённый ключ NVIDIA)
  CUDA_REPO_PATH="debian13/x86_64"
  # Если репозиторий debian13 недоступен, откатываемся на debian12 (совместимый источник)
  if ! curl -fsI "https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO_PATH}/" >/dev/null 2>&1; then
    warn "CUDA репозиторий для debian13 недоступен — используем debian12."
    CUDA_REPO_PATH="debian12/x86_64"
  fi
  CUDA_KEY_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO_PATH}/3bf863cc.pub"
  curl -fsSL "$CUDA_KEY_URL" | sudo_or_su gpg --dearmor -o /usr/share/keyrings/cuda-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO_PATH}/ /" | \
    sudo_or_su tee /etc/apt/sources.list.d/cuda-${CUDA_REPO_PATH//\//-}.list >/dev/null

  DEBIAN_FRONTEND=noninteractive sudo_or_su apt-get update -y || warn "Не удалось обновить индекс для CUDA"

  # Выбираем лучший доступный пакет CUDA Toolkit перед установкой
  CHOSEN_PKG=""
  LATEST_SPECIFIC=$(latest_cuda_toolkit_pkg || true)
  if $CUDA_AUTO_LATEST; then
    if [ -n "$LATEST_SPECIFIC" ] && apt_has_pkg "$LATEST_SPECIFIC"; then
      CHOSEN_PKG="$LATEST_SPECIFIC"
    elif apt_has_pkg cuda-toolkit; then
      CHOSEN_PKG="cuda-toolkit"
    elif apt_has_pkg cuda; then
      CHOSEN_PKG="cuda"
    fi
  else
    if [ -n "$CUDA_VERSION" ]; then
      CANDIDATE="cuda-toolkit-${CUDA_VERSION/./-}"
      if apt_has_pkg "$CANDIDATE"; then
        CHOSEN_PKG="$CANDIDATE"
      else
        warn "Пакет $CANDIDATE недоступен в репозитории."
      fi
    fi
    if [ -z "$CHOSEN_PKG" ] && apt_has_pkg cuda-toolkit; then
      CHOSEN_PKG="cuda-toolkit"
    fi
    if [ -z "$CHOSEN_PKG" ] && [ -n "$LATEST_SPECIFIC" ] && apt_has_pkg "$LATEST_SPECIFIC"; then
      CHOSEN_PKG="$LATEST_SPECIFIC"
    fi
    if [ -z "$CHOSEN_PKG" ] && apt_has_pkg cuda; then
      CHOSEN_PKG="cuda"
    fi
  fi

  if [ -n "$CHOSEN_PKG" ]; then
    info "Устанавливаем CUDA Toolkit пакет: $CHOSEN_PKG"
    DEBIAN_FRONTEND=noninteractive sudo_or_su apt-get install -y --no-install-recommends "$CHOSEN_PKG" || \
      warn "Не удалось установить $CHOSEN_PKG. Проверьте логи."
  else
    warn "Не найден доступный пакет CUDA Toolkit в подключённом репозитории."
  fi
  # Сохраним выбор для итогового отчёта
  CUDA_SELECTED_REPO="$CUDA_REPO_PATH"
  CUDA_SELECTED_PKG="${CHOSEN_PKG:-none}"
  CUDA_LATEST_PKG="${LATEST_SPECIFIC:-none}"
  ok "CUDA toolkit: шаг установки завершён. См. лог, если были предупреждения."
else
  info "Пропускаем установку CUDA Toolkit (не запрошено)."
fi

section "8. Проверка GPU (опция)"
if $CHECK_GPU; then
  info "Локальная проверка nvidia-smi..."
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi || warn "nvidia-smi завершился с ошибкой"
  else
    warn "nvidia-smi не найден. Проверьте драйвер/пакеты в WSL."
  fi
  if command -v docker >/dev/null 2>&1; then
    info "Проверка GPU в контейнере (может занять время)..."
    docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi || \
      warn "Контейнерная проверка не удалась. Проверьте конфигурацию Docker/NVIDIA."
  else
    warn "Docker недоступен — контейнерная проверка пропущена."
  fi
else
  info "Пропускаем проверку GPU (не запрошено)."
fi

section "8a. Fish Shell (опция)"
if $DO_FISH; then
  info "Устанавливаем и настраиваем Fish + Starship для пользователя $DEFAULT_USER и root"
  ensure_pkg fish git curl
  # Установка Starship
  if ! command -v starship >/dev/null 2>&1; then
    sh -c "$(curl -fsSL https://starship.rs/install.sh)" -- -y || warn "Не удалось установить Starship через скрипт"
  fi
  # Настройка для пользователя
  run_as_user bash -lc 'mkdir -p ~/.config && [ -f ~/.config/starship.toml ] || echo "add_newline = false" > ~/.config/starship.toml'
  run_as_user bash -lc 'mkdir -p ~/.config/fish && grep -q starship ~/.config/fish/config.fish 2>/dev/null || echo "starship init fish | source" >> ~/.config/fish/config.fish'
  # Сделать fish оболочкой по умолчанию (если можно)
  if command -v chsh >/dev/null 2>&1; then
    sudo_or_su chsh -s /usr/bin/fish "$DEFAULT_USER" || true
    [ "$DEFAULT_USER" != "root" ] && sudo_or_su chsh -s /usr/bin/fish root || true
  fi
  ok "Fish + Starship настроены."
else
  info "Пропускаем настройку Fish (не выбрано)."
fi

section "8b. Автообновления безопасности (опция)"
if $DO_UNATTENDED_UPDATES; then
  info "Устанавливаем unattended-upgrades и включаем автообновления безопасности..."
  ensure_pkg unattended-upgrades apt-listchanges
  sudo_or_su dpkg-reconfigure -f noninteractive unattended-upgrades || true
  # Минимальная гарантия включения через конфиг
  echo 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";' | sudo_or_su tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
  ok "Автообновления включены."
else
  info "Пропускаем автообновления (не выбрано)."
fi

section "9. Завершение"
ok "Готово. Лог: $LOG_FILE"
info "Для проверки GPU в контейнерах:"
echo "  docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi"
if $INSTALL_CUDA; then
  echo
  echo "Итог по CUDA:"
  echo "  Выбранный репозиторий: ${CUDA_SELECTED_REPO:-(не задан)}"
  echo "  Самый свежий пакет:   ${CUDA_LATEST_PKG:-(не найден)}"
  echo "  Установленный пакет:   ${CUDA_SELECTED_PKG:-(не установлен)}"
  echo
  echo "Экспорт переменных (при необходимости):"
  echo "  export CUDA_REPO_PATH=\"${CUDA_SELECTED_REPO:-}\""
  echo "  export CUDA_TOOLKIT_PKG=\"${CUDA_SELECTED_PKG:-}\""
fi
