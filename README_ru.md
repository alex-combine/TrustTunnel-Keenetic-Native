# TrustTunnel на роутерах Keenetic — со статистикой в веб-интерфейсе

[![Release](https://img.shields.io/github/v/release/alex-combine/TrustTunnel-Keenetic-Native)](https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/alex-combine/TrustTunnel-Keenetic-Native/total)](https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases)
[![License](https://img.shields.io/github/license/alex-combine/TrustTunnel-Keenetic-Native)](LICENSE)

[🇺🇸 Read this in English](README.md)

> Расширенная версия проекта [TrustTunnel-Keenetic](https://github.com/artemevsevev/TrustTunnel-Keenetic) (автор — Artem Evsevev).
>
> **Что нового:** TUN-подключение (OpkgTunN) наконец показывает настоящую статистику трафика в веб-интерфейсе Keenetic — в классической схеме там всегда 0.
> Уже работающие роутеры переходят одной командой, с автоматическим откатом, если что-то пойдёт не так.
> Быстрые ссылки: [Статистика в веб-интерфейсе](#статистика-в-веб-интерфейсе-режим-attach) · [Переход с классической схемы](#переход-роутера-с-классической-схемы)

## Предварительные требования

Перед установкой на роутер необходимо:
1. Установить Entware на роутер: [Инструкция по установке Entware](https://help.keenetic.com/hc/ru/articles/360021214160-%D0%A3%D1%81%D1%82%D0%B0%D0%BD%D0%BE%D0%B2%D0%BA%D0%B0-%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B-%D0%BF%D0%B0%D0%BA%D0%B5%D1%82%D0%BE%D0%B2-%D1%80%D0%B5%D0%BF%D0%BE%D0%B7%D0%B8%D1%82%D0%BE%D1%80%D0%B8%D1%8F-Entware-%D0%BD%D0%B0-USB-%D0%BD%D0%B0%D0%BA%D0%BE%D0%BF%D0%B8%D1%82%D0%B5%D0%BB%D1%8C)
2. Для использования в режиме Proxy, установить на роутере компонент "Клиент прокси".
3. Установить curl:
   ```bash
   opkg update
   opkg install curl
   ```
4. Установить и настроить сервер TrustTunnel на VPS (см. ниже)

### 1. Установка сервера на VPS

На VPS с Linux (x86_64 или aarch64) выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh | sh -s -
```

Сервер установится в `/opt/trusttunnel`. Запустите мастер настройки:

```bash
cd /opt/trusttunnel/
sudo ./setup_wizard
```

Мастер запросит:
- Адрес для прослушивания (по умолчанию `0.0.0.0:443`)
- Учетные данные пользователя
- Путь для хранения правил фильтрации
- Выбор сертификата (Let's Encrypt, самоподписанный или существующий)

Настройте автозапуск через systemd:

```bash
cp /opt/trusttunnel/trusttunnel.service.template /etc/systemd/system/trusttunnel.service
sudo systemctl daemon-reload
sudo systemctl enable --now trusttunnel
```

#### Настройка Let's Encrypt с автообновлением

Установите Certbot:

```bash
sudo apt update
sudo apt install -y certbot
```

Получите сертификат (замените `example.com` на ваш домен):

```bash
sudo certbot certonly --standalone -d example.com
```

Сертификаты сохранятся в:
- `/etc/letsencrypt/live/example.com/fullchain.pem`
- `/etc/letsencrypt/live/example.com/privkey.pem`

Укажите пути в конфигурации TrustTunnel (`hosts.toml`):

```toml
[[main_hosts]]
hostname = "example.com"
cert_chain_path = "/etc/letsencrypt/live/example.com/fullchain.pem"
private_key_path = "/etc/letsencrypt/live/example.com/privkey.pem"
```

Настройте автоматический перезапуск сервера после обновления сертификата:

```bash
sudo certbot reconfigure --deploy-hook "systemctl reload trusttunnel"
```

Проверьте работу автообновления:

```bash
sudo certbot renew
```

#### Экспорт конфигурации для клиента

После настройки сервера экспортируйте конфигурацию для клиента:

```bash
cd /opt/trusttunnel/
./trusttunnel_endpoint vpn.toml hosts.toml -c имя_клиента -a публичный_ip_сервера --format toml > config.toml
```

Это создаст файл конфигурации `config.toml`, который нужно передать на роутер.

### 2. Установка клиента на Keenetic

Выполните одну команду на роутере:

```bash
curl -fsSL https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases/latest/download/install.sh | sh
```

> Скрипты скачиваются из выпусков (Releases) GitHub, поэтому GitHub считает скачивания — это единственная статистика использования. Никакие данные о вашем роутере никуда не отправляются.

> Скрипт автоматически определяет последнюю стабильную версию (GitHub Release).
> Для установки конкретной версии:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/alex-combine/TrustTunnel-Keenetic-Native/main/install.sh | sh -s -- --version v2.0.2
> ```

> Для установки из ветки `main` (последняя dev-версия):
> ```bash
> curl -fsSL https://raw.githubusercontent.com/alex-combine/TrustTunnel-Keenetic-Native/main/install.sh | sh -s -- --dev
> ```

Скрипт установки выполнит следующее:
1. Остановит работающий сервис TrustTunnel (если запущен)
2. Предложит выбрать режим работы (SOCKS5 или TUN); при повторной настройке по умолчанию предлагается текущий режим
3. Автоматически определит занятые интерфейсы (Proxy для SOCKS5, OpkgTun для TUN) и предложит первый свободный индекс
4. Скачает и установит скрипты автозапуска (`S99trusttunnel`, `010-trusttunnel.sh`) и помощник `tt-stats` (`/opt/bin/tt-stats`)
5. Сохранит выбранный режим в `/opt/trusttunnel_client/mode.conf`
6. Предложит создать интерфейс (ProxyN для SOCKS5 или OpkgTunN для TUN) в Keenetic; при смене режима или индекса удалит старый интерфейс
7. Предложит установить/обновить клиент TrustTunnel (поддерживаемые архитектуры: x86_64, aarch64, armv7, mips, mipsel)

### Сравнение режимов

| | SOCKS5 (ProxyN) | TUN (OpkgTunN) |
|---|---|---|
| Интерфейс Keenetic | ProxyN (по умолчанию Proxy0) | OpkgTunN (по умолчанию OpkgTun0) |
| Тип трафика | TCP через SOCKS5-прокси | Весь трафик (TCP/UDP/ICMP) через TUN |
| Производительность | Ниже (userspace-прокси) | Выше (kernel TUN) |
| Совместимость | Все версии Keenetic с Entware | Keenetic firmware v5+ с поддержкой OpkgTun |
| Требования | — | Пакет `ip-full` в Entware, IP-адрес от VPN-сервера |

#### Настройка клиента

Сгенерируйте конфигурацию из файла, экспортированного с сервера:

```bash
cd /opt/trusttunnel_client/
./setup_wizard --mode non-interactive --endpoint_config config.toml --settings trusttunnel_client.toml
```

Подробная документация: https://github.com/TrustTunnel/TrustTunnel

#### Конфигурация для режима SOCKS5

В файле `trusttunnel_client.toml` должен быть настроен SOCKS-прокси listener:

```toml
[listener]

[listener.socks]
address = "127.0.0.1:1080"
username = ""
password = ""
```

Секции `[listener.tun]` в файле быть не должно.

#### Конфигурация для режима TUN

В файле `trusttunnel_client.toml` должен быть настроен TUN listener:

```toml
[listener]

[listener.tun]
device_name = "opkgtun0"
use_existing = true
bound_if = ""
included_routes = []
excluded_routes = []
change_system_dns = false
mtu_size = 1280
```

- `device_name` + `use_existing` включают **режим attach**: клиент использует устройство `opkgtunN`, которое Keenetic сам создал для `OpkgTunN`, и веб-интерфейс показывает статистику трафика (клиент ≥ 1.0.62; `N` = `TUN_IDX` из `mode.conf`). Без этих двух строк работает классическая схема. Подробно: [Статистика в веб-интерфейсе](#статистика-в-веб-интерфейсе-режим-attach).
- `included_routes = []` в режиме attach обязателен — маршрутизацией занимается Keenetic.
- Рекомендуется в начале файла: `killswitch_enabled = true` (см. [Kill switch](#рекомендуется-kill-switch)).

Секции `[listener.socks]` в файле быть не должно.

Проверить запуск:
```bash
./trusttunnel_client -c trusttunnel_client.toml
```

После настройки запустите сервис:
```bash
/opt/etc/init.d/S99trusttunnel start
```

### Настройка вручную в веб-интерфейсе Keenetic

#### Режим SOCKS5

Если при установке вы пропустили автоматическое создание интерфейса, добавьте прокси-соединение вручную:

1. Откройте веб-интерфейс Keenetic
2. Перейдите в раздел **Другие подключения** -> **Прокси-соединения**
3. Добавьте новое SOCKS5 прокси-соединение с адресом `127.0.0.1` и портом `1080` (имя интерфейса ProxyN, где N — индекс из `mode.conf`)
4. Настройте маршрутизацию трафика через это соединение

#### Режим TUN

Установщик создаёт интерфейс OpkgTunN (N = индекс из `mode.conf`, по умолчанию 0); Keenetic создаёт для него своё устройство `opkgtunN`, и в режиме attach клиент подключается к нему. В классической схеме интерфейс оживает после запуска клиента и переименования `tun0` в `opkgtunN`. Для ручной настройки через CLI:

```bash
ndmc -c 'interface OpkgTunN'
ndmc -c 'interface OpkgTunN description "TrustTunnel TUN N"'
ndmc -c 'interface OpkgTunN ip address <TUN_IP> 255.255.255.255'
ndmc -c 'interface OpkgTunN ip global auto'
ndmc -c 'interface OpkgTunN ip mtu 1280'
ndmc -c 'interface OpkgTunN ip tcp adjust-mss pmtu'
ndmc -c 'interface OpkgTunN security-level public'
ndmc -c 'interface OpkgTunN up'
ndmc -c 'ip route default OpkgTunN'
```

> **Важно:** Команда `ip route default` необходима для корректной работы политик маршрутизации Keenetic через OpkgTunN.

## Статистика в веб-интерфейсе (режим attach)

### Проблема

В режиме TUN веб-интерфейс Keenetic (**Другие подключения → OpkgTunN**) всегда показывает **0** трафика, хотя VPN работает. Командная строка подтверждает, что прошивка ничего не считает:

```
ndmc -c 'show interface OpkgTun0 stat'
    rxbytes: 0
  timestamp: 0.000000
```

Почему: Keenetic сам создаёт устройство ядра `opkgtunN` для интерфейса `OpkgTunN` и собирает статистику **только по этому устройству**. Классическая схема даёт клиенту создать `tun0`, удаляет устройство прошивки и переименовывает `tun0` → `opkgtunN`. Маршрутизация работает (имя совпадает), но прошивка это устройство больше не считает.

### Решение

Начиная с версии **1.0.62** клиент TrustTunnel умеет подключаться к уже существующему TUN-устройству вместо создания своего:

```
Классика:  клиент ──создаёт──> tun0 ──переименование──> opkgtun0   (устройство прошивки удалено)  → в панели: 0
Attach:    Keenetic ──создаёт──> opkgtun0 <──подключается── клиент                                → в панели: реальный трафик
```

```toml
[listener.tun]
device_name = "opkgtun0"   # N = TUN_IDX из mode.conf
use_existing = true
included_routes = []       # обязательно: с готовым устройством клиент не управляет маршрутами
```

Без `included_routes = []` клиент останавливается с ошибкой `Managed routing for an existing TUN device requires sport rule support`. Маршрутизация не меняется: в обоих режимах Keenetic ведёт трафик через `OpkgTunN`, меняется только то, кто создаёт устройство.

**Проверено на:** Keenetic Hero 4G (KN-2310), KeeneticOS 5.1.6 (mips), клиент TrustTunnel 1.1.7. После переключения и одной перезагрузки `show interface OpkgTun0 stat` показывает растущий `timestamp`, `rxbytes` совпадает со счётчиком ядра `/sys/class/net/opkgtun0/statistics/rx_bytes` байт в байт, а веб-интерфейс рисует график трафика.

### Новая установка

Запустите `install.sh`, выберите TUN, добавьте строки выше в конфиг клиента и запустите сервис. Установщик создаёт `OpkgTunN`, и Keenetic сразу создаёт своё устройство. Проверка:

```bash
tt-stats status
```

Если там `not yet` — перезагрузите роутер один раз: `tt-stats reboot`.

### Переход роутера с классической схемы

Для роутеров, настроенных по оригинальному TrustTunnel-Keenetic (или старой версии этого проекта). Ваш конфиг клиента и настройки сохраняются, добавляются только строки режима attach.

```bash
curl -fsSL https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases/latest/download/tt-stats -o /opt/bin/tt-stats
chmod +x /opt/bin/tt-stats
tt-stats status            # только чтение: что сейчас
tt-stats enable --reboot   # безопасное переключение и одна перезагрузка
```

Перезагрузка нужна один раз: классический скрипт удалил устройство прошивки, и Keenetic создаёт его заново при загрузке. До перезагрузки VPN уже работает в режиме attach, просто счётчики стоят на нуле.

**Как `tt-stats enable` бережёт ваше подключение:**

1. **Сначала проверки — если хоть одна не прошла, ничего не меняется:** режим TUN, клиент ≥ 1.0.62, `OpkgTunN` есть в Keenetic, VPN работает прямо сейчас.
2. **Резервная копия:** `S99trusttunnel`, `010-trusttunnel.sh`, конфиг клиента и `mode.conf` копируются в `/opt/trusttunnel_client/backup-classic/` с `MD5SUMS`.
3. **Новые файлы готовятся до остановки сервиса:** скрипты с поддержкой attach скачиваются и проверяются на синтаксис (`sh -n`).
4. **Страховочный таймер:** если переключение не доложит об успехе за 10 минут, классическая схема восстанавливается.
5. **Проверка:** VPN должен ответить за 90 с, журнал клиента должен подтвердить подключение к устройству, затем 3 проверки за 60 с. Любой сбой → автоматический откат.
6. **Сторож загрузки** (`/opt/etc/init.d/S99ttstats-guard`): если после перезагрузки VPN не поднялся за 4 минуты, классическая схема восстанавливается.
7. **`--reboot`** выполняет предполётные проверки (attach включён, копия цела, сторож установлен, VPN работает, настройки сохранены) и только потом перезагружает.

Ручной откат в любой момент:

```bash
tt-stats disable
```

Все действия записываются в `/opt/var/log/tt-stats.log`.

| Команда | Что делает |
|---|---|
| `tt-stats status` | Режим, версия клиента, устройство, проверка VPN, счётчики Keenetic, работает ли статистика (только чтение) |
| `tt-stats enable [--reboot]` | Безопасный переход в режим attach с автоматическим откатом |
| `tt-stats disable` | Возврат классической схемы из резервной копии |
| `tt-stats reboot` | Предполётные проверки и перезагрузка роутера |
| `tt-stats version` | Версия помощника |

### Рекомендуется: kill switch

Поставьте `killswitch_enabled = true` в начале `trusttunnel_client.toml`. С `false` при недоступном VPN-сервере клиент может пустить трафик напрямую через провайдера. Настройка не зависит от режима attach, но её стоит проверить заодно — `tt-stats status` её показывает.

### Дополнительно: защита памяти (роутеры со 128 МБ)

На роутерах со 128 МБ памяти долгая быстрая загрузка через туннель может съесть всю память, и роутер зависает (см. [раздел про зависания](#роутер-зависает-или-перезагружается-во-время-больших-загрузок-через-vpn)). Защита памяти этого не допускает:

```bash
tt-stats memguard on          # включить (порог — 10000 кБ свободной памяти)
tt-stats memguard on 15000    # включить со своим порогом, кБ
tt-stats memguard             # состояние, свободная память, последние события
tt-stats memguard off         # выключить
```

Раз в 5 секунд защита смотрит свободную память (`MemAvailable`). Ниже порога — перезапускает только клиент TrustTunnel: это освобождает его буферы, туннель переподключается за несколько секунд. Если так случилось 3 раза за 10 минут — останавливает VPN на 15 минут и потом запускает снова: короткий перерыв лучше зависшего роутера. При включённом kill switch устройства, которым разрешён только VPN, на время паузы остаются без интернета. Автозапуск: `/opt/etc/init.d/S97tt-memguard`, журнал: `/opt/var/log/tt-memguard.log`.

### Частые вопросы

- **Меняет ли режим attach маршрутизацию, политики или firewall?** Нет. В обоих режимах Keenetic ведёт трафик через `OpkgTunN`; меняется только то, кто создаёт устройство.
- **Мой клиент старше 1.0.62.** `tt-stats enable` откажется переключать. Обновите клиент (`install.sh` это предлагает) и запустите снова.
- **Режим SOCKS5?** Режим attach относится только к TUN.
- **MTU?** В режиме attach MTU устройства берётся из `TUN_MTU` в `mode.conf`; `tt-stats enable` ставит его по `mtu_size` из конфига клиента и выравнивает с ним `interface OpkgTunN ip mtu`.
- **Что если сразу после перезагрузки лежит сам VPN-сервер?** Сторож загрузки не может отличить сбой сервера от неудачного переключения, поэтому для надёжности возвращает классическую схему. Когда сервер вернётся, снова выполните `tt-stats enable --reboot`.
- **Как вернуться обратно?** `tt-stats disable` (или вручную восстановите файлы из `/opt/trusttunnel_client/backup-classic/`).

## Структура файлов

```
/opt/
├── bin/
│   └── tt-stats                    # Помощник статистики: status / enable / disable
├── etc/
│   ├── init.d/
│   │   ├── S99trusttunnel          # Основной init-скрипт
│   │   ├── S99ttstats-guard        # Сторож загрузки (создаёт tt-stats enable)
│   │   └── S97tt-memguard          # Защита памяти (создаёт tt-stats memguard on)
│   └── ndm/
│       └── wan.d/
│           └── 010-trusttunnel.sh  # Хук при поднятии WAN
├── var/
│   ├── run/
│   │   ├── trusttunnel.pid         # PID клиента
│   │   ├── trusttunnel_watchdog.pid # PID watchdog
│   │   ├── trusttunnel_hc_state    # Состояние health check
│   │   └── trusttunnel_start_ts    # Время старта клиента (для grace period WAN-хука)
│   └── log/
│       ├── trusttunnel.log         # Лог работы (ротация при 512 КБ)
│       ├── trusttunnel.log.old     # Предыдущий лог после ротации
│       └── tt-stats.log            # Лог tt-stats (переключения, откаты, сторож загрузки)
└── trusttunnel_client/
    ├── trusttunnel_client          # Бинарник клиента
    ├── trusttunnel_client.toml     # Конфигурация
    ├── mode.conf                   # Режим работы (socks5/tun), TUN_IDX, PROXY_IDX, TUN_MTU, настройки HC
    └── backup-classic/             # Копия классической схемы от tt-stats enable (+ MD5SUMS)
```

## Ручная установка

Если вы предпочитаете ручную установку вместо скрипта:

```bash
VERSION="v2.0.2"  # Укажите нужную версию (тег GitHub Release)

# Создаём директории
mkdir -p /opt/etc/init.d
mkdir -p /opt/etc/ndm/wan.d
mkdir -p /opt/var/run
mkdir -p /opt/var/log

# Init-скрипт
curl -fsSL "https://raw.githubusercontent.com/alex-combine/TrustTunnel-Keenetic-Native/${VERSION}/S99trusttunnel" -o /opt/etc/init.d/S99trusttunnel
chmod +x /opt/etc/init.d/S99trusttunnel

# WAN-хук
curl -fsSL "https://raw.githubusercontent.com/alex-combine/TrustTunnel-Keenetic-Native/${VERSION}/010-trusttunnel.sh" -o /opt/etc/ndm/wan.d/010-trusttunnel.sh
chmod +x /opt/etc/ndm/wan.d/010-trusttunnel.sh

# Помощник статистики
mkdir -p /opt/bin
curl -fsSL "https://raw.githubusercontent.com/alex-combine/TrustTunnel-Keenetic-Native/${VERSION}/tt-stats" -o /opt/bin/tt-stats
chmod +x /opt/bin/tt-stats

# Убедитесь, что клиент исполняемый
chmod +x /opt/trusttunnel_client/trusttunnel_client
```

## Использование

### Управление сервисом

```bash
# Запуск (клиент + watchdog)
/opt/etc/init.d/S99trusttunnel start

# Остановка (клиент + watchdog)
/opt/etc/init.d/S99trusttunnel stop

# Полный перезапуск
/opt/etc/init.d/S99trusttunnel restart

# Мягкий перезапуск (только клиент, watchdog перезапустит его)
/opt/etc/init.d/S99trusttunnel reload

# Проверка статуса
/opt/etc/init.d/S99trusttunnel status
```

### Просмотр логов

```bash
# Текущий лог
cat /opt/var/log/trusttunnel.log

# В реальном времени
tail -f /opt/var/log/trusttunnel.log
```

Лог автоматически ротируется при достижении 512 КБ: текущий файл переименовывается в `trusttunnel.log.old`.

## Как это работает

### Автозапуск при загрузке
- Entware автоматически запускает все скрипты `S*` в `/opt/etc/init.d/` при старте
- Скрипт `S99trusttunnel` запускается последним (99 = высокий приоритет)

### Watchdog (перезапуск при падении)
- После запуска клиента стартует фоновый процесс watchdog
- Каждые 10 секунд проверяет, жив ли клиент
- При падении автоматически перезапускает с линейным backoff: 10с, 20с, 30с... до 300с (максимум 10 попыток)
- Дополнительно проверяет реальную связность через туннель (health check)

### Переподключение WAN
- Keenetic вызывает скрипты из `/opt/etc/ndm/wan.d/` при поднятии WAN
- Скрипт `010-trusttunnel.sh` инициирует перезапуск клиента, с рядом защит:
  - **Пропуск собственного интерфейса** — если WAN-событие вызвано нашим же `OpkgTunN`, перезапуск не происходит (предотвращает бесконечный цикл)
  - **Grace period** — если клиент запущен менее 30 секунд назад, перезапуск пропускается
  - **Проверка состояния сервиса** — перезапуск только если watchdog активен (сервис запущен)
- В режиме TUN: перед перезапуском опускаются интерфейсы `opkgtunN`/`tun0`
- Watchdog подхватит и запустит клиент заново

### Health check (мониторинг связности)

Watchdog проверяет не только живость процесса, но и реальную связность через туннель:

- **TUN-режим**: HTTP-запрос через интерфейс `opkgtunN` (`curl --interface`)
- **SOCKS5-режим**: HTTP-запрос через прокси (`curl --socks5`, по умолчанию `127.0.0.1:1080`, настраивается через `HC_SOCKS5_PROXY`)

Оба режима используют легковесный connectivity-check endpoint (HTTP 204, без тела).

Параметры по умолчанию:

| Параметр | Значение | Описание |
|---|---|---|
| `HC_ENABLED` | `yes` | Включить/выключить health check |
| `HC_INTERVAL` | `30` | Интервал проверки (секунды) |
| `HC_FAIL_THRESHOLD` | `3` | Сбоев подряд до переподключения |
| `HC_GRACE_PERIOD` | `60` | Пауза без проверок после (пере)старта |
| `HC_TARGET_URL` | `http://connectivitycheck.gstatic.com/generate_204` | URL для проверки связности |
| `HC_CURL_TIMEOUT` | `5` | Таймаут curl (секунды) |
| `HC_SOCKS5_PROXY` | `127.0.0.1:1080` | Адрес SOCKS5-прокси для проверки (режим SOCKS5) |

Для настройки раскомментируйте и измените параметры в `/opt/trusttunnel_client/mode.conf`.

Для полного отключения health check:
```
HC_ENABLED="no"
```

Текущий статус health check отображается в выводе `status`:
```bash
/opt/etc/init.d/S99trusttunnel status
# Health check: ok (2025-01-15 12:34:56)
```

### Режим TUN (OpkgTunN)

**Режим attach** (`use_existing = true` в конфиге клиента):
- Keenetic создаёт устройство `opkgtunN` для интерфейса `OpkgTunN` (при создании интерфейса и при каждой загрузке)
- Init-скрипт ждёт устройство (до 15 секунд), выставляет MTU (`TUN_MTU`) и адреса и запускает клиент
- Клиент подключается к устройству; Keenetic считает его трафик и показывает в веб-интерфейсе
- Если устройства нет, init-скрипт создаёт его сам, чтобы VPN работал (статистика появится после одной перезагрузки)

**Классическая схема** (без `use_existing`):
- TrustTunnel Client создаёт интерфейс `tun0`
- Init-скрипт ожидает появления `tun0` (до 30 секунд) и переименовывает его в `opkgtunN` (N = индекс из `mode.conf`)
- Keenetic распознаёт `opkgtunN` как интерфейс `OpkgTunN` и применяет маршрутизацию/firewall
- Watchdog проверяет и исправляет непереименованный `tun0` при каждом цикле

### Защита от дублей
- PID-файл предотвращает запуск нескольких экземпляров
- Проверка через `pidof` как fallback

## Отключение автозапуска

```bash
# Временно (до следующего ребута)
/opt/etc/init.d/S99trusttunnel stop

# Постоянно
# Измените ENABLED=yes на ENABLED=no в скрипте
# или удалите/переименуйте скрипт:
mv /opt/etc/init.d/S99trusttunnel /opt/etc/init.d/_S99trusttunnel
```

## Troubleshooting

### Роутер зависает или перезагружается во время больших загрузок через VPN

На роутерах со 128 МБ памяти (например, MIPS-модели вроде Keenetic Hero 4G) долгая быстрая загрузка через туннель — обновление Steam или игры, торрент — может съесть всю память: клиент набирает трафик быстрее, чем процессор успевает его шифровать. Веб-интерфейс перестаёт отвечать, роутер может перезагрузиться, а если загрузка после перезагрузки продолжится — всё повторяется.

Что помогает:
1. **Пустить большие загрузки мимо VPN** — им он обычно не нужен. Для устройств без политики доступа: Маршрутизация → DNS-маршруты в веб-интерфейсе Keenetic (например, `steamcontent.com` через подключение провайдера).
2. **Ограничить скорость загрузки** в самой программе (Steam: Настройки → Загрузки).
3. **Включить защиту памяти:** `tt-stats memguard on` — см. [Защита памяти](#дополнительно-защита-памяти-роутеры-со-128-мб).
4. Проверить память: `grep MemAvailable /proc/meminfo` — ниже примерно 10 МБ роутер в опасности.

### Загрузка обрывается: `Connection reset by peer`

Если команда установки падает с `curl: (35) Recv failure: Connection reset by peer` (или по таймауту), значит провайдер обрывает соединения с GitHub. С роутером всё в порядке. Что можно сделать:

1. Повторить команду несколько раз — обрывы часто бывают не каждый раз.
2. Скачать файлы релиза на компьютере со страницы [Releases](https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases/latest) (`install.sh`, `configure.sh`, `S99trusttunnel`, `010-trusttunnel.sh`, `tt-stats`), скопировать их на роутер (например, WinSCP или `scp` в `/opt/tmp/`) и выполнить [ручную установку](#ручная-установка).
3. Если на роутере уже есть работающее VPN-подключение — направить через него `github.com` и `githubusercontent.com` (Маршрутизация → DNS-маршруты в веб-интерфейсе Keenetic) и повторить команду.

### Клиент не запускается
```bash
# Проверьте права
ls -la /opt/trusttunnel_client/

# Попробуйте запустить вручную
/opt/trusttunnel_client/trusttunnel_client -c /opt/trusttunnel_client/trusttunnel_client.toml

# Проверьте лог
cat /opt/var/log/trusttunnel.log
```

### Watchdog не работает
```bash
# Проверьте процессы
ps | grep trusttunnel

# Проверьте PID файлы
cat /opt/var/run/trusttunnel_watchdog.pid
```

### WAN-хук не срабатывает
```bash
# Проверьте права
ls -la /opt/etc/ndm/wan.d/

# Проверьте, что Keenetic поддерживает ndm хуки
# (требуется установленный пакет opt в прошивке)
```

### TUN-интерфейс не появляется (режим TUN)
```bash
# Проверьте текущий режим и TUN_IDX в mode.conf
cat /opt/trusttunnel_client/mode.conf

# Проверьте наличие tun0 / opkgtunN
ip link show tun0
ip link show opkgtunN  # N = TUN_IDX из mode.conf

# Проверьте, что ip-full установлен
opkg list-installed | grep ip-full

# Попробуйте переименовать вручную (замените N на индекс)
ip link set tun0 down
ip link set tun0 name opkgtunN
ip link set opkgtunN up

# Проверьте лог на ошибки переименования
logread | grep TrustTunnel | tail -20
```

### Health check вызывает частые переподключения

Если туннель работает, но health check регулярно фиксирует сбои и перезапускает клиент:

```bash
# Увеличьте порог сбоев и интервал проверки в /opt/trusttunnel_client/mode.conf:
HC_FAIL_THRESHOLD=5
HC_INTERVAL=60

# Или полностью отключите health check:
HC_ENABLED="no"

# Перезапустите сервис после изменения настроек:
/opt/etc/init.d/S99trusttunnel restart
```

### Веб-интерфейс показывает 0 трафика у OpkgTunN
```bash
tt-stats status
```
- `Attach mode: no` → см. [Переход роутера с классической схемы](#переход-роутера-с-классической-схемы)
- `Attach mode: yes`, статистика `not yet` → перезагрузите один раз: `tt-stats reboot`
- `Client version ... TOO OLD` → обновите клиент до 1.0.62 или новее

### OpkgTunN не виден в веб-интерфейсе Keenetic
```bash
# Проверьте, что интерфейс создан в Keenetic (замените N на индекс из mode.conf)
ndmc -c 'show interface' | grep OpkgTunN

# Если нет — создайте вручную (замените N и IP)
ndmc -c 'interface OpkgTunN'
ndmc -c 'interface OpkgTunN ip address 172.16.219.2 255.255.255.255'
ndmc -c 'interface OpkgTunN ip global auto'
ndmc -c 'interface OpkgTunN security-level public'
ndmc -c 'interface OpkgTunN up'
ndmc -c 'ip route default OpkgTunN'
ndmc -c 'system configuration save'
```

## Благодарности

Основано на [TrustTunnel-Keenetic](https://github.com/artemevsevev/TrustTunnel-Keenetic) (автор — Artem Evsevev, MIT). Режим attach использует параметр `use_existing` клиента [TrustTunnel](https://github.com/TrustTunnel/TrustTunnel).
