#!/bin/sh
# Razvilka — installer for Keenetic (Entware). v0.8
# Razvilka — installer for Keenetic routers (Entware).
#
#   sh razvilka-install.sh               — install or update
#   sh razvilka-install.sh --demo        — DRY RUN: real checks, but changes NOTHING
#   sh razvilka-install.sh --root=DIR    — TEST INTO A FOLDER: files go to DIR, firmware commands are only printed
#   sh razvilka-install.sh --uninstall   — remove and restore everything
#   flags: --lang=ru|en  --yes
#
# Next to the installer — the razvilka-files/ folder (core, bot, data).
# Rules: 1) look first; 2) do not touch what is not ours; 3) before changes — a settings backup and a list of what was done
# (manifest) for rollback; 4) after install check the VPN — no answer → roll everything back; 5) show the plan, ask "yes".
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
VERSION=0.8
HERE=$(cd "$(dirname "$0")" && pwd); FILES=$HERE/razvilka-files
TS=$(date +%Y%m%d_%H%M%S 2>/dev/null)
DEMO=0; YES=0; LNG=""; MODE=install; R=""
for a in "$@"; do case "$a" in
  --demo) DEMO=1;; --yes) YES=1;; --uninstall) MODE=uninstall;;
  --root=*) R=${a#--root=}; R=${R%/};; --lang=*) LNG=${a#--lang=};; ru|en) LNG=$a;;
esac; done
APP=/opt/share/razvilka; ETC=/opt/etc/razvilka; MAN=$ETC/manifest; GROUP=rudirect

# ---------- output ----------
L() { if [ "$LNG" = en ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
line() { echo "────────────────────────────────────────────"; }
head1() { echo; line; echo " $1"; line; }
okm() { echo "  ✅ $1"; }
wrn() { echo "  🟡 $1"; }
bad() { echo "  ⛔ $1"; BLOCK=1; }
yes_word() { L да yes; }
ask() {  # ask "question" "default" → $ANS
  if [ $YES = 1 ]; then ANS=$2; echo "  ❓ $1 [$2] → $2"; return; fi
  printf '  ❓ %s [%s]: ' "$1" "$2"; read -r ANS; [ -n "$ANS" ] || ANS=$2
}
is_yes() { case "$1" in да|Да|ДА|д|Д|y|Y|yes|Yes|YES) return 0;; esac; return 1; }
# system change: in a test into a folder — only print
sys() { if [ -n "$R" ]; then echo "     [проба] $*"; else sh -c "$*"; fi; }
note() { mkdir -p "$R$ETC"; echo "$*" >> "$R$MAN"; }    # manifest: what was done (for rollback)

# ---------- language ----------
if [ -z "$LNG" ]; then
  if [ $YES = 1 ]; then LNG=ru; else
    echo "Язык / Language:  1) Русский   2) English"; printf '> '; read -r x
    case "$x" in 2|en|EN) LNG=en;; *) LNG=ru;; esac
  fi
fi
case "$LNG" in ru|en) ;; *) LNG=en;; esac

# ================= UNINSTALL =================
if [ $MODE = uninstall ]; then
  head1 "🔀 $(L 'Развилка — удаление' 'Razvilka — removal') v$VERSION"
  [ -s "$R$MAN" ] || { echo "  $(L 'Развилка не установлена этим установщиком (нет списка сделанного).' 'Razvilka was not installed by this installer (no manifest).')"; exit 0; }
  echo "  $(L 'Верну всё по списку сделанного:' 'I will undo everything from the manifest:') $R$MAN"
  ask "$(L 'Удаляем? (да/нет)' 'Remove? (yes/no)')" "$([ $YES = 1 ] && yes_word || L нет no)"; is_yes "$ANS" || { echo "  $(L 'Хорошо, ничего не меняю.' 'OK, nothing changed.')"; exit 0; }
  [ -x "$R/opt/etc/init.d/S99razvilka" ] && sys "/opt/etc/init.d/S99razvilka stop"
  sed -i '/# razvilka:guard$/d' "$R/opt/etc/crontab" 2>/dev/null; rm -f "$R/opt/etc/ndm/netfilter.d/57-razvilka-fuse.sh"   # nothing may put the fuse back
  [ -x "$R$APP/rzv-act.sh" ] && sys "$APP/rzv-act.sh fuse_off >/dev/null 2>&1"   # take the DNS fuse off if it is on
  # walk the list from the end
  awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' "$R$MAN" | while read -r kind a b c; do case "$kind" in
    file)  case "$a" in "$ETC"/*) continue;; esac                            # settings — decided by the question below
           rm -f "$R$a"; echo "  🗑 $a";;                                     # new file — delete
    repl)  cp -p "$R$b" "$R$a" && echo "  ↩️ $a";;                            # replaced file — restore the copy
    cron)  sed -i "/# razvilka:$a\$/d" "$R/opt/etc/crontab" && echo "  ⏰ cron: $a";;
    ndm)   case "$a" in group) sys "ndmc -c 'no dns-proxy route object-group $GROUP $b'"; sys "ndmc -c 'no object-group fqdn $GROUP'";;
           esac; sys "ndmc -c 'system configuration save'"; echo "  ⚙️ $(L 'настройки прошивки: группа' 'firmware: group') $GROUP";;
    routes) sys "$b off";;
  esac; done
  ask "$(L 'Удалить и настройки Развилки (токен, списки)? (да/нет)' 'Also delete Razvilka settings (token, lists)? (yes/no)')" "$(L нет no)"
  is_yes "$ANS" && { rm -rf "$R$ETC"; echo "  🗑 $ETC"; } || { mv "$R$MAN" "$R$MAN.removed_$TS"; echo "  $(L 'Настройки оставил в' 'Settings kept in') $ETC"; }
  echo; okm "$(L 'Готово. Развилка удалена.' 'Done. Razvilka removed.')"; exit 0
fi

head1 "🔀 $(L 'Развилка — установка' 'Razvilka — setup') v$VERSION"
# ---------- what is Razvilka ----------
if [ $LNG = ru ]; then cat <<'EOF'
  Развилка делит интернет на роутере на две дороги:
    • сайты и сервисы своей страны — напрямую, через провайдера
      (быстро; банки, госуслуги и местные сервисы не ругаются на VPN);
    • всё остальное — через ваш TrustTunnel.
  Роутер сам собирает карту сетей страны и обновляет её каждую ночь.
  Управление — из вашего личного Telegram-бота:
    🔎 прислали адрес сайта — бот скажет, куда он идёт, и поменяет одной кнопкой;
    📱 у каждого устройства своё правило; 💡 подскажет, если что-то своё шло через VPN;
    ☀️ утренняя сводка, 🕰 тревога, если пропал VPN или свет;
    🛠 VPN завис — роутер сам его перезапустит и не даст себе зависнуть.

  Бот живёт прямо на роутере — без серверов и облаков. Берёт около 1 МБ на флешке
  и около 8 МБ оперативной памяти; процессор почти не трогает (короткая проверка
  раз в минуту, сборка карты страны — ночью, около 1–2 минут).

  Что понадобится: работающий TrustTunnel из этого проекта (режим TUN) и свой
  бот (@BotFather → /newbot).
  Сначала я всё проверю и покажу план — без вашего «да» ничего не меняю.
  Хотите просто посмотреть? Запустите с --demo: проверка и план, без изменений.
  Удалить потом: sh razvilka-install.sh --uninstall. Это бета: о проблемах пишите
  в Issues на GitHub (alex-combine/TrustTunnel-Keenetic-Native).
EOF
else cat <<'EOF'
  Razvilka splits the internet on your router into two roads:
    • sites and services of your own country — direct, through your ISP
      (fast; local banks, government and other services do not complain about a VPN);
    • everything else — through your TrustTunnel.
  The router builds the map of your country's networks itself and refreshes it every night.
  You control it from your own Telegram bot:
    🔎 send a site address — the bot tells where it goes and switches it with one tap;
    📱 a rule per device; 💡 a hint when something local went via VPN;
    ☀️ a morning summary, 🕰 an alarm when the VPN or power is gone;
    🛠 the VPN hangs — the router restarts it by itself and does not hang itself.

  The bot lives on the router itself — no servers, no cloud. It takes about 1 MB on the
  USB stick and about 8 MB of RAM; the CPU stays almost idle (a short check once a minute,
  the country map is built at night in about 1–2 minutes).

  You will need: a working TrustTunnel from this project (TUN mode) and your own
  bot (@BotFather → /newbot).
  First I check everything and show the plan — nothing changes without your "yes".
  Just want a look? Run with --demo: checks and the plan, no changes.
  To remove later: sh razvilka-install.sh --uninstall. This is a beta: please report problems
  in Issues on GitHub (alex-combine/TrustTunnel-Keenetic-Native).
EOF
fi
[ $DEMO = 1 ] && echo "  🧪 $(L 'ПРОБА: смотрю и показываю, но ничего не меняю' 'DRY RUN: I look and show, but change nothing')"
[ -n "$R" ] && echo "  🧪 $(L 'ПРОБА В ПАПКУ' 'TEST INTO FOLDER'): $R — $(L 'команды прошивки только печатаю' 'firmware commands are only printed')"


# ---------- step 1: router ----------
head1 "$(L 'Шаг 1. Смотрю, что за роутер' 'Step 1. Looking at the router')"
BLOCK=0
MODEL=$(ndmc -c 'show version' 2>/dev/null | awk -F': ' '/ model:/{print $2; exit}')
REL=$(ndmc -c 'show version' 2>/dev/null | awk -F': ' '/ release:/{print $2; exit}')
[ -n "$MODEL" ] && okm "$(L Модель Model): $MODEL, KeeneticOS $REL ($(uname -m))" || bad "$(L 'Это не Keenetic' 'Not a Keenetic')"
MEMT=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo); MEMA=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
if [ "$MEMT" -lt 100 ]; then bad "$(L 'Память' 'Memory'): $MEMT $(L МБ MB) — $(L 'боту Развилки нужно от 128 МБ' 'the Razvilka bot needs 128 MB or more')"
elif [ "$MEMA" -lt 12 ]; then wrn "$(L 'Память' 'Memory'): $MEMT $(L МБ MB), $(L 'свободно' 'free') $MEMA $(L МБ MB) — $(L 'тесно; бот будет ждать, если памяти не хватит' 'tight; the bot will wait when memory is low')"
else okm "$(L 'Память' 'Memory'): $MEMT $(L МБ MB), $(L 'свободно' 'free') $MEMA $(L МБ MB)"; fi
[ "$MEMT" -lt 200 ] && LITE_DEF=1 || LITE_DEF=0
[ -x /opt/bin/opkg ] && okm "Entware" || bad "Entware: —"
FREE=$(df -m /opt 2>/dev/null | awk 'NR==2{print $4}')
[ "${FREE:-0}" -ge 20 ] && okm "$(L 'Свободно на флешке' 'Free on USB'): ${FREE} $(L МБ MB)" || bad "$(L 'Свободно на флешке' 'Free on USB'): ${FREE:-?} $(L МБ MB) (< 20)"
# ISP: default route (Linux name) and its firmware name
WAN=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
WAN_NDM=$(ndmc -c 'show ip route' 2>/dev/null | awk '$1=="0.0.0.0/0"{print $3; exit}')
LANIP=$(ip -4 addr show br0 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')
[ -n "$WAN" ] && okm "$(L 'Провайдер' 'Internet uplink'): $WAN ($WAN_NDM), $(L 'роутер' 'router') $LANIP" || bad "$(L 'Не нашёл выход в интернет напрямую' 'No direct internet uplink found')"
# VPN: TrustTunnel from this project in TUN mode (the only setup Razvilka is tested with)
VPNIF=""; TTC=/opt/trusttunnel_client/mode.conf
TTM=$(sed -n 's/^TT_MODE="\{0,1\}\([a-z0-9]*\).*/\1/p' $TTC 2>/dev/null | tail -1)
TTI=$(sed -n 's/^TUN_IDX="\{0,1\}\([0-9]*\).*/\1/p' $TTC 2>/dev/null | tail -1)
if [ ! -x /opt/etc/init.d/S99trusttunnel ] || [ -z "$TTM" ]; then
  bad "TrustTunnel: $(L 'не нашёл — Развилка работает с TrustTunnel из этого проекта (install.sh, режим TUN)' 'not found — Razvilka works with TrustTunnel from this project (install.sh, TUN mode)')"
elif [ "$TTM" != tun ]; then
  bad "TrustTunnel: $(L 'режим SOCKS5 — Развилке нужен режим TUN (запустите install.sh ещё раз и выберите 2)' 'SOCKS5 mode — Razvilka needs TUN mode (run install.sh again and choose 2)')"
else
  i=opkgtun${TTI:-0}
  c=$(curl -s -o /dev/null -w '%{http_code}' --interface $i --max-time 6 http://connectivitycheck.gstatic.com/generate_204 2>/dev/null)
  if [ "$c" = 204 ]; then VPNIF=$i; okm "TrustTunnel: $i"
  else bad "TrustTunnel ($i): $(L 'интернет через него не идёт — сначала добейтесь, чтобы VPN работал' 'no internet through it — get the VPN working first')"; fi
fi
# programs
NEED=""; for p in curl:curl jq:jq idn:idn dig:bind-dig ipset:ipset; do command -v ${p%%:*} >/dev/null 2>&1 || NEED="$NEED ${p#*:}"; done
[ -z "$NEED" ] && okm "$(L 'Программы на месте' 'Programs present'): curl jq idn dig ipset" || wrn "$(L 'Поставлю программы' 'Will install'):$NEED"

# ---------- step 2: what is already installed ----------
head1 "$(L 'Шаг 2. Ищу, что у вас уже стоит' 'Step 2. Looking for what you already have')"
SELF=0; [ -f "$R$ETC/net.conf" ] || [ -f "$R$APP/rzv-bot.sh" ] && SELF=1
CORE=$APP/core; [ -f "$R$ETC/net.conf" ] && { c=$(sed -n 's/^CORE=\([^ #]*\).*/\1/p' "$R$ETC/net.conf"); [ -n "$c" ] && CORE=$c; }
[ $SELF = 1 ] && wrn "$(L 'Развилка уже стоит — обновлю файлы, ваши настройки и токен не трону' 'Razvilka is already installed — I will update files and keep your settings and token')" \
              || okm "$(L 'Развилки нет — поставлю с нуля' 'No Razvilka — fresh install')"
FOUND=0
for p in /opt/etc/xkeen:XKeen /opt/apps/kvas:Kvas /opt/etc/hydraroute:HydraRoute /opt/etc/bypass_keenetic:bypass_keenetic; do
  [ -e "${p%%:*}" ] && { FOUND=1; wrn "${p#*:} — $(L 'тоже направляет трафик; может спорить с Развилкой' 'also routes traffic; may conflict with Razvilka')"; }
done
for p in /opt/etc/AdGuardHome:AdGuardHome /opt/etc/smartdns:smartdns /opt/etc/xray:Xray /opt/etc/sing-box:sing-box; do
  [ -e "${p%%:*}" ] && { FOUND=1; okm "${p#*:} — $(L 'не трогаю, встаю рядом' 'untouched, I sit next to it')"; }
done
GRP_EXISTS=0; [ -z "$R" ] && ndmc -c 'show running-config' 2>/dev/null | grep -q "^object-group fqdn $GROUP\$" && GRP_EXISTS=1
[ $GRP_EXISTS = 1 ] && okm "$(L 'Группа сайтов' 'Site group') $GROUP $(L 'уже есть в прошивке' 'already exists in firmware')"
USED_T=$(ip rule 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="lookup") print $(i+1)}' | sort -u | tr '\n' ' ')
TABLE=$(sed -n "s/^$GROUP[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p" "$R/opt/etc/direct-routes.conf" 2>/dev/null | head -1)
[ -z "$TABLE" ] && { TABLE=1998; while echo " $USED_T " | grep -q " $TABLE "; do TABLE=$((TABLE+1)); done; }
[ $FOUND = 0 ] && okm "$(L 'Ничего постороннего не нашёл' 'Nothing else found')"

# ---------- step 3: choices ----------
head1 "$(L 'Шаг 3. Ваш выбор' 'Step 3. Your choices')"
DEFC=$([ $LNG = ru ] && echo ru || echo "")
[ -f "$R/opt/etc/direct-routes.geo.conf" ] && DEFC=$(sed -n 's/^COUNTRY=//p' "$R/opt/etc/direct-routes.geo.conf" | tr -d '"' | tail -1)
echo "  ru 🇷🇺  by 🇧🇾  kz 🇰🇿  uz 🇺🇿  cn 🇨🇳  ir 🇮🇷  tr 🇹🇷  ae 🇦🇪  … ($(L 'код страны' 'country code'))"
ask "$(L 'Ваша страна (её сайты пойдут напрямую)' 'Your country (its sites will go direct)')" "${DEFC:-ru}"; COUNTRY=$(echo "$ANS" | tr A-Z a-z)
case "$COUNTRY" in [a-z][a-z]) ;; *) bad "$(L 'Код страны — две латинские буквы' 'Country code — two latin letters')";; esac
# split DNS (country profile DNS_SPLIT=1, now cn) — needs smartdns from Entware
if [ -f "$FILES/core/geo-profiles.sh" ] && ( . "$FILES/core/geo-profiles.sh"; profile $COUNTRY >/dev/null 2>&1; [ "$DNS_SPLIT" = 1 ] ); then
  command -v smartdns >/dev/null 2>&1 || [ -x "$CORE/smartdns-geo/smartdns" ] || { NEED="$NEED smartdns"; wrn "$(L 'Для страны' 'For country') $COUNTRY $(L 'нужен раздельный DNS — поставлю smartdns' 'split DNS is needed — will install smartdns')"; }
fi
LITE=0
if [ $SELF = 0 ]; then   # on update the map is not touched — it is already set up
  echo "  $(L 'Для умеренных роутеров (до 256 МБ) советую лёгкую карту: только крупные блоки страны.' 'For modest routers (up to 256 MB) I suggest the light map: only large country blocks.')"
  ask "$(L 'Лёгкая карта? (да/нет)' 'Light map? (yes/no)')" "$([ $LITE_DEF = 1 ] && yes_word || L нет no)"; is_yes "$ANS" && LITE=1
fi
TOKEN=""; ADMIN=""
if [ $SELF = 1 ] && [ -s "$R$ETC/tg.env" ]; then okm "$(L 'Токен бота уже есть — оставляю' 'Bot token already set — keeping it')"
elif [ $DEMO = 1 ] || [ $YES = 1 ]; then echo "  ❓ $(L 'Токен бота от @BotFather' 'Bot token from @BotFather'): ($(L 'пропущено в пробе' 'skipped in dry run'))"
else
  echo "  $(L 'Создайте своего бота: в Telegram откройте @BotFather → /newbot → получите токен.' 'Create your bot: in Telegram open @BotFather → /newbot → get the token.')"
  printf '  ❓ %s: ' "$(L 'Токен бота (ввод скрыт)' 'Bot token (hidden)')"; stty -echo 2>/dev/null; read -r TOKEN; stty echo 2>/dev/null; echo
  if ! printf '%s' "$TOKEN" | grep -qE '^[0-9]{5,12}:[A-Za-z0-9_-]{30,50}$'; then bad "$(L 'Не похоже на токен бота' 'Does not look like a bot token')"
  elif [ -n "$VPNIF" ]; then
    # owner ID: the person sends /start to their bot, the installer catches it through the VPN
    K=/tmp/razvilka-k.$$; ( umask 077; printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$TOKEN" > $K )
    BN=$(curl -s --interface $VPNIF --max-time 20 -K $K | jq -r '.result.username // empty' 2>/dev/null)
    if [ -z "$BN" ]; then bad "$(L 'Telegram не принял токен (или нет jq — поставьте и повторите)' 'Telegram rejected the token (or jq missing — install it and retry)')"
    else okm "$(L 'Бот' 'Bot'): @$BN"
      echo "  👉 $(L "Откройте в Telegram @$BN и нажмите «Старт» (жду до 2 минут)…" "Open @$BN in Telegram and press Start (waiting up to 2 minutes)…")"
      ( umask 077; printf 'url = "https://api.telegram.org/bot%s/getUpdates?timeout=25"\n' "$TOKEN" > $K )
      for n in 1 2 3 4; do
        ADMIN=$(curl -s --interface $VPNIF --max-time 35 -K $K | jq -r '[.result[] | .message.from | select(.is_bot == false)] | last | .id // empty' 2>/dev/null)
        [ -n "$ADMIN" ] && break
      done
      [ -n "$ADMIN" ] && okm "$(L 'Хозяин бота найден' 'Bot owner found') (ID $ADMIN)" || bad "$(L 'Не дождался «Старт» в боте' 'No Start received in the bot')"
    fi; rm -f $K
  fi
fi

# ---------- step 4: plan ----------
head1 "$(L 'Шаг 4. План — что именно изменится' 'Step 4. The plan — exactly what will change')"
BK=/opt/backup/razvilka_$TS
echo "  💾 $(L 'Копия настроек роутера и файлов' 'Backup of router settings and files'): $BK"
[ -n "$NEED" ] && echo "  📦 $(L 'Программы' 'Packages'):$NEED"
echo "  📁 $(L 'Файлы' 'Files'): $CORE ($(L 'ядро' 'core')), $APP ($(L 'бот' 'bot')), $ETC ($(L 'настройки' 'settings'))"
echo "  ⚙️ $(L 'Служба' 'Service'): /opt/etc/init.d/S99razvilka"
[ $SELF = 0 ] && echo "  🗺 net.conf: WAN=$WAN TUN=$VPNIF LANIP=$LANIP; $(L 'страна' 'country') $COUNTRY$([ $LITE = 1 ] && echo ", $(L 'лёгкая карта' 'light map')")"
[ $SELF = 0 ] && echo "  🛣 $(L 'Своя таблица маршрутов' 'Own routing table') №$TABLE, $(L 'устройства с VPN-политикой' 'devices with a VPN policy') (@policy)"
[ $GRP_EXISTS = 0 ] && echo "  🔧 $(L 'Прошивка: группа сайтов' 'Firmware: site group') $GROUP + DNS-$(L 'маршрут через' 'route via') $WAN_NDM"
echo "  ⏰ $(L 'Расписание (cron), строки с пометкой «# razvilka»' 'Cron lines marked «# razvilka»')"
echo "  🙅 $(L 'Не трону: чужие правила, ваши настройки DNS, другие программы' 'Won'"'"'t touch: other rules, your DNS settings, other programs')"
echo "  ↩️  $(L 'Вернуть всё как было' 'Undo everything'): sh $0 --uninstall"
[ -d "$FILES/core" ] && [ -d "$FILES/bot" ] || bad "$(L 'Рядом с установщиком нет папки razvilka-files' 'razvilka-files folder not found next to the installer')"
if [ "$BLOCK" = 1 ]; then echo; echo "  ⛔ $(L 'Установку остановил: сначала нужно исправить пункты ⛔ выше.' 'Stopped: please fix the ⛔ items above first.')"; [ $DEMO = 1 ] && exit 0; exit 1; fi
if [ $DEMO = 1 ]; then echo; echo "  🧪 $(L 'Проба закончена. Ничего не изменено.' 'Dry run finished. Nothing was changed.')"; exit 0; fi
ask "$(L 'Начинаем? (да/нет)' 'Proceed? (yes/no)')" "$([ $YES = 1 ] && yes_word || L нет no)"
is_yes "$ANS" || { echo "  $(L 'Хорошо, ничего не меняю.' 'OK, nothing changed.')"; exit 0; }

# ---------- step 5: install ----------
head1 "$(L 'Шаг 5. Установка' 'Step 5. Installing')"
mkdir -p "$R$BK" "$R$ETC" "$R$APP" "$R$CORE" "$R/opt/etc/init.d" "$R/opt/var/log"; chmod 700 "$R$ETC"
echo "# Развилка: что сделал установщик $TS (для отката: sh razvilka-install.sh --uninstall)" >> "$R$MAN"
ndmc -c 'show running-config' > "$R$BK/running-config.txt" 2>/dev/null; cp -p /opt/etc/crontab "$R$BK/crontab" 2>/dev/null
okm "$(L 'Копия настроек' 'Settings backup'): $BK"

# 5.1 programs: the usual way, and if that fails — download through the VPN (the repository is unreachable from some countries)
pkg_install() {
  [ -n "$R" ] && { sys "opkg install $*"; return 0; }
  opkg update >/dev/null 2>&1; opkg install $* >/dev/null 2>&1
  for p in $*; do opkg list-installed | grep -q "^$p " || return 1; done
}
pkg_via_vpn() {   # download packages and all missing dependencies through the VPN, install from files
  D=/opt/tmp/razvilka-pkg; rm -rf $D; mkdir -p $D/lists; SRC=$(awk '$1=="src/gz"{print $3; exit}' /opt/etc/opkg.conf)
  curl -s --interface $VPNIF --max-time 90 "$SRC/Packages.gz" | gunzip > $D/Packages 2>/dev/null; [ -s $D/Packages ] || return 1
  orig="$*"; want="$*"; got=""
  while [ -n "$want" ]; do set -- $want; p=$1; shift; want="$*"
    echo " $got " | grep -q " $p " && continue; opkg list-installed | grep -q "^$p " && continue
    got="$got $p"
    want="$want $(awk -v p=$p '$1=="Package:"{n=$2} $1=="Depends:"&&n==p{sub(/^Depends: /,""); gsub(/\([^)]*\)/,""); gsub(/,/," "); print; exit}' $D/Packages)"
  done
  for p in $got; do f=$(awk -v p=$p '$1=="Package:"{n=$2} $1=="Filename:"&&n==p{print $2; exit}' $D/Packages)
    [ -n "$f" ] && curl -s --interface $VPNIF --max-time 120 -o $D/$f "$SRC/$f"; done
  printf 'dest root /\nlists_dir ext %s/lists\n%s\n' $D "$(awk '$1=="arch"{print "arch "$2" "$3}' /opt/etc/opkg.conf)" > $D/local.conf
  opkg -f $D/local.conf install $D/*.ipk >/dev/null 2>&1; rm -rf $D
  for p in $orig; do opkg list-installed | grep -q "^$p " || return 1; done
}
if [ -n "$NEED" ]; then
  if pkg_install $NEED; then okm "$(L 'Программы поставлены' 'Packages installed'):$NEED"
  elif [ -z "$R" ] && pkg_via_vpn $NEED; then okm "$(L 'Программы поставлены через VPN' 'Packages installed via VPN'):$NEED"
  else bad "$(L 'Не удалось поставить' 'Could not install'):$NEED"; exit 1; fi
fi

# 5.2 files: new ones — into the "delete on rollback" list, replaced ones — a copy in $BK
put() {  # put source target mode
  if [ -f "$R$2" ]; then cmp -s "$1" "$R$2" && return 0
    mkdir -p "$R$BK/files$(dirname "$2")"; cp -p "$R$2" "$R$BK/files$2"; note "repl $2 $BK/files$2"
  else note "file $2"; fi
  mkdir -p "$(dirname "$R$2")"; cp "$1" "$R$2.new" && chmod $3 "$R$2.new" && mv "$R$2.new" "$R$2"
}
for f in direct-routes.sh geo-build.sh geo-dns.sh geo-profiles.sh; do put "$FILES/core/$f" "$CORE/$f" 755; done
for f in rzv-lib.sh rzv-bot.sh rzv-act.sh; do put "$FILES/bot/$f" "$APP/$f" 755; done
put "$FILES/bot/S99razvilka" /opt/etc/init.d/S99razvilka 755
okm "$(L 'Файлы на месте' 'Files in place')"

# 5.3 settings (only if they do not exist yet — yours are not touched)
newconf() {  # newconf path mode — content from stdin
  [ -f "$R$1" ] && { cat > /dev/null; return 0; }
  mkdir -p "$(dirname "$R$1")"; cat > "$R$1"; chmod $2 "$R$1"; note "file $1"
}
newconf $ETC/net.conf 644 <<EOF
# Razvilka: this router's network. Written by the installer $TS; you can edit it by hand.
WAN=$WAN          # ISP (direct internet exit)
TUN=$VPNIF        # VPN tunnel
LANIP=$LANIP   # router address in the home network
CORE=$CORE   # core folder
BOTLANG=$LNG   # bot language: ru or en (to change — edit and run /opt/etc/init.d/S99razvilka restart)
EOF
newconf /opt/etc/direct-routes.conf 644 <<EOF
# Razvilka: group "$GROUP" — devices with a VPN policy (@policy); !MAC — strictly via VPN
$GROUP   $TABLE   @policy
EOF
newconf /opt/etc/direct-routes.geo.conf 644 <<EOF
# Razvilka: "home country direct"
ENABLED=1
COUNTRY=$COUNTRY
GROUP=$GROUP
LITE=$LITE
EOF
if [ -f "$FILES/data/$COUNTRY/asn_allow.conf" ]; then newconf $ETC/asn_allow.conf 644 < "$FILES/data/$COUNTRY/asn_allow.conf"
else newconf $ETC/asn_allow.conf 644 < "$FILES/data/any/asn_allow.conf"; fi
newconf $ETC/asn_deny.conf 644 < "$FILES/data/any/asn_deny.conf"
if [ -n "$TOKEN" ] && [ -n "$ADMIN" ]; then
  ( umask 077; printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ADMIN_ID=%s\n' "$TOKEN" "$ADMIN" > "$R$ETC/tg.env" ); note "file $ETC/tg.env"
fi
okm "$(L 'Настройки записаны' 'Settings written')"

# 5.4 firmware: site group and DNS route through the ISP (if the group does not exist yet)
if [ $GRP_EXISTS = 0 ]; then
  sys "ndmc -c 'object-group fqdn $GROUP' >/dev/null"
  sys "ndmc -c 'dns-proxy route object-group $GROUP $WAN_NDM auto' >/dev/null || ndmc -c 'dns-proxy route object-group $GROUP $WAN_NDM' >/dev/null"
  sys "ndmc -c 'system configuration save' >/dev/null"; note "ndm group $WAN_NDM"
  okm "$(L 'Прошивка: группа' 'Firmware: group') $GROUP"
fi

# 5.5 hooks and schedule
if [ ! -f "$R/opt/etc/ndm/netfilter.d/56-direct-routes.sh" ]; then
  mkdir -p "$R/opt/etc/ndm/netfilter.d"; note "file /opt/etc/ndm/netfilter.d/56-razvilka-routes.sh"
  printf '#!/bin/sh\n# Развилка: после пересборки nat прошивкой — вернуть DNS-правила групп\n[ "$type" = iptables ] && [ "$table" = nat ] && %s/direct-routes.sh nat >/dev/null 2>&1\nexit 0\n' "$CORE" > "$R/opt/etc/ndm/netfilter.d/56-razvilka-routes.sh"
  chmod 755 "$R/opt/etc/ndm/netfilter.d/56-razvilka-routes.sh"
fi
if [ ! -f "$R/opt/etc/ndm/netfilter.d/57-razvilka-fuse.sh" ]; then
  mkdir -p "$R/opt/etc/ndm/netfilter.d"; note "file /opt/etc/ndm/netfilter.d/57-razvilka-fuse.sh"
  printf '#!/bin/sh\n# Razvilka: after the firmware rebuilds the filter table, put the DNS fuse back (only if it is on)\n[ "$table" = filter ] && %s/rzv-act.sh fuse_apply >/dev/null 2>&1\nexit 0\n' "$APP" > "$R/opt/etc/ndm/netfilter.d/57-razvilka-fuse.sh"
  chmod 755 "$R/opt/etc/ndm/netfilter.d/57-razvilka-fuse.sh"
fi
cronline() {  # cronline tag "line" [marker of an existing line]
  grep -q "# razvilka:$1\$" "$R/opt/etc/crontab" 2>/dev/null && return 0
  [ -n "$3" ] && grep -qF "$3" "$R/opt/etc/crontab" 2>/dev/null && return 0
  echo "$2 # razvilka:$1" >> "$R/opt/etc/crontab"; note "cron $1"
}
touch "$R/opt/etc/crontab"
[ -f "$R/opt/etc/cron.1min/direct-routes" ] || cronline routes "* * * * * root $CORE/direct-routes.sh tick >/dev/null 2>&1" "direct-routes.sh tick"
cronline geo     "23 4 * * * root $CORE/geo-build.sh apply"         "geo-build.sh apply"
cronline checks  "*/5 * * * * root $APP/rzv-act.sh checks"          "rzv-act.sh checks"
cronline guard   "* * * * * root $APP/rzv-act.sh guard"             "rzv-act.sh guard"
cronline watch   "*/10 * * * * root $APP/rzv-act.sh watch"          "rzv-act.sh watch"
cronline refresh "45 4 * * * root $APP/rzv-act.sh refresh"          "rzv-act.sh refresh"
okm "$(L 'Расписание' 'Cron'): OK"

# 5.6 start and check
if [ $SELF = 0 ]; then
  note "routes - $CORE/direct-routes.sh"
  sys "$CORE/direct-routes.sh apply >/dev/null 2>&1"
  echo "  ⏳ $(L 'Собираю карту страны — пару минут…' 'Building the country map — a couple of minutes…')"
  sys "$CORE/geo-build.sh apply >/dev/null 2>&1"
fi
sys "/opt/etc/init.d/S99razvilka restart >/dev/null 2>&1"
if [ -z "$R" ]; then
  sleep 5
  c=$(curl -s -o /dev/null -w '%{http_code}' --interface $VPNIF --max-time 8 http://connectivitycheck.gstatic.com/generate_204)
  if [ "$c" != 204 ]; then echo "  ⛔ $(L 'VPN не отвечает после установки — возвращаю всё как было' 'VPN does not respond after install — restoring everything')"
    YES=1 LNG=$LNG sh "$0" --uninstall --yes --lang=$LNG >/dev/null 2>&1; exit 1; fi
  okm "$(L 'VPN работает' 'VPN works')"
fi
echo; okm "$(L 'Готово! Откройте своего бота в Telegram и нажмите /start.' 'Done! Open your bot in Telegram and press /start.')"
echo "  ↩️  $(L 'Вернуть как было' 'Undo'): sh $0 --uninstall"
exit 0
