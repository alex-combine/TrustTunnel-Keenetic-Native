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
    jlog "END setup code=$exit_code" 2>/dev/null || true
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

# === What is on the router already? Decided BEFORE anything changes ===
TT_JOURNAL="/opt/var/log/tt-install.log"
jlog() { mkdir -p /opt/var/log; echo "$(date '+%F %T') $*" >> "$TT_JOURNAL"; }
D_MC="/opt/trusttunnel_client/mode.conf"
D_CFG="/opt/trusttunnel_client/trusttunnel_client.toml"
D_INIT="/opt/etc/init.d/S99trusttunnel"
D_MODE=""; D_IDX="0"; D_PIDX="0"
if [ -f "$D_MC" ]; then
    D_MODE=$(sed -n 's/^TT_MODE="\{0,1\}\([a-z0-9]*\).*/\1/p' "$D_MC" | tail -1)
    D_IDX=$(sed -n 's/^TUN_IDX="\{0,1\}\([0-9]*\).*/\1/p' "$D_MC" | tail -1); D_IDX=${D_IDX:-0}
    D_PIDX=$(sed -n 's/^PROXY_IDX="\{0,1\}\([0-9]*\).*/\1/p' "$D_MC" | tail -1); D_PIDX=${D_PIDX:-0}
fi
D_HASCFG=""; grep -q '^\[endpoint\]' "$D_CFG" 2>/dev/null && D_HASCFG=1
D_ATTACH=""; grep -q '^[[:space:]]*use_existing[[:space:]]*=[[:space:]]*true' "$D_CFG" 2>/dev/null && D_ATTACH=1
D_OURS=""; grep -q '^ensure_device()' "$D_INIT" 2>/dev/null && D_OURS=1
D_KS=""; grep -q '^killswitch_enabled[[:space:]]*=[[:space:]]*true' "$D_CFG" 2>/dev/null && D_KS=1
D_RZV=""; [ -x /opt/etc/init.d/S99razvilka ] && D_RZV=1
D_VPN=""
if [ "$D_MODE" = "tun" ]; then
    _c=$(curl -s -o /dev/null -w '%{http_code}' --interface "opkgtun$D_IDX" --max-time 6 http://connectivitycheck.gstatic.com/generate_204 2>/dev/null) || _c=""
elif [ "$D_MODE" = "socks5" ]; then
    _c=$(curl -s -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:1080 --max-time 6 http://connectivitycheck.gstatic.com/generate_204 2>/dev/null) || _c=""
else _c=""; fi
[ "$_c" = "204" ] && D_VPN=1
D_FREE=$(df -k /opt 2>/dev/null | awk 'NR==2 {print int($4/1024)}'); D_FREE=${D_FREE:-0}

if [ -x "$D_INIT" ] && [ -n "$D_MODE" ] && [ -n "$D_HASCFG" ]; then
    if [ "$D_MODE" = "socks5" ]; then D_STATE="socks"
    elif [ -n "$D_ATTACH" ]; then D_STATE="attach"
    else D_STATE="classic"; fi
elif [ ! -e "$D_INIT" ] && [ ! -f "$D_MC" ] && [ ! -f "$D_CFG" ]; then D_STATE="fresh"
else D_STATE="unclear"; fi

yn() { [ -n "$1" ] && L 'да' 'yes' || L 'нет' 'no'; }
echo ""
echo "--------------------------------------------------------------------"
echo " $(L 'Нашёл на роутере' 'Found on the router')"
echo "--------------------------------------------------------------------"
case "$D_STATE" in
    fresh)   echo "  $(L 'TrustTunnel не стоит — будет новая установка.' 'No TrustTunnel — a fresh install.')" ;;
    *)
        echo "  $(L 'Служба TrustTunnel' 'TrustTunnel service'): $(yn "$([ -x "$D_INIT" ] && echo 1)")$([ -n "$D_OURS" ] && L ' (этот проект)' ' (this project)')$([ -x "$D_INIT" ] && [ -z "$D_OURS" ] && L ' (исходный TrustTunnel-Keenetic или старая версия)' ' (original TrustTunnel-Keenetic or an old version)')"
        echo "  $(L 'Режим' 'Mode'): ${D_MODE:-?}$([ "$D_MODE" = tun ] && { [ -n "$D_ATTACH" ] && echo " (attach, opkgtun$D_IDX)" || L " (классический, opkgtun$D_IDX)" " (classic, opkgtun$D_IDX)"; })$([ "$D_MODE" = socks5 ] && echo " (Proxy$D_PIDX)")"
        echo "  $(L 'Файл настроек клиента' 'Client config'): $(yn "$D_HASCFG"), kill switch: $(yn "$D_KS")"
        echo "  $(L 'VPN работает сейчас' 'VPN works now'): $(yn "$D_VPN")"
        echo "  $(L 'Развилка' 'Razvilka'): $(yn "$D_RZV")" ;;
esac
echo "  $(L 'Свободно на флешке' 'Free on USB'): ${D_FREE} $(L МБ MB)"
echo ""
echo " $(L 'Сделаю' 'Plan'):"
case "$D_STATE" in
    fresh)   echo "  $(L '• полная установка: режим, интерфейс, клиент, файл настроек из config.toml, проверка VPN, Развилка по желанию' '• full install: mode, interface, client, client config from config.toml, VPN check, Razvilka optional')" ;;
    attach)  echo "  $(L '• обновлю служебные скрипты и tt-stats (копия старых — в /opt/backup)' '• update the service scripts and tt-stats (old ones backed up to /opt/backup)')"
             [ -z "$D_KS" ] && echo "  $(L '• включу kill switch (без него при падении сервера трафик идёт напрямую)' '• turn the kill switch on (without it traffic goes direct when the server is down)')"
             echo "  $(L '• перезапущу VPN и проверю; не заработал — верну всё как было' '• restart the VPN and check it; if it fails — put everything back')"
             echo "  $(L '• Развилка: ' '• Razvilka: ')$([ -n "$D_RZV" ] && L 'предложу обновить' 'offer an update' || L 'предложу поставить' 'offer to install')" ;;
    classic) echo "  $(L '• обновлю служебные скрипты и tt-stats (копия старых — в /opt/backup)' '• update the service scripts and tt-stats (old ones backed up to /opt/backup)')"
             [ -z "$D_KS" ] && echo "  $(L '• включу kill switch' '• turn the kill switch on')"
             echo "  $(L '• перезапущу VPN и проверю; не заработал — верну всё как было' '• restart the VPN and check it; if it fails — put everything back')"
             echo "  $(L '• переведу на новый режим attach через tt-stats enable (своя проверка и откат, сторож загрузки)' '• switch to attach mode with tt-stats enable (own check and rollback, boot guard)')"
             echo "  $(L '• Развилка по желанию; в конце — одна перезагрузка для статистики в веб-панели' '• Razvilka optional; at the end — one reboot for the dashboard statistics')" ;;
    socks)   echo "  $(L '• обновлю служебные скрипты и tt-stats, режим SOCKS5 и настройки веб-панели не трогаю' '• update the service scripts and tt-stats, keep SOCKS5 and the web panel settings')"
             [ -z "$D_KS" ] && echo "  $(L '• включу kill switch' '• turn the kill switch on')"
             echo "  $(L '• перезапущу VPN и проверю; не заработал — верну всё как было' '• restart the VPN and check it; if it fails — put everything back')"
             echo "  $(L '• Развилке нужен режим TUN — расскажу, как перейти (это настройка заново)' '• Razvilka needs TUN mode — I will tell how to switch (that is a new setup)')" ;;
    unclear) echo "  $(L '• не уверен, что у вас стоит (не хватает mode.conf, службы или файла настроек) — сам ничего не меняю' '• not sure what is installed (mode.conf, the service or the client config is missing) — I change nothing by myself')"
             echo "  $(L '• можно «настроить заново»: все вопросы по порядку, как при новой установке' '• you can choose «set up again»: all questions in order, as in a fresh install')" ;;
esac
[ -n "$D_VPN" ] || [ "$D_STATE" = fresh ] || [ "$D_STATE" = unclear ] || echo "  $(L '⚠ VPN сейчас не работает: обновлю только файлы и попробую запустить, режим не меняю' '⚠ The VPN does not work now: I only update files and try to start it, the mode is not changed')"
if [ "$D_FREE" -lt 2 ] && [ "$D_STATE" != fresh ]; then
    echo "  ⛔ $(L 'На флешке меньше 2 МБ — освободите место и запустите ещё раз.' 'Less than 2 MB free on USB — free some space and run again.')"
    [ -n "$TT_CHECK" ] || { trap - EXIT; exit 1; }
fi
if [ -f "$TT_JOURNAL" ] && tail -n 1 "$TT_JOURNAL" | grep -qv ' END'; then
    echo "  $(L 'Прошлый запуск прервался на шаге' 'The previous run stopped at step'): $(tail -n 1 "$TT_JOURNAL" | cut -d' ' -f3-) — $(L 'продолжу, шаги можно повторять' 'continuing, the steps are safe to repeat')"
fi
echo ""
if [ -n "$TT_CHECK" ]; then
    echo "$(L 'Это была проверка (--check): ничего не изменено. Журнал прошлых запусков' 'This was a check (--check): nothing changed. Journal of past runs'): $TT_JOURNAL"
    trap - EXIT; exit 0
fi

# === Update an existing install: keep the user's settings, step by step, with rollback ===
if [ "$D_STATE" = attach ] || [ "$D_STATE" = classic ] || [ "$D_STATE" = socks ]; then
    echo "  1) $(L 'Обновить, сохранив ваши настройки (рекомендую)' 'Update and keep your settings (recommended)')"
    echo "  2) $(L 'Настроить заново (все вопросы)' 'Set up again (all questions)')"
    printf "%s [1]: " "$(L 'Выбор' 'Choice')"
    read -r up_choice < /dev/tty || up_choice=""
    [ "$up_choice" = 2 ] && D_STATE="reconfigure"
elif [ "$D_STATE" = unclear ]; then
    ask_yes_no "$(L 'Настроить заново?' 'Set up again?')" || { trap - EXIT; exit 0; }
fi
if [ "$D_STATE" = attach ] || [ "$D_STATE" = classic ] || [ "$D_STATE" = socks ]; then
    TS=$(date +%Y%m%d_%H%M%S); BK="/opt/backup/tt_update_$TS"; W="/opt/tmp/tt_update.$$"
    jlog "START update from $D_STATE"
    mkdir -p "$BK" "$W"
    for f in "$D_INIT" /opt/etc/ndm/wan.d/010-trusttunnel.sh /opt/bin/tt-stats "$D_CFG" "$D_MC"; do [ -f "$f" ] && cp -p "$f" "$BK/"; done
    chmod 600 "$BK/trusttunnel_client.toml" 2>/dev/null || true
    jlog "step backup $BK"
    echo "$(L 'Копия старых файлов' 'Backup of the old files'): $BK"
    echo "$(L 'Скачиваю новые скрипты...' 'Downloading the new scripts...')"
    curl -fsSL "$REPO_URL/S99trusttunnel" -o "$W/S99trusttunnel" && curl -fsSL "$REPO_URL/010-trusttunnel.sh" -o "$W/010-trusttunnel.sh" && \
        curl -fsSL "$REPO_URL/tt-stats" -o "$W/tt-stats" && sh -n "$W/S99trusttunnel" && sh -n "$W/tt-stats" || {
        echo "⛔ $(L 'Не скачалось — ничего не менял.' 'Download failed — nothing changed.')"; jlog "END failed download"; rm -rf "$W"; trap - EXIT; exit 1; }
    jlog "step download"
    "$D_INIT" stop >/dev/null 2>&1 || true
    cp "$W/S99trusttunnel" "$D_INIT"; chmod +x "$D_INIT"
    mkdir -p /opt/etc/ndm/wan.d; cp "$W/010-trusttunnel.sh" /opt/etc/ndm/wan.d/010-trusttunnel.sh; chmod +x /opt/etc/ndm/wan.d/010-trusttunnel.sh
    mkdir -p /opt/bin; cp "$W/tt-stats" /opt/bin/tt-stats
    sed -i "s|^TTS_REPO_URL=.*|TTS_REPO_URL=\"\${TTS_REPO_URL:-$REPO_URL}\"|" /opt/bin/tt-stats; chmod +x /opt/bin/tt-stats
    /opt/bin/tt-stats update-check --install-cron >/dev/null 2>&1 || true
    rm -rf "$W"
    if [ -z "$D_KS" ]; then
        if grep -q '^killswitch_enabled' "$D_CFG"; then sed -i 's/^killswitch_enabled.*/killswitch_enabled = true/' "$D_CFG"
        else { echo "killswitch_enabled = true"; cat "$D_CFG"; } > "$D_CFG.new" && mv "$D_CFG.new" "$D_CFG"; fi
        chmod 600 "$D_CFG"
    fi
    jlog "step files"
    echo "$(L 'Запускаю VPN и проверяю (до 2 минут)...' 'Starting the VPN and checking (up to 2 minutes)...')"
    "$D_INIT" start >/dev/null 2>&1 || true
    U_OK=""; _n=0
    while [ $_n -lt 12 ]; do
        if [ "$D_MODE" = tun ]; then
            _c=$(curl -s -o /dev/null -w '%{http_code}' --interface "opkgtun$D_IDX" --max-time 5 http://connectivitycheck.gstatic.com/generate_204 2>/dev/null) || _c=""
        else
            _c=$(curl -s -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:1080 --max-time 5 http://connectivitycheck.gstatic.com/generate_204 2>/dev/null) || _c=""
        fi
        [ "$_c" = 204 ] && { U_OK=1; break; }
        sleep 5; _n=$((_n + 1))
    done
    if [ -z "$U_OK" ] && [ -n "$D_VPN" ]; then
        echo "⛔ $(L 'После обновления VPN не заработал — возвращаю старые файлы.' 'The VPN did not start after the update — restoring the old files.')"
        "$D_INIT" stop >/dev/null 2>&1 || true
        cp -p "$BK/S99trusttunnel" "$D_INIT" 2>/dev/null || true
        cp -p "$BK/010-trusttunnel.sh" /opt/etc/ndm/wan.d/010-trusttunnel.sh 2>/dev/null || true
        cp -p "$BK/tt-stats" /opt/bin/tt-stats 2>/dev/null || true
        cp -p "$BK/trusttunnel_client.toml" "$D_CFG" 2>/dev/null || true
        "$D_INIT" start >/dev/null 2>&1 || true
        jlog "END rolled back"
        echo "   $(L 'Вернул как было. Журнал клиента' 'Rolled back. Client log'): /opt/var/log/trusttunnel.log"
        trap - EXIT; exit 1
    fi
    jlog "step vpn_check ok=${U_OK:-0}"
    [ -n "$U_OK" ] && echo "✅ $(L 'Обновлено, VPN работает.' 'Updated, the VPN works.')"
    [ -z "$U_OK" ] && echo "🟡 $(L 'Файлы обновлены, но VPN не работал и до обновления — проверьте сервер и журнал /opt/var/log/trusttunnel.log.' 'Files updated, but the VPN did not work before the update either — check the server and /opt/var/log/trusttunnel.log.')"
    NEED_REBOOT=""
    if [ "$D_STATE" = classic ] && [ -n "$U_OK" ]; then
        echo ""
        echo "$(L 'Перевожу на режим attach (tt-stats enable, около 3 минут, сама проверяет и откатывает)...' 'Switching to attach mode (tt-stats enable, about 3 minutes, checks and rolls back by itself)...')"
        if /opt/bin/tt-stats enable; then D_STATE=attach; NEED_REBOOT=1; jlog "step attach ok"
        else echo "🟡 $(L 'Перевод не удался и откатан — VPN работает по-старому. Подробности' 'The switch failed and was rolled back — the VPN works the old way. Details'): /opt/var/log/tt-stats.log"; jlog "step attach failed"; fi
    fi
    if [ "$D_STATE" = socks ]; then
        echo ""
        echo "$(L 'Развилке нужен режим TUN. Перейти: запустите установщик, выберите «2 — настроить заново» и режим TUN; потом в веб-панели Keenetic переключите политики устройств с Proxy на OpkgTun.' 'Razvilka needs TUN mode. To switch: run the installer, choose «2 — set up again» and TUN; then in the Keenetic web panel move the device policies from Proxy to OpkgTun.')"
    elif [ "$D_STATE" = attach ] && [ -n "$U_OK" ]; then
        RZV_DIR="/opt/tmp/razvilka-setup"
        if [ -n "$D_RZV" ]; then q="$(L 'Обновить Развилку (настройки и токен сохранятся)?' 'Update Razvilka (settings and token are kept)?')"
        else
            echo ""
            echo "$(L 'Развилка (по желанию): сайты своей страны — напрямую, остальное — через TrustTunnel; свой Telegram-бот на роутере (~1 МБ флешки, ~8 МБ памяти). Подробнее: razvilka/README_ru.md' 'Razvilka (optional): home country sites direct, everything else via TrustTunnel; your own Telegram bot on the router (~1 MB USB, ~8 MB RAM). More: razvilka/README.md')"
            q="$(L 'Поставить Развилку сейчас?' 'Install Razvilka now?')"
        fi
        if ask_yes_no "$q"; then
            mkdir -p "$RZV_DIR"
            if curl -fsSL "$REPO_URL/razvilka.tar.gz" -o /opt/tmp/razvilka.tar.gz && tar xzf /opt/tmp/razvilka.tar.gz -C "$RZV_DIR"; then
                sh "$RZV_DIR/razvilka-install.sh" --lang="$TT_LANG" < /dev/tty || true
                jlog "step razvilka"
            else echo "$(L 'Не удалось скачать Развилку.' 'Could not download Razvilka.')"; fi
            rm -f /opt/tmp/razvilka.tar.gz
        fi
    fi
    jlog "END ok"
    echo ""
    echo "=== $(L 'Готово' 'Done') ==="
    echo "   $(L 'Копия старых файлов' 'Old files backup'): $BK"
    echo "   $(L 'Журнал установщика' 'Installer journal'): $TT_JOURNAL"
    echo "   $(L 'Если что-то не так — выключить VPN' 'If something is wrong — turn the VPN off'): $D_INIT stop"
    if [ -n "$NEED_REBOOT" ]; then
        echo ""
        if ask_yes_no "$(L 'Для статистики в веб-панели нужна одна перезагрузка роутера (сторож проверит VPN после неё). Перезагрузить сейчас?' 'Dashboard statistics need one router reboot (the boot guard checks the VPN after it). Reboot now?')"; then
            /opt/bin/tt-stats reboot || true
        else echo "$(L 'Перезагрузить потом' 'Reboot later'): tt-stats reboot"; fi
    fi
    trap - EXIT; exit 0
fi
jlog "START setup ($D_STATE)"

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
    MISMATCH=""
    if [ -f "$CFG" ] && grep -q '^\[endpoint\]' "$CFG"; then
        if { [ "$TT_MODE" = "tun" ] && grep -q '^\[listener\.socks\]' "$CFG"; } || { [ "$TT_MODE" = "socks5" ] && grep -q '^\[listener\.tun\]' "$CFG"; }; then
            MISMATCH=1
            echo "$(L 'Режим сменился — переделаю ваш файл настроек под новый режим (адрес и пароль сервера сохранятся).' 'The mode changed — I will rebuild your client config for the new mode (server address and password are kept).')"
        fi
    fi
    if [ -z "$MISMATCH" ] && [ -f "$CFG" ] && grep -q '^\[endpoint\]' "$CFG"; then
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
        elif [ -f "$CFG" ] && grep -q '^\[endpoint\]' "$CFG"; then
            SRC="$CFG"
            echo "$(L 'Беру адрес и пароль сервера из вашего нынешнего файла настроек.' 'Taking the server address and password from your current client config.')"
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
                "$CFG") cp "$CFG" "$WORK/raw.toml"; grep -q '^\[listener\]' "$WORK/raw.toml" || printf '\n[listener]\n' >> "$WORK/raw.toml" ;;
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
                [ -f "$SRC" ] && [ "$SRC" != "$CFG" ] && chmod 600 "$SRC"
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
