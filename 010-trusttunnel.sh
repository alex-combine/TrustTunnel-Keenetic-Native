#!/bin/sh

LOG_TAG="TrustTunnel"
MODE_CONF="/opt/trusttunnel_client/mode.conf"

# Load mode (defaults to socks5)
TT_MODE="socks5"
if [ -f "$MODE_CONF" ]; then
    . "$MODE_CONF"
fi

TUN_IDX="${TUN_IDX:-0}"
OPKG_IFACE="opkgtun${TUN_IDX}"

# Attach mode is on when the client config has use_existing = true
TUN_USE_EXISTING="no"
grep -q '^[[:space:]]*use_existing[[:space:]]*=[[:space:]]*true' /opt/trusttunnel_client/trusttunnel_client.toml 2>/dev/null && TUN_USE_EXISTING="yes"
NDMC_IFACE="OpkgTun${TUN_IDX}"

# Skip reload when triggered by our own TUN interface
# (prevents infinite restart loop when OpkgTun is a default gateway)
# (KeeneticOS passes start|stop in $1 and the interface in the environment)
if [ "$1" = "$NDMC_IFACE" ] || [ "${interface:-}" = "$NDMC_IFACE" ] || [ "${system_name:-}" = "$OPKG_IFACE" ]; then
    logger -t "$LOG_TAG" "WAN event for own TUN interface ($1), skipping"
    exit 0
fi

# Both "start" and "stop" are checked: on a hot-standby failover only the main link's "stop" arrives.
# A check never reloads a VPN that still passes data, so an extra event costs nothing.

# The checks below may take up to a minute: do not hold up KeeneticOS (it runs the hooks in turn)
if [ -z "$TT_WAN_BG" ]; then
    TT_WAN_BG=1 "$0" "$@" </dev/null >/dev/null 2>&1 &
    exit 0
fi

# One check at a time: two links changing together must not end in two reloads. An event that comes
# during a check is not lost: it leaves a mark, and the running check looks once more when it is done.
LOCK=/tmp/tt-wan-hook.lock
if ! mkdir "$LOCK" 2>/dev/null; then
    # the lock time, or the folder's own time if the holder was killed before writing it
    lts=$(cat "$LOCK/ts" 2>/dev/null); [ -n "$lts" ] || lts=$(date -r "$LOCK" +%s 2>/dev/null)
    # a lock older than 3 minutes was left by a killed copy: a check takes about a minute
    if ! { [ -n "$lts" ] && [ $(( $(date +%s) - lts )) -gt 180 ] 2>/dev/null && rm -rf "$LOCK" && mkdir "$LOCK" 2>/dev/null; }; then
        touch "$LOCK/pending" 2>/dev/null
        logger -t "$LOG_TAG" "WAN event (${1:-?}): another check is running, it will look again"; exit 0
    fi
fi
date +%s > "$LOCK/ts"
trap 'rm -rf "$LOCK"' EXIT

START_TS_FILE="/opt/var/run/trusttunnel_start_ts"
GRACE_PERIOD=30
WATCHDOG_PID_FILE="/opt/var/run/trusttunnel_watchdog.pid"
MEMGUARD_PAUSE="/tmp/tt-memguard.pause"
HC_TARGET_URL="${HC_TARGET_URL:-http://connectivitycheck.gstatic.com/generate_204}"
HC_SOCKS5_PROXY="${HC_SOCKS5_PROXY:-127.0.0.1:1080}"

service_running() {  # the watchdog is alive and the memory guard has not paused the VPN
    wpid=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)
    [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null && [ ! -f "$MEMGUARD_PAUSE" ]
}
vpn_passes() {
    if [ "$TT_MODE" = "tun" ]; then
        curl --interface "$OPKG_IFACE" --connect-timeout 5 --max-time 10 -s -o /dev/null "$HC_TARGET_URL" >/dev/null 2>&1
    else
        curl --socks5 "$HC_SOCKS5_PROXY" --connect-timeout 5 --max-time 10 -s -o /dev/null "$HC_TARGET_URL" >/dev/null 2>&1
    fi
}

check() {
    # Wait first: an event fired while the service restarts itself must see the new start time
    EVENT_TS=$(date +%s)
    sleep 5
    start_ts=$(cat "$START_TS_FILE" 2>/dev/null); now=$(date +%s)
    if [ -n "$start_ts" ] && [ $((now - start_ts)) -lt "$GRACE_PERIOD" ] 2>/dev/null; then
        logger -t "$LOG_TAG" "Client started $((now - start_ts))s ago, skipping WAN reload"; return
    fi
    service_running || { logger -t "$LOG_TAG" "WAN event (${1:-?}): the service is not running (or paused), skipping"; return; }
    # A WAN event does not always break the tunnel: a backup link (an LTE modem, a second provider) going
    # down and up again leaves the VPN on the main link untouched (a real day: the VPN was cut for 11 s for nothing).
    vpn_passes && { logger -t "$LOG_TAG" "WAN event (${1:-?}): the VPN still passes data, no reload needed"; return; }
    # A tunnel that is being (re)started needs ~20 s to connect, and the watchdog restarts a killed client
    # within ~10 s: a reload now would kill it again (a real day: 5 minutes of restarts in a loop).
    sleep 30
    start_ts=$(cat "$START_TS_FILE" 2>/dev/null)
    if [ -n "$start_ts" ] && [ "$start_ts" -ge "$EVENT_TS" ] 2>/dev/null; then
        logger -t "$LOG_TAG" "WAN event (${1:-?}): the client was restarted meanwhile, no reload needed"; return
    fi
    vpn_passes && { logger -t "$LOG_TAG" "WAN event (${1:-?}): the VPN passes data again, no reload needed"; return; }
    # the service may have been stopped meanwhile (the memory guard pause, a manual stop, an update):
    # a reload of a stopped service would start it again
    service_running || { logger -t "$LOG_TAG" "WAN event (${1:-?}): the service was stopped meanwhile, skipping"; return; }

    logger -t "$LOG_TAG" "WAN event (${1:-?}), the VPN does not pass data - reloading TrustTunnel..."
    if [ "$TT_MODE" = "tun" ]; then
        if [ "$TUN_USE_EXISTING" = "yes" ]; then
            # Attach mode: opkgtunN belongs to KeeneticOS, keep it up.
            ip link set tun0 down 2>/dev/null
        else
            logger -t "$LOG_TAG" "TUN mode: bringing down tunnel interfaces before reload..."
            ip link set "$OPKG_IFACE" down 2>/dev/null
            ip link set tun0 down 2>/dev/null
        fi
    fi
    /opt/etc/init.d/S99trusttunnel reload
}

n=0
while :; do
    rm -f "$LOCK/pending"
    check "$@"; n=$((n + 1))
    [ -f "$LOCK/pending" ] && [ "$n" -lt 3 ] || break
    logger -t "$LOG_TAG" "another WAN event came during the check - checking again"
done
exit 0
