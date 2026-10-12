#!/bin/sh

set -e
# Uncomment for debugging:
# set -x

# Language (ru|en) comes from install.sh in TT_LANG; asked here if missing
case "$TT_LANG" in ru|en) ;; *)
    printf "Язык / Language: 1) Русский  2) English [1]: "
    if read lang_choice < /dev/tty 2>/dev/null; then
        case "$lang_choice" in 2|en|EN|e|E) TT_LANG=en ;; *) TT_LANG=ru ;; esac
    else TT_LANG=en; fi ;;
esac
L() { if [ "$TT_LANG" = ru ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# REPO_URL is passed from install.sh via environment variable
if [ -z "$REPO_URL" ]; then
    echo "$(L 'Ошибка: не задан REPO_URL. Запустите install.sh.' 'Error: REPO_URL is not set. Run install.sh.')"
    exit 1
fi

cleanup_on_error() {
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        echo "!!! $(L 'Установка прервана из-за ошибки' 'Installation aborted due to error') ($(L 'код' 'code'): $exit_code) !!!"
        echo "$(L 'Чтобы поставить заново, запустите скрипт ещё раз.' 'To reinstall, run the script again.')"
        echo "$(L 'Чтобы убрать вручную, удалите:' 'To clean up manually, delete:')"
        echo "  rm -f /opt/etc/init.d/S99trusttunnel"
        echo "  rm -f /opt/etc/ndm/wan.d/010-trusttunnel.sh"
        echo "  rm -f /opt/trusttunnel_client/mode.conf"
        echo "  rm -f /opt/bin/tt-stats"
        echo "  rm -f /opt/etc/cron.daily/tt-stats-update-check"
    fi
}
trap cleanup_on_error EXIT

if [ ! -d "/opt" ]; then
    echo "$(L 'Ошибка: нет /opt. Сначала установите Entware.' 'Error: /opt not found. Install Entware first.')"
    echo "$(L 'Подробнее' 'Details'): https://help.keenetic.com/hc/$(L ru en-us)/articles/360021214160"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "$(L "Ошибка: нет команды 'curl'. Установите пакет curl:" "Error: 'curl' command not found. Install curl package:")"
    echo "  opkg update && opkg install curl"
    exit 1
fi

ask_yes_no() {
    printf "%s (%s) " "$1" "$(L 'д/н' 'y/n')"
    read answer < /dev/tty || return 1
    case "$answer" in
        y|Y|д|Д|l|L) return 0 ;;
        *) return 1 ;;
    esac
}

# === Stop running service ===
INIT_SCRIPT="/opt/etc/init.d/S99trusttunnel"
if [ -x "$INIT_SCRIPT" ]; then
    echo "$(L 'Останавливаю TrustTunnel...' 'Stopping TrustTunnel...')"
    "$INIT_SCRIPT" stop || true
fi

# Find first free interface index by prefix
# Usage: find_free_index <prefix> <existing_idx>
# Sets shell variable: default_idx
find_free_index() {
    _fi_prefix="$1"
    _fi_existing="$2"

    if [ -n "$_fi_existing" ]; then
        default_idx="$_fi_existing"
    else
        default_idx="0"
    fi

    if ! command -v ndmc >/dev/null 2>&1; then
        return 0
    fi

    _fi_scan=$(ndmc -c 'show interface' 2>/dev/null) || return 0
    [ -n "$_fi_scan" ] || return 0

    _fi_used=$(echo "$_fi_scan" | grep -E "${_fi_prefix}[0-9]+" | sed -E "s/.*${_fi_prefix}([0-9]+).*/\1/" | sort -nu || true)

    # If no interfaces found, just return with default_idx already set
    if [ -z "$_fi_used" ]; then
        return 0
    fi

    echo "$(L "Нашёл интерфейсы ${_fi_prefix}:" "Discovered existing ${_fi_prefix}-interfaces:")"
    echo "$_fi_scan" | { grep -E "${_fi_prefix}[0-9]+" || true; } | while read -r _fi_line; do
        echo "  $_fi_line"
    done
    echo ""

    if [ -z "$_fi_existing" ]; then
        _fi_next=0
        for _fi_idx in $_fi_used; do
            if [ "$_fi_next" -eq "$_fi_idx" ]; then
                _fi_next=$((_fi_next + 1))
            fi
        done
        default_idx="$_fi_next"
    fi

    return 0
}

# === Read existing config ===
EXISTING_TUN_IDX=""
EXISTING_PROXY_IDX=""
EXISTING_MODE=""
if [ -f /opt/trusttunnel_client/mode.conf ]; then
    . /opt/trusttunnel_client/mode.conf
    EXISTING_TUN_IDX="${TUN_IDX:-0}"
    EXISTING_PROXY_IDX="${PROXY_IDX:-0}"
    EXISTING_MODE="${TT_MODE:-socks5}"
fi

# === Mode selection ===
if [ "$EXISTING_MODE" = "tun" ]; then
    default_mode=2
else
    default_mode=1
fi
echo "$(L 'Выберите режим работы TrustTunnel:' 'Select TrustTunnel operation mode:')"
echo "  1) SOCKS5 - $(L 'прокси через интерфейс Proxy' 'proxying through Proxy interface')"
echo "  2) TUN    - $(L 'туннель через интерфейс OpkgTun (только прошивка 5.x; нужен для Развилки)' 'tunnel through OpkgTun interface (only for firmware 5.x; needed for Razvilka)')"
printf "%s [%s]: " "$(L 'Режим' 'Mode')" "$default_mode"
read mode_choice < /dev/tty
mode_choice="${mode_choice:-$default_mode}"
case "$mode_choice" in
    2) TT_MODE="tun" ;;
    *) TT_MODE="socks5" ;;
esac
echo "$(L 'Выбран режим' 'Selected mode'): $TT_MODE"
echo ""

TUN_IP="172.16.219.2"
TUN_IPV6="fd01::2"
if [ "$TT_MODE" = "tun" ]; then
    if ! command -v ip >/dev/null 2>&1; then
        echo "$(L "Ошибка: нет команды 'ip'. Установите пакет ip-full:" "Error: 'ip' command not found. Install ip-full package:")"
        echo "  opkg update && opkg install ip-full"
        exit 1
    fi
    echo "TUN IP: $TUN_IP"
    echo "TUN IPv6: $TUN_IPV6"
    echo ""

    find_free_index "OpkgTun" "$EXISTING_TUN_IDX"

    printf "%s (%s %s): " "$(L 'Номер интерфейса OpkgTun' 'OpkgTun interface index')" "$(L 'по умолчанию' 'default')" "$default_idx"
    read tun_idx_input < /dev/tty
    TUN_IDX="${tun_idx_input:-$default_idx}"
    case "$TUN_IDX" in
        ''|*[!0-9]*)
            echo "$(L 'Ошибка: номер — целое число от 0.' 'Error: index must be a non-negative number.')"
            exit 1 ;;
    esac
    echo "$(L 'Интерфейс' 'Interface'): OpkgTun${TUN_IDX} (opkgtun${TUN_IDX})"
    echo ""
    PROXY_IDX="${EXISTING_PROXY_IDX:-0}"
else
    TUN_IDX="${EXISTING_TUN_IDX:-0}"

    find_free_index "Proxy" "$EXISTING_PROXY_IDX"

    printf "%s (%s %s): " "$(L 'Номер интерфейса Proxy' 'Proxy interface index')" "$(L 'по умолчанию' 'default')" "$default_idx"
    read proxy_idx_input < /dev/tty
    PROXY_IDX="${proxy_idx_input:-$default_idx}"
    case "$PROXY_IDX" in
        ''|*[!0-9]*)
            echo "$(L 'Ошибка: номер — целое число от 0.' 'Error: index must be a non-negative number.')"
            exit 1 ;;
    esac
    echo "$(L 'Интерфейс' 'Interface'): Proxy${PROXY_IDX}"
    echo ""
fi

echo "$(L 'Создаю папки...' 'Creating directories...')"
mkdir -p /opt/etc/init.d
mkdir -p /opt/etc/ndm/wan.d
mkdir -p /opt/var/run
mkdir -p /opt/var/log
mkdir -p /opt/trusttunnel_client

echo "$(L 'Скачиваю' 'Downloading') S99trusttunnel..."
curl -fsSL "$REPO_URL/S99trusttunnel" -o /opt/etc/init.d/S99trusttunnel
chmod +x /opt/etc/init.d/S99trusttunnel

echo "$(L 'Скачиваю' 'Downloading') 010-trusttunnel.sh..."
curl -fsSL "$REPO_URL/010-trusttunnel.sh" -o /opt/etc/ndm/wan.d/010-trusttunnel.sh
chmod +x /opt/etc/ndm/wan.d/010-trusttunnel.sh

echo "$(L 'Скачиваю tt-stats (статистика в веб-панели)...' 'Downloading tt-stats (dashboard statistics helper)...')"
mkdir -p /opt/bin
curl -fsSL "$REPO_URL/tt-stats" -o /opt/bin/tt-stats
sed -i "s|^TTS_REPO_URL=.*|TTS_REPO_URL=\"\${TTS_REPO_URL:-$REPO_URL}\"|" /opt/bin/tt-stats
chmod +x /opt/bin/tt-stats
/opt/bin/tt-stats update-check --install-cron || true   # daily "update available" note (reads only the version number)

# === Write mode.conf ===
echo "$(L 'Сохраняю режим в' 'Saving mode to') /opt/trusttunnel_client/mode.conf..."
cat > /opt/trusttunnel_client/mode.conf <<MEOF
# TrustTunnel mode: socks5 or tun
TT_MODE="$TT_MODE"
TUN_IP="$TUN_IP"
TUN_IPV6="$TUN_IPV6"
TUN_IDX="$TUN_IDX"
PROXY_IDX="$PROXY_IDX"
# MTU of the TUN device (keep equal to mtu_size in the client config)
TUN_MTU="1280"

# Health check settings (uncomment to customize)
# HC_ENABLED="yes"
# HC_INTERVAL=30
# HC_FAIL_THRESHOLD=3
# HC_GRACE_PERIOD=60
# HC_TARGET_URL="http://connectivitycheck.gstatic.com/generate_204"
# HC_CURL_TIMEOUT=5
# HC_SOCKS5_PROXY="127.0.0.1:1080"
MEOF
echo "$(L 'mode.conf сохранён' 'mode.conf saved') (TT_MODE=$TT_MODE)."

# === Interface ===
if ask_yes_no "$(L 'Создать интерфейс TrustTunnel?' 'Create TrustTunnel interface?')"; then

    if ! command -v ndmc >/dev/null 2>&1; then
        echo "$(L "Ошибка: нет команды 'ndmc'. Настроить интерфейс не получится." "Error: 'ndmc' command not found. Interface configuration is not possible.")"
        echo "$(L 'Настройте интерфейс вручную в веб-панели роутера.' "Configure the interface manually via the router's web interface.")"
    else
        ndmc_iface_output=$(ndmc -c 'show interface' 2>&1) || {
            echo "$(L 'Ошибка: ndmc не отдал список интерфейсов.' 'Error: failed to get interface list from ndmc.')"
            echo "$(L 'Настройте интерфейс вручную в веб-панели роутера.' "Configure the interface manually via the router's web interface.")"
            ndmc_iface_output=""
        }

        if [ -n "$ndmc_iface_output" ]; then
            # Determine old interface name for cleanup
            OLD_IFACE_NAME=""
            if [ -n "$EXISTING_MODE" ]; then
                if [ "$EXISTING_MODE" = "tun" ]; then
                    OLD_IFACE_NAME="OpkgTun${EXISTING_TUN_IDX}"
                else
                    OLD_IFACE_NAME="Proxy${EXISTING_PROXY_IDX}"
                fi
            fi

            # Remove old interface if index or mode changed
            NDMC_IFACE="OpkgTun${TUN_IDX}"
            if [ "$TT_MODE" = "socks5" ]; then
                IFACE_NAME="Proxy${PROXY_IDX}"
            else
                IFACE_NAME="${NDMC_IFACE}"
            fi
            if [ -n "$OLD_IFACE_NAME" ] && [ "$OLD_IFACE_NAME" != "$IFACE_NAME" ]; then
                echo "$(L 'Убираю старый интерфейс' 'Removing old interface') ${OLD_IFACE_NAME}..."
                ndmc -c "no interface ${OLD_IFACE_NAME}" || true
            fi

            if [ -n "$OLD_IFACE_NAME" ] && [ "$OLD_IFACE_NAME" = "$IFACE_NAME" ]; then
                # Interface already configured — skip creation, just ensure default route
                echo "$(L "Интерфейс ${IFACE_NAME} уже настроен, не создаю заново." "Interface ${IFACE_NAME} is already configured, skipping creation.")"
                if [ "$TT_MODE" = "tun" ]; then
                    ndmc -c "ip route default $TUN_IP ${NDMC_IFACE}"
                    ndmc -c "ipv6 route default ${NDMC_IFACE}"
                fi
            elif [ "$TT_MODE" = "socks5" ]; then
                # --- SOCKS5 Interface ---
                echo "$(L 'Настраиваю интерфейс' 'Configuring interface') Proxy${PROXY_IDX}..."
                ndmc -c "interface Proxy${PROXY_IDX}"
                ndmc -c "interface Proxy${PROXY_IDX} description \"TrustTunnel Proxy ${PROXY_IDX}\""
                ndmc -c "interface Proxy${PROXY_IDX} proxy protocol socks5"
                ndmc -c "interface Proxy${PROXY_IDX} proxy upstream 127.0.0.1 1080"
                ndmc -c "interface Proxy${PROXY_IDX} proxy connect"
                ndmc -c "interface Proxy${PROXY_IDX} ip global auto"
                ndmc -c "interface Proxy${PROXY_IDX} security-level public"
                echo "$(L 'Интерфейс настроен' 'Interface configured'): Proxy${PROXY_IDX}."
            else
                # --- TUN Interface ---
                echo "$(L 'Настраиваю интерфейс' 'Configuring interface') ${NDMC_IFACE}..."
                ndmc -c "interface ${NDMC_IFACE}"
                ndmc -c "interface ${NDMC_IFACE} description \"TrustTunnel TUN ${TUN_IDX}\""
                ndmc -c "interface ${NDMC_IFACE} ip address $TUN_IP 255.255.255.255"
                ndmc -c "interface ${NDMC_IFACE} ipv6 address $TUN_IPV6"
                ndmc -c "interface ${NDMC_IFACE} ip global auto"
                ndmc -c "interface ${NDMC_IFACE} ip mtu 1280"
                ndmc -c "interface ${NDMC_IFACE} ip tcp adjust-mss pmtu"
                ndmc -c "interface ${NDMC_IFACE} security-level public"
                ndmc -c "interface ${NDMC_IFACE} up"
                ndmc -c "ip route default $TUN_IP ${NDMC_IFACE}"
                ndmc -c "ipv6 route default ${NDMC_IFACE}"
                echo "$(L 'Интерфейс настроен' 'Interface configured'): ${NDMC_IFACE}."
            fi

            ndmc -c 'system configuration save'
            echo "$(L 'Настройки роутера сохранены.' 'Configuration saved.')"
        fi
    fi
else
    echo "$(L 'Интерфейс не трогаю.' 'Interface configuration skipped.')"
fi


# === TrustTunnel install ===
if ask_yes_no "$(L 'Установить или обновить клиент TrustTunnel?' 'Install/Update TrustTunnel Client?')"; then
    echo "$(L 'Ставлю клиент TrustTunnel (его установщик говорит по-английски)...' 'Starting TrustTunnel installation...')"
    curl -fsSL https://raw.githubusercontent.com/TrustTunnel/TrustTunnelClient/refs/heads/master/scripts/install.sh | sh -s -
    echo "$(L 'Клиент TrustTunnel установлен.' 'TrustTunnel installation completed.')"
else
    echo "$(L 'Клиент TrustTunnel не трогаю.' 'TrustTunnel installation skipped.')"
fi

# === Attach mode support (dashboard statistics) needs client >= 1.0.62 ===
CLIENT_VERSION=""
if [ -x /opt/trusttunnel_client/trusttunnel_client ]; then
    CLIENT_VERSION=$(/opt/trusttunnel_client/trusttunnel_client --version 2>/dev/null | awk '{print $2; exit}')
fi
if [ "$TT_MODE" = "tun" ] && [ -n "$CLIENT_VERSION" ]; then
    if awk -v a="$CLIENT_VERSION" -v b="1.0.62" 'BEGIN {
            split(a, x, "."); split(b, y, ".")
            for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
            exit 0 }'; then
        echo "$(L "Клиент $CLIENT_VERSION умеет режим подключения к устройству (статистика в веб-панели)." "Client $CLIENT_VERSION supports attach mode (dashboard statistics).")"
    else
        echo "$(L "ВНИМАНИЕ: клиент $CLIENT_VERSION старше 1.0.62 и не может подключиться к устройству KeeneticOS." "WARNING: client $CLIENT_VERSION is older than 1.0.62 and cannot attach to the KeeneticOS device.")"
        echo "         $(L 'Обновите клиент или не добавляйте use_existing/device_name в настройки.' 'Update the client, or do not add use_existing/device_name to the config.')"
    fi
fi

# === Razvilka (beta, optional): home country direct, everything else via VPN ===
RZV_DIR="/opt/tmp/razvilka-setup"
RZV_GOT=""
echo ""
echo "--------------------------------------------------------------------"
if [ "$TT_LANG" = ru ]; then cat <<'REOF'
 Развилка (по желанию, бета) - две дороги для домашнего интернета
--------------------------------------------------------------------
 * Банки, госуслуги и местные сервисы своей страны открываются напрямую:
   быстро, и они перестают ругаться на VPN.
 * Всё остальное по-прежнему идёт через ваш TrustTunnel.
 * Свой Telegram-бот на роутере: проверить любой сайт и переключить его
   одной кнопкой, правило для каждого устройства, утренняя сводка,
   тревога, если VPN пропал, а зависший VPN роутер перезапустит сам.
 Сейчас она только скачается - ничего не изменится. Попробовать потом
 можно пробой (--demo), которая ничего не меняет; удалить - одной
 командой. Нужен TrustTunnel в режиме TUN. Подробнее: razvilka/README_ru.md
REOF
else cat <<'REOF'
 Razvilka (optional, beta) - two roads for your home internet
--------------------------------------------------------------------
 * Banks, government and local services of your country open directly:
   fast, and they stop complaining about the VPN.
 * Everything else stays behind your TrustTunnel.
 * Your own Telegram bot on the router: check any site and switch it with
   one tap, per-device rules, a morning summary, an alarm if the VPN drops,
   and the router restarts a hung VPN by itself.
 Now it is only downloaded - nothing changes. Try it later with a dry run
 (--demo) that changes nothing; remove it with one command. Needs
 TrustTunnel in TUN mode. More: razvilka/README.md
REOF
fi
if ask_yes_no "$(L 'Скачать Развилку, чтобы попробовать потом?' 'Download Razvilka to try it later?')"; then
    mkdir -p "$RZV_DIR"
    if curl -fsSL "$REPO_URL/razvilka.tar.gz" -o /opt/tmp/razvilka.tar.gz && tar xzf /opt/tmp/razvilka.tar.gz -C "$RZV_DIR"; then
        RZV_GOT="yes"
        echo "$(L 'Развилка скачана в' 'Razvilka downloaded to') $RZV_DIR"
    else
        echo "$(L 'Не удалось скачать Развилку (нет в этом выпуске?). Как взять её потом — в razvilka/README_ru.md.' 'Could not download Razvilka (not attached to this release?). See razvilka/README.md to get it later.')"
    fi
    rm -f /opt/tmp/razvilka.tar.gz
else
    echo "$(L 'Развилку не скачиваю. Взять её можно в любой момент: razvilka/README_ru.md' 'Razvilka skipped. You can get it any time: see razvilka/README.md')"
fi

echo ""
echo "=== $(L 'Установка завершена' 'Installation completed') ==="
echo ""
echo "$(L 'Что дальше:' 'Next steps:')"
echo "1. $(L 'Создайте файл настроек клиента' 'Create a configuration file') /opt/trusttunnel_client/trusttunnel_client.toml"
if [ "$TT_MODE" = "tun" ]; then
    echo ""
    echo "   $(L 'Добавьте в него раздел [listener.tun]:' 'Add the [listener.tun] section to the client configuration:')"
    echo "   [listener.tun]"
    echo "   device_name = \"opkgtun${TUN_IDX}\""
    echo "   use_existing = true"
    echo "   included_routes = []"
    echo "   excluded_routes = []"
    echo "   change_system_dns = false"
    echo ""
    if [ "$TT_LANG" = ru ]; then
    echo "   device_name + use_existing: клиент подключается к устройству, которое KeeneticOS"
    echo "   создала для OpkgTun${TUN_IDX}, и статистика трафика видна в веб-панели"
    echo "   (нужен клиент от 1.0.62). Без этих двух строк работает классический режим."
    echo ""
    echo "   В начале файла рекомендуем: killswitch_enabled = true"
    echo "   (иначе, если сервер недоступен, клиент пускает трафик напрямую)."
    echo ""
    echo "   Раздела [listener.socks] в файле быть не должно."
    echo ""
    echo "   Обновляете роутер, где уже работал классический режим? Оставьте настройки и выполните:"
    echo "   tt-stats enable --reboot   (безопасное переключение с автоматическим откатом)"
    else
    echo "   device_name + use_existing: the client attaches to the device that KeeneticOS"
    echo "   created for OpkgTun${TUN_IDX}, so traffic statistics appear in the web UI"
    echo "   (needs client >= 1.0.62). Without these two lines the classic mode is used."
    echo ""
    echo "   Recommended at the top of the file: killswitch_enabled = true"
    echo "   (otherwise the client sends traffic directly when the server is unreachable)."
    echo ""
    echo "   The [listener.socks] section should not be in the file."
    echo ""
    echo "   Upgrading a router that already ran the classic setup? Keep your config and run:"
    echo "   tt-stats enable --reboot   (safe switch with automatic rollback)"
    fi
else
    echo ""
    echo "   $(L 'В настройках клиента должен быть раздел [listener.socks].' 'The client configuration must contain the [listener.socks] section.')"
    echo "   $(L 'Раздела [listener.tun] в файле быть не должно.' 'The [listener.tun] section should not be in the file.')"
fi
echo ""
echo "2. $(L 'Запустите службу' 'Start the service'): /opt/etc/init.d/S99trusttunnel start"
if [ "$TT_MODE" = "tun" ]; then
    echo "3. $(L 'Проверьте статистику в веб-панели' 'Check dashboard statistics'): tt-stats status"
fi
if [ -n "$RZV_GOT" ]; then
    echo ""
    echo "$(L 'Развилка (когда VPN заработает)' 'Razvilka (when the VPN works)'):"
    echo "   sh $RZV_DIR/razvilka-install.sh --demo --lang=$TT_LANG   ($(L 'проба, ничего не меняет' 'dry run, changes nothing'))"
    echo "   sh $RZV_DIR/razvilka-install.sh --lang=$TT_LANG          ($(L 'установка; --uninstall — удалить' 'install; --uninstall to remove'))"
fi
echo ""

exit 0
