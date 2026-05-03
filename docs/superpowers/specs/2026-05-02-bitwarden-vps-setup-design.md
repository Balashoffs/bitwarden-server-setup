# Bitwarden Self-Hosted Server на VPS — дизайн-спецификация

**Дата:** 2026-05-02
**Статус:** утверждён в брейншторме, готов к плану реализации
**Целевой репозиторий:** `bitwarden-server-setup` (этот репо)
**Источник продукта:** официальный self-host от Bitwarden — https://github.com/bitwarden/self-host (lite/unified Docker-образ `ghcr.io/bitwarden/lite`)

---

## 1. Цель

Развернуть личный self-hosted Bitwarden Server на уже существующем VPS, на котором крутятся другие сайты под управлением nginx. Один пользователь, минимум движущихся частей, простое восстановление.

## 2. Решения, принятые в брейншторме

| Тема | Решение | Почему |
|---|---|---|
| Аудитория | 1 пользователь (личное использование) | Не нужны org-функции, SSO, политики |
| VPS | 2 vCPU / 2 GB RAM / 60 GB SSD, Ubuntu 22.04 LTS x86_64, sudo + SSH-ключ | Уже арендован |
| Что уже на VPS | nginx на 80/443, сайты на 8080/8081/22300 | Встраиваемся в существующий nginx, не ставим второй reverse proxy |
| Домен | `example.com` | Указан пользователем |
| TLS | Let's Encrypt через существующий certbot | Стандартный путь для nginx |
| Метод деплоя | Bitwarden lite Docker-образ (`ghcr.io/bitwarden/lite:beta`) | Лёгкий (~350 MB RAM), один контейнер, рекомендован Bitwarden для self-host малого масштаба. Альтернативу `bitwarden.sh` (MSSQL + ~9 контейнеров) отклонили — не помещается в 2 GB RAM. |
| База данных | SQLite (файл в volume) | Достаточно для 1 пользователя, отсутствует отдельный контейнер БД |
| Email / SMTP | Отключён | Пользователь не хочет настраивать. Регистрация без email-верификации, после регистрации блокируется. 2FA через TOTP. |
| Бэкапы | Локально на VPS, ежедневно, ротация 7 дней, шифрование openssl | Минимальный уровень, защищает от случайного удаления, не от смерти VPS |
| Автообновления | Не используем (Watchtower не ставим) | Риск получить сломанный билд в проде без человека рядом. Обновление руками раз в неделю-месяц. |

## 3. Архитектура

```
Internet → :80/:443 → существующий nginx
                       ├── другие сайты → 127.0.0.1:8080 / 8081 / 22300
                       └── example.com → 127.0.0.1:8082 (новый vhost)
                                                      ↓
                                              Bitwarden unified container
                                                      ↓
                                              docker volume bitwarden_data
                                              (SQLite + attachments + sends + keys)
```

**Контейнеры:**

| Контейнер | Образ | Назначение | RAM (примерно) |
|---|---|---|---|
| `bitwarden` | `ghcr.io/bitwarden/lite:beta` | api + identity + admin + web vault + notifications | ~350 MB |

(Caddy/Traefik не используем — reverse proxy один и тот же, существующий nginx.)

**Сети:** контейнер `bitwarden` биндится **только на `127.0.0.1:8082`**. Снаружи VPS он недоступен — попасть к нему можно только через nginx.

**Volumes:**
- `bitwarden_data` (named) → `/etc/bitwarden` внутри контейнера. Содержит: SQLite БД, attachments, sends, keys, лицензии. Это всё ценное; бэкап работает с этим volume.

**Порты на хосте:**
- `22/tcp` — SSH (как было)
- `80/tcp`, `443/tcp` — nginx (как было)
- Остальное — закрыто (UFW не трогаем без явного флага)

**Внешние зависимости (живут вне репозитория, но требуются):**
- DNS A-запись `example.com → <IP_VPS>`
- Installation ID + key с https://bitwarden.com/host/ (бесплатно, нужен email)
- Установленные на хосте: Docker Engine, Docker Compose plugin, certbot, nginx (последний уже есть)

## 4. Структура репозитория

```
bitwarden-server-setup/
├── README.md
├── .gitignore                       # .env, secrets/, backups/, *.log
├── .env.example
├── docker-compose.yml
├── nginx/
│   └── example.com.conf.template   # vhost-шаблон с плейсхолдерами
├── scripts/
│   ├── bootstrap.sh                 # подготовка VPS: docker, certbot, swap
│   ├── install.sh                   # развёртывание bitwarden + nginx + cert
│   ├── lockdown.sh                  # отключить регистрацию после первого юзера
│   ├── backup.sh                    # ежедневный бэкап (вызывается systemd timer)
│   ├── restore.sh                   # ручное восстановление из архива
│   └── update.sh                    # обновление образа
├── systemd/
│   ├── bitwarden-backup.service
│   └── bitwarden-backup.timer
└── docs/superpowers/specs/
    └── 2026-05-02-bitwarden-vps-setup-design.md   # этот документ
```

### 4.1 `.env.example`

```env
# Domain
DOMAIN=example.com
ADMIN_EMAIL=you@example.tld          # для certbot

# Bitwarden installation credentials (https://bitwarden.com/host/)
BW_INSTALLATION_ID=
BW_INSTALLATION_KEY=

# Local bind port для bitwarden-контейнера (на 127.0.0.1)
BW_BIND_PORT=8082

# Database — SQLite в volume
BW_DB_PROVIDER=sqlite

# Email — выключено
BW_MAIL_ENABLED=false

# Регистрация — false при первом запуске (чтобы создать владельца), потом lockdown.sh переключает в true
BW_DISABLE_USER_REGISTRATION=false
```

### 4.2 `docker-compose.yml`

```yaml
services:
  bitwarden:
    image: ghcr.io/bitwarden/lite:beta
    container_name: bitwarden
    restart: unless-stopped
    ports:
      - "127.0.0.1:${BW_BIND_PORT}:8080"
    env_file: .env
    environment:
      BW_DOMAIN: ${DOMAIN}
      BW_DB_PROVIDER: ${BW_DB_PROVIDER}
      globalSettings__disableUserRegistration: ${BW_DISABLE_USER_REGISTRATION}
      globalSettings__installation__id: ${BW_INSTALLATION_ID}
      globalSettings__installation__key: ${BW_INSTALLATION_KEY}
    volumes:
      - bitwarden_data:/etc/bitwarden
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/alive"]
      interval: 30s
      timeout: 5s
      retries: 3

volumes:
  bitwarden_data:
```

### 4.3 nginx vhost-шаблон

`nginx/example.com.conf.template` (плейсхолдеры `__DOMAIN__` и `__BIND_PORT__` подменяются `install.sh` через `envsubst` или `sed`):

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;
    # certbot сам добавит HTTPS-блок и redirect

    location / {
        proxy_pass http://127.0.0.1:__BIND_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # WebSocket (notifications/SignalR)
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 1d;
    }

    client_max_body_size 525M;
}
```

После прогона `certbot --nginx -d __DOMAIN__` certbot допишет блок `listen 443 ssl;` и redirect 80 → 443.

## 5. Скрипты

### 5.1 `scripts/bootstrap.sh` — подготовка VPS

Идемпотентный, можно запускать повторно. Делает:

1. Sanity: запущен под sudo, ОС Ubuntu 22.04, архитектура x86_64.
2. `apt-get update && apt-get install -y curl ca-certificates gnupg lsb-release jq`.
3. **Docker Engine + Compose plugin**, если ещё не стоят. Установка из официального apt-репо `download.docker.com/linux/ubuntu`. Добавить sudo-юзера в группу `docker` (предупредить, что нужно перелогиниться).
4. **certbot + python3-certbot-nginx**, если не стоят. Проверить `systemctl is-active certbot.timer`.
5. **Swap 2 GB**, если `swapon --show` пуст:
   - `fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`
   - Прописать в `/etc/fstab`: `/swapfile none swap sw 0 0`
   - Установить `vm.swappiness=10` через `/etc/sysctl.d/99-swap.conf`
6. **UFW не трогаем по умолчанию.** Только показываем `ufw status` для глазастой проверки. Если передан флаг `--configure-ufw` — настроить с нуля: `default deny incoming`, allow 22/80/443.
7. **fail2ban** — не ставим. В README — упоминание как опции.
8. Финальный вывод: чек-лист "что осталось сделать" (DNS, .env, install.sh).

Что bootstrap **не делает:**
- Не меняет SSH-конфиг
- Не правит существующие nginx-конфиги
- Не ставит Watchtower / мониторинг

### 5.2 `scripts/install.sh` — развёртывание

Идемпотентный. Шаги:

1. Проверка: `.env` существует, `BW_INSTALLATION_ID` и `BW_INSTALLATION_KEY` непустые, `DOMAIN` непустой.
2. Проверка: порт `BW_BIND_PORT` свободен на `127.0.0.1` (`ss -tlnp` фильтр на этот порт). Если занят — фейл с понятным сообщением "поменяй BW_BIND_PORT в .env".
3. `docker compose pull && docker compose up -d`.
4. Подождать healthcheck: цикл до 60 секунд проверяет `docker inspect --format '{{.State.Health.Status}}' bitwarden` == `healthy`.
5. Сгенерить vhost из шаблона (заменить `__DOMAIN__` и `__BIND_PORT__`), положить в `/etc/nginx/sites-available/${DOMAIN}.conf`, симлинк в `sites-enabled/`.
6. `nginx -t && systemctl reload nginx`.
7. Проверка: `curl -fsS http://${DOMAIN}/alive` (через 80 порт — без TLS). Если 200 — ок.
8. Сертификат: `certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m ${ADMIN_EMAIL} --redirect`. Если сертификат уже есть — certbot скажет.
9. Проверка: `curl -fsS https://${DOMAIN}/alive` → 200.
10. Установка systemd-юнитов для бэкапа: скопировать в `/etc/systemd/system/`, `daemon-reload`, `enable --now bitwarden-backup.timer`.
11. Финальный вывод: ссылка `https://${DOMAIN}`, инструкция "зарегистрируй владельца, потом запусти `sudo ./scripts/lockdown.sh`".

### 5.3 `scripts/lockdown.sh` — закрыть регистрацию

1. Проверить: в `.env` `BW_DISABLE_USER_REGISTRATION` присутствует.
2. `sed -i 's/^BW_DISABLE_USER_REGISTRATION=.*/BW_DISABLE_USER_REGISTRATION=true/' .env`.
3. `docker compose up -d` (Compose увидит изменение env и пересоздаст контейнер).
4. Подождать healthcheck.
5. Проверка: попытка зарегистрировать нового юзера через API должна вернуть ошибку. Curl: `curl -X POST https://${DOMAIN}/identity/accounts/register -H 'Content-Type: application/json' -d '{"email":"test@test.tld","masterPasswordHash":"x","masterPasswordHint":null,"key":"x","kdf":0,"kdfIterations":600000}'` → ожидаем 400/403.
6. Печать: "Регистрация закрыта".

### 5.4 `scripts/backup.sh` — ежедневный бэкап

Запускается systemd timer'ом, не cron'ом. Шаги:

1. Создать SQLite-дамп **внутри контейнера**:
   `docker compose exec -T bitwarden sqlite3 /etc/bitwarden/data/db.sqlite ".backup '/etc/bitwarden/data/db.sqlite.bak'"`
   (это атомарный backup для SQLite, не ломается при параллельной записи)
2. Выгрузить **весь volume** во временный tar через одноразовый контейнер:
   ```
   docker run --rm \
     -v bitwarden_data:/src:ro \
     -v /var/backups/bitwarden:/dst \
     alpine tar czf /dst/$(date +%Y-%m-%d-%H%M).tar.gz -C /src .
   ```
3. Зашифровать архив:
   ```
   openssl enc -aes-256-cbc -pbkdf2 -iter 200000 \
     -in /var/backups/bitwarden/<date>.tar.gz \
     -out /var/backups/bitwarden/<date>.tar.gz.enc \
     -pass file:/root/.bitwarden-backup-pass
   rm /var/backups/bitwarden/<date>.tar.gz
   ```
   Файл с паролем `/root/.bitwarden-backup-pass`:
   - Создаётся при **первом запуске backup.sh**, если отсутствует: `head -c 64 /dev/urandom | base64 > /root/.bitwarden-backup-pass && chmod 600 /root/.bitwarden-backup-pass`.
   - **Этот пароль критически важен.** Без него зашифрованный бэкап нельзя расшифровать. После первого создания пароля скрипт печатает: "СОХРАНИ ОФЛАЙН: $(cat /root/.bitwarden-backup-pass)" — пользователь обязан скопировать в офлайн-носитель.
4. Удалить дамп БД внутри контейнера: `docker compose exec -T bitwarden rm /etc/bitwarden/data/db.sqlite.bak`.
5. Ротация: `find /var/backups/bitwarden -name '*.tar.gz.enc' -mtime +7 -delete`.
6. Лог в `/var/log/bitwarden-backup.log`: дата, размер архива, exit code.

### 5.5 `scripts/restore.sh <архив.tar.gz.enc>` — восстановление

Деструктивный, требует флаг `--yes-i-know`:

1. Проверка: аргумент `<архив>` существует.
2. Проверка: флаг `--yes-i-know` передан, иначе фейл и подсказка.
3. `docker compose down`.
4. Расшифровать архив паролем из `/root/.bitwarden-backup-pass` (или попросить ввести с tty, если файла нет): `openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in <archive> -out /tmp/restore.tar.gz -pass ...`.
5. Удалить старый volume: `docker volume rm bitwarden_data && docker volume create bitwarden_data`.
6. Распаковать:
   ```
   docker run --rm \
     -v bitwarden_data:/dst \
     -v /tmp/restore.tar.gz:/restore.tar.gz:ro \
     alpine tar xzf /restore.tar.gz -C /dst
   ```
7. `rm /tmp/restore.tar.gz`.
8. `docker compose up -d`, ждать healthcheck.
9. Печать: "Восстановлено из <архив>. Открой https://${DOMAIN}, войди мастер-паролем."

### 5.6 `scripts/update.sh` — обновление

1. Запомнить текущий digest: `docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/bitwarden/lite:beta > .last_known_good_digest`.
2. `docker compose pull`.
3. `docker compose up -d`, ждать healthcheck.
4. `docker image prune -f`.
5. Печать текущего digest и пути `.last_known_good_digest` для отката.

### 5.7 systemd-юниты

`systemd/bitwarden-backup.service`:
```ini
[Unit]
Description=Bitwarden daily backup
After=docker.service

[Service]
Type=oneshot
ExecStart=/home/<user>/bitwarden-server-setup/scripts/backup.sh
StandardOutput=append:/var/log/bitwarden-backup.log
StandardError=append:/var/log/bitwarden-backup.log
```

`systemd/bitwarden-backup.timer`:
```ini
[Unit]
Description=Run Bitwarden backup daily at 03:30

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
```

(Путь к скрипту `install.sh` подставит при копировании в `/etc/systemd/system/`.)

## 6. Runbook — пошаговая инструкция (если возвращаюсь к проекту через месяц)

### 6.1 Первоначальное развёртывание

**Шаг 1 — DNS.** На стороне регистратора зоны `hello-vanilla.ru` добавить A-запись:
```
panda    A    <IP_VPS>
```
Проверка: `dig +short example.com` возвращает IP VPS.

**Шаг 2 — Installation ID + key.** Открыть https://bitwarden.com/host/, ввести email, получить два значения. Это бесплатно, никаких облачных привязок — только лицензионная проверка.

**Шаг 3 — На VPS:**
```bash
# Залогиниться
ssh <user>@<IP_VPS>

# Склонировать репо
git clone <url-репо> ~/bitwarden-server-setup
cd ~/bitwarden-server-setup

# Подготовить хост (поставит docker, certbot, swap)
sudo ./scripts/bootstrap.sh

# ВАЖНО: после этого — перелогиниться, чтобы группа docker применилась
exit
ssh <user>@<IP_VPS>
cd ~/bitwarden-server-setup

# Заполнить .env
cp .env.example .env
nano .env
#   DOMAIN=example.com
#   ADMIN_EMAIL=ваш email (для certbot)
#   BW_INSTALLATION_ID=<из шага 2>
#   BW_INSTALLATION_KEY=<из шага 2>
#   остальное оставить как есть

# Поднять
sudo ./scripts/install.sh
```

**Шаг 4 — Регистрация владельца.** Открыть `https://example.com` в браузере → Create Account → ввести email + мастер-пароль.

**КРИТИЧНО: записать мастер-пароль офлайн (на бумаге).** Сбросить его нельзя — это ключ шифрования всего сейфа. Потеря = потеря всех паролей навсегда.

**Шаг 5 — Закрыть регистрацию.**
```bash
sudo ./scripts/lockdown.sh
```
После этого новый аккаунт никто (включая владельца) не создаст.

**Шаг 6 — 2FA.** В веб-интерфейсе: Account Settings → Security → Two-step Login → Authenticator App (TOTP). Сохранить recovery-код офлайн.

**Шаг 7 — Сохранить пароль шифрования бэкапов.** После первого автоматического бэкапа (в 03:30 следующего дня) или ручного запуска `sudo ./scripts/backup.sh` появится файл `/root/.bitwarden-backup-pass`. **Скопировать содержимое офлайн** (на бумагу или в свой собственный новый Bitwarden vault — но дублировать тоже офлайн!). Без этого пароля все бэкапы превратятся в мусор.

### 6.2 Регулярное обслуживание

**Раз в неделю-месяц — обновление:**
```bash
ssh <user>@<IP_VPS>
cd ~/bitwarden-server-setup
# Прочитать CHANGELOG: https://github.com/bitwarden/server/releases
sudo ./scripts/update.sh
```

**Раз в квартал — drill восстановления:**
- Скопировать самый свежий `.tar.gz.enc` на отдельную тестовую машину (не на тот же VPS!).
- Расшифровать там через `openssl enc -d ...` и убедиться, что внутри лежат `db.sqlite`, `attachments/`, `keys/`, и БД открывается в `sqlite3`.
- Без drill бэкап = надежда, не гарантия.

**Раз в неделю — ручная проверка:**
- `https://example.com/alive` → должно вернуть 200.
- `sudo systemctl status bitwarden-backup.timer` → активен.
- `ls -lh /var/backups/bitwarden/` → есть архивы за последние дни.

### 6.3 Восстановление из бэкапа

Например, после потери диска:
```bash
# Восстановить новый VPS до состояния "bootstrap.sh + .env заполнен" (шаги 1–3 первоначальной установки, до install.sh)
# НО: вместо install.sh — restore.sh

# Скопировать архив с резервного места на VPS:
scp /<offline_storage>/2026-04-30-0330.tar.gz.enc <user>@<NEW_IP>:/tmp/

# Скопировать файл с паролем (или ввести пароль с tty при запуске):
scp /<offline_storage>/.bitwarden-backup-pass <user>@<NEW_IP>:/tmp/
ssh <user>@<NEW_IP> "sudo mv /tmp/.bitwarden-backup-pass /root/ && sudo chmod 600 /root/.bitwarden-backup-pass"

# Восстановить
ssh <user>@<NEW_IP>
cd ~/bitwarden-server-setup
sudo ./scripts/install.sh    # развернёт пустой контейнер + nginx + cert
sudo ./scripts/restore.sh /tmp/2026-04-30-0330.tar.gz.enc --yes-i-know
```

После: `https://example.com` → войти мастер-паролем.

### 6.4 Troubleshooting (что делать, если упало)

| Симптом | Диагностика | Решение |
|---|---|---|
| Сайт отдаёт 502 | `docker compose ps`, `docker compose logs --tail=100 bitwarden` | Чаще всего OOM или некорректный `.env`. Проверить `dmesg \| grep -i kill`, `swapon --show`. |
| TLS-ошибка в браузере | `certbot certificates`, `curl -v https://${DOMAIN}` | `sudo certbot renew --force-renewal -d example.com && sudo systemctl reload nginx` |
| OOM-kill | В `dmesg` есть `Killed process` | Проверить swap. Если 0 — добавить (повторно прогнать bootstrap). Если уже есть, но всё равно — посмотреть `docker stats` другие контейнеры на хосте. |
| Диск заполнен | `df -h`, `docker system df` | `docker image prune -a`, проверить `/var/backups/bitwarden` (ротация должна сама удалять старые). |
| Бэкап падает | `journalctl -u bitwarden-backup.service -n 100` | Чаще всего — пермишены на `/var/backups/bitwarden` или контейнер не запущен. |
| Забыт мастер-пароль | — | Восстановление невозможно. Только перерегистрация с нуля и потеря всех паролей. |

## 7. Smoke-чеклист (после `install.sh`)

Все пункты должны проходить:

- [ ] `dig +short example.com` возвращает IP VPS
- [ ] `curl -fsS https://example.com/alive` → 200
- [ ] `docker compose ps` показывает `bitwarden` со статусом `healthy`
- [ ] `nginx -t` без ошибок
- [ ] `certbot certificates` показывает действующий сертификат для `example.com`
- [ ] `systemctl is-active bitwarden-backup.timer` → `active`
- [ ] `systemctl list-timers bitwarden-backup.timer` показывает следующий запуск в течение 24 ч
- [ ] Веб-интерфейс открывается, страница регистрации доступна **до** `lockdown.sh`
- [ ] После `lockdown.sh` страница регистрации либо отсутствует, либо API возвращает 400/403 на попытку
- [ ] Установлены **мобильное приложение** и **браузерное расширение Bitwarden**, оба настроены на server URL `https://example.com`, вход работает, сейф синхронизируется
- [ ] Ручной запуск `sudo ./scripts/backup.sh` создаёт файл `/var/backups/bitwarden/*.tar.gz.enc` ненулевого размера
- [ ] Создан и сохранён **офлайн** файл `/root/.bitwarden-backup-pass`

## 8. Риски и явные ограничения

1. **Бэкапы только локальные.** При гибели VPS (диск, провайдер исчез, ransomware) — данные пропадут безвозвратно. Принято осознанно. Если позже передумать — добавить в `backup.sh` второй шаг с `rclone copy` в S3-совместимое хранилище (~20 строк скрипта).
2. **Пароль шифрования бэкапов лежит на том же VPS** (`/root/.bitwarden-backup-pass`). Защищает от утечки архивов, но не от компрометации root. Альтернатива (если позже захочется): GPG-шифрование публичным ключом, приватный ключ только на ноутбуке.
3. **Пик нагрузки = OOM-риск.** 2 GB RAM делятся между Bitwarden + nginx + существующими сайтами. Swap 2 GB смягчает, но не устраняет. Мониторить `docker stats` периодически.
4. **Версия зафиксирована, но не по digest.** В `docker-compose.yml` стоит `image: ghcr.io/bitwarden/lite:2026.4.0` — это calendar-version тег, который у Bitwarden иммутабелен (версия 2026.4.0 после релиза не перезаписывается). Тем не менее upstream может тихо «передвинуть» его в крайних случаях (security-rebuild, исправление ошибки сборки). Для полного pinning'а — после первого `docker compose up -d` снять digest (`docker inspect ... | grep RepoDigests`) и закрепить в `docker-compose.yml` как `image: ghcr.io/bitwarden/lite@sha256:...`. Делать вручную при стабилизации.
5. **Нет fail2ban.** Защита от перебора — только rate-limit Bitwarden + (опционально) `limit_req` в nginx vhost. Достаточно для одного публично известного юзера; при подозрении на атаки — поставить fail2ban руками.
6. **Master password recovery невозможен.** Это особенность модели Bitwarden — мастер-пароль = ключ шифрования. Принято осознанно; смягчение — записать офлайн на бумаге.
7. **Watchtower не используется** — обновления вручную. Если обновлять забывают — копится security-долг. Смягчение: календарное напоминание раз в месяц.

## 9. Что НЕ входит в этот спек (out of scope)

- Multi-user / организации / SSO
- Интеграция с внешними identity provider'ами (LDAP, AD)
- Облачное резервное копирование
- Мониторинг (Prometheus / Grafana / Loki)
- Watchtower / автообновления
- WireGuard / private networking
- Kubernetes / Swarm
- High availability / репликация
- Замена существующего nginx на другой reverse proxy

## 10. Открытые пункты для плана реализации

Вопросы, которые решаются на этапе writing-plans, не дизайна:

- Точное содержимое `bootstrap.sh` (apt-репы для Docker, точные команды) — сейчас описаны словами, в плане появятся как готовые команды.
- Точный текст vhost'а с `limit_req_zone` для login-эндпоинта — выбрать ли защиту через nginx или оставить на Bitwarden.
- Какой пользователь VPS будет владеть репо и запускать `docker compose` (любой sudo-юзер подойдёт; в плане зафиксируем имя).
- Куда положить лог `/var/log/bitwarden-backup.log` — `logrotate` нужен или `journalctl` достаточно (через `StandardOutput=journal`).
- **Сверить с актуальной документацией lite-образа `ghcr.io/bitwarden/lite`** перед написанием compose-файла:
  - Точное имя env-переменной для отключения регистрации (`globalSettings__disableUserRegistration` vs `BW_ENABLE_USER_REGISTRATION` — у unified-образа могут быть свои короткие алиасы).
  - Точные имена `BW_DOMAIN`, `BW_DB_PROVIDER` (vs `globalSettings__*`).
  - Точный путь к SQLite-файлу внутри контейнера (предполагаем `/etc/bitwarden/data/db.sqlite`).
  - Endpoint healthcheck'а (предполагаем `/alive`).
  Источник истины: `https://github.com/bitwarden/server` (README по unified deployment) и `bitwarden.com/help/install-and-deploy-unified`. Если имена расходятся — поправить compose до запуска install.sh.

Эти пункты не блокируют утверждение дизайна — они тактика, не стратегия.

---

## 11. Verified env-var names (supersedes open items in Section 10)

This section resolves the open item at the end of Section 10. All names were verified directly from the `bitwarden/self-host` repository sources listed in the `Source` column. Section 10 is left intact as the historical record of what was unknown at design time.

> **Note:** the unified image's source lives in `bitwarden-lite/` in the upstream repo (`github.com/bitwarden/self-host`), not `docker-unified/` (a different, heavier variant).

**Source files consulted:**
- `entrypoint.sh`: https://github.com/bitwarden/self-host/blob/main/bitwarden-lite/entrypoint.sh
- `settings.env`: https://github.com/bitwarden/self-host/blob/main/bitwarden-lite/settings.env
- `Dockerfile`: https://github.com/bitwarden/self-host/blob/main/bitwarden-lite/Dockerfile
- `nginx-config.hbs`: https://github.com/bitwarden/self-host/blob/main/bitwarden-lite/hbs/nginx-config.hbs

### 11.1 Verified env-var table

| Function | Env var (exact) | Notes | Source |
|---|---|---|---|
| Domain (full hostname, no trailing slash) | `BW_DOMAIN` | The entrypoint builds an intermediate variable first: `VAULT_SERVICE_URI=https://${BW_DOMAIN:-localhost}` (line 12), then exports `globalSettings__baseServiceUri__vault=${globalSettings__baseServiceUri__vault:-$VAULT_SERVICE_URI}` (line 21). Set to bare hostname e.g. `example.com` (not a full URL). | entrypoint.sh lines 12 and 21 |
| Database provider | `BW_DB_PROVIDER` | Values: `sqlite`, `mysql`, `postgresql`, `sqlserver`. Mapped to `globalSettings__databaseProvider`. | entrypoint.sh line 28; settings.env |
| SQLite file path inside container | `BW_DB_FILE` | Default set in Dockerfile: `/etc/bitwarden/vault.db`. This default is used unless overridden. Mapped to connection string `Data Source=$BW_DB_FILE;`. | Dockerfile line 40 (`ENV BW_DB_FILE="/etc/bitwarden/vault.db"`); entrypoint.sh line 16 |
| Installation ID | `BW_INSTALLATION_ID` | Mapped to `globalSettings__installation__id`. | entrypoint.sh line 22 |
| Installation key | `BW_INSTALLATION_KEY` | Mapped to `globalSettings__installation__key`. | entrypoint.sh line 23 |
| Disable user registration | `globalSettings__disableUserRegistration` | **Direct `globalSettings__` variable — no short `BW_` alias exists.** Set to `false` (allow) or `true` (block). Default in settings.env is `false` (commented). | settings.env |
| Internal HTTP port | `BW_PORT_HTTP` | Default: `8080`. This is the port nginx inside the container listens on when `BW_ENABLE_SSL` is not `true` (else branch: `export globalSettings__baseServiceUri__internalVault=http://localhost:${BW_PORT_HTTP:-8080}`). We leave `BW_ENABLE_SSL` unset (defaults to off), so the container listens on `BW_PORT_HTTP=8080` and the host nginx terminates TLS. Compose should bind `127.0.0.1:${BW_BIND_PORT}:8080`. | entrypoint.sh line 37; nginx-config.hbs |
| Healthcheck endpoint | `/alive` | nginx returns `200 OK` with GMT timestamp. No dedicated env var — path is hardcoded in nginx-config.hbs (lines 69–72): `location /alive { default_type text/plain; return 200 $date_gmt; }`. Correct healthcheck: `curl -f http://localhost:8080/alive`. | nginx-config.hbs lines 69–72 |
| Disable mail (SMTP) | `globalSettings__mail__smtp__host` + related | There is NO `BW_ENABLE_MAIL` or similar flag. Mail is effectively disabled by leaving all `globalSettings__mail__smtp__*` vars unset/absent. The relevant vars are: `globalSettings__mail__replyToEmail`, `globalSettings__mail__smtp__host`, `globalSettings__mail__smtp__port`, `globalSettings__mail__smtp__ssl`, `globalSettings__mail__smtp__username`, `globalSettings__mail__smtp__password`. | settings.env |

### 11.2 Corrections to the spec's current assumptions

The following items in the existing spec (sections 4.1, 4.2, and 5.3) use incorrect names or paths and must be updated before downstream tasks write actual files:

1. **`BW_DISABLE_USER_REGISTRATION` does not exist.** The spec's `.env.example` and `docker-compose.yml` use this as a proxy variable that maps to `globalSettings__disableUserRegistration`. The unified image has no such alias. Correct approach for downstream tasks: pass `globalSettings__disableUserRegistration` directly in the `environment:` block of `docker-compose.yml`, sourced from a `.env` variable named `BW_DISABLE_REGISTRATION` for human convenience. Alternatively, set it directly without an intermediate `.env` variable since it only ever takes two values.

2. **SQLite path is `/etc/bitwarden/vault.db`, not `/etc/bitwarden/data/db.sqlite`.** The Dockerfile sets `ENV BW_DB_FILE="/etc/bitwarden/vault.db"`. The spec's `backup.sh` section references `sqlite3 /etc/bitwarden/data/db.sqlite` — this path is wrong. Downstream tasks must use `/etc/bitwarden/vault.db`.

3. **`BW_DOMAIN` expects bare hostname, not full HTTPS URL.** The entrypoint prepends `https://` itself: `VAULT_SERVICE_URI=https://${BW_DOMAIN:-localhost}` (entrypoint.sh line 12). Setting `BW_DOMAIN=https://example.com` would result in `https://https://example.com`. Correct value: `BW_DOMAIN=example.com`. Note: the spec's own Section 4.1 `.env.example` already uses `DOMAIN=example.com` (bare hostname — correct). However, the plan file `docs/superpowers/plans/2026-05-02-bitwarden-vps-setup.md` Task 2 (around line 118) and Task 7 (around line 587) both assume `BW_DOMAIN=https://...` and strip the scheme with shell parameter expansion. Those plan sections contradict the verified upstream behaviour and must be updated before the implementer runs Task 7's `install.sh`.

4. **`BW_ENABLE_MAIL=false` does not exist.** There is no such variable. Mail is disabled by simply not setting any `globalSettings__mail__smtp__*` variables.

### Confirmations

5. **Image registry/name corrected: `ghcr.io/bitwarden/lite:2026.4.0`.** The image is published to GitHub Container Registry (GHCR), NOT Docker Hub — there is no `bitwarden/self-host` repo on Docker Hub (`docker pull` returns "repository does not exist"). Verified by querying the GHCR public tag list (`https://ghcr.io/v2/bitwarden/lite/tags/list` after fetching an anonymous bearer token from `https://ghcr.io/token?scope=repository:bitwarden/lite:pull`). Available tags include: `:2026.4.0` (current pinned version per `version.json`), `:latest` (moving stable), `:beta` (moving preview), `:dev` (moving bleeding-edge), and many `sha256-…` digest tags. We pin to `:2026.4.0` to match the upstream `bitwarden-lite/docker-compose.yml` default (`image: ${REGISTRY:-ghcr.io/bitwarden}/lite:${TAG:-2026.4.0}`); this also makes `update.sh` a deliberate user action — bumping the tag in compose first, then running the script — rather than an implicit grab of whatever moved on `:beta` overnight. The `bitwarden/self-host` GitHub repo (still at https://github.com/bitwarden/self-host) is the correct *source* repository — its `bitwarden-lite/` subdirectory builds and publishes the `lite` package as confirmed by the Dockerfile labels `com.bitwarden.product="bitwarden"` / `com.bitwarden.project="lite"`. So source = `bitwarden/self-host` (GitHub), but artifact = `ghcr.io/bitwarden/lite:2026.4.0` (GHCR).

### 11.3 Volume mount and data layout (confirmed)

Two volumes are mounted, matching the upstream `bitwarden-lite/docker-compose.yml` reference:

- `bitwarden_data:/etc/bitwarden` — persistent application data (the only volume `backup.sh` snapshots).
- `bitwarden_logs:/var/log/bitwarden` — internal service logs from the unified container's supervisord-managed processes; deliberately excluded from backups since these are noisy and not recoverable state. Mounting them on a named volume keeps them around across `docker compose down`/`up` cycles for debugging.

Confirmed directory layout under `/etc/bitwarden` (from Dockerfile `RUN mkdir -p` at line 76–89 and ENV directives at lines 55–59):

```
/etc/bitwarden/
├── vault.db              # SQLite database (BW_DB_FILE default)
├── identity.pfx          # Identity server certificate (auto-generated on first run by
│                         #   entrypoint.sh lines 41–61 if the file is absent)
├── attachments/          # user attachment blobs (top-level files stored here)
│   └── send/             # Bitwarden Send payloads (subdirectory of attachments/)
├── data-protection/      # ASP.NET data protection keys
├── licenses/
└── logs/
```

Note: user-uploaded attachment files are stored directly inside `attachments/` at the top level; `send/` is a sibling subdirectory within `attachments/` holding only Bitwarden Send payloads, not general attachments. The `logs/` subdirectory under `/etc/bitwarden/` is unused at runtime — actual logs go to `/var/log/bitwarden/` via the separate `bitwarden_logs` volume above.

---

**Конец спецификации.**
