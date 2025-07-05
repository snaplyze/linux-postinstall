curl -sL https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-vps.sh | sudo bash
curl -sL https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-wsl.sh | sudo bash

# Скрипт автоматической настройки VPS на Debian 12

## Быстрый старт (интерактивный режим)

Для запуска скрипта с интерактивным меню (без скачивания файла на диск) выполните:

```bash
bash <(curl -s https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-vps.sh)
```

- Скрипт запустит пошаговое меню выбора компонентов для установки и настройки.
- Не требуется предварительное скачивание файла или ручное выставление переменных.
- Требуются права root (или используйте `sudo bash <(curl ...)`)

## Неинтерактивный режим (автоматизация)

Если нужно полностью автоматизировать установку (например, для CI или cloud-init), используйте переменные окружения:

```bash
NONINTERACTIVE=true UPDATE_SYSTEM=true INSTALL_BASE_UTILS=true CREATE_USER=true NEW_USERNAME=admin SSH_PUBLIC_KEY="ssh-rsa AAAA..." bash <(curl -s https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-vps.sh)
```

- Указывайте только те переменные, которые хотите включить (`true`).
- Для создания пользователя обязательно задайте `NEW_USERNAME`.
- Для добавления SSH-ключа используйте `SSH_PUBLIC_KEY`.
- Если переменная не указана, компонент не будет установлен.

## Примеры переменных для неинтерактивного режима

| Переменная         | Описание                                      |
|--------------------|-----------------------------------------------|
| UPDATE_SYSTEM      | Обновить систему (true/false)                 |
| INSTALL_BASE_UTILS | Установить базовые утилиты (true/false)       |
| CREATE_USER        | Создать нового пользователя (true/false)      |
| NEW_USERNAME       | Имя нового пользователя                       |
| SSH_PUBLIC_KEY     | Публичный SSH-ключ для пользователя           |
| CHANGE_HOSTNAME    | Изменить hostname (true/false)                |
| NEW_HOSTNAME       | Новое имя хоста                               |
| INSTALL_DOCKER     | Установить Docker и Compose (true/false)      |
| INSTALL_FISH       | Установить и настроить fish shell (true/false)|
| ...                | ... и другие, см. комментарии в скрипте       |

## Важно
- Для интерактивного режима используйте только `bash <(curl ...)` — так меню будет работать корректно.
- Для неинтерактивного режима обязательно указывайте все необходимые переменные.
- Скрипт рассчитан на Debian 12 (VPS/сервер).

## Пример для WSL (альтернативный скрипт)

Для настройки WSL используйте:

```bash
bash <(curl -s https://raw.githubusercontent.com/snaplyze/linux-postinstall/main/debian-wsl.sh)
```

---

Подробнее о компонентах и переменных смотрите в комментариях внутри скрипта.
