#!/opt/bin/sh
# Razvilka on the router — shared library. v1.4 (English via BOTLANG=en; time zone from the router settings)
# Sourced by rzv-bot.sh and rzv-act.sh:  . /opt/share/razvilka/rzv-lib.sh
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
[ -z "$TZ" ] && [ -s /etc/TZ ] && TZ=$(cat /etc/TZ); export TZ   # time zone set in Keenetic (the firmware writes it to /etc/TZ)
APP=/opt/share/razvilka
ETC=/opt/etc/razvilka
KV=$ETC/kv                            # small values: one key — one file
TMP=/tmp/razvilka
LOG=/opt/var/log/razvilka.log
GROUP=rudirect
DRCONF=/opt/etc/direct-routes.conf
GEO_CONF=/opt/etc/direct-routes.geo.conf
R_DIR=/opt/etc/direct-routes.auto
R_FILE=$R_DIR/$GROUP.nets
GEO_FILE=$R_DIR/$GROUP.geo
DR=/opt/share/razvilka/core/direct-routes.sh
GEO_SH=/opt/share/razvilka/core/geo-build.sh
ALLOW=$ETC/asn_allow.conf
DENY=$ETC/asn_deny.conf
NETSDB=$ETC/nets.db                   # "network asn last_seen_date"
HINTED=$ETC/hinted                    # "asn date"
REFRESHED=$ETC/refreshed              # «asn unixtime»
CACHE_IP=$ETC/cache.ip                # «ip asn cc holder…»
CACHE_AS=$ETC/cache.asn               # «asn holder…»
HINTS_OFF=$ETC/hints.off
QUEUE=$ETC/queue                      # "unixtime text" — messages not sent because the connection was down
HC_URL=$ETC/hc_url                    # watchdog URL (secret, 600)
TUN=opkgtun0
WAN=""                                # ISP interface (direct internet exit), from net.conf
GUARD=1; FUSE=1; HEAL=1               # self-healing (rzv-act.sh guard): on / DNS fuse / restart the VPN; 0 = off (net.conf)
VPN_NDM=""                            # Keenetic name of the VPN connection for the restart (e.g. Wireguard0); empty — guessed from TUN
MEM_LOW_KB=15000
HOSTING_RE='HOST|CLOUD|VPS|DATA ?CENT|SERVER|HOSTING|COLO|TIMEWEB|SELECTEL|BEGET|REG\.RU|FIRSTBYTE|AEZA|DDOS|QRATOR|STORMWALL'
CORE=/opt/share/razvilka/core
BOTLANG=ru
[ -f /opt/etc/razvilka/net.conf ] && . /opt/etc/razvilka/net.conf   # this router's network: TUN, core folder CORE, language BOTLANG (no file — the values above)
case "$BOTLANG" in en) ;; *) BOTLANG=ru;; esac
DR=$CORE/direct-routes.sh; GEO_SH=$CORE/geo-build.sh
mkdir -p $TMP $KV $ETC; chmod 700 $TMP $ETC
W=$TMP/w.$$; mkdir -p $W                 # a folder per process (the bot and background actions do not get in each other's way)
SCR=$W/scr.txt; SKB=$W/scr.kb

# ---------- language: L 'Russian' 'English' ----------
en() { [ "$BOTLANG" = en ]; }
L() { if en; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

log() { echo "$(date '+%F %T') $*" >> $LOG; [ "$(wc -c < $LOG)" -gt 200000 ] && { tail -n 800 $LOG > $LOG.t; mv $LOG.t $LOG; }; return 0; }   # always 0: callers end with log
mem_kb() { awk '/MemAvailable/{print $2}' /proc/meminfo; }
now() { date +%s; }

# ---------- small values ----------
kv_get() { [ -f "$KV/$1" ] && cat "$KV/$1" || echo "$2"; }
kv_set() { printf '%s' "$2" > "$KV/$1.t" && mv "$KV/$1.t" "$KV/$1"; }
kv_del() { rm -f "$KV/$1"; }

# ---------- lock: one heavy job at a time ----------
lock() {   # lock [seconds to wait]
  n=0; while ! mkdir $TMP/lock 2>/dev/null; do
    [ -n "$(find $TMP/lock -maxdepth 0 -mmin +15 2>/dev/null)" ] && { rmdir $TMP/lock; continue; }
    n=$((n+5)); [ $n -ge ${1:-300} ] && return 1; sleep 5
  done; return 0
}
unlock() { rmdir $TMP/lock 2>/dev/null; }

# ---------- Telegram ----------
[ -f $ETC/tg.env ] && . $ETC/tg.env
ADMIN=${TELEGRAM_ADMIN_ID:-0}

tg() {   # tg METHOD json_file [timeout] → answer on stdout. The token is not visible in ps: the URL is in a 600 file.
  k=$TMP/k.$$.$RANDOM
  ( umask 077; printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TELEGRAM_BOT_TOKEN" "$1" > $k )
  curl -s --interface $TUN --max-time ${3:-30} -K $k -H 'Content-Type: application/json' --data-binary @"$2"
  rc=$?; rm -f $k; return $rc
}

# keyboard: file, line = row of buttons, buttons separated by TAB, inside a button "text<0x1f>data"
B=$(printf '\037'); T=$(printf '\t')
kb_json() { [ -s "$1" ] || { echo null; return; }
  jq -R -s -c 'split("\n")|map(select(length>0)|split("\t")|map(split("\u001f")|{text:.[0],callback_data:.[1]}))|{inline_keyboard:.}' "$1"; }
if en; then
MAIN_KB='{"keyboard":[[{"text":"📊 Status"},{"text":"🔎 Site"}],[{"text":"📱 Devices"},{"text":"⚙️ Settings"}]],"resize_keyboard":true,"is_persistent":true,"input_field_placeholder":"Site address or a button below"}'
else
MAIN_KB='{"keyboard":[[{"text":"📊 Статус"},{"text":"🔎 Сайт"}],[{"text":"📱 Устройства"},{"text":"⚙️ Настройки"}]],"resize_keyboard":true,"is_persistent":true,"input_field_placeholder":"Адрес сайта или кнопка внизу"}'
fi

send() {   # send "text" [JSON markup]
  f=$TMP/s.$$.json
  jq -n -c --arg t "$1" --argjson c "$ADMIN" --argjson m "${2:-null}" \
     '{chat_id:$c, text:$t[0:3900]} + (if $m then {reply_markup:$m} else {} end)' > $f
  r=$(tg sendMessage $f 30); rm -f $f
  echo "$r" | grep -q '"ok":true' && return 0
  log "не отправлено: $(echo "$r" | cut -c1-120)"
  # automatic messages (alerts, reports) are not lost: queue them and send when the connection is back
  [ "${QUEUE_ON_FAIL:-0}" = 1 ] && printf '%s %s\n' "$(now)" "$(printf '%s' "$1" | head -c 600 | tr '\n' ' ')" >> $QUEUE
  return 1
}
edit() {   # edit message_id "text" [JSON markup]; on failure — a new message
  f=$TMP/e.$$.json
  jq -n -c --arg t "$2" --argjson c "$ADMIN" --argjson i "$1" --argjson m "${3:-null}" \
     '{chat_id:$c, message_id:$i, text:$t[0:3900]} + (if $m then {reply_markup:$m} else {} end)' > $f
  r=$(tg editMessageText $f 30); rm -f $f
  echo "$r" | grep -qE '"ok":true|not modified' || send "$2" "$3"
}
del_msg() {  # delete a chat message (e.g. one with a secret link)
  f=$TMP/d.$$.json; jq -n -c --argjson c "$ADMIN" --argjson i "$1" '{chat_id:$c, message_id:$i}' > $f
  tg deleteMessage $f 15 >/dev/null; rm -f $f
}
toast() {  # toast callback_id [text]
  f=$TMP/a.$$.json; jq -n -c --arg i "$1" --arg t "${2:-}" '{callback_query_id:$i, text:$t[0:190]}' > $f
  tg answerCallbackQuery $f 15 >/dev/null; rm -f $f
}
# screen = $SCR (text) + $SKB (buttons)
scr_send() { send "$(cat $SCR)" "$(kb_json $SKB)"; }
scr_edit() { edit "$1" "${2:-}$(cat $SCR)" "$(kb_json $SKB)"; }

# ---------- router data ----------
vpn_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --interface $TUN --max-time 8 http://connectivitycheck.gstatic.com/generate_204)" = 204 ]; }
geo_on() { ! grep -q '^ENABLED=0' $GEO_CONF 2>/dev/null; }
country() { c=$(sed -n 's/^COUNTRY=//p' $GEO_CONF 2>/dev/null | tr -d '"' | tail -1); echo "${c:-ru}"; }
cname() { if en; then case "${1:-$(country)}" in ru|RU) echo Russia;; by|BY) echo Belarus;; kz|KZ) echo Kazakhstan;; uz|UZ) echo Uzbekistan;;
  cn|CN) echo China;; ir|IR) echo Iran;; tr|TR) echo Turkey;; ae|AE) echo UAE;; *) echo "${1:-?}" | tr a-z A-Z;; esac; return; fi
  case "${1:-$(country)}" in ru|RU) echo Россия;; by|BY) echo Беларусь;; kz|KZ) echo Казахстан;; uz|UZ) echo Узбекистан;;
  cn|CN) echo Китай;; ir|IR) echo Иран;; tr|TR) echo Турция;; ae|AE) echo ОАЭ;; *) echo "${1:-?}" | tr a-z A-Z;; esac; }
flag() { case "${1:-$(country)}" in ru|RU) echo 🇷🇺;; by|BY) echo 🇧🇾;; kz|KZ) echo 🇰🇿;; uz|UZ) echo 🇺🇿;;
  cn|CN) echo 🇨🇳;; ir|IR) echo 🇮🇷;; tr|TR) echo 🇹🇷;; ae|AE) echo 🇦🇪;; *) echo 🏠;; esac; }
known_cc() { case "$1" in ru|RU|by|BY|kz|KZ|uz|UZ|cn|CN|ir|IR|tr|TR|ae|AE) return 0;; esac; return 1; }
geo_n() { awk 'NF{n++} END{print n+0}' $GEO_FILE 2>/dev/null || echo 0; }
geo_t() { [ -f $GEO_FILE ] && date -r $GEO_FILE +%s || echo 0; }
geo_stale() { geo_on && { t=$(geo_t); [ "$t" = 0 ] || [ $(( $(now) - t )) -gt 172800 ]; }; }
ago() {   # ago unixtime → "сегодня в 04:23" / "today at 04:23"
  [ "${1:-0}" = 0 ] && { L 'ещё не собирался' 'not built yet'; echo; return; }
  d=$(date -d @$1 +%Y%m%d); td=$(date +%Y%m%d); yd=$(date -d @$(( $(now) - 86400 )) +%Y%m%d)
  if [ "$d" = "$td" ]; then w=$(L сегодня today); elif [ "$d" = "$yd" ]; then w=$(L вчера yesterday)
  elif en; then w=$(date -d @$1 '+%b %d'); else w=$(date -d @$1 +%d.%m); fi
  echo "$w $(L в at) $(date -d @$1 +%H:%M)"
}

# lists: one site per line
list_n() { awk 'NF{n++} END{print n+0}' "$1" 2>/dev/null || echo 0; }
list_get() { sed -n "$2p" "$1" 2>/dev/null; }                 # list_get file number (from 1)
list_has() { grep -qxF "$2" "$1" 2>/dev/null; }
list_add() { list_has "$1" "$2" || echo "$2" >> "$1"; }
list_del() { [ -f "$1" ] && grep -vxF "$2" "$1" > "$1.t"; mv "$1.t" "$1" 2>/dev/null; }

# companies from allow: "asn name" (name — up to " — " or " ("), names without repeats
companies() { sed -n 's/^[[:space:]]*\(AS\)\{0,1\}\([0-9][0-9]*\)[[:space:]]*#\{0,1\}[[:space:]]*\(.*\)$/\2 \3/p' $ALLOW 2>/dev/null |
  awk '{a=$1; $1=""; n=$0; sub(/^ /,"",n); sub(/ +[—(].*$/,"",n); if(n=="") n="AS" a; if(!(n in s)){s[n]=1; print a, n}}'; }
asn_in() { grep -qE "^[[:space:]]*(AS)?$2([^0-9]|$)" "$1" 2>/dev/null; }

# strict site address filter: no raw text ever reaches a command
clean_domain() {
  t=$(printf '%s' "$1" | head -n1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s#^[A-Za-z]*://##; s#[/?:].*##; s/\.$//')
  case "$t" in *[!\ -~]*) t=$(CHARSET=UTF-8 idn --quiet -a "$t" 2>/dev/null) || return 1;; esac
  t=$(printf '%s' "$t" | tr 'A-Z' 'a-z'); t=${t#www.}
  [ ${#t} -ge 3 ] && [ ${#t} -le 253 ] || return 1
  printf '%s' "$t" | grep -qE '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$' || return 1
  echo "$t"
}
hc_ok_url() { printf '%s' "$1" | grep -qE '^https://[a-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9/_.-]{8,200}$'; }
hc_ping() {   # hc_ping [/fail] — signal to the watchdog THROUGH THE TUNNEL (VPN down → no signals → alert)
  [ -s $HC_URL ] || return 1
  u=$(cat $HC_URL); s=${1:-}
  case "$u$s" in *cronitor.link*/fail) s='?state=fail';; *okchecker.ru*/fail) s='?status=fail';; esac   # alert: Cronitor ?state=fail, OKchecker ?status=fail, healthchecks /fail
  curl -sf -o /dev/null --interface $TUN --max-time 10 --retry 1 "$u$s" && kv_set hc_ok $(now)   # -f: a wrong link (404) is not a signal
}
# Can the watchdog service take an explicit alarm? Tracker.ru cannot: it alarms only on silence.
hc_can_fail() { case "$(cat $HC_URL 2>/dev/null)" in *hc-ping.com*|*healthchecks*|*cronitor.link*|*okchecker.ru*) return 0;; esac; return 1; }
hc_fail_direct() {   # the router is alive but the VPN is not: send the alarm straight through the ISP, not waiting for silence
  [ -s $HC_URL ] && [ -n "$WAN" ] && hc_can_fail || return 1
  u=$(cat $HC_URL)
  case "$u" in *cronitor.link*) s='?state=fail';; *okchecker.ru*) s='?status=fail';; *) s='/fail';; esac
  curl -s -o /dev/null --interface $WAN --max-time 10 --retry 1 "$u$s"
}
hc_paused() { [ "$(kv_get hc_pause 0)" -gt "$(now)" ]; }   # «silence test» is running
# Devices of the Razvilka group, as direct-routes.sh reads them: explicit MACs + @policy (every device with a
# Keenetic policy), minus !MAC (strictly via VPN).
group_macs() {
  toks=$(sed 's/#.*//' $DRCONF 2>/dev/null | awk -v g=$GROUP '$1==g{for(i=3;i<=NF;i++) print tolower($i)}')
  ex=" $(echo "$toks" | sed -n 's/^!//p' | tr '\n' ' ') "
  for t in $toks; do case "$t" in
    @policy) iptables -t mangle -S _NDM_HOTSPOT_PREROUTING_MANGL 2>/dev/null | grep -i set-xmark | grep -io 'mac-source [0-9a-f:]*' | awk '{print tolower($2)}';;
    !*) ;; *) echo "$t";; esac; done | sort -u | awk -v ex="$ex" 'index(ex, " " $0 " ") == 0'
}
# Marks of the policies whose route goes into the VPN tunnel (learned while the VPN works: when it is
# down, the firmware may drop the route). Other policies (e.g. «via the second ISP») are not touched.
vpn_marks() { ip rule 2>/dev/null | awk '$2 == "from" && $3 == "all" && $4 == "fwmark" && $6 == "lookup" {sub("/.*", "", $5); print $5, $7}' |
  while read -r m t; do ip route show table "$t" 2>/dev/null | grep -qE "^default( .*)? dev $TUN( |$)" && echo "$m"; done | sort -u | tr '\n' ' '; }
# Devices with a VPN policy: MAC addresses marked with one of the learned VPN marks.
policy_macs() { iptables -t mangle -S _NDM_HOTSPOT_PREROUTING_MANGL 2>/dev/null | grep -i 'set-xmark' |
  awk -v marks=" $(kv_get vpn_marks) " '{m = ""; x = ""; for (i = 1; i < NF; i++) { if ($i == "--mac-source") m = tolower($(i + 1)); if ($i == "--set-xmark") { x = $(i + 1); sub("/.*", "", x) } }
    if (m != "" && x != "" && index(marks, " " x " ")) print m}' | sort -u; }
# A company name people can read: «HCRU-AS - JSC _RU-CENTER_, RU» → «RU-CENTER»
org_name() {   # holder [asn]
  o=$(printf '%s' "$1" | sed -E 's/^[A-Za-z0-9_.-]+ - //; s/,[^,]*$//; s/[_"«»]//g; s/^(JSC|PJSC|OJSC|CJSC|LLC|Llc|OOO|AO|ZAO|PAO|LTD|Ltd)\.? +//; s/ +(JSC|PJSC|LLC|Llc|LTD|Ltd|GmbH|Inc|AG|BV|B\.V)\.?$//; s/^ +| +$//g')
  [ -n "$o" ] && printf '%s' "$o" || printf 'AS%s' "$2"
}
# A site name from the address itself (reverse DNS), only when it looks like a name, not like an ISP pool
ptr_site() {
  p=$(dig +short +time=2 +tries=1 -x "$1" @77.88.8.8 2>/dev/null | head -1 | sed 's/\.$//')
  case "$p" in ''|*[0-9]-[0-9]*|*static*|*dynamic*|*pool*|*dsl*|*client*|*broadband*|*customer*|*ip-*|*in-addr*) return 0;; esac
  echo "$p" | awk -F. 'NF>=2{print $(NF-1)"."$NF}'
}
kn() { v=$(kv_get "$1" 0); case "$v" in ''|*[!0-9]*) echo 0;; *) echo "$v";; esac; }   # numeric kv value, 0 if broken
heal_known() {   # does the self-healing know how to restart this VPN connection?
  [ -n "$VPN_NDM" ] && return 0
  case "$TUN" in opkgtun*) [ -x /opt/etc/init.d/S99trusttunnel ];; nwg*) return 0;; *) return 1;; esac; }
qadd() { printf '%s %s\n' "$(now)" "$(printf '%s' "$1" | head -c 600 | tr '\n' ' ')" >> $QUEUE; }   # to the bot later, when the connection is back
is_num() { case "$1" in ''|*[!0-9]*) return 1;; esac; return 0; }
is_mac() { printf '%s' "$1" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'; }

# ---------- networks as integers ----------
# nets_int: "a.b.c.d/n" → "start end network" (for awk checks)
NET2INT='function ip2n(s,  a){split(s,a,"."); return ((a[1]*256+a[2])*256+a[3])*256+a[4]}
function rng(c,  p,b,l){split(c,p,"/"); b=ip2n(p[1]); l=2^(32-p[2]); S=b-(b%l); E=S+l-1}'

# address owner via Team Cymru DNS (cached): "asn cc holder"
owner() {
  c=$(awk -v ip="$1" '$1==ip{$1=""; sub(/^ /,""); print; exit}' $CACHE_IP 2>/dev/null)
  [ -n "$c" ] && { echo "$c"; return; }
  rev=$(echo "$1" | awk -F. '{print $4"."$3"."$2"."$1}')
  o=$(dig +short +time=3 +tries=1 TXT $rev.origin.asn.cymru.com 2>/dev/null | head -1 | tr -d '"')
  asn=$(echo "$o" | awk -F'|' '{split($1,a," "); print a[1]+0}'); cc=$(echo "$o" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
  h=''
  if [ "${asn:-0}" != 0 ]; then
    h=$(awk -v a="$asn" '$1==a{$1=""; sub(/^ /,""); print; exit}' $CACHE_AS 2>/dev/null)
    if [ -z "$h" ]; then
      h=$(dig +short +time=3 +tries=1 TXT AS$asn.asn.cymru.com 2>/dev/null | head -1 | tr -d '"' | awk -F'|' '{sub(/^ +/,"",$NF); print $NF}')
      [ -n "$h" ] && echo "$asn $h" >> $CACHE_AS
    fi
  fi
  echo "$1 ${asn:-0} ${cc:--} ${h:--}" >> $CACHE_IP
  echo "${asn:-0} ${cc:--} ${h:--}"
}
