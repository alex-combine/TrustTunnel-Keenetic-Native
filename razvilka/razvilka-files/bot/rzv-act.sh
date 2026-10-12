#!/opt/bin/sh
# Razvilka on the router — button actions (in the background) and scheduled automation. v1.3
#   rzv-act.sh checks | watch | refresh [ASN…] | <button action> …
. /opt/share/razvilka/rzv-bot.sh            # screens + library (without the main loop)
trap 'rm -rf $W' EXIT
MAX_ADD=400; MAX_TOTAL=3000; STALE_DAYS=30; HINT_MIN_BYTES=200000
today() { date +%F; }
geo_sync() {   # "via VPN" list → router setting → map rebuild (≈1.5 min)
  v=$(tr '\n' ' ' < $ETC/vpn_sites 2>/dev/null | sed 's/ *$//')
  cp -p $GEO_CONF $GEO_CONF.prev
  grep -q '^EXCLUDE_DOMAINS=' $GEO_CONF && sed -i "s/^EXCLUDE_DOMAINS=.*/EXCLUDE_DOMAINS=\"$v\"/" $GEO_CONF || echo "EXCLUDE_DOMAINS=\"$v\"" >> $GEO_CONF
  $GEO_SH apply >/dev/null 2>&1
}
site_add() {   # the domain has already passed clean_domain
  ndmc -c "object-group fqdn $GROUP include $1" >/dev/null 2>&1; ndmc -c 'system configuration save' >/dev/null 2>&1
  $DR apply >/dev/null 2>&1
  [ "$(ndmc -c 'show running-config' 2>/dev/null | grep -c "include $1\$")" -ge 1 ] || return 1
  list_add $ETC/sites $1; log "сайт $1 — напрямую"
}
site_del() {   # domain
  ndmc -c "no object-group fqdn $GROUP include $1" >/dev/null 2>&1; ndmc -c 'system configuration save' >/dev/null 2>&1
  $DR apply >/dev/null 2>&1; list_del $ETC/sites $1; log "сайт $1 — снова через VPN"
}
allow_del() {  # asn name → move from allow to deny, marked "removed by button"
  grep -vE "^[[:space:]]*(AS)?$1([^0-9]|\$)" $ALLOW > $ALLOW.t; mv $ALLOW.t $ALLOW
  echo "$1   # $2 — убрано кнопкой $(today)" >> $DENY; log "убрана AS$1 $2"
}
company_add() {   # asn [holder] → 0 added, 1 not allowed (cloud/hosting)
  mine=$(grep -E "^[[:space:]]*$1([^0-9]|\$)" $DENY 2>/dev/null)
  if [ -n "$mine" ]; then echo "$mine" | grep -qv 'кнопкой' && return 1
    grep -vE "^[[:space:]]*$1([^0-9]|\$)" $DENY > $DENY.t; mv $DENY.t $DENY; fi
  if ! asn_in $ALLOW $1; then
    note=${2:-$(awk -v a="$1" '$1==a{$1=""; sub(/^ /,""); print; exit}' $CACHE_AS 2>/dev/null)}
    [ -n "$mine" ] && n2=$(echo "$mine" | head -1 | sed -n 's/^[^#]*#[[:space:]]*//p' | sed 's/[[:space:]]*—[[:space:]]*\(убрано\|отклонено\).*$//') && [ -n "$n2" ] && note=$n2
    echo "$1   # $note — добавлено кнопкой $(today)" >> $ALLOW
  fi
  log "добавить AS$1"; refresh "$(L "по кнопке AS$1" "button AS$1")" $1; return 0
}

# ---------- company networks refresh (RIPE through the tunnel) ----------
ripe() {   # asn → IPv4 networks (not wider than /10, not private)
  curl -s --interface $TUN --max-time 40 "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS$1&sourceapp=razvilka" > $W/ripe.json || return 1
  [ "$(jq -r .status $W/ripe.json 2>/dev/null)" = ok ] || return 1
  jq -r '.data.prefixes[].prefix' $W/ripe.json | grep -v : | awk -F/ '$2>=10' |
    grep -vE '^(0|10|127)\.|^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|^169\.254\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^192\.168\.|^(22[4-9]|2[3-5][0-9])\.'
}
refresh() {   # refresh "reason" [ASN…] — without a list: all companies
  reason=$1; shift; only=" $* "; d=$(today); cut=$(date -d @$(( $(now) - STALE_DAYS*86400 )) +%F)
  touch $NETSDB
  for a in $(sed -n 's/^[[:space:]]*\(AS\)\{0,1\}\([0-9][0-9]*\).*/\2/p' $ALLOW | sort -un); do
    asn_in $DENY $a && continue; [ "$only" != '  ' ] && ! echo "$only" | grep -q " $a " && continue
    if ! ripe $a > $W/got || [ ! -s $W/got ]; then log "AS$a: RIPE не ответил или пусто — оставляю прошлые сети"; continue; fi
    awk -v a=$a -v d=$d 'NR==FNR{g[$1]=1; next} !($1 in g)' $W/got $NETSDB > $W/db; awk -v a=$a -v d=$d '{print $1, a, d}' $W/got >> $W/db
    mv $W/db $NETSDB; echo "$a $(now)" >> $REFRESHED; sleep 1
  done
  # fresh and allowed
  sed -n 's/^[[:space:]]*\(AS\)\{0,1\}\([0-9][0-9]*\).*/\2/p' $ALLOW | sort -u > $W/al
  sed -n 's/^[[:space:]]*\(AS\)\{0,1\}\([0-9][0-9]*\).*/\2/p' $DENY | sort -u > $W/dn
  awk -v c=$cut 'FILENAME==ARGV[1]{al[$1]=1; next} FILENAME==ARGV[2]{dn[$1]=1; next} $3>=c && ($2 in al) && !($2 in dn)' $W/al $W/dn $NETSDB > $W/db; mv $W/db $NETSDB
  # drop nested networks and those already covered by the country map
  cut -d' ' -f1 $NETSDB | sort -u > $W/n
  awk "$NET2INT"'FILENAME==ARGV[1]{rng($1); gs[++g]=S; ge[g]=E; next}
    {rng($1); s[++n]=S; e[n]=E; c[n]=$1}
    END{for(i=1;i<=n;i++){k=0; for(j=1;j<=n;j++) if(j!=i && s[j]<=s[i] && e[j]>=e[i] && (s[j]<s[i]||e[j]>e[i]||j<i)){k=1;break}
        if(!k) for(j=1;j<=g;j++) if(gs[j]<=s[i] && ge[j]>=e[i]){k=1;break}
        if(!k) print c[i]}}' $GEO_FILE $W/n 2>/dev/null | sort > $W/new
  [ -f $GEO_FILE ] || sort $W/n > $W/new
  touch $R_FILE; sort $R_FILE > $W/old
  tot=$(grep -c . $W/new); add=$(awk 'NR==FNR{o[$1]=1; next} !($1 in o)' $W/old $W/new | grep -c .); rem=$(awk 'NR==FNR{o[$1]=1; next} !($1 in o)' $W/new $W/old | grep -c .)
  if [ $tot -gt $MAX_TOTAL ] || { [ -s $W/old ] && [ $add -gt $MAX_ADD ]; }; then
    log "СТОП: слишком большое изменение (+$add, всего $tot) — не применяю"
    send "$(L "⚠️ Развилка: RIPE дал подозрительно много сетей (+$add, всего $tot). Не применял. Проверь список компаний." "⚠️ Razvilka: RIPE returned suspiciously many networks (+$add, $tot in total). Not applied. Check the company list.")"; return 1; fi
  cmp -s $W/old $W/new && { log "refresh ($reason): без изменений, сетей $tot"; return 0; }
  push "$reason" $add $rem $tot
}
push() {   # file $W/new → router (.prev copy) → load → VPN check → rollback on failure
  mkdir -p $R_DIR; [ -f $R_FILE ] && cp $R_FILE $R_FILE.prev
  cp $W/new $R_FILE.new && mv $R_FILE.new $R_FILE
  $DR autoload >/dev/null 2>&1; sleep 3
  if ! vpn_ok; then sleep 10; if ! vpn_ok; then
    [ -f $R_FILE.prev ] && cp $R_FILE.prev $R_FILE || rm -f $R_FILE; $DR autoload >/dev/null 2>&1
    log 'push: VPN не отвечает после загрузки — ОТКАТ на прошлый список'
    send "$(L '⚠️ Развилка: после обновления сетей VPN не ответил — вернул прошлый список. Нужен осмотр.' '⚠️ Razvilka: VPN did not answer after the network update — I put the previous list back. Needs a look.')"; return 1; fi; fi
  log "push ($1): +$2 −$3, всего $4"
  if [ -s $W/old ]; then
    m="$(L "🛣 Прямые дороги обновлены ($1): +$2 −$3, всего сетей $4." "🛣 Direct routes updated ($1): +$2 −$3, $4 networks in total.")"
    m="$m$(awk 'NR==FNR{o[$1]=1; next} !($1 in o){n++; if(n<=15) printf "\n+ %s", $1} END{if(n>15) printf "\n…"}' $W/old $W/new)"
    m="$m$(awk 'NR==FNR{o[$1]=1; next} !($1 in o){n++; if(n<=10) printf "\n− %s", $1} END{if(n>10) printf "\n…"}' $W/new $W/old)"
    send "$m"; fi
}

# ---------- hints from connections (every 10 min) ----------
watch() {
  [ -f $HINTS_OFF ] && return 0
  vpn_ok || return 0                       # without a connection the hints would not arrive — wait
  macs=$(group_macs); [ -n "$macs" ] || return 0     # «@policy» is a word, not a device: read it like direct-routes.sh
  tip=$(ip -4 addr show $TUN 2>/dev/null | awk '/inet /{sub("/.*","",$2); print $2; exit}'); [ -z "$tip" ] && return 0
  grep " dst=$tip " /proc/net/nf_conntrack 2>/dev/null | awk -v M=" $(echo $macs) " '
    { mac=""; if (match($0,/mac=[0-9a-f:]+/)) mac=substr($0,RSTART+4,17); if (index(M," " mac " ")==0) next
      d=""; b=0; nb=0; for(i=1;i<=NF;i++){ if($i ~ /^dst=/ && d=="") d=substr($i,5); if($i ~ /^bytes=/){b+=substr($i,7); nb++} }
      if (d!="" && nb>=2) f[d]+=b }
    END { for (d in f) print f[d], d }' | sort -rn | head -40 > $W/flows
  [ -s $W/flows ] || return 0
  CC=$(country | tr a-z A-Z); stale=''; hints=0; nowt=$(now)
  while read -r by ip; do
    cat $R_FILE $GEO_FILE 2>/dev/null | awk -v IP=$ip "$NET2INT"' BEGIN{x=ip2n(IP)} /\//{rng($1); if(x>=S&&x<=E){f=1; exit}} END{exit !f}' && continue   # -v: the IP must be known in BEGIN
    set -- $(owner $ip); asn=$1; cc=$2; shift 2; holder="$*"; [ "$asn" = 0 ] && continue
    if asn_in $ALLOW $asn && ! asn_in $DENY $asn; then
      last=$(awk -v a=$asn '$1==a{t=$2} END{print t+0}' $REFRESHED 2>/dev/null)
      [ $(( nowt - last )) -gt 21600 ] && ! echo " $stale " | grep -q " $asn " && stale="$stale $asn"
    elif [ "$cc" = "$CC" ] && ! asn_in $DENY $asn && [ $by -ge $HINT_MIN_BYTES ] && ! grep -q "^$asn " $HINTED 2>/dev/null \
         && ! echo "$holder" | grep -qiE "$HOSTING_RE" && [ $hints -lt 5 ]; then
      hints=$((hints+1)); echo "$asn $(today)" >> $HINTED; log "watch: кандидат AS$asn $holder ($ip, $((by/1024)) КБ через VPN)"
      org=$(printf '%s' "$holder" | sed 's/^[A-Z0-9-]* - //; s/,[^,]*$//'); [ -z "$org" ] && org="AS$asn"; mb=$((by/1048576)); [ $mb -lt 1 ] && mb=1
      : > $SKB; row "$(L '🌐 Пустить напрямую' '🌐 Send direct')" "add:$asn" "$(L 'Не надо' 'No, thanks')" "skip:$asn"
      send "$(L "💡 Похоже, что-то от «$org» открывалось через VPN ($mb МБ).
Это компания из твоей страны, но её адресов нет в карте. Пустить её напрямую?" "💡 Looks like something from «$org» opened via VPN ($mb MB).
This company is from your home country, but its addresses are not in the map. Let it go direct?")" "$(kb_json $SKB)"
    fi
  done < $W/flows
  [ -n "$stale" ] && { log "watch: адреса компаний из списка шли через VPN:$stale"; refresh "$(L 'найдено в соединениях' 'found in connections')" $stale; }   # the lock is already taken in "watch)"
  return 0
}

# ---------- self-healing (every minute) ----------
# The VPN connection may stay «connected» while no data goes through it. Then devices that may use only
# the VPN retry DNS without a pause, thousands of connections pile up and a small router can hang.
# 3 minutes without data → the DNS fuse (these devices get an instant «no DNS», nothing leaks to the ISP)
# and a restart of the VPN connection (at most once in 30 minutes); 6 minutes → own script heal2.sh, if any.
FUSE_CH=RZVFUSE
fuse_rules_on() {
  m=$(policy_macs); [ -n "$m" ] || { log "предохранитель DNS: не нашёл устройств с VPN-политикой — не ставлю"; return 1; }
  for T in iptables ip6tables; do
    command -v $T >/dev/null 2>&1 || continue   # no IPv6 tools on some routers: IPv4 is enough then
    if [ $T = iptables ]; then R=icmp-port-unreachable; else R=icmp6-port-unreachable; fi
    $T -w -N $FUSE_CH 2>/dev/null; $T -w -F $FUSE_CH
    $T -w -A $FUSE_CH -p udp --dport 53 -j REJECT --reject-with $R
    $T -w -A $FUSE_CH -p tcp --dport 53 -j REJECT --reject-with tcp-reset
    for x in $m; do $T -w -C INPUT -i br+ -m mac --mac-source $x -j $FUSE_CH 2>/dev/null || $T -w -I INPUT 1 -i br+ -m mac --mac-source $x -j $FUSE_CH; done
  done
  return 0   # the fuse must be remembered once any rule is in, or nobody would take it off
}
fuse_rules_off() {
  for T in iptables ip6tables; do
    command -v $T >/dev/null 2>&1 || continue
    $T -w -S INPUT 2>/dev/null | grep -- "-j $FUSE_CH" | sed 's/^-A /-D /' | while read -r r; do eval "$T -w $r" 2>/dev/null; done
    $T -w -F $FUSE_CH 2>/dev/null; $T -w -X $FUSE_CH 2>/dev/null
  done
}
fuse_on()  { fuse_rules_on && kv_set fuse_on $(now); }
fuse_off() { kv_del fuse_on; fuse_rules_off; }   # flag first: the netfilter hook must not put the rules back
fuse_present() { iptables -w -S INPUT 2>/dev/null | grep -q -- "-j $FUSE_CH"; }
fuse_sync() {   # every minute: the rules follow the flag, both ways (hook races, firmware rebuilds, a broken flag)
  if [ "$(kn fuse_on)" -gt 0 ]; then fuse_present || fuse_rules_on
  elif fuse_present; then fuse_rules_off; log "предохранитель DNS: правила остались без флага — убрал"; fi
}
heal_vpn() {   # restart the VPN connection → prints what was restarted
  id=$VPN_NDM
  if [ -z "$id" ]; then case "$TUN" in
    opkgtun*) [ -x /opt/etc/init.d/S99trusttunnel ] && { /opt/etc/init.d/S99trusttunnel reload >/dev/null 2>&1; echo TrustTunnel; return 0; } ;;
    nwg*) id="Wireguard${TUN#nwg}" ;;
  esac; fi
  [ -n "$id" ] || return 1
  ndmc -c "interface $id down" >/dev/null 2>&1; sleep 5; ndmc -c "interface $id up" >/dev/null 2>&1; echo "$id"
}
guard() { guard_step; fuse_sync; }
guard_step() {
  t=$(now); fo=$(kn fuse_on)
  if [ "$GUARD" != 1 ] || [ "$FUSE" != 1 ]; then   # turned off in net.conf: never leave the fuse behind
    [ "$fo" -gt 0 ] && { fuse_off; log "предохранитель DNS снят: он выключен в net.conf"; }
    fo=0; [ "$GUARD" = 1 ] || return 0
  fi
  if [ "$fo" -gt 0 ] && [ $((t - fo)) -ge 1800 ]; then
    fuse_off; kv_set g_fail 0; log "предохранитель DNS снят по таймеру (30 мин), проверяю VPN заново"; return 0
  fi
  if vpn_ok; then
    kv_set g_fail 0; ok=$(( $(kn g_ok) + 1 )); kv_set g_ok $ok
    vm=$(vpn_marks); [ "$vm" != "$(kv_get vpn_marks)" ] && kv_set vpn_marks "$vm"   # a policy moved off the VPN is forgotten too
    [ "$fo" -gt 0 ] && [ $ok -ge 2 ] && { fuse_off; log "VPN снова пропускает данные — предохранитель DNS снят"; }
    [ -n "$(kv_get heal_step)" ] && { kv_del heal_step; log "самолечение помогло — VPN снова пропускает данные"; }
    return 0
  fi
  kv_set g_ok 0; f=$(( $(kn g_fail) + 1 )); kv_set g_fail $f
  [ $f -eq 3 ] && [ "$FUSE" = 1 ] && [ "$fo" = 0 ] && fuse_on && log "VPN не пропускает данные 3 мин — устройствам с VPN-политикой сразу отказ DNS (предохранитель)"
  if [ $f -ge 3 ]; then   # the restart repeats every 30 minutes while the outage lasts
    if [ "$HEAL" = 1 ] && [ $((t - $(kn heal_at))) -ge 1800 ]; then
      if h=$(heal_vpn); then kv_set heal_at $t; kv_set heal_step 1; log "самолечение: перезапустил VPN ($h)"
        qadd "$(L "🛠 VPN перестал пропускать данные — я перезапустил подключение ($h)." "🛠 The VPN stopped passing data — I restarted the connection ($h).")"
      else [ $f -eq 3 ] && log "самолечение: не знаю, как перезапустить $TUN — впиши имя подключения в net.conf: VPN_NDM=…"; fi
    elif [ "$(kv_get heal_step)" = 1 ] && [ $((t - $(kn heal_at))) -ge 180 ] && [ -x $ETC/heal2.sh ]; then   # 3 minutes after a restart
      kv_set heal_step 2; log "самолечение, шаг 2: запускаю свой сценарий heal2.sh"; $ETC/heal2.sh >/dev/null 2>&1
    fi
  fi
  return 0
}

# ---------- alerts and summary (every 5 min) ----------
checks() {
  t=$(now)
  p=$(kv_get hc_pause 0)
  if [ "$p" -gt 0 ] && [ $t -ge $p ]; then kv_del hc_pause; log 'сторож: тест молчания окончен'
    send "$(L '🤫 Тест молчания окончен, сигналы сторожу снова идут.
Пришла тревога от сторожа (письмо, MAX или Telegram)? Если да — всё настроено правильно. Если нет — этот сервис тишину не ловит: возьми другой (⚙️ Настройки → 🕰 Сторож связи).' '🤫 The silence test is over, signals go to the watchdog again.
Did the watchdog alarm reach you (email or Telegram)? If yes — everything is set up right. If not — this service does not catch silence: take another one (⚙️ Settings → 🕰 Connection watchdog).')"; fi
  if vpn_ok; then
    hc_paused || hc_ping                     # "I am alive" to the watchdog (if enabled); through the tunnel
    kv_del hc_failsent
    dn=$(kv_get vpn_down_at)
    if [ -n "$dn" ]; then
      m="$(L "🟢 Защищённый канал снова работает. Его не было с $(date -d @$dn +%H:%M) до $(date +%H:%M) (около $(( (t-dn)/60 )) мин)." "🟢 The secure channel works again. It was down from $(date -d @$dn +%H:%M) to $(date +%H:%M) (about $(( (t-dn)/60 )) min).")"
      if [ -s $QUEUE ]; then m="$m

$(L '📬 Пока не было связи, накопилось:' '📬 While there was no connection, this piled up:')$(awk '{t=$1; $1=""; printf "\n• %s —%s", strftime("%H:%M", t), $0}' $QUEUE 2>/dev/null || awk '{$1=""; printf "\n•%s", $0}' $QUEUE)"; fi
      send "$m" && : > $QUEUE
    elif [ -s $QUEUE ]; then send "$(L '📬 Не дошло раньше:' '📬 Did not get through earlier:')$(awk '{$1=""; printf "\n•%s", $0}' $QUEUE)" && : > $QUEUE; fi
    kv_set vpn_bad 0; kv_del vpn_down_at
  else b=$(( $(kv_get vpn_bad 0) + 1 )); kv_set vpn_bad $b; [ $b = 2 ] && kv_set vpn_down_at $((t-300))
    # the router is alive, the VPN is not: no «I am alive» (silence → alarm); a service that takes explicit alarms gets one now
    if ! hc_paused && [ -z "$(kv_get hc_failsent)" ] && hc_fail_direct; then kv_set hc_failsent $t; log 'сторож: VPN не отвечает — тревога отправлена напрямую через провайдера'; fi
  fi
  m=$(mem_kb); [ "$m" -lt $MEM_LOW_KB ] && [ $(( t - $(kv_get mem_alert 0) )) -gt 21600 ] && {
    send "$(L "🟡 У роутера мало памяти: $((m/1024)) МБ. Защита памяти сработает сама; если повторяется — загляни в README (раздел «Если что-то не так»)." "🟡 The router is low on memory: $((m/1024)) MB. Memory protection will kick in by itself; if it repeats, see the README (Troubleshooting).")"; kv_set mem_alert $t; }
  set -- $(cat /opt/etc/geo-status 2>/dev/null)
  if [ "$1" = toobig ] && [ $(( t - $(kv_get geo_big_alert 0) )) -gt 86400 ]; then
    : > $SKB; row "$(L '🗺 Включить лёгкую карту' '🗺 Turn on the light map')" lite; row "$(L '🔎 Добавить сайт' '🔎 Add a site')" add
    if en; then send "🟡 The country map did not fit into the router’s memory ($2 networks, but the router can hold $3). So right now everything goes via VPN.

What you can do:
• 🗺 Turn on the «light map» — the router takes the biggest blocks of the country that fit (usually 99% of addresses: banks, government sites, providers). Small networks go via VPN, but they will work.
• 🔎 Add the sites you need by hand — they will go direct.
• Get a stronger router (256 MB of memory or more)." "$(kb_json $SKB)"
    else send "🟡 Карта страны не влезла в память роутера ($2 сетей, а роутер выдержит $3). Поэтому сейчас всё идёт через VPN.

Что можно сделать:
• 🗺 Включить «лёгкую карту» — роутер возьмёт самые крупные блоки страны, сколько влезет (обычно это 99% адресов: банки, госсайты, провайдеры). Мелкие сети пойдут через VPN, но будут работать.
• 🔎 Добавлять нужные сайты вручную — они пойдут напрямую.
• Поставить роутер мощнее (от 256 МБ памяти)." "$(kb_json $SKB)"; fi; kv_set geo_big_alert $t; fi
  geo_stale && [ $(( t - $(kv_get geo_alert 0) )) -gt 86400 ] && {
    send "$(L '🟡 Список своей страны не обновлялся больше двух суток. Сайты открываются по старому списку. Если повторится завтра — загляни в README (раздел «Если что-то не так»).' '🟡 The home country list has not been updated for more than two days. Sites open by the old list. If it repeats tomorrow, see the README (Troubleshooting).')"; kv_set geo_alert $t; }
  if geo_on; then kv_del geo_off_since
  else os=$(kv_get geo_off_since); [ -z "$os" ] && { kv_set geo_off_since $t; os=$t; }
    if [ $((t-os)) -gt 86400 ] && [ $(( t - $(kv_get geo_off_remind 0) )) -gt 86400 ]; then
      : > $SKB; row "$(flag) $(L 'Включить' 'Turn on')" geo:on "$(L 'Оставить' 'Keep')" set
      send "$(L '⚪ Напоминаю: «Своя страна напрямую» выключена уже сутки — всё идёт через VPN. Включить?' '⚪ A reminder: «Home country direct» has been off for a day — everything goes via VPN. Turn it on?')" "$(kb_json $SKB)"; kv_set geo_off_remind $t; fi; fi
  if [ -s $HC_URL ] && ! hc_paused && [ $(( t - $(kv_get hc_ok $t) )) -gt 2400 ] && [ $(( t - $(kv_get hc_alert 0) )) -gt 86400 ] && vpn_ok; then
    send "$(L '🟡 Сторож связи давно не получает сигналов от роутера, хотя VPN работает. Проверь ссылку: ⚙️ Настройки → 🕰 Сторож связи.' '🟡 The connection watchdog has not received signals from the router for a long time, although the VPN works. Check the link: ⚙️ Settings → 🕰 Connection watchdog.')"; kv_set hc_alert $t; fi
  if [ "$(kv_get digest 1)" = 1 ] && [ "$(date +%H)" = 09 ] && [ "$(kv_get digest_day)" != "$(today)" ]; then
    kv_set digest_day "$(today)"; screen_status
    HCL=''; [ -s $HC_URL ] && HCL="

$(L "🕰 Сторож связи на посту, последний сигнал $(ago "$(kv_get hc_ok 0)")." "🕰 Watchdog is in touch, last signal $(ago "$(kv_get hc_ok 0)").")"
    if head -1 $SCR | grep -q '^✅'; then : > $SKB; row "$(L 'Подробнее' 'Details')" det; send "$(L '☀️ Доброе утро! Дома всё работает.' '☀️ Good morning! Everything at home works.')$HCL" "$(kb_json $SKB)"
    else send "$(L '☀️ Доброе утро!' '☀️ Good morning!')

$(cat $SCR)$HCL" "$(kb_json $SKB)"; fi; fi
}

# ---------- button actions (MID — the message to update) ----------
busy() { edit $MID "$(L '⏳ Роутер занят другим делом — попробуй через минуту.' '⏳ The router is busy with something else — try again in a minute.')"; exit 0; }
A=$1; shift
case "$A" in
  checks) QUEUE_ON_FAIL=1; checks ;;
  guard)  mkdir $TMP/guard.lock 2>/dev/null || { [ -n "$(find $TMP/guard.lock -mmin +5 2>/dev/null)" ] && rmdir $TMP/guard.lock; exit 0; }
          guard; rmdir $TMP/guard.lock ;;
  fuse_apply) [ "$GUARD" = 1 ] && [ "$FUSE" = 1 ] && [ "$(kn fuse_on)" -gt 0 ] && fuse_rules_on; exit 0 ;;
  fuse_off) fuse_off; exit 0 ;;
  watch)  lock 60 || exit 0; watch; unlock ;;
  refresh) QUEUE_ON_FAIL=1; lock 600 || exit 0; refresh "$(L 'сверка' 'check')" "$@"; unlock ;;
  card_as|card_ac|card_vpn)
    MID=$1; set -- $(kv_get card); d=$1; asn=$2; shift 2 2>/dev/null; holder="$*"
    [ -z "$d" ] && exit 0; clean_domain "$d" >/dev/null || exit 0; is_num "$asn" || asn=0
    : > $SKB
    case "$A" in
      card_as) lock 300 || busy
        if site_add $d; then res="$(L "✅ $d теперь напрямую.
Сработает для устройств, которые спрашивают адреса у роутера." "✅ $d now goes direct.
It works for devices that ask the router for addresses.")"; else res="$(L '😕 Не получилось добавить сайт — роутер не ответил. Попробуй ещё раз.' '😕 Could not add the site — the router did not answer. Try again.')"; fi
        unlock; kv_del card; row "$(L '🛣 Посмотреть дороги' '🛣 See routes')" roads; edit $MID "$res" "$(kb_json $SKB)" ;;
      card_ac) lock 600 || busy
        if [ "$asn" != 0 ] && company_add $asn "$holder"; then res="$(L '✅ Вся компания теперь напрямую.' '✅ The whole company now goes direct.')"; else res="$(L 'Эту компанию целиком добавить нельзя — это облако или хостинг.' 'This company cannot be added as a whole — it is a cloud or hosting.')"; fi
        unlock; kv_del card; row "$(L '🛣 Посмотреть дороги' '🛣 See routes')" roads; edit $MID "$res" "$(kb_json $SKB)" ;;
      card_vpn) edit $MID "$(L "⏳ Пускаю $d через VPN — пересобираю карту страны, около полутора минут…" "⏳ Sending $d via VPN — rebuilding the country map, about a minute and a half…")"
        lock 300 || busy
        list_has $ETC/sites $d && site_del $d
        list_add $ETC/vpn_sites $d
        if geo_sync; then res="$(L "✅ $d теперь через VPN. Если сайт сменит адреса — Развилка подхватит их при ночном обновлении." "✅ $d now goes via VPN. If the site changes addresses, Razvilka will pick them up in the nightly update.")"
        else res="$(L '😕 Роутер не ответил. Попробуй ещё раз через минуту.' '😕 The router did not answer. Try again in a minute.')"; fi
        unlock; log "сайт $d — через VPN"; kv_del card; row "$(L '📋 Мои исключения' '📋 My exceptions')" list; edit $MID "$res" "$(kb_json $SKB)" ;;
    esac ;;
  site_del) n=$1; MID=$2; d=$(list_get $ETC/sites $n); lock 300 || busy
    [ -n "$d" ] && site_del $d; unlock; ok="${d:+$(L "✅ $d теперь через VPN." "✅ $d now goes via VPN.")

}"; screen_list; scr_edit $MID "$ok" ;;
  vsite_del) n=$1; MID=$2; d=$(list_get $ETC/vpn_sites $n); lock 300 || busy
    [ -n "$d" ] && { list_del $ETC/vpn_sites $d; geo_sync; log "сайт $d — снова по общему правилу"; }
    unlock; ok="${d:+$(L "✅ $d снова идёт по общему правилу." "✅ $d follows the general rule again.")

}"; screen_list; scr_edit $MID "$ok" ;;
  company_del) a=$1; MID=$2; nm=$(companies | awk -v a="$a" '$1==a{$1=""; sub(/^ /,""); print; exit}'); lock 600 || busy
    [ -n "$nm" ] && { allow_del $a "$nm"; refresh "$(L "убрано кнопкой AS$a" "removed by button AS$a")"; }; unlock
    ok="${nm:+$(L "✅ $nm теперь через VPN." "✅ $nm now goes via VPN.")

}"; screen_list; scr_edit $MID "$ok" ;;
  service_del) i=$1; MID=$2; l=$(services | awk -F'|' -v i="$i" '$1==i'); nm=$(echo "$l" | cut -d'|' -f2); lock 600 || busy
    if [ -n "$l" ]; then
      for a in $(echo "$l" | cut -d'|' -f3); do allow_del $a "$nm"; done
      for d in $(echo "$l" | cut -d'|' -f4); do site_del $d; done
      [ -n "$(echo "$l" | cut -d'|' -f3)" ] && refresh "$(L "убрано кнопкой: $nm" "removed by button: $nm")"
    fi; unlock; ok="${nm:+$(L "✅ $nm теперь через VPN." "✅ $nm now goes via VPN.")

}"; screen_list; scr_edit $MID "$ok" ;;
  device) mac=$1; MID=$2; is_mac $mac || exit 0
    line=$(device_list | awk -v m=$mac '$1==m'); [ -z "$line" ] && { screen_devices; scr_edit $MID "$(L '✅ Это устройство сейчас без VPN в Keenetic.' '✅ This device has no VPN in Keenetic right now.')

"; exit 0; }
    set -- $line; st=$2; shift 2; nm="$*"; lock 120 || busy; cp -p $DRCONF $DRCONF.prev
    if [ $st = 1 ]; then sed -i "/^$GROUP[[:space:]]/ s/[[:space:]]!$mac//" $DRCONF; res="$nm: $(L 'своя страна напрямую' 'home country direct')"
    else sed -i "/^$GROUP[[:space:]]/ s/^\([^#]*[^[:space:]#]\)/\1 !$mac/" $DRCONF; res="$nm: $(L 'всё через VPN' 'everything via VPN')"; fi
    $DR apply >/dev/null 2>&1; unlock; log "устройство $mac ($nm) → $([ $st = 1 ] && echo 'обычный режим' || echo 'строго через VPN')"
    screen_devices; scr_edit $MID "✅ $res

" ;;
  geo) MID=$1; w=$2; [ -n "$w" ] || { geo_on && w=off || w=on; }
    if { [ $w = off ] && ! geo_on; } || { [ $w = on ] && geo_on; }; then screen_settings; scr_edit $MID; exit 0; fi   # already so (a double tap)
    if [ $w = off ]; then lock 120 || busy; $GEO_SH off >/dev/null 2>&1; unlock; log 'своя страна → выкл'
      screen_settings; scr_edit $MID "$(L '✅ «Своя страна напрямую» выключена. Остались только твои исключения.' '✅ «Home country direct» is off. Only your exceptions are left.')

"
    else log 'своя страна → вкл'; GEO_FORCE=$(L вкл on) screen_settings
      scr_edit $MID "$(L '✅ Включаю «Своя страна напрямую». Роутер соберёт список сам — около двух минут.' '✅ Turning on «Home country direct». The router will build the list itself — about two minutes.')

"
      lock 300 && { $GEO_SH on >/dev/null 2>&1; unlock; }; fi ;;
  lite) MID=$1; edit $MID "$(L '🗺 Включаю лёгкую карту — роутер соберёт её за пару минут. Проверить: 📊 Статус.' '🗺 Turning on the light map — the router will build it in a couple of minutes. To check: 📊 Status.')"; log 'включена лёгкая карта'
    lock 300 || exit 0; grep -q '^LITE=' $GEO_CONF && sed -i 's/^LITE=.*/LITE=1/' $GEO_CONF || echo LITE=1 >> $GEO_CONF
    $GEO_SH apply >/dev/null 2>&1; unlock ;;
  rollback) MID=$1; lock 300 || busy; n=0
    [ -f $GEO_FILE.prev ] && cp $GEO_FILE.prev $GEO_FILE && n=1; [ -f $R_FILE.prev ] && cp $R_FILE.prev $R_FILE && n=1
    [ $n = 1 ] && $DR autoload >/dev/null 2>&1; unlock; screen_settings
    if [ $n = 1 ]; then scr_edit $MID "$(L '✅ Вернул как было. Ночью карта обновится снова — если проблема вернётся, загляни в README (раздел «Если что-то не так»).' '✅ Undone. The map will update again tonight — if the problem comes back, see the README (Troubleshooting).')

"; else scr_edit $MID "$(L 'Прошлой версии нет — возвращать нечего.' 'There is no previous version — nothing to undo.')

"; fi ;;
  hint_skip) a=$1; MID=$2; echo "$a   # отклонено кнопкой $(today)" >> $DENY
    edit $MID "$(L "Хорошо, AS$a оставляю через VPN и больше не спрашиваю." "OK, AS$a stays via VPN and I will not ask again.")" ;;
  hint_add) a=$1; MID=$2; lock 600 || busy
    if company_add $a; then res="$(L "✅ AS$a теперь напрямую." "✅ AS$a now goes direct.")"; else res="$(L "AS$a — облако или хостинг, целиком не добавляю." "AS$a is a cloud or hosting, I do not add it as a whole.")"; fi; unlock; edit $MID "$res" ;;
esac
