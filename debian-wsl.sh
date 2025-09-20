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
  --install-cuda           Установить CUDA Toolkit из репозитория NVIDIA
  --cuda-version X.Y       Версия CUDA Toolkit (например, 12.5). По умолчанию авто.
  --cuda-auto-latest       Игнорировать --cuda-version и выбрать самую свежую cuda-toolkit-X-Y
  --check-gpu              Проверить доступность GPU в WSL и через Docker
  --help                   Показать эту справку
EOF
}

# -------- args --------
CONFIGURE_WSL_CONF=false
ENABLE_ROOTLESS=false
INSTALL_CUDA=false
CUDA_VERSION=""
CHECK_GPU=false
CUDA_AUTO_LATEST=false

while [ $# -gt 0 ]; do
  case "$1" in
    --configure-wsl-conf) CONFIGURE_WSL_CONF=true ;;
    --rootless-docker)    ENABLE_ROOTLESS=true ;;
    --install-cuda)       INSTALL_CUDA=true ;;
    --cuda-version)       CUDA_VERSION=${2:-}; shift ;;
    --cuda-auto-latest)   CUDA_AUTO_LATEST=true ;;
    --check-gpu)          CHECK_GPU=true ;;
    --help|-h)            usage; exit 0 ;;
    *) warn "Неизвестная опция: $1"; usage; exit 1 ;;
  esac
  shift
done

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

section "1. Настройка WSL (опция)"
if $CONFIGURE_WSL_CONF; then
  info "Обновляем /etc/wsl.conf: включаем systemd=true..."
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

section "3. Настройка ssh-agent в WSL"
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

section "5. Rootless Docker (опция)"
if $ENABLE_ROOTLESS; then
  info "Настраиваем rootless Docker для пользователя: $USER"
  ensure_pkg uidmap dbus-user-session slirp4netns fuse-overlayfs docker-ce-rootless-extras
  # Устанавливаем rootless окружение
  if command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
    export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}
    if [ -z "$XDG_RUNTIME_DIR" ]; then
      # Без systemd используем локальный runtime dir
      export XDG_RUNTIME_DIR="$HOME/.local/run"
      mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
    fi
    dockerd-rootless-setuptool.sh install -f || warn "Не удалось выполнить rootless setup"
    # Настройки окружения для клиента
    RL_SNIPPET='# WSL: rootless Docker\nexport XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$HOME/.local/run}"\nexport DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"\n'
    for f in "$HOME/.bash_profile" "$HOME/.profile"; do
      [ -f "$f" ] || touch "$f"
      if ! grep -F "WSL: rootless Docker" "$f" >/dev/null 2>&1; then
        printf "%b\n" "$RL_SNIPPET" >>"$f"
        ok "Добавлены переменные окружения rootless Docker в ${f#${HOME}/}."
      fi
    done
    if has_user_systemd; then
      systemctl --user enable --now docker.service || warn "Не удалось запустить user docker.service"
    else
      warn "Пользовательский systemd недоступен. Добавляем автостарт dockerd-rootless.sh в профиль."
      START_SNIPPET='# WSL: запуск dockerd-rootless.sh при входе\nif ! pgrep -u "$USER" -f dockerd-rootless.sh >/dev/null 2>&1; then\n  nohup dockerd-rootless.sh >/dev/null 2>&1 &\nfi\n'
      for f in "$HOME/.bash_profile" "$HOME/.profile"; do
        if ! grep -F "WSL: запуск dockerd-rootless.sh" "$f" >/dev/null 2>&1; then
          printf "%b\n" "$START_SNIPPET" >>"$f"
          ok "Добавлен автостарт rootless демона в ${f#${HOME}/}."
        fi
      done
    fi
    ok "Rootless Docker настроен."
  else
    warn "dockerd-rootless-setuptool.sh не найден — проверьте пакет docker-ce-rootless-extras."
  fi
else
  info "Пропускаем настройку rootless Docker (не запрошено)."
fi

section "6. NVIDIA Container Toolkit для WSL"
info "Подготавливаем ключ и репозиторий NVIDIA..."
gpu_status_wsl || warn "GPU может быть недоступен в WSL сейчас; установка продолжится."
sudo_or_su install -m 0755 -d /usr/share/keyrings
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo_or_su gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

# Используем стабильный список, чтобы избежать несовместимости с codename
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/amd64/ | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo_or_su tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

DEBIAN_FRONTEND=noninteractive \
sudo_or_su apt-get update -y
DEBIAN_FRONTEND=noninteractive \
sudo_or_su apt-get install -y --no-install-recommends nvidia-container-toolkit || warn "Не удалось установить NVIDIA Container Toolkit"

if command -v nvidia-ctk >/dev/null 2>&1; then
  info "Конфигурируем NVIDIA runtime для Docker..."
  if $ENABLE_ROOTLESS; then
    # Конфигурация для rootless: пользовательский daemon.json
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
  if has_systemd; then
    :
  else
    :
  fi
  ok "NVIDIA Container Toolkit установлен."
else
  warn "nvidia-ctk не найден — проверьте, установился ли пакет."
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
