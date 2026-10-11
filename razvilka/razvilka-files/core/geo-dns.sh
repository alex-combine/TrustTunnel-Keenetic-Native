#!/opt/bin/sh
# geo-dns.sh v1 — split DNS for "home country direct".
# Enabled ONLY when the country profile has DNS_SPLIT=1 (now — cn). Do NOT enable in Russia: the ISP DNS
# may return a local block-page address for blocked sites, and the scheme would accept it.
#
# How it works (smartdns, port 127.0.0.1:$PORT):
#   • local ISP DNS — the answer is accepted only if the address is inside the country map (whitelist-ip)
#   • trusted DoT (1.1.1.1, 8.8.8.8) — everything else
#   • private addresses (10/8, 172.16/12, 192.168/16, 127/8) are never accepted
# Keenetic dns-proxy asks smartdns instead of DoT. Watchdog: 3 failed checks in a row → back to the stock DoT.
#
# Usage: geo-dns.sh start|stop|test   — start/stop smartdns (does not touch the Keenetic chain)
#        geo-dns.sh enable|disable    — put into the Keenetic chain (saving the previous settings) / restore
#        geo-dns.sh watch             — watchdog (from cron once a minute)
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF=/opt/etc/direct-routes.geo.conf
CORE=/opt/share/razvilka/core; [ -f /opt/etc/razvilka/net.conf ] && . /opt/etc/razvilka/net.conf   # this router's core folder
D=$CORE/smartdns-geo
PORT=5399; GROUP=rudirect; COUNTRY=ru; LOCAL_DNS=""
. "$CONF"; . $CORE/geo-profiles.sh; profile $COUNTRY; . "$CONF"
LOG=/opt/var/log/ttwatch/direct-routes.log
PID=/tmp/smartdns-geo.pid; SAVE=/opt/etc/geo-dns.saved; FAIL=/tmp/geo-dns.fail
say() { echo "$*"; echo "$(date '+%F %T') geo-dns: $*" >> $LOG; }

local_dns() {  # ISP DNS: from conf or the one WAN got via DHCP
  [ -n "$LOCAL_DNS" ] && { echo $LOCAL_DNS; return; }
  ndmc -c 'show ip name-server' 2>/dev/null | awk '/address: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print $2; exit}'
}

make_conf() {
  mkdir -p $D
  L=$(local_dns); [ -n "$L" ] || { say "нет DNS провайдера — не запускаю"; return 1; }
  sed 's/^/whitelist-ip /' /opt/etc/direct-routes.auto/$GROUP.geo > $D/country-whitelist.conf
  cat > $D/smartdns.conf <<EOF
bind 127.0.0.1:$PORT
cache-size 256
prefetch-domain no
serve-expired no
speed-check-mode none
response-mode fastest-response
log-level warn
log-file /tmp/smartdns-geo.log
log-size 64k
blacklist-ip 10.0.0.0/8
blacklist-ip 172.16.0.0/12
blacklist-ip 192.168.0.0/16
blacklist-ip 127.0.0.0/8
blacklist-ip 0.0.0.0/8
server $L -whitelist-ip
server-tls 1.1.1.1 -host-name one.one.one.one
server-tls 8.8.8.8 -host-name dns.google
conf-file $D/country-whitelist.conf
EOF
}

running() { [ -f $PID ] && kill -0 $(cat $PID) 2>/dev/null; }
alive() { dig +short +time=2 +tries=1 @127.0.0.1 -p $PORT A one.one.one.one 2>/dev/null | grep -qE '^[0-9]+\.'; }

SD=$D/smartdns; [ -x $SD ] || SD=$(command -v smartdns)   # own copy next to it or the Entware smartdns package
start() { running && return 0; [ -n "$SD" ] || { say "нет smartdns: opkg install smartdns"; return 1; }; make_conf || return 1; $SD -c $D/smartdns.conf -p $PID && sleep 2 && alive && say "smartdns запущен на $PORT"; }
stop()  { running && kill $(cat $PID); rm -f $PID; say "smartdns остановлен"; }

enable() {
  [ "$DNS_SPLIT" = 1 ] || { say "в профиле $COUNTRY раздельный DNS выключен (DNS_SPLIT=0) — не включаю"; return 1; }
  start || return 1
  ndmc -c 'show running-config' | awk '/^dns-proxy/{f=1;next} /^!/{f=0} f && /tls upstream/{print}' > $SAVE
  while read -r l; do ndmc -c "dns-proxy no $(echo $l | sed 's/^ *//')" >/dev/null 2>&1; done < $SAVE
  ndmc -c "ip name-server 127.0.0.1:$PORT" >/dev/null 2>&1
  ndmc -c 'system configuration save' >/dev/null 2>&1
  touch $D/enabled; say "раздельный DNS включён (прежние upstream сохранены в $SAVE)"
}

disable() {
  ndmc -c "no ip name-server 127.0.0.1:$PORT" >/dev/null 2>&1
  [ -s $SAVE ] && while read -r l; do ndmc -c "dns-proxy $(echo $l | sed 's/^ *//')" >/dev/null 2>&1; done < $SAVE
  ndmc -c 'system configuration save' >/dev/null 2>&1
  rm -f $D/enabled; stop; say "раздельный DNS выключен — вернул штатный DoT"
}

case "$1" in
  start) start;;
  stop) stop;;
  test) start && for d in ya.ru taobao.com google.com; do echo "$d → $(dig +short +time=2 @127.0.0.1 -p $PORT A $d | grep -E '^[0-9.]+$' | head -1)"; done;;
  enable) enable;;
  disable) disable;;
  watch)
    [ -f $D/enabled ] || exit 0
    running || start
    if alive; then rm -f $FAIL; else
      n=$(( $(cat $FAIL 2>/dev/null || echo 0) + 1 )); echo $n > $FAIL
      [ $n -ge 3 ] && { say "smartdns не отвечает 3 раза подряд — откат на штатный DoT"; disable; rm -f $FAIL; }
    fi;;
  *) echo "usage: $0 start|stop|test|enable|disable|watch";;
esac
