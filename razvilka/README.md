# 🔀 Razvilka — home country direct, everything else via VPN (beta)

[Русский](README_ru.md) · part of [TrustTunnel-Keenetic-Native](../README.md)

**Razvilka** (Russian for “fork in the road”) splits the internet on a Keenetic router into two roads:

```
sites and services of your own country ──► direct, via your ISP
everything else                       ──► through your VPN
```

The router builds the map of your country's networks by itself and refreshes it every night. You control it from your own Telegram bot: check a site, send it direct or via VPN, switch a device, get alerts when the VPN drops.

> **Beta.** Tested on Keenetic Hero 4G (KN-2310, 128 MB RAM, KeeneticOS 5.1) and in a sandbox. It is off unless you install it. Please report problems in [Issues](https://github.com/alex-combine/TrustTunnel-Keenetic-Native/issues).

Razvilka works with **TrustTunnel from this project in TUN mode** — the only setup it is tested with.

## Requirements
- Keenetic with **Entware on a USB stick**.
- **TrustTunnel installed by this project in TUN mode** (`install.sh`, mode 2), working, and devices with a VPN policy.
- **128 MB of RAM or more** (on 128–256 MB the installer offers a "light map").
- Your own Telegram bot: open **@BotFather → /newbot** and keep the token.

## How much it takes from the router
The bot lives on the router itself — no servers, no cloud.
- **USB stick:** about 1 MB (the bot and the core ~0.2 MB, the country map and caches ~0.5 MB, the log). If `jq`, `idn` or `dig` are missing, the installer adds them from Entware (a few hundred KB).
- **RAM:** about 8 MB all the time (the bot ~1 MB plus its connection waiting for Telegram ~7 MB); the country map in the router's tables ~0.2 MB. The nightly map rebuild needs 12 MB free and waits if there is less.
- **CPU:** almost idle — a short VPN check once a minute, checks every 5–10 minutes, the country map rebuild at night (about 1–2 minutes).

## Install
1. SSH into the router and download the package:
   ```
   mkdir -p /opt/tmp/razvilka-setup && cd /opt/tmp/razvilka-setup
   curl -fsSL https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases/latest/download/razvilka.tar.gz | tar xzf -
   ```
   (Easier: the main installer of this project offers to install Razvilka at the very end, once the VPN works.)
2. Run a **dry run** first — it changes nothing:
   ```
   sh /opt/tmp/razvilka-setup/razvilka-install.sh --demo --lang=en
   ```
3. If there are no ⛔ items — install:
   ```
   sh /opt/tmp/razvilka-setup/razvilka-install.sh --lang=en
   ```
   You will be asked for your country and bot token, then to press "Start" in your bot (this is how the installer learns who the owner is). It shows the plan and asks for "yes".
4. Open your bot and press **/start**.

Before any change the installer backs up router settings to `/opt/backup/razvilka_<time>/` and records every step. If the VPN does not respond after installing, it **restores everything automatically**. If Razvilka is already installed, it **updates the files** and keeps your settings, lists and token.

The installer and the bot speak English and Russian. To switch the bot later: edit `BOTLANG=en` (or `ru`) in `/opt/etc/razvilka/net.conf` and run `/opt/etc/init.d/S99razvilka restart`.

## Remove
```
sh /opt/tmp/razvilka-setup/razvilka-install.sh --uninstall --lang=en
```
Everything the installer added is removed in reverse order. Answer "yes" to the last question to delete the settings and the bot token too.

## What the bot does
- 📊 **Status** — VPN, router memory, freshness of the country map.
- 📋 **My exceptions** — everything you changed on top of the country map; tap a line to remove it.
- 🔎 **Site** — send an address: the bot tells where it goes now and lets you send it direct or via VPN. Understands internationalized domains.
- 📱 **Devices** — for each: "home country direct" or "everything via VPN".
- ⚙️ **Settings** — country on/off, morning summary, hints, "undo to yesterday", 🕰 connection watchdog. ✅/⬜ is a switch (tap — it switches), «→» opens its own screen, «…» asks first.
- 💡 **Hints** — when something from your home country went via VPN, the bot tells which company, which device and which site, and offers to let it go direct. Recognise it — «Send direct»; don't — «No, thanks».
- Long buttons (send direct, remove, switch) answer at once with «⏳ …», take the buttons away and write when done — there is nothing to press twice.
- Alerts: VPN lost and back, low memory, map not updated. While there is no connection, alerts are queued and arrive together when it is back.
- **🕰 Connection watchdog (optional)** — an outside service (a «dead man’s hand»): the router tells it «I am alive» every 5 minutes, and if the signals stop (no power, internet or VPN), the watchdog sends you an alarm by email or Telegram. healthchecks.io is recommended; tracker.ru (Russia) and cronitor.io work too. If the router is alive but the VPN is not, Razvilka raises the alarm at healthchecks and cronitor right away, straight through the ISP. The «🤫 Silence test» button checks that the alarm really reaches you (not every service catches silence). Instructions in the bot: ⚙️ Settings → 🕰 Connection watchdog.
- **🛠 Self-healing** — every minute the router checks that data goes through the VPN. After 3 minutes without data, devices with a VPN policy get an instant «no DNS» instead of silence (their DNS does not answer in these minutes anyway, and without the refusal they retry without a pause and the router may hang; nothing leaks to the ISP), and TrustTunnel is restarted (every 30 minutes until it is back). 3 minutes after a restart that did not help, your own script `/opt/etc/razvilka/heal2.sh` runs, if it exists. To turn off: `GUARD=0` (all), `FUSE=0` (no DNS refusal) or `HEAL=0` (no restart) in `net.conf`.

## Troubleshooting
- **Status says the VPN is not answering.** If 🛠 Self-healing is on (the default), the router restarts the connection by itself within minutes and tells you. If it does not recover in 15 minutes, check the VPN in the Keenetic web panel and reboot the router.
- **A site does not open.** Send its address to the bot: it shows whether the site goes direct or via VPN, and you can switch it with one button. If something broke after an update, use ⚙️ Settings → ↩️ Undo to yesterday.
- **The router is low on memory.** Turn on the «light map» (the bot offers it) or use a router with 256 MB of RAM or more.
- **The country map was not rebuilt tonight.** The build waits for a working VPN and enough free memory; if the VPN drops during the build, it stops and tries again the next night (see `/opt/var/log/ttwatch/direct-routes.log`).
- **The country list is not updated for days.** The router keeps using the old list. Check that the VPN works (the list is downloaded through it) and look at `/opt/var/log/razvilka.log`.
- **The bot is silent.** Telegram is reached through your VPN, so check the VPN first. Then on the router: `/opt/etc/init.d/S99razvilka status` and `restart`. To be alerted even when the VPN is down, turn on 🕰 Connection watchdog in ⚙️ Settings.
- **The router does not answer at all after installing.** The installer rolls back by itself when the VPN check fails. If you cannot reach the router, unplug the USB stick and reboot: Entware (and Razvilka with it) does not start without it.

## Privacy
- No telemetry: Razvilka sends nothing to the author.
- The bot token stays on your router only (`/opt/etc/razvilka/tg.env`, root-only, mode 600).
- The bot answers its owner only. Text from Telegram is never passed into router commands: site addresses are strictly validated.
- To learn the country and owner of an address, Razvilka queries public databases (RIPE, Team Cymru) through your VPN; for hints — the site name of an address (a reverse DNS query).
- 🕰 The connection watchdog (if you turn it on) only gets an «I am alive» signal from the router — no addresses, no content.

## Files on the router
| Path | What |
|---|---|
| `/opt/share/razvilka/` | bot (`rzv-lib.sh`, `rzv-bot.sh`, `rzv-act.sh`) and core (`core/`) |
| `/opt/etc/razvilka/` | settings, lists, bot token (`tg.env`) |
| `/opt/etc/init.d/S99razvilka` | service |
| `/opt/etc/crontab` | lines marked `# razvilka:` |
| `/opt/var/log/razvilka.log` | log |

## License
MIT — see [LICENSE](../LICENSE). The software is provided “as is”, without warranty; you are responsible for how you use it and for following the laws of your country.
