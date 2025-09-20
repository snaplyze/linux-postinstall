#!/usr/bin/env bash
# Upgrade Debian 12 (bookworm) -> Debian 13 (trixie) on a clean server (no WSL).
# Safe defaults, deb822 sources, backups, and noninteractive full-upgrade.
# Run as root:  curl -fsSL https://example.com/upgrade.sh | bash
# Or:          bash upgrade-debian12-to-13.sh
set -euo pipefail

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[✗] %s\033[0m\n" "$*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Запустите от root: sudo -i && bash $0"
    exit 1
  fi
}

detect_debian12() {
  if [[ ! -r /etc/os-release ]]; then
    err "/etc/os-release не найден — это точно Debian?"
    exit 1
  fi
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then
    err "Обнаружена не Debian система: ID=${ID:-unknown}"
    exit 1
  fi
  if [[ "${VERSION_CODENAME:-}" != "bookworm" ]]; then
    warn "VERSION_CODENAME=${VERSION_CODENAME:-unknown}. Скрипт рассчитан на Debian 12 (bookworm)."
    read -r -p "Продолжить всё равно? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || exit 1
  fi
}

preflight() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a   # автоматический режим для needrestart
  log "Обновление списка пакетов и базовых утилит"
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg apt-transport-https lsb-release \
    aptitude needrestart debian-archive-keyring apt-utils
}

backup_state() {
  TS="$(date -u +%Y%m%d-%H%M%SZ)"
  BKP="/root/upgrade-bookworm-to-trixie-$TS"
  mkdir -p "$BKP"
  log "Бэкапим конфиги APT и список пакетов в $BKP"
  cp -a /etc/apt/sources.list "$BKP"/sources.list 2>/dev/null || true
  cp -a /etc/apt/sources.list.d "$BKP"/sources.list.d 2>/dev/null || true
  cp -a /etc/apt/preferences{,.d} "$BKP"/ 2>/dev/null || true
  dpkg --get-selections > "$BKP"/dpkg-selections.txt
  apt-cache policy > "$BKP"/apt-policy.txt
  uname -a > "$BKP"/uname.txt
}

hold_check() {
  log "Проверяем зафиксированные (hold) пакеты"
  if apt-mark showhold | grep -q .; then
    warn "Найдены удержанные пакеты:"
    apt-mark showhold
    read -r -p "Снять hold со всех? [y/N] " ans
    if [[ "${ans,,}" == "y" ]]; then
      apt-mark showhold | xargs -r apt-mark unhold
    else
      warn "Удержанные пакеты могут помешать обновлению."
    fi
  fi
}

disable_third_party() {
  log "Отключаем сторонние репозитории (кроме deb.debian.org и security.debian.org)"
  mkdir -p /etc/apt/sources.list.d.disabled
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.list; do
    if grep -Eqv 'deb(\-src)?\s+.*(deb\.debian\.org|security\.debian\.org|ftp\.debian\.org)' "$f"; then
      mv -v "$f" "/etc/apt/sources.list.d.disabled/$(basename "$f").disabled"
    fi
  done
  shopt -u nullglob
}

write_deb822_sources() {
  log "Переходим на deb822-формат источников APT для trixie"
  mkdir -p /etc/apt/sources.list.d
  # Сохраняем старый sources.list, если он есть, и очищаем его
  if [[ -f /etc/apt/sources.list ]]; then
    mv -v /etc/apt/sources.list "/etc/apt/sources.list.$TS.bak"
    touch /etc/apt/sources.list
  fi

  cat > /etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

update_and_minimal_upgrade() {
  log "apt update и минимальное обновление (без смены релиза)"
  apt-get update -y
  apt-get upgrade -y
}

dist_upgrade() {
  log "Полное обновление до Debian 13 (trixie)"
  apt-get full-upgrade -y \
    -o Dpkg::Options::="--force-confnew" \
    -o Dpkg::Options::="--force-confdef"
}

cleanup() {
  log "Очистка и удаление лишних пакетов"
  apt-get autoremove -y
  apt-get autoclean -y
}

verify_version() {
  . /etc/os-release || true
  log "Текущая версия: ${PRETTY_NAME:-unknown}"
  lsb_release -a || true
  if [[ "${VERSION_CODENAME:-}" == "trixie" ]]; then
    log "Обновление успешно выполнено ✔"
  else
    warn "Похоже, обновление не завершилось (VERSION_CODENAME=${VERSION_CODENAME:-}). Проверьте вывод выше."
  fi
}

final_hint() {
  log "Рекомендация: перезагрузите сервер: reboot"
}

main() {
  require_root
  detect_debian12
  preflight
  backup_state
  hold_check
  disable_third_party
  write_deb822_sources
  update_and_minimal_upgrade
  dist_upgrade
  cleanup
  verify_version
  final_hint
}

main "$@"
