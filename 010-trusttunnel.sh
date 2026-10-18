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
if [ "$1" = "$NDMC_IFACE" ]; then
    logger -t "$LOG_TAG" "WAN event for own TUN interface ($1), skipping"
    exit 0
fi

# Wait first: an event fired while the service restarts itself must see the new start time
sleep 5

# Skip reload if client was started recently (prevents restart during startup)
START_TS_FILE="/opt/var/run/trusttunnel_start_ts"
GRACE_PERIOD=30
if [ -f "$START_TS_FILE" ]; then
    start_ts=$(cat "$START_TS_FILE" 2>/dev/null)
    now=$(date +%s)
    if [ -n "$start_ts" ] && [ $((now - start_ts)) -lt "$GRACE_PERIOD" ]; then
        logger -t "$LOG_TAG" "Client started ${start_ts:+$((now - start_ts))s ago}, skipping WAN reload"
        exit 0
    fi
fi

# Only reload if the service was running (watchdog is alive)
WATCHDOG_PID_FILE="/opt/var/run/trusttunnel_watchdog.pid"
if [ -f "$WATCHDOG_PID_FILE" ]; then
    wpid=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)
    if [ -z "$wpid" ] || ! kill -0 "$wpid" 2>/dev/null; then
        logger -t "$LOG_TAG" "WAN up but service is not running, skipping"
        exit 0
    fi
else
    logger -t "$LOG_TAG" "WAN up but service is not running, skipping"
    exit 0
fi

# A WAN event does not always break the tunnel: a backup link (an LTE modem, a second provider) going
# down and up again leaves the VPN on the main link untouched. Reload only if the VPN really stopped
# passing data (a real day: the backup 4G modem reconnected and the VPN was cut for 11 s for nothing).
HC_TARGET_URL="${HC_TARGET_URL:-http://connectivitycheck.gstatic.com/generate_204}"
HC_SOCKS5_PROXY="${HC_SOCKS5_PROXY:-127.0.0.1:1080}"
if [ "$TT_MODE" = "tun" ]; then
    curl --interface "$OPKG_IFACE" --connect-timeout 5 --max-time 10 -s -o /dev/null "$HC_TARGET_URL" >/dev/null 2>&1
else
    curl --socks5 "$HC_SOCKS5_PROXY" --connect-timeout 5 --max-time 10 -s -o /dev/null "$HC_TARGET_URL" >/dev/null 2>&1
fi && { logger -t "$LOG_TAG" "WAN event (${1:-?}): the VPN still passes data, no reload needed"; exit 0; }

logger -t "$LOG_TAG" "WAN interface up (${1:-?}), the VPN does not pass data - reloading TrustTunnel..."

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

exit 0
