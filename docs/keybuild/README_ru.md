# Сборка клиента TrustTunnel с ключом-пропуском для роутеров MIPS

[🇺🇸 English](README.md)

**Зачем.** В TrustTunnel 1.3 сервер может пускать только клиентов с ключом-пропуском (`client_random_auth_key`). Официальный клиент для роутеров с процессором MIPS little-endian (mipsel — большинство Keenetic) собран с OpenSSL, а код ключа там включается только с BoringSSL. Поэтому такой клиент ключ **молча не использует**, и сервер, где ключ обязателен, роутер не пустит.

**Что сделано.** Те же исходники клиента (`7bde23f`, это 1.3.0 и ещё два коммита) и две небольшие правки:

- OpenSSL 4.0.2: функция `SSL_set_custom_client_random()` — своё 32-байтовое значение ClientRandom в ClientHello, только для TLS 1.3 (как в патче AdGuard для BoringSSL), и `HKDF()` с порядком аргументов BoringSSL;
- клиент: код ключа собирается с OpenSSL.

Обе правки прошли четыре круга внешней проверки кода и проверены вживую: сервер видит ключ, а клиент с неверным ключом получает отказ.

> **Функция новая: пока проверена на одном роутере.** Ставится с автоматическим откатом.

## Как поставить

Установщик сам предложит сборку на подходящем роутере (по умолчанию — «нет»). Вручную:

```bash
tt-stats keybuild            # что стоит и нужна ли сборка этому роутеру
tt-stats keybuild install    # поставить
tt-stats keybuild revert     # вернуть прежний клиент
```

`install` скачивает `trusttunnel_client-authkey-mipsel` из выпуска и сверяет `sha256`, пробно запускает его на роутере и сохраняет прежний клиент в `/opt/trusttunnel_client/trusttunnel_client.official`. Потом меняет клиент и перезапускает VPN. Если VPN не поднимется за 90 секунд или 4 раза подряд не ответит в следующие 10 минут, прежний клиент вернётся сам. SSH можно закрыть.

Затем добавьте ключ в настройки клиента, в раздел `[endpoint]`, — через `tt-stats apply`, он тоже откатывает сам:

```bash
cp /opt/trusttunnel_client/trusttunnel_client.toml /opt/tmp/new.toml
# в /opt/tmp/new.toml в [endpoint]: client_random_auth_key = "<ключ с сервера, 64 hex>"
tt-stats apply /opt/tmp/new.toml
tt-stats selftest            # «auth key: set, this client build supports it»
```

Своя сборка у вас уже есть? Поставьте её так: `tt-stats keybuild install /путь/к/файлу` (рядом можно положить `файл.sha256`).

## Собрать самому

Linux x86_64, около 25 ГБ места, 1–2 часа на двух ядрах. Нужны `git`, `curl`, `python3`, `make`, `file` и `mipsel-linux-gnu-strip` (Debian/Ubuntu: `apt install binutils-mipsel-linux-gnu`). Остальное скрипт скачает сам: zig 0.17.1 (со сверкой контрольной суммы), Rust 1.95 и nightly с `rust-src`, conan 2.34, cmake, ninja.

```bash
./build.sh /путь/к/рабочей/папке
```

Результат — `trusttunnel_client-authkey-mipsel` и `.sha256`. Сверка: в бинарнике **нет** строки `SSL_set_custom_client_random is unavailable` (она есть только в сборках без поддержки ключа).

## Лицензии

Клиент TrustTunnel и OpenSSL — Apache License 2.0 ([LICENSE-Apache-2.0](LICENSE-Apache-2.0)). Что изменено, перечислено в [NOTICE](NOTICE). Полные правки лежат в [patches/](patches/).
