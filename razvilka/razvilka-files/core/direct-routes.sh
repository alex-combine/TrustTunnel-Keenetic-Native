#!/opt/bin/sh
# "Direct routes past the VPN" (direct-routes) v1.6 (WAN/TUN/LANIP from /opt/etc/razvilka/net.conf; v1.5: country networks DR_GEO_<group>; v1.4: @policy and !MAC; v1.3: company networks DR_AUTO_<group>; self-repair, iptables -w).
# Site groups (object-group fqdn on the router) for the selected devices
# go direct through the ISP (WAN); everything else on these devices goes through the VPN as before.
#
# Settings: /opt/etc/direct-routes.conf — lines "group  table  MAC [MAC ...]".
#   @policy — all devices with a VPN policy in Keenetic (new ones are picked up automatically);
#   !MAC    — exclude a device: it goes strictly through the VPN (e.g. a miner).
# How it works (for each group):
#  1) The firmware fills the group address list (ipset _NDM_OGDN_4_@<group>) from the answers
#     of the router's MAIN DNS (:53). The Policy0 DNS (:41100) does NOT fill the list.
#  2) nat   : a device's DNS questions exactly about the group domains (exact name suffix match in the packet)
#             go to the main DNS instead of the Policy0 DNS. Other questions go as before.
#  3) routes: addresses from the list → own table (through the ISP) + rule pref 99
#             "from the device IP with its policy mark → this table first".
#             Packet marks are NOT touched: the FASTNAT accelerator picks the path by the connection mark.
#  4) ks    : a narrow hole in the VPNKS kill switch: this MAC + list addresses + WAN only.
#  5) watch : once a minute logs large (≥ HEAVY_MB) connections of these devices going through the VPN
#             to /opt/var/log/ttwatch/vpn-heavy.log.
#
#  6) auto  : the second group list — company networks (ipset DR_AUTO_<group>) from /opt/etc/direct-routes.auto/<group>.nets;
#             the file is written by the bot, here it is only loaded (atomically, via swap).
# Commands: apply | nat | ks | sync | tick | autoload | off | on | status
#   tick — from cron once a minute (in the background): rules + watch, and list→routes every 10 seconds.
# Rollback: direct-routes.sh off  (+ ndmc: no dns-proxy route object-group <group> ...; no object-group fqdn <group>)
export PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/opt/usr/sbin:/usr/sbin:/usr/bin:/sbin:/bin
CONF=/opt/etc/direct-routes.conf
CACHE=/opt/etc/direct-routes.cache   # backup copy of the group domains (USB; written only on change)
RUN=/tmp/direct-routes   # in memory (tmpfs): files are updated every 10 s, the USB drive is not worn out
LOG=/opt/var/log/ttwatch/direct-routes.log
HEAVY=/opt/var/log/ttwatch/vpn-heavy.log
WAN=eth3
TUN=opkgtun0
LANIP=192.168.1.1
PREF=99
HEAVY_MB=5
[ -f /opt/etc/razvilka/net.conf ] && . /opt/etc/razvilka/net.conf   # v1.6: this router's network (no file — the values above)
mkdir -p $RUN ${LOG%/*}
iptables() { command iptables -w "$@"; }   # wait if someone else is editing the table (firmware, cron) — otherwise rules get lost
ts() { date '+%Y-%m-%d %H:%M:%S'; }
conf() { sed 's/#.*//' "$CONF" 2>/dev/null | grep -vE '^[[:space:]]*$'; }
groups() { conf | awk '{print $1}'; }
g_table() { conf | awk -v g="$1" '$1==g {print $2; exit}'; }
policy_macs() { iptables -t mangle -S _NDM_HOTSPOT_PREROUTING_MANGL 2>/dev/null | grep -i 'set-xmark' | grep -io 'mac-source [0-9a-f:]*' | awk '{print tolower($2)}' | sort -u; }
g_macs() {  # group MACs: explicit + @policy, minus !MAC
  toks=$(conf | awk -v g="$1" '$1==g {for (i=3;i<=NF;i++) print tolower($i)}')
  ex=" $(echo "$toks" | sed -n 's/^!//p' | tr '\n' ' ') "
  for t in $toks; do case "$t" in @policy) policy_macs;; !*) ;; *) echo "$t";; esac; done | sort -u | awk -v ex="$ex" 'index(ex, " " $0 " ") == 0'
}
all_macs() { for g in $(groups); do g_macs $g; done | sort -u; }
set_of() { echo "_NDM_OGDN_4_@$1"; }
aset_of() { echo "DR_AUTO_$1"; }
gset_of() { echo "DR_GEO_$1"; }   # v1.5: country networks (file <group>.geo)
AUTODIR=/opt/etc/direct-routes.auto
KSPAT='--match-set (_NDM_OGDN_4_@|DR_AUTO_|DR_GEO_)'
load_auto() {  # $1=group: networks file → ipset DR_AUTO_<group> (a whole new set, then swap)
  f=$AUTODIR/$1.nets; A=$(aset_of $1); [ -f "$f" ] || return 0
  ipset create ${A}_n hash:net maxelem 8192 -exist && ipset flush ${A}_n || return 1
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$f" | sed "s/^/add ${A}_n /" | ipset restore -exist
  ipset create $A hash:net maxelem 8192 -exist && ipset swap ${A}_n $A && ipset destroy ${A}_n
  cp "$f" $RUN/$1.autoloaded
  echo "$(ts) авто-сети [$1]: загружено $(ipset list $A | awk '/^Members:/{f=1;next} f&&/^[0-9]/' | wc -l)" >> $LOG
}
load_geo() {  # $1=group: "country networks" file → ipset DR_GEO_<group> + route list (no file — the set becomes empty)
  f=$AUTODIR/$1.geo; A=$(gset_of $1)
  if [ ! -f "$f" ]; then ipset flush $A 2>/dev/null; rm -f $RUN/$1.geowant $RUN/$1.geoloaded; return 0; fi
  ipset create ${A}_n hash:net maxelem 65536 -exist && ipset flush ${A}_n || return 1
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$f" | sort -u > $RUN/$1.geowant
  sed "s/^/add ${A}_n /" $RUN/$1.geowant | ipset restore -exist
  ipset create $A hash:net maxelem 65536 -exist && ipset swap ${A}_n $A && ipset destroy ${A}_n
  cp "$f" $RUN/$1.geoloaded
  echo "$(ts) сети России [$1]: загружено $(wc -l < $RUN/$1.geowant)" >> $LOG
}
have_set() { ipset list -n 2>/dev/null | grep -qxF "$1"; }
wan_gw() { ip route show table all 2>/dev/null | awk -v d=$WAN '$1=="default" && $2=="via" && $0 ~ ("dev " d " ") {print $3; exit}'; }
pol_mark() { iptables -t mangle -S _NDM_HOTSPOT_PREROUTING_MANGL 2>/dev/null | grep -i -- "--mac-source $1 " | grep -o 'set-xmark 0x[0-9a-f]*' | head -n 1 | cut -d' ' -f2; }
mac_ip() { ip neigh show dev br0 2>/dev/null | awk -v m="$1" 'tolower($3)==m {print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1; }
rc_domains() {  # domains of group $1 from the saved router settings (stdin)
  awk -v g="$1" '
    $1=="object-group" && $2=="fqdn" {cur=$3; next}
    /^!/ {cur=""}
    cur==g && $1=="include" && $2 !~ /^[0-9.\/]+$/ {print tolower($2)}'   # адреса/подсети — не домены, DNS-правило им не нужно
}
dn_hex() { echo "$1" | awk -F. '{s=""; for (i=1;i<=NF;i++) s = s sprintf("|%02x|%s", length($i), $i); print s "|00|"}'; }

# ---------- nat: DNS about group domains → the router's main DNS ----------
nat_clean() {
  for p in udp tcp; do
    while iptables -t nat -D PREROUTING -i br0 -d $LANIP -p $p --dport 53 -j DR_DNS 2>/dev/null; do :; done
  done
  for c in $(iptables -t nat -S 2>/dev/null | awk '$1=="-N" && $2 ~ /^DR_DNS/ {print $2}'); do iptables -t nat -F $c; done
  for c in $(iptables -t nat -S 2>/dev/null | awk '$1=="-N" && $2 ~ /^DR_DNS/ {print $2}'); do iptables -t nat -X $c 2>/dev/null; done
}
do_nat() {
  nat_clean
  [ -n "$(groups)" ] || return 0
  lsmod | grep -q '^xt_string' || insmod /lib/modules/$(uname -r)/xt_string.ko 2>/dev/null
  iptables -t nat -N DR_DNS || return 1
  # Read the router settings once. Right after boot the router may not answer yet —
  # then use the backup copy from USB, and tick retries in a minute.
  ndmc -c "show running-config" > $RUN/rc.txt 2>/dev/null
  if grep -q '^object-group fqdn' $RUN/rc.txt; then ok=1; else ok=0; fi
  mkdir -p $CACHE
  for g in $(groups); do
    ch="DR_DNS_$g"; iptables -t nat -N $ch || continue
    if [ $ok = 1 ]; then
      rc_domains $g < $RUN/rc.txt > $RUN/$g.domains
      cmp -s $RUN/$g.domains $CACHE/$g.domains || cp $RUN/$g.domains $CACHE/$g.domains
    else
      cp $CACHE/$g.domains $RUN/$g.domains 2>/dev/null || : > $RUN/$g.domains
    fi
    for d in $(cat $RUN/$g.domains); do
      iptables -t nat -A $ch -m string --algo bm --hex-string "$(dn_hex $d)" -j ACCEPT
    done
    for m in $(g_macs $g); do iptables -t nat -A DR_DNS -m mac --mac-source $m -j $ch; done
    [ "$(iptables -t nat -S $ch | grep -c hex-string)" -eq "$(grep -c . $RUN/$g.domains)" ] || ok=0   # did everything get set
  done
  for p in tcp udp; do iptables -t nat -I PREROUTING 1 -i br0 -d $LANIP -p $p --dport 53 -j DR_DNS; done
  rm -f $RUN/rc.txt
  if [ $ok = 1 ]; then touch $RUN/nat.ok
  else rm -f $RUN/nat.ok; echo "$(ts) DNS-правила встали не полностью (роутер не ответил или занят) — повторю через минуту" >> $LOG; fi
}

# ---------- kill switch: narrow exceptions ----------
do_ks() {
  while iptables -S VPNKS 2>/dev/null | grep -qE -- "$KSPAT"; do
    r=$(iptables -S VPNKS | grep -E -- "$KSPAT" | head -n 1 | sed 's/^-A /-D /'); eval iptables $r || break
  done
  iptables -L VPNKS -n >/dev/null 2>&1 || return 0
  for g in $(groups); do
    for S in $(set_of $g) $(aset_of $g) $(gset_of $g); do
      have_set "$S" || continue
      for m in $(g_macs $g); do iptables -I VPNKS 1 -o $WAN -m mac --mac-source $m -m set --match-set "$S" dst -j RETURN; done
    done
  done
}

# ---------- address list → routes through the ISP ----------
sync_sets() {  # $1=full — always compare with the table; otherwise only if the list changed
  GW=$(wan_gw); [ -n "$GW" ] || return 0
  oldgw=$(cat $RUN/gw 2>/dev/null)
  for g in $(groups); do
    t=$(g_table $g); S=$(set_of $g); [ -n "$t" ] || continue
    { ipset list "$S" 2>/dev/null; ipset list "$(aset_of $g)" 2>/dev/null; } | awk '/^Name:/ {f=0} /^Members:/ {f=1; next} f && /^[0-9]/ {print $1}' > $RUN/$g.want0
    cat $RUN/$g.want0 $RUN/$g.geowant 2>/dev/null | sort -u > $RUN/$g.want
    if [ "$1" != full ] && [ "$GW" = "$oldgw" ] && cmp -s $RUN/$g.want $RUN/$g.last; then continue; fi
    if [ "$GW" = "$oldgw" ]; then ip route show table $t 2>/dev/null | awk '{print $1}' | sort > $RUN/$g.have; else : > $RUN/$g.have; fi
    {
      awk -v gw=$GW -v d=$WAN -v t=$t 'FILENAME==ARGV[1] {h[$1]; next} !($1 in h) {print "route replace " $1 " via " gw " dev " d " table " t}' $RUN/$g.have $RUN/$g.want
      awk -v t=$t 'FILENAME==ARGV[1] {w[$1]; next} !($1 in w) {print "route del " $1 " table " t}' $RUN/$g.want $RUN/$g.have
    } > $RUN/$g.batch
    [ -s $RUN/$g.batch ] && ip -batch $RUN/$g.batch >/dev/null 2>&1
    cp $RUN/$g.want $RUN/$g.last
  done
  echo "$GW" > $RUN/gw
}

# ---------- rules "from device IP → group table" ----------
sync_rules() {
  : > $RUN/rules.want
  for g in $(groups); do
    t=$(g_table $g)
    for m in $(g_macs $g); do
      mk=$(pol_mark $m); [ -n "$mk" ] || continue          # a device without a policy already goes direct
      ipa=$(mac_ip $m)
      [ -n "$ipa" ] || ipa=$(ip rule | awk -v p="$PREF:" -v k="$mk" -v t="$t" '$1==p && $5==k && $7==t {print $3; exit}')
      [ -n "$ipa" ] && echo "$ipa $mk $t" >> $RUN/rules.want
    done
  done
  ip rule | awk -v p="$PREF:" '$1==p {print $3, $5, $7}' > $RUN/rules.have
  awk 'FILENAME==ARGV[1] {w[$0]; next} !($0 in w)' $RUN/rules.want $RUN/rules.have | while read a k t; do ip rule del from $a fwmark $k lookup $t pref $PREF 2>/dev/null; done
  awk 'FILENAME==ARGV[1] {h[$0]; next} !($0 in h)' $RUN/rules.have $RUN/rules.want | while read a k t; do ip rule add from $a fwmark $k lookup $t pref $PREF; done
}

# ---------- watch: large connections of these devices through the VPN ----------
collect() {
  TIP=$(ip -4 addr show $TUN 2>/dev/null | awk '/inet /{sub("/.*","",$2); print $2; exit}'); [ -n "$TIP" ] || return 0
  W=""; for m in $(all_macs); do a=$(mac_ip $m); [ -n "$a" ] && W="$W $a"; done; [ -n "$W" ] || return 0
  today=$(date +%F)
  if [ -s $HEAVY ] && [ "$(head -c 10 $HEAVY)" != "$today" ]; then mv $HEAVY $HEAVY.1; fi
  awk -v t=" dst=$TIP " -v ips=" $W " -v min=$((HEAVY_MB*1048576)) -v now="$(date '+%F %H:%M')" '
    index($0, t) {
      s=""; d=""; sp=""; dp=""; n=0; b=0
      for (i=1;i<=NF;i++) {
        if (s=="" && $i ~ /^src=/) s=substr($i,5); else if (d=="" && $i ~ /^dst=/) d=substr($i,5)
        else if (sp=="" && $i ~ /^sport=/) sp=substr($i,7); else if (dp=="" && $i ~ /^dport=/) dp=substr($i,7)
        if ($i ~ /^bytes=/) { n++; if (n==2) b=substr($i,7) }
      }
      if (index(ips, " " s " ") && b+0 >= min) print now, s, d, dp, sp, b
    }' /proc/net/nf_conntrack >> $HEAVY
}

tick() {
  if [ -f $RUN/tick.pid ] && kill -0 $(cat $RUN/tick.pid) 2>/dev/null; then return 0; fi
  echo $$ > $RUN/tick.pid
  [ -n "$(groups)" ] || { rm -f $RUN/tick.pid; return 0; }
  # self-repair after boot: DNS rules were not read in full or there are fewer kill switch holes than needed
  [ -f $RUN/nat.ok ] || { do_nat; echo "$(ts) tick: DNS-правила переставлены" >> $LOG; }
  for g in $(groups); do
    if [ -f $AUTODIR/$g.geo ]; then { have_set "$(gset_of $g)" && cmp -s $AUTODIR/$g.geo $RUN/$g.geoloaded; } || load_geo $g
    elif [ -f $RUN/$g.geoloaded ]; then load_geo $g; fi
    [ -f $AUTODIR/$g.nets ] || continue
    { have_set "$(aset_of $g)" && cmp -s $AUTODIR/$g.nets $RUN/$g.autoloaded; } || load_auto $g
  done
  need=0; for g in $(groups); do for S in $(set_of $g) $(aset_of $g) $(gset_of $g); do have_set "$S" && need=$((need + $(g_macs $g | wc -l))); done; done
  [ "$(iptables -S VPNKS 2>/dev/null | grep -cE -- "$KSPAT")" -lt $need ] && iptables -L VPNKS -n >/dev/null 2>&1 && { do_ks; echo "$(ts) tick: kill switch дополнен" >> $LOG; }
  sync_rules; sync_sets full; collect
  for i in 1 2 3 4 5; do sleep 10; sync_sets; done
  rm -f $RUN/tick.pid
}

do_off() {
  [ -f "$CONF" ] && mv "$CONF" "$CONF.off"
  nat_clean; do_ks
  while ip rule del pref $PREF 2>/dev/null; do :; done
  for t in $(sed 's/#.*//' "$CONF.off" 2>/dev/null | awk 'NF>1 {print $2}'); do ip route flush table $t 2>/dev/null; done
  rm -f $RUN/*.last $RUN/gw
}

case "$1" in
  autoload) for g in $(groups); do load_auto $g; load_geo $g; done; do_ks; sync_sets full;;
  apply)  for g in $(groups); do load_auto $g; load_geo $g; done; do_nat; do_ks; sync_rules; sync_sets full; echo "$(ts) поставлено: $(conf | awk '{printf "%s(%d MAC) ", $1, NF-2}')" >> $LOG;;
  nat)    do_nat;;
  ks)     do_ks;;
  sync)   sync_rules; sync_sets full;;
  tick)   tick;;
  off)    do_off; echo "$(ts) ВЫКЛЮЧЕНО" >> $LOG;;
  on)     [ -f "$CONF.off" ] && mv "$CONF.off" "$CONF"; $0 apply;;
  status) echo "шлюз провайдера (WAN): $(wan_gw)"
          for g in $(groups); do
            t=$(g_table $g)
            echo "[$g] таблица $t | MAC: $(g_macs $g | tr '\n' ' ')| доменов: $(wc -l < $RUN/$g.domains 2>/dev/null) | адресов в списке: $(ipset list $(set_of $g) 2>/dev/null | awk '/^Members:/{f=1;next} f&&/^[0-9]/' | wc -l) | сетей компаний: $(ipset list $(aset_of $g) 2>/dev/null | awk '/^Members:/{f=1;next} f&&/^[0-9]/' | wc -l) | сетей России: $(cat $RUN/$g.geowant 2>/dev/null | wc -l) | маршрутов: $(ip route show table $t | grep -c .)"
          done
          ip rule | grep "^$PREF:"
          iptables -t nat -L DR_DNS -n -v 2>/dev/null | awk 'NR>2 {print "DNS→основной:", $1, "пак.", $NF, $(NF-2)}'
          iptables -S VPNKS 2>/dev/null | grep -cE -- "$KSPAT" | sed 's/^/исключений в kill switch: /'
          echo "сторож: записей сегодня $(grep -c "^$(date +%F)" $HEAVY 2>/dev/null)";;
  *) echo "usage: $0 apply|nat|ks|sync|tick|autoload|off|on|status";;
esac
