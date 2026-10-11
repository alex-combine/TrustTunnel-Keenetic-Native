#!/opt/bin/sh
# geo-build.sh v2.2 (v2.2: light map LITE=1; v2.1: memory limit; v2: country profiles in geo-profiles.sh) — "home country direct": the router builds the list ITSELF.
#   ① country networks (ipverse rir-ip, all countries) ② minus data centers (world list X4BNet + own AS/networks)
#   ③ result → /opt/etc/direct-routes.auto/<group>.geo → direct-routes.sh autoload → VPN check → rollback on failure.
# Everything is downloaded THROUGH the VPN tunnel (GitHub is blocked in some countries), every source has a mirror
# and a backup copy on USB. Settings: /opt/etc/direct-routes.geo.conf
#   ENABLED=1             1 — on, 0 — off (Razvilka button / geo-build.sh on|off)
#   COUNTRY=ru            country code (ISO, lower case)
#   GROUP=rudirect        direct-routes group
#   EXTRA_ASN="49505 ..." own hosting providers (AS numbers) — subtract too (default — from the country profile)
#   SUBTRACT_DC=1, KEEP_ASN="…" — from the country profile (geo-profiles.sh), can be overridden here
#   EXTRA_NETS="1.2.3.4/32 ..." own addresses — subtract (e.g. the address of your VPN server)
#   EXCLUDE_DOMAINS="site.ru ..." home country sites to send via VPN (addresses are resolved on every build)
# Usage: geo-build.sh dry [code] — build and show, change nothing (with a code — a trial for another country)
#        geo-build.sh apply — build and install (from cron once a day)
#        geo-build.sh off|on — turn off (companies and sites stay) / turn on
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF=/opt/etc/direct-routes.geo.conf
[ -f "$CONF" ] || { echo "нет $CONF"; exit 1; }
ENABLED=1; LITE=0; COUNTRY=ru; GROUP=rudirect; EXTRA_NETS=""; EXCLUDE_DOMAINS=""; TUN=opkgtun0; CORE=/opt/share/razvilka/core
[ -f /opt/etc/razvilka/net.conf ] && . /opt/etc/razvilka/net.conf   # this router's TUN and core folder (CORE)
. "$CONF"
. $CORE/geo-profiles.sh
if [ "$1" = dry ] && [ -n "$2" ]; then   # trial for another country: clean profile, without own overrides
  COUNTRY=$2; profile $COUNTRY; EXTRA_NETS=""; EXCLUDE_DOMAINS=""
else
  profile $COUNTRY; . "$CONF"            # country profile, own overrides from conf on top
fi
W=/tmp/geo-build; CACHE=/opt/etc/geo-cache
OUT=/opt/etc/direct-routes.auto/$GROUP.geo
DR=$CORE/direct-routes.sh
LOG=/opt/var/log/ttwatch/direct-routes.log
mkdir -p $W $CACHE /opt/etc/direct-routes.auto
ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "$*"; echo "$(ts) geo: $*" >> $LOG; }
NETRE='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'

fetch() {  # $1=destination, $2=min. lines, then mirror URLs; a successful download updates the copy on USB
  f=$1; min=$2; shift 2; name=$(basename $f)
  for u in "$@"; do
    curl -sf --interface $TUN --max-time 60 "$u" 2>/dev/null | tr -d '\r' | grep -E "$NETRE" > $f.tmp
    if [ "$(grep -c . $f.tmp)" -ge "$min" ]; then
      mv $f.tmp $f; cmp -s $f $CACHE/$name || cp $f $CACHE/$name; return 0
    fi
  done
  rm -f $f.tmp
  [ -s $CACHE/$name ] && { cp $CACHE/$name $f; say "$name: источник не ответил — беру копию с флешки"; return 0; }
  return 1
}

asn_nets() {  # company networks (AS numbers) from RIPEstat; a successful answer goes to the copy on USB
  for a in "$@"; do
    curl -sf --interface $TUN --max-time 60 "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS$a&sourceapp=keenetic-geo" 2>/dev/null |
      grep -o '"prefix": *"[0-9.]*/[0-9]*"' | grep -oE '[0-9.]+/[0-9]+' > $W/as$a.tmp
    if [ -s $W/as$a.tmp ]; then cmp -s $W/as$a.tmp $CACHE/as$a.txt || cp $W/as$a.tmp $CACHE/as$a.txt
    else say "AS$a: RIPEstat не ответил — беру копию с флешки"; fi
    [ -s $CACHE/as$a.txt ] && cat $CACHE/as$a.txt
    rm -f $W/as$a.tmp; sleep 1
  done
}

vpn_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --interface $TUN --max-time 8 http://connectivitycheck.gstatic.com/generate_204)" = 204 ]; }

build() {
  R=https://raw.githubusercontent.com; J=https://cdn.jsdelivr.net/gh
  fetch $W/country_$COUNTRY.txt 10 \
    "$R/ipverse/rir-ip/master/country/$COUNTRY/ipv4-aggregated.txt" \
    "$J/ipverse/rir-ip@master/country/$COUNTRY/ipv4-aggregated.txt" || { say "сети страны $COUNTRY не скачались и копии нет"; return 1; }
  : > $W/datacenters.txt
  if [ "$SUBTRACT_DC" = 1 ]; then
    fetch $W/datacenters.txt 1000 \
      "$R/X4BNet/lists_vpn/main/output/datacenter/ipv4.txt" \
      "$J/X4BNet/lists_vpn@main/output/datacenter/ipv4.txt" || say "мировой список дата-центров недоступен — вычитаю только свои"
  fi
  asn_nets $EXTRA_ASN > $W/extra.txt
  for n in $EXTRA_NETS; do echo $n; done >> $W/extra.txt
  for d in $EXCLUDE_DOMAINS; do   # home country sites the user sent through the VPN
    for h in $d www.$d; do dig +short +time=3 +tries=1 A $h 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/$/\/32/'; done
  done >> $W/extra.txt
  cat $W/datacenters.txt $W/extra.txt 2>/dev/null | grep -E "$NETRE" > $W/excl.txt
  asn_nets $KEEP_ASN | grep -E "$NETRE" > $W/keep.txt
  # networks → number intervals, sort, subtract, back to networks (busybox awk, numbers up to 2^32 — no precision loss)
  toiv='{split($1,a,"[./]"); s=a[1]*16777216+a[2]*65536+a[3]*256+a[4]; z=2^(32-a[5]); s=s-s%z; printf "%.0f %.0f\n", s, s+z-1}'
  awk "$toiv" $W/keep.txt | sort -n -k1,1 > $W/keep.iv
  awk "$toiv" $W/excl.txt | sort -n -k1,1 > $W/excl0.iv
  subtract $W/keep.iv $W/excl0.iv | awk "$toiv" | sort -n -k1,1 > $W/excl.iv      # "what to subtract" − KEEP_ASN
  awk "$toiv" $W/country_$COUNTRY.txt | sort -n -k1,1 > $W/country.iv
  subtract $W/excl.iv $W/country.iv > $W/result.txt
  say "собрано для $COUNTRY: сетей страны $(grep -c . $W/country_$COUNTRY.txt), вычитаю $(grep -c . $W/excl.txt) (оставляю $(echo $KEEP_ASN | wc -w) компаний), итог $(grep -c . $W/result.txt)"
}

subtract() {  # $1 = what to subtract (intervals), $2 = from what (intervals) → networks (CIDR)
  awk '
    function ip(x) { return sprintf("%.0f.%.0f.%.0f.%.0f", int(x/16777216), int(x/65536)%256, int(x/256)%256, x%256) }
    function emit(s, e,   sz, len) {
      while (s <= e) { sz = 1; len = 32
        while (len > 0 && s % (sz*2) == 0 && s + sz*2 - 1 <= e) { sz *= 2; len-- }
        print ip(s) "/" len; s += sz }
    }
    FILENAME == ARGV[1] { if (n && $1 <= xe[n] + 1) { if ($2 > xe[n]) xe[n] = $2 } else { n++; xs[n] = $1; xe[n] = $2 }; next }
    { a = $1; b = $2; if (pe != "" && a <= pe) a = pe + 1; if (a > b) next; pe = b
      while (j < n && xe[j+1] < a) j++
      cur = a
      for (k = j + 1; k <= n && xs[k] <= b; k++) {
        if (xs[k] > cur) emit(cur, xs[k] - 1)
        if (xe[k] + 1 > cur) cur = xe[k] + 1
        if (cur > b) break
      }
      if (cur <= b) emit(cur, b)
    }' "$1" "$2"
}

case "$1" in
  dry)   build && echo "результат: $W/result.txt";;
  apply)
    trap 'rm -rf $W' EXIT   # temporary files are in memory (tmpfs) — clean up
    [ "$ENABLED" = 1 ] || { echo "выключено (ENABLED=0)"; exit 0; }
    build || exit 1
    new=$(grep -c . $W/result.txt); old=$(grep -c . $OUT 2>/dev/null || echo 0)
    [ "$new" -ge 10 ] || { say "итог пустой ($new) — не ставлю"; exit 1; }
    # big countries (US ~48k networks): no more than the router memory can hold
    mt=$(awk "/MemTotal/{print int(\$2/1024)}" /proc/meminfo); if [ $mt -lt 150 ]; then maxn=25000; else maxn=60000; fi   # 60k — ipset set limit (maxelem 65536)
    ST=/opt/etc/geo-status   # for Razvilka: ok | lite | toobig
    if [ "$new" -gt "$maxn" ]; then
      if [ "$LITE" = 1 ]; then   # light map: the largest country blocks while they fit (in the US — 99% of addresses)
        awk -F/ '{print $2, $0}' $W/result.txt | sort -n | head -n $maxn | cut -d' ' -f2 > $W/lite.txt && mv $W/lite.txt $W/result.txt
        say "лёгкая карта: оставил $maxn крупнейших сетей из $new"; echo "lite $maxn $new" > $ST; new=$maxn
      else
        say "итог $new сетей — больше, чем выдержит роутер с ${mt} МБ (предел $maxn). Не ставлю"; echo "toobig $new $maxn" > $ST; exit 1
      fi
    else echo "ok $new" > $ST; fi
    if [ "$old" -gt 0 ] && [ $((new * 2)) -lt "$old" ]; then say "итог меньше половины прошлого ($new против $old) — не ставлю"; exit 1; fi
    cmp -s $W/result.txt $OUT && { say "без изменений ($new)"; exit 0; }
    [ -f $OUT ] && cp $OUT $OUT.prev
    cp $W/result.txt $OUT.new && mv $OUT.new $OUT
    $DR autoload >/dev/null 2>&1; sleep 3
    if ! vpn_ok; then sleep 10
      if ! vpn_ok; then
        if [ -f $OUT.prev ]; then cp $OUT.prev $OUT; else rm -f $OUT; fi
        $DR autoload >/dev/null 2>&1; say "VPN не ответил после загрузки — ОТКАТ"; exit 1
      fi
    fi
    say "поставлено: было $old, стало $new";;
  off)   sed -i 's/^ENABLED=.*/ENABLED=0/' "$CONF"; grep -q '^ENABLED=' "$CONF" || echo ENABLED=0 >> "$CONF"
         [ -f $OUT ] && mv $OUT $OUT.prev; $DR autoload >/dev/null 2>&1; say "выключено";;
  on)    sed -i 's/^ENABLED=.*/ENABLED=1/' "$CONF"; grep -q '^ENABLED=' "$CONF" || echo ENABLED=1 >> "$CONF"
         say "включено"; exec $0 apply;;
  *)     echo "usage: $0 dry|apply|on|off";;
esac
