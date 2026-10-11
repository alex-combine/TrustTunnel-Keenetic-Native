# 🔀 Razvilka — home country direct, everything else via VPN (beta)

[Русский](README_ru.md) · part of [TrustTunnel-Keenetic-Native](../README.md)

**Razvilka** (Russian for “fork in the road”) splits the internet on a Keenetic router into two roads:

```
sites and services of your own country ──► direct, via your ISP
everything else                       ──► through your VPN
```

The router builds the map of your country's networks by itself and refreshes it every night. You control it from your own Telegram bot: check a site, send it direct or via VPN, switch a device, get alerts when the VPN drops.

> **Beta.** Tested on Keenetic Hero 4G (KN-2310, 128 MB RAM, KeeneticOS 5.1) and in a sandbox. It is off unless you install it. Please report problems in [Issues](https://github.com/alex-combine/TrustTunnel-Keenetic-Native/issues).

Razvilka works with **any VPN connection in Keenetic** (TrustTunnel, WireGuard, OpenVPN, …) — TrustTunnel is not required.

## Requirements
- Keenetic with **Entware on a USB stick**.
- A **working VPN connection** in Keenetic and devices with a VPN policy.
- **128 MB of RAM or more** (on 128–256 MB the installer offers a "light map").
- Your own Telegram bot: open **@BotFather → /newbot** and keep the token.

## Install
1. SSH into the router and download the package:
   ```
   mkdir -p /opt/tmp/razvilka-setup && cd /opt/tmp/razvilka-setup
   curl -fsSL https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases/latest/download/razvilka.tar.gz | tar xzf -
   ```
   (`configure.sh` of this project offers to download it at the end of the setup.)
2. Run a **dry run** first — it changes nothing:
   ```
   sh /opt/tmp/razvilka-setup/razvilka-install.sh --demo --lang=en
   ```
3. If there are no ⛔ items — install:
   ```
   sh /opt/tmp/razvilka-setup/razvilka-install.sh --lang=en
   ```
   You will be asked for your country, VPN interface and bot token, then to press "Start" in your bot (this is how the installer learns who the owner is). It shows the plan and asks for "yes".
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
- 🔎 **Site** — send an address: the bot tells where it goes now and lets you send it direct or via VPN. Understands internationalized domains.
- 📱 **Devices** — for each: "home country direct" or "everything via VPN".
- ⚙️ **Settings** — country on/off, morning summary, hints, "undo to yesterday", 🕰 watchdog.
- Alerts: VPN lost and back, low memory, map not updated. While there is no connection, alerts are queued and arrive together when it is back.
- **🕰 Watchdog (optional)** — if the router goes silent completely (no power, internet or VPN), a free outside service emails you: healthchecks.io, okchecker.ru or cronitor.io. Instructions in the bot: ⚙️ Settings → 🕰 Watchdog.

## Troubleshooting
- **Status says the VPN is not answering.** Check the VPN connection in the Keenetic web panel; if it does not recover in 10 minutes, reboot the router. Razvilka never turns the VPN off by itself.
- **A site does not open.** Send its address to the bot: it shows whether the site goes direct or via VPN, and you can switch it with one button. If something broke after an update, use ⚙️ Settings → ↩️ Undo to yesterday.
- **The router is low on memory.** Turn on the «light map» (the bot offers it) or use a router with 256 MB of RAM or more.
- **The country list is not updated for days.** The router keeps using the old list. Check that the VPN works (the list is downloaded through it) and look at `/opt/var/log/razvilka.log`.
- **The bot is silent.** Telegram is reached through your VPN, so check the VPN first. Then on the router: `/opt/etc/init.d/S99razvilka status` and `restart`. To be alerted even when the VPN is down, turn on 🕰 Watchdog in ⚙️ Settings.
- **The router does not answer at all after installing.** The installer rolls back by itself when the VPN check fails. If you cannot reach the router, unplug the USB stick and reboot: Entware (and Razvilka with it) does not start without it.

## Privacy
- No telemetry: Razvilka sends nothing to the author.
- The bot token stays on your router only (`/opt/etc/razvilka/tg.env`, root-only, mode 600).
- The bot answers its owner only. Text from Telegram is never passed into router commands: site addresses are strictly validated.
- To learn the country and owner of an address, Razvilka queries public databases (RIPE, Team Cymru) through your VPN.

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
