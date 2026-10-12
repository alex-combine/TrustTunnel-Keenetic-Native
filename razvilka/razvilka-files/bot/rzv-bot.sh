#!/opt/bin/sh
# Razvilka on the router — Telegram bot (sh + curl + jq). v1.2 (BOTLANG=en in net.conf for English)
# Screens and texts match the earlier Python version one to one.
# Start: /opt/etc/init.d/S99razvilka start   (the service restarts it after a crash)
. /opt/share/razvilka/rzv-lib.sh
row() { r=''; while [ $# -ge 2 ]; do [ -n "$r" ] && r="$r$T"; r="$r$1$B$2"; shift 2; done; echo "$r" >> $SKB; }
scr() { printf '%s' "$1" > $SCR; : > $SKB; }

# ---------- data ----------
# number|Russian name~English name|asn in allow|sites in sites
SERVICES='0|VK и Mail.ru~VK & Mail.ru|47541 47764|vk-cdn.net oneme.ru
1|Яндекс~Yandex|208398|yandexcloud.net
2|Rutube~Rutube|51115|rutube.ru
3|mos.ru~mos.ru|8901|
4|Okko~Okko||okko.tv
5|Авито~Avito||avito.st
6|Wildberries~Wildberries||wbbasket.ru
7|Звонки по Wi-Fi (оператор)~Wi-Fi calling (carrier)||pub.3gppnetwork.org'
services() {   # "number|name|asn in allow|sites in sites" — only services with something in the exceptions
  [ "$(country)" = ru ] || return 0
  echo "$SERVICES" | while IFS='|' read -r i nm as ds; do
    if en; then nm=${nm#*~}; else nm=${nm%%~*}; fi
    a=''; for x in $as; do asn_in $ALLOW $x && a="$a $x"; done
    d=''; for x in $ds; do list_has $ETC/sites $x && d="$d $x"; done
    [ -n "$a$d" ] && echo "$i|$nm|${a# }|${d# }"
  done
}
device_list() {   # "mac strict(0/1) name"
  pol=$(iptables -t mangle -S _NDM_HOTSPOT_PREROUTING_MANGL 2>/dev/null | grep -i set-xmark | grep -io 'mac-source [0-9a-f:]*' | awk '{print tolower($2)}' | sort -u)
  [ -z "$pol" ] && return 0
  ndmc -c 'show ip hotspot' 2>/dev/null | awk '/ mac: /{m=tolower($2)} /^ *name: /{sub(/^ *name: */,""); if(!(m in n)) n[m]=$0} /^ *hostname: /{sub(/^ *hostname: */,""); if(!(m in h)) h[m]=$0}
     END{for(m in n) print "N", m, n[m]; for(m in h) print "H", m, h[m]}' > $W/hs
  strict=$(sed 's/#.*//' $DRCONF | awk -v g=$GROUP '$1==g{for(i=2;i<=NF;i++) if(substr($i,1,1)=="!") print tolower(substr($i,2))}')
  for m in $pol; do
    nm=$(awk -v m=$m '$1=="N"&&$2==m{$1="";$2=""; sub(/^ +/,""); print; exit}' $W/hs)
    hn=$(awk -v m=$m '$1=="H"&&$2==m{$1="";$2=""; sub(/^ +/,""); print; exit}' $W/hs)
    [ -z "$nm" ] && nm=${hn:-$m}
    case "$nm" in *' - Home network'*) nm=${hn:-${nm%% - Home network*}};; esac
    s=0; echo "$strict" | grep -qx "$m" && s=1
    printf '%s %s %s\n' "$m" "$s" "$(printf '%s' "$nm" | cut -c1-28)"
  done | sort -k3
}

# ---------- screens ----------
screen_status() {   # [det]
  mem=$(( $(mem_kb) / 1024 )); vpn=0; vpn_ok && vpn=1; on=0; geo_on && on=1; p=''
  if [ $vpn = 0 ]; then if [ "$GUARD" = 1 ] && [ "$HEAL" = 1 ] && heal_known; then p="$p
$(L '🔴 VPN не отвечает — на устройствах с VPN сайты могут не открываться. Роутер сам перезапустит VPN в ближайшие минуты, перезагружать его не нужно. Если не пройдёт за 15 минут — тогда перезагрузи роутер.' '🔴 VPN is not answering — sites may not open on devices with VPN. The router restarts the VPN by itself within minutes, no need to reboot it. If it does not pass in 15 minutes — then reboot the router.')"
  else p="$p
$(L '🔴 VPN не отвечает — заграничные сайты могут не открываться. Если не пройдёт за 10 минут, перезагрузи роутер.' '🔴 VPN is not answering — foreign sites may not open. If it does not pass in 10 minutes, reboot the router.')"; fi; fi
  [ $mem -lt 15 ] && p="$p
$(L "🟡 Роутеру тесно: свободно $mem МБ. Обычно проходит само." "🟡 The router is short on memory: $mem MB free. It usually passes by itself.")"
  geo_stale && p="$p
$(L '🟡 Список своей страны давно не обновлялся. Работает старый — сайты открываются, но могут появиться новые адреса.' '🟡 The home country list has not been updated for a while. The old one works — sites open, but new addresses may appear.')"
  [ $on = 0 ] && p="$p
$(L '⚪ «Своя страна напрямую» выключена — всё идёт через VPN (кроме твоих исключений).' '⚪ «Home country direct» is off — everything goes via VPN (except your exceptions).')"
  [ -z "$p" ] && h=$(L '✅ Всё в порядке' '✅ All good') || h=$(L '⚠️ Есть что проверить' '⚠️ Something to check')
  [ $on = 1 ] && r="$(flag) $(L "Своя страна ($(cname)) — напрямую, остальное — через VPN." "Home country ($(cname)) — direct, everything else — via VPN.")" || r=$(L '🔒 Всё — через VPN.' '🔒 Everything — via VPN.')
  t="$h

$r$p

$(L 'Список страны обновлён' 'Country list updated') $(ago $(geo_t))."
  if [ "$1" = det ]; then
    up=$(cut -d. -f1 /proc/uptime); ex=$(( $(companies | grep -c .) + $(list_n $ETC/sites) + $(list_n $ETC/vpn_sites) ))
    [ $vpn = 1 ] && v=$(L '🟢 VPN — работает' '🟢 VPN — working') || v=$(L '🔴 VPN — не отвечает' '🔴 VPN — not answering')
    if en; then t="$t

— Details —
$v
🧠 Router memory — $mem MB free
🗺 Home country networks — $(geo_n)
📋 Your exceptions — $ex
⏱ Router up without reboot — $((up/86400)) d $((up%86400/3600)) h"
    else t="$t

— Подробнее —
$v
🧠 Память роутера — свободно $mem МБ
🗺 Сетей своей страны — $(geo_n)
📋 Твоих исключений — $ex
⏱ Роутер без перезагрузки — $((up/86400)) д $((up%86400/3600)) ч"; fi
    scr "$t"; row "$(L '🔄 Обновить' '🔄 Refresh')" st "$(L 'Скрыть подробности' 'Hide details')" st
  else scr "$t"; row "$(L '🔄 Обновить' '🔄 Refresh')" st "$(L 'Подробнее' 'Details')" det; fi
  row "$(L '📋 Мои исключения' '📋 My exceptions')" list
}
screen_list() {
  services > $W/svc
  cs=$(companies); sv_a=$(cut -d'|' -f3 $W/svc | tr ' ' '\n'); sv_d=$(cut -d'|' -f4 $W/svc | tr ' ' '\n')
  if [ -s $W/svc ] || [ -n "$cs" ] || [ -s $ETC/sites ] || [ -s $ETC/vpn_sites ]; then e=$(L 'Нажми на строку, чтобы убрать.' 'Tap a line to remove it.'); else e=$(L 'Пока пусто — и это нормально.' 'Empty for now — and that is fine.'); fi
  if en; then scr "📋 My exceptions

Everything in your home country already goes direct. Here is only what you changed on top of that:
🌐 — direct, although the map would send it via VPN
🔒 — via VPN, although the site is from your home country

$e"
  else scr "📋 Мои исключения

Всё в своей стране и так идёт напрямую. Здесь — только то, что ты поменял поверх этого:
🌐 — напрямую, хотя по карте шло бы через VPN
🔒 — через VPN, хотя сайт из своей страны

$e"; fi
  while IFS='|' read -r i nm a d; do row "🌐 $nm" "g:$i"; done < $W/svc
  echo "$cs" | while read -r asn nm; do [ -z "$asn" ] && continue
    echo "$sv_a" | grep -qx "$asn" || row "🌐 $(org_name "$nm" $asn | cut -c1-30)" "c:$asn"; done
  n=0; [ -f $ETC/sites ] && while read -r d; do n=$((n+1)); echo "$sv_d" | grep -qxF "$d" || row "🌐 $d" "s:$n"; done < $ETC/sites
  n=0; [ -f $ETC/vpn_sites ] && while read -r d; do n=$((n+1)); row "🔒 $d" "v:$n"; done < $ETC/vpn_sites
  row "$(L '🔎 Проверить сайт' '🔎 Check a site')" add
}
screen_service() {
  l=$(services | awk -F'|' -v i="$1" '$1==i'); [ -z "$l" ] && { screen_list; return; }
  nm=$(echo "$l" | cut -d'|' -f2); a=$(echo "$l" | cut -d'|' -f3); d=$(echo "$l" | cut -d'|' -f4)
  parts=''; [ -n "$a" ] && parts=$(L 'сети компании за рубежом' 'company networks abroad'); [ -n "$d" ] && parts="${parts:+$parts; }$(echo $d | sed 's/ /, /g')"
  if en; then scr "🌐 $nm

Goes direct entirely: $parts.
This is not in the country map, so it was added separately.

Remove it — and it will go via VPN."
  else scr "🌐 $nm

Идёт напрямую целиком: $parts.
Этого нет в карте страны, поэтому добавлено отдельно.

Убрать — и это пойдёт через VPN."; fi
  row "$(L '↩️ Убрать исключение' '↩️ Remove exception')" "gd:$1"; row "$(L '« Назад' '« Back')" list
}
screen_company() {
  nm=$(companies | awk -v a="$1" '$1==a{$1=""; sub(/^ /,""); print; exit}'); [ -z "$nm" ] && { screen_list; return; }
  scr "🌐 $(org_name "$nm" $1)

$(L 'Идёт напрямую. Это сети компании за рубежом, которых нет в карте страны (например, её серверы в других странах).

Убрать — и они пойдут через VPN.' 'Goes direct. These are the company’s networks abroad that are not in the country map (for example, its servers in other countries).

Remove it — and they will go via VPN.')"
  row "$(L '↩️ Убрать исключение' '↩️ Remove exception')" "cd:$1"; row "$(L '« Назад' '« Back')" list
}
screen_site() {
  d=$(list_get $ETC/sites $1); [ -z "$d" ] && { screen_list; return; }
  scr "🌐 $d

$(L 'Идёт напрямую — ты так решил.' 'Goes direct — your choice.')"; row "$(L '↩️ Убрать исключение' '↩️ Remove exception')" "sd:$1"; row "$(L '« Назад' '« Back')" list
}
screen_vsite() {
  d=$(list_get $ETC/vpn_sites $1); [ -z "$d" ] && { screen_list; return; }
  scr "🔒 $d

$(L 'Идёт через VPN, хотя сайт из своей страны — ты так решил.' 'Goes via VPN, although the site is from your home country — your choice.')"; row "$(L '↩️ Убрать исключение' '↩️ Remove exception')" "vd:$1"; row "$(L '« Назад' '« Back')" list
}
screen_devices() {
  device_list > $W/dev
  [ -s $W/dev ] || { scr "$(L 'Не вижу устройств с VPN. Включи VPN для устройства в Keenetic — и оно появится здесь.' 'I see no devices with VPN. Turn on VPN for a device in Keenetic — and it will appear here.')"; return; }
  f=$(flag)
  if en; then scr "📱 Devices with VPN

$f — home country direct: banks, government and local services open as usual, everything else via VPN.
🔒 — everything via VPN: good for privacy, but some banks and government sites may refuse this device.

Tap a device to switch it."
  else scr "📱 Устройства с VPN

$f — своя страна напрямую: банки, госуслуги, местные сервисы открываются как обычно, остальное через VPN.
🔒 — всё через VPN: удобно для приватности, но некоторые банки и Госуслуги на этом устройстве могут не пустить.

Нажми на устройство, чтобы переключить."; fi
  set --; while read -r m s nm; do [ $s = 1 ] && i=🔒 || i=$f
    set -- "$@" "$i $(printf '%s' "$nm" | cut -c1-18)" "dev:$m"; [ $# -ge 4 ] && { row "$@"; set --; }
  done < $W/dev; [ $# -ge 2 ] && row "$@"
}
box() { if [ "$1" = 1 ]; then printf '✅'; else printf '⬜'; fi; }   # a switch: tap = switch at once
screen_settings() {
  g=0; geo_on && g=1; [ -n "$GEO_FORCE" ] && g=1; dg=$(kv_get digest 1); h=1; [ -f $HINTS_OFF ] && h=0; f=$(flag)
  if en; then scr "⚙️ Settings

✅ — on, tap to turn off · ⬜ — off, tap to turn on
→ — opens its own screen · … — asks first

$f Home country ($(cname)) direct — the main rule. Turn it off — and everything goes via VPN.
☀️ Morning summary — a short report every morning.
💡 Hints — if something from your home country goes via VPN, Razvilka will offer to let it go direct. For that it looks at where devices connected; the history can be erased.
🕰 Connection watchdog — sends an alarm when the router or the VPN goes silent.
↩️ Undo to yesterday — if something stopped opening after changes."
  else scr "⚙️ Настройки

✅ — включено, нажми, чтобы выключить · ⬜ — выключено, нажми, чтобы включить
→ — откроет отдельный экран · … — сначала спрошу

$f Своя страна ($(cname)) напрямую — главное правило. Выключишь — всё пойдёт через VPN.
☀️ Утренняя сводка — короткий отчёт каждое утро.
💡 Подсказки — если что-то из своей страны идёт через VPN, Развилка предложит пустить напрямую. Для этого она смотрит, куда ходили устройства; историю можно стереть.
🕰 Сторож связи — пришлёт тревогу, если роутер или VPN замолчит.
↩️ Вернуть как было вчера — если после изменений что-то перестало открываться."; fi
  q=''; [ $g = 1 ] && q='…'; row "$(box $g) $f $(L 'Своя страна напрямую' 'Home country direct')$q" geo
  row "$(box $dg) ☀️ $(L 'Утренняя сводка' 'Morning summary')" dg
  row "$(box $h) 💡 $(L 'Подсказки' 'Hints')" hint
  if [ -s $HC_URL ]; then hc=$(L 'включён' 'on'); else hc=$(L 'выключен' 'off'); fi
  row "🕰 $(L 'Сторож связи' 'Connection watchdog'): $hc →" hc
  row "$(L '🧹 Стереть историю подсказок…' '🧹 Erase hint history…')" hclr
  row "$(L '↩️ Вернуть как было вчера…' '↩️ Undo to yesterday…')" rb:ask
}
ask() {   # ask "question" "yes label" yes_callback — «Cancel» comes first, so a quick tap does no harm
  scr "$1"; row "$(L '« Отмена' '« Cancel')" set "$2" "$3"
}
screen_hc() {
  if [ -s $HC_URL ]; then
    t=$(kv_get hc_ok 0); [ "$t" = 0 ] && last=$(L 'ещё не было' 'none yet') || last=$(ago $t)
    fl=''; hc_can_fail && fl=$(L ' А если роутер жив, а VPN нет — тревогу сразу пошлю я, напрямую через провайдера.' ' And if the router is alive but the VPN is not, I send the alarm right away, straight through the ISP.')
    pz=''; hc_paused && pz="

$(L "🤫 Идёт тест молчания до $(date -d "@$(kv_get hc_pause)" +%H:%M): тревога от сторожа должна прийти минут через 20." "🤫 A silence test is running until $(date -d "@$(kv_get hc_pause)" +%H:%M): the watchdog alarm should come in about 20 minutes.")"
    if en; then scr "🕰 Connection watchdog is on

Every 5 minutes the router tells the watchdog «I am alive» through the VPN. If the signals stop (VPN down, no power or internet), the watchdog sends you an alarm by itself.$fl

Last signal: $last.$pz"
    else scr "🕰 Сторож связи включён

Каждые 5 минут роутер через VPN говорит сторожу «я жив». Если сигналы пропадут (упал VPN, нет света или интернета) — сторож сам пришлёт тревогу.$fl

Последний сигнал: $last.$pz"; fi
    if hc_paused; then row "$(L '⏹ Прервать тест молчания' '⏹ Stop the silence test')" hcsilx
    else row "$(L '🤫 Тест молчания (30 мин)' '🤫 Silence test (30 min)')" hcsil; fi
    hc_can_fail && row "$(L '🧪 Тест тревоги' '🧪 Test alarm')" hct
    row "$(L '❌ Выключить сторожа…' '❌ Turn watchdog off…')" hcoff; row "$(L '« Назад' '« Back')" set
  else
    if en; then scr "🕰 Connection watchdog — a «dead man’s hand»

When the router loses VPN or power, Telegram at home may go silent too — and there is no one to tell you. The watchdog is an outside service: the router tells it «I am alive» every 5 minutes, and if the signals stop, the watchdog sends you an alarm. It reaches you without VPN.

How to turn it on (5 minutes, free):
1. Go to healthchecks.io and sign up.
2. Press «Add Check»: Period — 5 minutes, Grace — 15 minutes. Notifications — email or Telegram.
3. Copy the link like https://hc-ping.com/… and send it to me like this:
/storozh link
4. Press «🤫 Silence test» and make sure the alarm really comes.

tracker.ru and cronitor.io work too — check with the silence test that the alarm reaches you.

The link is like a key: do not show it to anyone. I will delete your message from the chat right after saving it."
    else scr "🕰 Сторож связи — «мёртвая рука»

Когда у роутера пропадает VPN или свет, Telegram у тебя дома тоже может замолчать — и сказать об этом некому. Сторож — внешний сервис: роутер каждые 5 минут говорит ему «я жив», а если сигналы пропали — сторож сам присылает тревогу. Она доходит и без VPN.

Как включить (5 минут, бесплатно):
1. Зайди на tracker.ru и зарегистрируйся (российский сервис).
2. «Heartbeat» → «Создать»: период — 5 мин, допустимая задержка — 15 мин. Уведомления — почта, MAX или Telegram (MAX и Telegram сначала подключи в «Настройках» сервиса).
3. Скопируй ссылку для пинга (вида https://hb.tracker.ru/ping/…) и пришли мне так:
/storozh ссылка
4. Нажми «🤫 Тест молчания» — убедись, что тревога правда приходит.

Подойдут и healthchecks.io или cronitor.io — проверь тестом молчания, что тревога до тебя доходит.

Ссылка — как ключ: никому её не показывай. Я удалю твоё сообщение из чата сразу после сохранения."; fi
    row "$(L '« Назад' '« Back')" set
  fi
}

# ---------- site ----------
ask_site() { kv_set await site
  if en; then send '🔎 Which site should I check?

Send the address — I will tell where it goes now, and you can change it.' '{"force_reply":true,"input_field_placeholder":"for example, example.com"}'
  else send '🔎 Какой сайт проверить?

Пришли адрес — скажу, куда он идёт сейчас, и можно будет поменять.' '{"force_reply":true,"input_field_placeholder":"например, rustore.ru"}'; fi; }
site_card() {   # domain → card; card data is kept in kv card
  d=$1
  ips=$(dig +short +time=3 +tries=1 A "$d" @77.88.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -4)
  ip=$(echo "$ips" | head -1)
  [ -z "$ip" ] && { send "$(L "Не нашёл сайт $d. Проверь адрес — например, rustore.ru" "Could not find the site $d. Check the address — for example, example.com")" "$MAIN_KB"; return; }
  set -- $(owner $ip); asn=$1; cc=$2; shift 2; holder="$*"; [ "$cc" = - ] && cc=''; [ "$holder" = - ] && holder=''
  kv_set card "$d $asn $holder"; kv_del await
  dco=0; [ -s $R_FILE ] && awk -v IP=$ip "$NET2INT"' BEGIN{x=ip2n(IP)} {rng($1); if(x>=S&&x<=E){f=1; exit}} END{exit !f}' $R_FILE && dco=1
  dgeo=0; ipset test DR_GEO_$GROUP $ip 2>&1 | grep -q 'is in set' && dgeo=1
  ddom=0; ipset test _NDM_OGDN_4_@$GROUP $ip 2>&1 | grep -q 'is in set' && ddom=1
  den=0; { asn_in $DENY $asn || echo "$holder" | grep -qiE "$HOSTING_RE"; } && den=1
  org=$(org_name "$holder" $asn)
  lc=$(echo "$cc" | tr A-Z a-z)
  if [ -z "$cc" ]; then fl='?'; elif known_cc $lc; then fl="$(flag $lc) $(cname $lc)"; else fl="🌍 $cc"; fi
  CC=$(country | tr a-z A-Z)
  scr "🔎 $d
🏢 $org · $fl
"
  if list_has $ETC/vpn_sites $d; then printf '\n%s' "$(L '🔒 Сейчас идёт через VPN — это твоё исключение.' '🔒 Now goes via VPN — this is your exception.')" >> $SCR
    row "$(L '↩️ Убрать исключение' '↩️ Remove exception')" "vd:$(grep -nxF "$d" $ETC/vpn_sites | cut -d: -f1)"
  elif list_has $ETC/sites $d; then printf '\n%s' "$(L '🌐 Сейчас идёт напрямую — это твоё исключение.' '🌐 Now goes direct — this is your exception.')" >> $SCR
    row "$(L '↩️ Убрать исключение' '↩️ Remove exception')" "sd:$(grep -nxF "$d" $ETC/sites | cut -d: -f1)"
  elif [ $dgeo = 1 ] || [ $dco = 1 ] || [ $ddom = 1 ]; then
    if [ $dgeo = 1 ]; then w=$(L 'адрес в своей стране' 'address in your home country'); elif [ $dco = 1 ]; then w=$(L "исключение «$org»" "exception «$org»"); else w=$(L 'сайт в старом списке роутера' 'site in the router’s old list'); fi
    printf '\n%s' "$(L "✅ Сейчас идёт напрямую: $w." "✅ Now goes direct: $w.")" >> $SCR; row "$(L '🔒 Пустить через VPN' '🔒 Send via VPN')" vpn
  else
    if [ $den = 1 ] && [ "$cc" = "$CC" ]; then w=$(L 'сайт на хостинге, где живут и чужие сайты' 'site on a hosting shared with other sites'); elif [ "$cc" != "$CC" ]; then w=$(L 'адрес за рубежом' 'address abroad'); else w=$(L 'адреса нет в карте страны' 'address is not in the country map'); fi
    printf '\n%s' "$(L "🔒 Сейчас идёт через VPN: $w." "🔒 Now goes via VPN: $w.")" >> $SCR; row "$(L '🌐 Пустить напрямую' '🌐 Send direct')" as
  fi
  row "$(L '👌 Понятно' '👌 Got it')" x; scr_send
}

# ---------- handlers ----------
on_message() {
  case "$TEXT" in
    '📊 Статус'|'📊 Status'|/status) kv_del await; screen_status; scr_send ;;
    '🔎 Сайт'|'🔎 Site'|'➕ Сайт'|/site) ask_site ;;
    '📋 Мои исключения'|'📋 My exceptions'|'🛣 Дороги'|/roads|/list) kv_del await; screen_list; scr_send ;;
    '📱 Устройства'|'📱 Devices'|/devices) kv_del await; screen_devices; scr_send ;;
    '⚙️ Настройки'|'⚙️ Settings'|/settings) kv_del await; screen_settings; scr_send ;;
    /storozh|/storozh\ *)
      [ "$MSGID" != 0 ] && del_msg $MSGID                  # do not leave the secret in the chat
      u=$(printf '%s' "${TEXT#/storozh}" | tr -d ' \t' | head -c 220)
      if hc_ok_url "$u"; then ( umask 077; printf '%s' "$u" > $HC_URL ); log 'сторож: ссылка сохранена'
        if hc_ping; then send "$(L '✅ Сторож связи включён: первый сигнал дошёл. Дальше роутер сам будет отмечаться каждые 5 минут.' '✅ Watchdog is on: the first signal got through. From now on the router checks in by itself every 5 minutes.')" "$MAIN_KB"
        else send "$(L '🟡 Ссылку сохранил, но первый сигнал не дошёл. Проверь ссылку и пришли её ещё раз: /storozh ссылка. Если VPN сейчас не работает — сигнал уйдёт сам, когда он оживёт.' '🟡 Link saved, but the first signal did not get through. Check the link and send it again: /storozh link. If the VPN is down right now, the signal will go by itself when it is back.')" "$MAIN_KB"; fi
      else send "$(L 'Не похоже на ссылку сторожа 🤔
Пришли так: /storozh https://hb.tracker.ru/ping/…' 'This does not look like a watchdog link 🤔
Send it like this: /storozh https://hc-ping.com/…')" "$MAIN_KB"; fi ;;
    *) d=$(clean_domain "$TEXT")
       if [ -n "$d" ]; then site_card "$d"
       elif [ "$(kv_get await)" = site ]; then send "$(L 'Не похоже на адрес сайта 🤔
Пришли так: rustore.ru — без лишних слов.' 'This does not look like a site address 🤔
Send it like this: example.com — nothing else.')" "$MAIN_KB"
       elif en; then send '🔀 I am Razvilka — I split your home internet into two roads.

The rule is simple: everything in your home country goes direct, everything else via VPN.

📊 Status — is everything OK
🔎 Site — where a site goes, and change it
📱 Devices — which rule for whom
⚙️ Settings — country, summary, hints, connection watchdog, undo

If something breaks, I will write to you myself.' "$MAIN_KB"
       else send '🔀 Я Развилка — делю домашний интернет на две дороги.

Правило простое: всё в своей стране — напрямую, остальное — через VPN.

📊 Статус — всё ли в порядке
🔎 Сайт — куда идёт сайт, и поменять
📱 Устройства — кому какое правило
⚙️ Настройки — страна, сводка, подсказки, сторож связи, откат

Если что-то сломается — я напишу сама.' "$MAIN_KB"; fi ;;
  esac
}
act() { $APP/rzv-act.sh "$@"; }   # heavy actions run as a separate process (with the lock)
on_callback() {
  s=${DATA#*:}; WAIT=$(L 'Минутку…' 'One moment…')
  case "$DATA" in
    st)  toast "$CQ" "$(L 'Проверяю…' 'Checking…')"; screen_status; scr_edit $MID ;;
    det) toast "$CQ" "$(L 'Проверяю…' 'Checking…')"; screen_status det; scr_edit $MID ;;
    list|roads) toast "$CQ"; screen_list; scr_edit $MID ;;
    set) toast "$CQ"; screen_settings; scr_edit $MID ;;
    add) toast "$CQ"; ask_site ;;
    g:*)  is_num "$s" && { toast "$CQ"; screen_service $s; scr_edit $MID; } ;;
    c:*)  is_num "$s" && { toast "$CQ"; screen_company $s; scr_edit $MID; } ;;
    s:*)  is_num "$s" && { toast "$CQ"; screen_site $s; scr_edit $MID; } ;;
    v:*)  is_num "$s" && { toast "$CQ"; screen_vsite $s; scr_edit $MID; } ;;
    gd:*) is_num "$s" && { toast "$CQ" "$WAIT"; act service_del $s $MID & } ;;
    cd:*) is_num "$s" && { toast "$CQ" "$WAIT"; act company_del $s $MID & } ;;
    sd:*) is_num "$s" && { toast "$CQ" "$WAIT"; act site_del $s $MID & } ;;
    vd:*) is_num "$s" && { toast "$CQ" "$(L 'Минутку — пересобираю карту страны…' 'One moment — rebuilding the country map…')"; act vsite_del $s $MID & } ;;
    as|ac|vpn)
      c=$(kv_get card); [ -z "$c" ] && { toast "$CQ" "$(L 'Устарело — пришли адрес ещё раз' 'Outdated — send the address again')"; return; }
      [ $DATA = vpn ] && toast "$CQ" "$(L 'Минутку — около полутора минут…' 'One moment — about a minute and a half…')" || toast "$CQ" "$WAIT"
      act card_$DATA $MID & ;;
    x) kv_del card; kv_del await; toast "$CQ" "$(L 'Хорошо' 'OK')"; edit $MID "${MTEXT:-$(L 'Хорошо.' 'OK.')}" ;;
    dev:*) is_mac "$s" && { toast "$CQ" "$(L 'Переключаю…' 'Switching…')"; act device $s $MID & } ;;
    dg) if [ "$(kv_get digest 1)" = 1 ]; then kv_set digest 0; toast "$CQ" "$(L 'Сводка выключена' 'Summary off')"; else kv_set digest 1; toast "$CQ" "$(L 'Сводка включена' 'Summary on')"; fi
        screen_settings; scr_edit $MID ;;
    hint) [ -f $HINTS_OFF ] && rm -f $HINTS_OFF || : > $HINTS_OFF; toast "$CQ" "$(L 'Готово' 'Done')"; screen_settings; scr_edit $MID ;;
    hclr) toast "$CQ"; ask "$(L '🧹 Стереть историю подсказок?

Развилка забудет, куда ходили устройства, и какие подсказки уже показывала. Твои исключения и настройки не изменятся. Вернуть историю нельзя.' '🧹 Erase the hint history?

Razvilka will forget where devices connected and which hints it already showed. Your exceptions and settings will not change. The history cannot be brought back.')" "$(L '🧹 Стереть' '🧹 Erase')" hclr:yes; scr_edit $MID ;;
    hclr:yes) : > $CACHE_IP; : > $HINTED; log 'история подсказок стёрта'; toast "$CQ" "$(L 'История стёрта' 'History erased')"
          screen_settings; scr_edit $MID "$(L '🧹 История подсказок стёрта.' '🧹 Hint history erased.')

" ;;
    geo|geo:on) if [ "$DATA" = geo ] && geo_on; then toast "$CQ"; ask "$(L "$(flag) Выключить «Своя страна напрямую»?

Сайты своей страны (банки, госуслуги, местные сервисы) пойдут через VPN — некоторые из них могут не пустить. Включить обратно можно здесь же, сборка займёт около двух минут." "$(flag) Turn off «Home country direct»?

Sites of your home country (banks, government, local services) will go via VPN — some of them may refuse. You can turn it back on here, the build takes about two minutes.")" "$(L 'Выключить' 'Turn off')" geo:off; scr_edit $MID
         else toast "$CQ" "$(L 'Включаю…' 'Turning on…')"; act geo $MID on & fi ;;
    geo:off) toast "$CQ" "$(L 'Выключаю…' 'Turning off…')"; act geo $MID off & ;;
    lite) toast "$CQ" "$(L 'Включаю…' 'Turning on…')"; act lite $MID & ;;
    rb:ask) toast "$CQ"; scr "$(L '↩️ Вернуть карту страны и сети исключений такими, какими они были до последнего обновления?

Устройства и твои сайты не изменятся.' '↩️ Bring the country map and exception networks back to how they were before the last update?

Devices and your sites will not change.')"; row "$(L '↩️ Вернуть как было' '↩️ Undo')" rb:yes "$(L 'Оставить' 'Keep')" set; scr_edit $MID ;;
    rb:yes) toast "$CQ" "$(L 'Возвращаю…' 'Undoing…')"; act rollback $MID & ;;
    hc) toast "$CQ"; screen_hc; scr_edit $MID ;;
    hct) if hc_ping /fail; then toast "$CQ" "$(L 'Отправил' 'Sent')"; screen_hc; scr_edit $MID "$(L '🧪 Отправил сторожу «тревога». Сейчас придёт тревога, а через 5 минут — «снова в порядке».' '🧪 Sent «alarm» to the watchdog. An alarm will come now, and in 5 minutes — «back to normal».')

"; else toast "$CQ" "$(L 'Сторож не ответил' 'Watchdog did not answer')"; fi ;;
    hcsil) [ -s $HC_URL ] || { toast "$CQ" "$(L 'Сторож связи выключен' 'Watchdog is off')"; screen_hc; scr_edit $MID; return; }
      kv_set hc_pause $(( $(now) + 1800 )); log 'сторож: тест молчания на 30 мин'; toast "$CQ" "$(L 'Тест начался' 'Test started')"; screen_hc
      scr_edit $MID "$(L '🤫 Тест молчания начался: 30 минут роутер не подаёт сторожу сигналов. Минут через 20 сторож должен прислать тревогу. Потом сигналы вернутся сами, и я спрошу, пришла ли она.' '🤫 The silence test has started: for 30 minutes the router sends no signals to the watchdog. In about 20 minutes the watchdog should send you an alarm. Then the signals come back by themselves and I will ask whether it came.')

" ;;
    hcsilx) kv_del hc_pause; hc_ping; log 'сторож: тест молчания прерван'; toast "$CQ" "$(L 'Тест прерван' 'Test stopped')"; screen_hc; scr_edit $MID ;;
    hcoff) toast "$CQ"; ask "$(L '🕰 Выключить сторожа связи?

Роутер перестанет подавать сигналы. Удали или поставь на паузу проверку у самого сервиса-сторожа — иначе минут через 20 он пришлёт тревогу.' '🕰 Turn the connection watchdog off?

The router will stop sending signals. Delete or pause the check at the watchdog service itself — otherwise it will send an alarm in about 20 minutes.')" "$(L '❌ Выключить' '❌ Turn off')" hcoff:yes; scr_edit $MID ;;
    hcoff:yes) rm -f $HC_URL; kv_del hc_ok; kv_del hc_pause; log 'сторож выключен'; toast "$CQ" "$(L 'Сторож связи выключен' 'Watchdog off')"
      screen_settings; scr_edit $MID "$(L '❌ Сторож связи выключен. Не забудь удалить или поставить на паузу проверку у сервиса-сторожа.' '❌ The connection watchdog is off. Remember to delete or pause the check at your watchdog service.')

" ;;
    add:*|skip:*) is_num "$s" && { toast "$CQ" "$(L 'Принято' 'Got it')"; act hint_${DATA%%:*} $s $MID & } ;;
    del|del:*) toast "$CQ" "$(L 'Открой 📋 Мои исключения — там новые кнопки' 'Open 📋 My exceptions — the new buttons are there')" ;;
    *) toast "$CQ" ;;
  esac
}

# ---------- once on first start (and when the language changes) ----------
setup_once() {
  [ "$(kv_get menu)" = "6$BOTLANG" ] && return
  f=$TMP/m.json
  if en; then
  echo '{"commands":[{"command":"start","description":"🏠 Start — buttons and what Razvilka can do"},{"command":"status","description":"📊 Status — is everything OK"},{"command":"site","description":"🔎 Site — where it goes, and change it"},{"command":"devices","description":"📱 Devices — which rule for whom"},{"command":"settings","description":"⚙️ Settings — country, summary, hints, watchdog, undo"},{"command":"list","description":"📋 My exceptions — what you changed on top of the rule"}]}' > $f
  else
  echo '{"commands":[{"command":"start","description":"🏠 Начало — кнопки и что умеет Развилка"},{"command":"status","description":"📊 Статус — всё ли в порядке"},{"command":"site","description":"🔎 Сайт — куда идёт, и поменять"},{"command":"devices","description":"📱 Устройства — кому какое правило"},{"command":"settings","description":"⚙️ Настройки — страна, сводка, подсказки, сторож, откат"},{"command":"list","description":"📋 Мои исключения — что поменял поверх правила"}]}' > $f
  fi
  tg setMyCommands $f >/dev/null; echo '{"menu_button":{"type":"commands"}}' > $f; tg setChatMenuButton $f >/dev/null; rm -f $f
  kv_set menu "6$BOTLANG"
}

# ---------- main loop (only "rzv-bot.sh run"; rzv-act.sh sources this file for the screens) ----------
[ "$1" = run ] || return 0
[ -n "$TELEGRAM_BOT_TOKEN" ] && [ "$ADMIN" != 0 ] || { log 'нет tg.env — бот не запущен'; exit 1; }
log "бот запущен (pid $$, язык $BOTLANG)"; setup_once
for x in $TMP/w.* $TMP/k.*; do case "$x" in "$W"|*"*") ;; *) rm -rf "$x";; esac; done   # leftovers of previous runs (k.* holds the URL with the token)
U=$TMP/upd.json; Q=$TMP/q.json
while :; do
  if [ "$(mem_kb)" -lt 8000 ]; then sleep 30; continue; fi     # the router is very short on memory — wait, do not make it worse
  jq -n -c --argjson o "$(kv_get offset 0)" '{offset:$o, timeout:25, allowed_updates:["message","callback_query"]}' > $Q
  if ! tg getUpdates $Q 40 > $U || ! grep -q '"ok":true' $U; then sleep 20; continue; fi
  jq -c '.result[]' $U 2>/dev/null > $TMP/ups
  while read -r u; do
    printf '%s' "$u" > $TMP/u1.json
    eval "$(jq -r '@sh "UPD=\(.update_id) FROM=\(.message.from.id // .callback_query.from.id // 0) CQ=\(.callback_query.id // "") DATA=\(.callback_query.data // "") MID=\(.callback_query.message.message_id // 0) MSGID=\(.message.message_id // 0) MTEXT=\(.callback_query.message.text // "") TEXT=\(.message.text // "")"' $TMP/u1.json)"
    kv_set offset $((UPD+1))
    [ "$FROM" = "$ADMIN" ] || continue                       # owner only; silence for everyone else
    if [ -n "$CQ" ]; then on_callback; else on_message; fi
  done < $TMP/ups
done
