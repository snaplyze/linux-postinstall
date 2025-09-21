**Linux Post‑Install Scripts**

- Набор скриптов для быстрой, безопасной и повторяемой настройки Linux‑систем: Debian (VPS, WSL, мини‑ПК) и Arch (универсальная оптимизация, мини‑ПК, инсталляция).
- Каждый сценарий можно запускать интерактивно (через меню) или автоматически (через переменные окружения).
- Все скрипты рассчитаны на повторный запуск; изменения выполняются через стандартные механизмы (systemd, sysctl.d, udev‑rules и т. п.).

Используйте root: запускайте через `sudo` или из root‑сессии.

—

**Содержание**
- Debian — VPS сервер: `debian-vps.sh`
- Debian — WSL среда: `debian-wsl.sh`
- Debian — Мини‑ПК (домашний сервер): `debian-mini-pc.sh`
- Обновление Debian 12 → 13: `upgrade-debian12-to-13.sh`
- Arch Linux — Универсальная оптимизация: `arch-linux-pc.sh`
- Arch Linux — Мини‑ПК: `arch-mini-pc.sh`
- Arch Linux — Установка/настройка: `arch-setup.sh`

—

**Debian VPS (12/13)**
- Быстрый старт (меню): `bash <(curl -s https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-vps.sh)`
- Автоматизация (пример): `NONINTERACTIVE=true UPDATE_SYSTEM=true INSTALL_BASE_UTILS=true CREATE_USER=true NEW_USERNAME=admin SSH_PUBLIC_KEY="ssh-rsa AAAA..." bash <(curl -s https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-vps.sh)`
- Ключевые возможности:
  - Обновления, базовые утилиты, создание пользователя, смена hostname
  - SSH настройка/усиление, Fail2ban, UFW (22/80/443)
  - TCP BBR, системные оптимизации (sysctl)
  - Локали и часовой пояс, NTP
  - Swap (опционально), логирование (journald, logrotate)
  - Мониторинг (sysstat, smartd, lm‑sensors), Docker/Compose
  - Опционально: ядро XanMod (автовыбор варианта)

—

**Debian WSL (12/13)**
- Быстрый старт: `bash <(curl -s https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-wsl.sh)`
- Особенности:
  - Учёт отсутствия systemd, аккуратная работа с `systemctl`/dbus
  - Docker CE и NVIDIA Container Toolkit (по желанию), CUDA Toolkit (опционально)
  - Опции для `/etc/wsl.conf`, fish/Starship, базовые CLI‑утилиты (fzf, ripgrep, fd, bat, jq, tree)
  - Ведёт лог в `LOG_FILE` (по умолчанию `./wsl.log`)

—

**Debian Мини‑ПК (домашний сервер)**
- Быстрый старт (меню): `bash <(curl -s https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-mini-pc.sh)`
- Автоматизация (пример):
  - `NONINTERACTIVE=true UPDATE_SYSTEM=true INSTALL_BASE_UTILS=true SETUP_TIMEZONE=true TIMEZONE=Europe/Moscow SETUP_LOCALES=true LOCALE_DEFAULT=ru_RU.UTF-8 SETUP_NTP=true SETUP_BBR=true SETUP_SSD=true SETUP_ZRAM=true SETUP_CPU_GOVERNOR=true CPU_GOVERNOR=schedutil SETUP_LOGROTATE=true SETUP_AUTO_UPDATES=true INSTALL_MONITORING=true INSTALL_DOCKER=true SETUP_FIREWALL=true SECURE_SSH=false bash <(curl -s https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-mini-pc.sh)`
- Что настраивает:
  - Обновления, базовые утилиты, локали (ru_RU/en_US), часовой пояс, NTP
  - Сеть: TCP BBR + fq, UFW (22/80/443), Fail2ban (sshd; пример nginx‑jail закомментирован)
  - SSH: базовая настройка (secure.conf) и безопасное усиление (проверка наличия ключей перед отключением пароля)
  - Диски/память: TRIM (`fstrim.timer`), планировщик I/O (udev), ZRAM (или swap‑файл), swappiness=10
  - CPU: governor (по умолчанию `schedutil`) — подходит для Intel N5095
  - Логи/обновления: journald‑лимиты, logrotate, unattended‑upgrades
  - Мониторинг: sysstat, smartd (ежедневная проверка), lm‑sensors, iperf3, nmon
  - Docker CE + Buildx + Compose
  - fish + Fisher + плагины (z, fzf.fish, autopair, done, bass), Starship, docker‑completions — для root, нового пользователя и существующего основного пользователя
  - Опционально: ядро XanMod (amd64, автоподбор `x64v1–v3`); после установки выводится подсказка о перезагрузке с версией ядра

—

**Обновление Debian 12 → 13**
- Сценарий: `upgrade-debian12-to-13.sh`
- Что делает:
  - Проверки окружения, бэкап APT и состояния системы
  - Отключение сторонних репозиториев, переход на deb822‑источники
  - `full-upgrade` в неинтерактивном режиме с безопасными опциями

—

**Arch Linux — Универсальная оптимизация**
- Сценарий: `arch-linux-pc.sh`
- Запуск от root, интерактивный выбор блоков:
  - pacman/housekeeping, swap/zram/sysctl/oomd, SSD/NVMe/HDD (fstrim, smartd, irqbalance)
  - Btrfs + Snapper, ядро/microcode/watchdog, CLI‑утилиты (fish, starship, zoxide, fzf, bat, eza)

—

**Arch Linux — Мини‑ПК**
- Сценарий: `arch-mini-pc.sh`
- Оптимизированная настройка мини‑ПК с акцентом на стабильность, энергопотребление, диски и инструменты CLI.

—

**Arch Linux — Установка/настройка**
- Сценарий: `arch-setup.sh`
- Помогает пройти начальную установку и базовую пост‑настройку.

—

**Общие рекомендации**
- Запускайте интерактивно через: `bash <(curl -s <URL>)`
- Для автоматизации используйте переменные окружения (`NONINTERACTIVE=true` и соответствующие флаги компонентов).
- Скрипты можно безопасно перезапускать — настройки выполняются идемпотентно.
- Всегда просматривайте созданные конфиги в `/etc` перед продуктивным использованием.
