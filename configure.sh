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
ATTACH=""
if [ -x /opt/trusttunnel_client/trusttunnel_client ]; then
    CLIENT_VERSION=$(/opt/trusttunnel_client/trusttunnel_client --version 2>/dev/null | awk '{print $2; exit}')
fi
if [ "$TT_MODE" = "tun" ] && [ -n "$CLIENT_VERSION" ]; then
    if awk -v a="$CLIENT_VERSION" -v b="1.0.62" 'BEGIN {
            split(a, x, "."); split(b, y, ".")
            for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
            exit 0 }'; then
        ATTACH=1
        echo "$(L "Клиент $CLIENT_VERSION умеет режим подключения к устройству (статистика в веб-панели)." "Client $CLIENT_VERSION supports attach mode (dashboard statistics).")"
    else
        echo "$(L "ВНИМАНИЕ: клиент $CLIENT_VERSION старше 1.0.62 и не может подключиться к устройству KeeneticOS." "WARNING: client $CLIENT_VERSION is older than 1.0.62 and cannot attach to the KeeneticOS device.")"
        echo "         $(L 'Обновите клиент или не добавляйте use_existing/device_name в настройки.' 'Update the client, or do not add use_existing/device_name to the config.')"
    fi
fi

# === Client config and first start: automatic, checked, rolled back on failure ===
TT_DIR="/opt/trusttunnel_client"
CFG="$TT_DIR/trusttunnel_client.toml"
TT_IF="opkgtun${TUN_IDX}"
CHECK_URL="http://connectivitycheck.gstatic.com/generate_204"
VPN_OK=""
MANUAL=""
TS=$(date +%Y%m%d_%H%M%S)

vpn_check() {  # up to 2 minutes: does the internet answer through the tunnel?
    _n=0
    while [ $_n -lt 12 ]; do
        if [ "$TT_MODE" = "tun" ]; then
            _c=$(curl -s -o /dev/null -w '%{http_code}' --interface "$TT_IF" --max-time 5 "$CHECK_URL" 2>/dev/null) || _c=""
        else
            _c=$(curl -s -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:1080 --max-time 5 "$CHECK_URL" 2>/dev/null) || _c=""
        fi
        [ "$_c" = "204" ] && return 0
        sleep 5; _n=$((_n + 1))
    done
    return 1
}

# Rewrite the listener for the chosen mode and keep the kill switch on.
# TUN: attach to the firmware device opkgtunN, Keenetic does the routing and DNS.
tt_fix_config() {  # $1 = file from setup_wizard, $2 = result
    awk -v mode="$TT_MODE" -v dev="$TT_IF" '
        /^\[/ {
            sec = $0; sub(/[[:space:]]*(#.*)?$/, "", sec); seen = 1
            if (sec == "[listener.tun]" || sec == "[listener.socks]") { drop = 1; next }
            drop = 0; print
            if (sec == "[listener]") {
                print ""
                if (mode == "tun") {
                    print "[listener.tun]"
                    print "device_name = \"" dev "\""
                    print "use_existing = true"
                    print "bound_if = \"\""
                    print "included_routes = []"
                    print "excluded_routes = []"
                    print "mtu_size = 1280"
                    print "change_system_dns = false"
                } else {
                    print "[listener.socks]"
                    print "address = \"127.0.0.1:1080\""
                    print "username = \"\""
                    print "password = \"\""
                }
                print ""
            }
            next
        }
        drop { next }
        !seen && /^[[:space:]]*killswitch_enabled[[:space:]]*=/ { print "killswitch_enabled = true"; next }
        { print }
    ' "$1" > "$2"
    grep -q '^killswitch_enabled' "$2" || { printf 'killswitch_enabled = true\n' > "$2.ks"; cat "$2" >> "$2.ks"; mv "$2.ks" "$2"; }
}

find_endpoint_config() {  # the file exported on the server: config.toml in the usual places
    for _f in /opt/tmp/config.toml /opt/config.toml "$TT_DIR/config.toml" /tmp/config.toml /opt/root/config.toml /root/config.toml; do
        [ -f "$_f" ] && grep -q 'hostname' "$_f" 2>/dev/null && { echo "$_f"; return 0; }
    done
    return 1
}

echo ""
echo "--------------------------------------------------------------------"
echo " $(L 'Настройка клиента и первый запуск' 'Client setup and first start')"
echo "--------------------------------------------------------------------"
if [ ! -x "$TT_DIR/trusttunnel_client" ] || [ ! -x "$TT_DIR/setup_wizard" ]; then
    echo "$(L 'Клиента TrustTunnel нет — настраивать нечего. Запустите установщик ещё раз и ответьте «д» на вопрос о клиенте.' 'No TrustTunnel client — nothing to set up. Run the installer again and answer "y" to the client question.')"
    MANUAL=1
elif [ "$TT_MODE" = "tun" ] && [ -z "$ATTACH" ]; then
    echo "$(L 'Клиент старше 1.0.62 — обновите его (запустите установщик ещё раз) или настройте по инструкции ниже.' 'The client is older than 1.0.62 — update it (run the installer again) or set it up by the steps below.')"
    MANUAL=1
else
    KEEP=""
    NEW=""
    CLASSIC=""
    if [ -f "$CFG" ] && grep -q '^\[endpoint\]' "$CFG"; then
        if [ "$TT_MODE" = "tun" ] && ! grep -q '^[[:space:]]*use_existing[[:space:]]*=[[:space:]]*true' "$CFG"; then
            CLASSIC=1
            echo "$(L 'Сейчас клиент работает в классическом режиме (как в исходном TrustTunnel-Keenetic).' 'The client now runs in the classic mode (as in the original TrustTunnel-Keenetic).')"
            echo "$(L 'Совет: оставьте файл как есть, а на новый режим (статистика в веб-панели, нужен Развилке) переключитесь потом командой tt-stats enable --reboot — она проверяет всё и сама откатывает.' 'Tip: keep the file as it is and switch to the new mode later (dashboard statistics, needed by Razvilka) with tt-stats enable --reboot — it checks everything and rolls back by itself.')"
        fi
        if ask_yes_no "$(L 'Файл настроек клиента уже есть. Оставить его как есть?' 'A client config already exists. Keep it as it is?')"; then
            KEEP=1
        fi
    fi
    if [ -z "$KEEP" ]; then
        SRC=$(find_endpoint_config) || SRC=""
        if [ -n "$SRC" ]; then
            echo "$(L 'Нашёл файл с сервера' 'Found the server file'): $SRC"
        else
            echo "$(L 'Нужен файл config.toml, который вы выгрузили на сервере (см. README, шаг 1).' 'I need the config.toml you exported on the server (see README, step 1).')"
            echo "$(L 'Положите его, например, в /opt/tmp/ и укажите путь. Можно вставить и ссылку tt://…' 'Put it, for example, into /opt/tmp/ and give the path. A tt://… link works too.')"
            printf "%s: " "$(L 'Путь к config.toml (Enter — пропустить)' 'Path to config.toml (Enter — skip)')"
            read -r SRC < /dev/tty || SRC=""
        fi
        if [ -z "$SRC" ]; then
            MANUAL=1
        else
            mkdir -p /opt/tmp
            WORK=$(mktemp -d /opt/tmp/tt_setup.XXXXXX)
            chmod 700 "$WORK"
            case "$SRC" in
                tt://*) "$TT_DIR/setup_wizard" -m non-interactive -d "$SRC" --settings "$WORK/raw.toml" >/dev/null 2>&1 || true ;;
                *)      "$TT_DIR/setup_wizard" -m non-interactive -e "$SRC" --settings "$WORK/raw.toml" >/dev/null 2>&1 || true ;;
            esac
            if [ -s "$WORK/raw.toml" ] && grep -q '^\[endpoint\]' "$WORK/raw.toml" && grep -q '^\[listener\]' "$WORK/raw.toml"; then
                tt_fix_config "$WORK/raw.toml" "$WORK/new.toml"
            fi
            if [ -s "$WORK/new.toml" ] && grep -q '^\[endpoint\]' "$WORK/new.toml" && grep -q '^killswitch_enabled = true' "$WORK/new.toml" && \
               { [ "$TT_MODE" != "tun" ] || grep -q "^device_name = \"$TT_IF\"" "$WORK/new.toml"; } && \
               { [ "$TT_MODE" = "tun" ] || grep -q '^address = "127.0.0.1:1080"' "$WORK/new.toml"; }; then
                [ -f "$CFG" ] && cp -p "$CFG" "$CFG.bak_$TS"
                cp "$WORK/new.toml" "$CFG"
                chmod 600 "$CFG"
                [ -f "$SRC" ] && chmod 600 "$SRC"
                NEW=1
                echo "$(L 'Файл настроек клиента готов, kill switch включён.' 'Client config is ready, kill switch on.')"
                [ -f "$CFG.bak_$TS" ] && echo "$(L 'Прежний файл сохранён' 'The previous file is kept as'): $CFG.bak_$TS"
            else
                echo "$(L 'Не смог собрать файл настроек из этого файла — настройте по инструкции ниже.' 'Could not build the client config from this file — set it up by the steps below.')"
                MANUAL=1
            fi
            rm -rf "$WORK"
        fi
    fi
    if [ -z "$MANUAL" ]; then
        echo "$(L 'Запускаю VPN и проверяю, что интернет идёт через него (до 2 минут)...' 'Starting the VPN and checking that the internet goes through it (up to 2 minutes)...')"
        /opt/etc/init.d/S99trusttunnel restart >/dev/null 2>&1 || true
        if vpn_check; then
            VPN_OK=1
            echo "✅ $(L 'VPN работает: интернет идёт через TrustTunnel.' 'The VPN works: the internet goes through TrustTunnel.')"
            [ -n "$CLASSIC" ] && [ -n "$NEW" ] && echo "   $(L 'Режим сменился с классического: статистика в веб-панели появится после перезагрузки роутера (tt-stats reboot).' 'The mode changed from classic: dashboard statistics appear after a router reboot (tt-stats reboot).')"
        else
            echo "⛔ $(L 'Интернет через VPN не пошёл за 2 минуты.' 'No internet through the VPN within 2 minutes.')"
            if [ -n "$NEW" ]; then
                /opt/etc/init.d/S99trusttunnel stop >/dev/null 2>&1 || true
                mv "$CFG" "$CFG.failed_$TS"
                chmod 600 "$CFG.failed_$TS"
                if [ -f "$CFG.bak_$TS" ]; then
                    cp -p "$CFG.bak_$TS" "$CFG"
                    /opt/etc/init.d/S99trusttunnel start >/dev/null 2>&1 || true
                fi
                echo "   $(L 'Вернул как было: VPN остановлен, новый файл сохранён как' 'Rolled back: the VPN is stopped, the new file is kept as') $CFG.failed_$TS"
            fi
            echo "   $(L 'Что пошло не так — последние строки журнала:' 'What went wrong — the last log lines:')"
            tail -n 5 /opt/var/log/trusttunnel.log 2>/dev/null | sed 's/^/     /' || true
            echo "   $(L 'Частые причины: сервер выключен, неверный файл с сервера, порт закрыт. Исправьте и запустите установщик ещё раз.' 'Common causes: the server is down, a wrong server file, a closed port. Fix it and run the installer again.')"
        fi
    fi
fi

# === Razvilka (beta, optional): home country direct, everything else via VPN ===
RZV_DIR="/opt/tmp/razvilka-setup"
RZV_DONE=""
rzv_get() {
    mkdir -p "$RZV_DIR"
    if curl -fsSL "$REPO_URL/razvilka.tar.gz" -o /opt/tmp/razvilka.tar.gz && tar xzf /opt/tmp/razvilka.tar.gz -C "$RZV_DIR"; then
        rm -f /opt/tmp/razvilka.tar.gz; return 0
    fi
    rm -f /opt/tmp/razvilka.tar.gz
    echo "$(L 'Не удалось скачать Развилку (нет в этом выпуске?). Как взять её потом — в razvilka/README_ru.md.' 'Could not download Razvilka (not attached to this release?). See razvilka/README.md to get it later.')"
    return 1
}
if [ "$TT_MODE" != "tun" ]; then
    echo ""
    echo "$(L 'Развилке (своя страна напрямую, бот в Telegram) нужен режим TUN — в режиме SOCKS5 её не предлагаю.' 'Razvilka (home country direct, a Telegram bot) needs TUN mode — not offered in SOCKS5 mode.')"
elif [ -n "$CLASSIC" ] && [ -n "$KEEP" ]; then
    echo ""
    echo "$(L 'Развилке нужен новый режим TUN. Сначала: tt-stats enable --reboot, после перезагрузки запустите установщик ещё раз — он предложит Развилку.' 'Razvilka needs the new TUN mode. First: tt-stats enable --reboot, after the reboot run the installer again — it will offer Razvilka.')"
elif [ -z "$VPN_OK" ]; then
    echo ""
    echo "$(L 'Развилку (своя страна напрямую, бот в Telegram) можно будет поставить, когда VPN заработает: запустите установщик ещё раз — он предложит.' 'Razvilka (home country direct, a Telegram bot) can be installed once the VPN works: run the installer again — it will offer it.')"
elif [ "$TT_MODE" = "tun" ]; then
    echo ""
    echo "--------------------------------------------------------------------"
    if [ "$TT_LANG" = ru ]; then cat <<'REOF'
 Развилка (по желанию, бета) - две дороги для домашнего интернета
--------------------------------------------------------------------
 * Банки, госуслуги и местные сервисы своей страны открываются напрямую:
   быстро, и они перестают ругаться на VPN.
 * Всё остальное по-прежнему идёт через ваш TrustTunnel.
 * Свой Telegram-бот: проверить любой сайт и переключить его одной кнопкой,
   правило для каждого устройства, утренняя сводка, тревога, если VPN
   пропал, а зависший VPN роутер перезапустит сам.
 * Бот живёт прямо на роутере - без серверов и облаков. Берёт около 1 МБ
   на флешке и около 8 МБ оперативной памяти; процессор почти не трогает
   (короткая проверка раз в минуту, сборка карты страны - ночью).
 Сначала покажет план и спросит «да»; удалить - одной командой.
 Подробнее: razvilka/README_ru.md
REOF
    else cat <<'REOF'
 Razvilka (optional, beta) - two roads for your home internet
--------------------------------------------------------------------
 * Banks, government and local services of your country open directly:
   fast, and they stop complaining about the VPN.
 * Everything else stays behind your TrustTunnel.
 * Your own Telegram bot: check any site and switch it with one tap,
   per-device rules, a morning summary, an alarm if the VPN drops,
   and the router restarts a hung VPN by itself.
 * The bot lives on the router itself - no servers, no cloud. It takes
   about 1 MB on the USB stick and about 8 MB of RAM; the CPU stays almost
   idle (a short check once a minute, the country map is built at night).
 It shows the plan first and asks "yes"; removal is one command.
 More: razvilka/README.md
REOF
    fi
    if ask_yes_no "$(L 'Поставить Развилку сейчас?' 'Install Razvilka now?')"; then
        if rzv_get; then
            sh "$RZV_DIR/razvilka-install.sh" --lang="$TT_LANG" < /dev/tty || true
            [ -x /opt/etc/init.d/S99razvilka ] && [ -f /opt/etc/razvilka/tg.env ] && RZV_DONE=1
        fi
    else
        echo "$(L 'Хорошо. Захотите потом — запустите установщик ещё раз, он предложит снова.' 'OK. If you want it later, run the installer again — it will offer it again.')"
    fi
fi

echo ""
echo "=== $(L 'Установка завершена' 'Installation completed') ==="
echo ""
if [ -n "$VPN_OK" ]; then
    echo "✅ $(L 'TrustTunnel работает и запускается сам после перезагрузки роутера.' 'TrustTunnel works and starts by itself after a router reboot.')"
    [ "$TT_MODE" = "tun" ] && echo "   $(L 'Статистика в веб-панели и проверка' 'Dashboard statistics and a check'): tt-stats status"
    echo "   $(L 'Журнал' 'Log'): /opt/var/log/trusttunnel.log"
    echo "   $(L 'Если что-то не так — выключить VPN' 'If something is wrong — turn the VPN off'): /opt/etc/init.d/S99trusttunnel stop"
    [ -n "$RZV_DONE" ] && echo "   $(L 'Развилка: откройте своего бота в Telegram и нажмите /start' 'Razvilka: open your bot in Telegram and press /start')"
    echo ""
    exit 0
fi
if [ -z "$MANUAL" ]; then
    echo "⛔ $(L 'VPN не заработал — причина выше, всё возвращено как было. Исправьте её и запустите установщик ещё раз.' 'The VPN did not start — the reason is above, everything is rolled back. Fix it and run the installer again.')"
    echo ""
    exit 0
fi
echo "$(L 'Проще всего: положите config.toml с сервера в /opt/tmp/ и запустите установщик ещё раз — он всё настроит и проверит сам.' 'Easiest: put the config.toml from the server into /opt/tmp/ and run the installer again — it sets up and checks everything itself.')"
echo ""
echo "$(L 'Или вручную:' 'Or by hand:')"
echo "1. $(L 'Создайте файл настроек клиента' 'Create a configuration file') /opt/trusttunnel_client/trusttunnel_client.toml"
echo "   cd /opt/trusttunnel_client && ./setup_wizard --mode non-interactive --endpoint_config config.toml --settings trusttunnel_client.toml"
if [ "$TT_MODE" = "tun" ]; then
    echo ""
    echo "   $(L 'Замените в нём раздел [listener.tun] на:' 'Replace the [listener.tun] section with:')"
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
    echo "   В начале файла должно быть: killswitch_enabled = true"
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
    echo "   At the top of the file: killswitch_enabled = true"
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
echo ""

exit 0
