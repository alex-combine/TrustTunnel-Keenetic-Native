# Changelog

## v2.3.3 — Razvilka: self-healing and a watchdog that really alarms

- **Self-healing** (`rzv-act.sh guard`, every minute): after 3 minutes without data through the VPN,
  devices with a VPN policy get an instant «no DNS» (the DNS fuse: REJECT on port 53, IPv4 and IPv6 —
  nothing leaks to the ISP, no retry storm, no conntrack pile-up), and the VPN connection is restarted
  (`S99trusttunnel reload`), every 30 minutes while the outage lasts; 3 minutes after a restart that did not help —
  optional own script `heal2.sh`. Every minute the rules are checked against the fuse flag both ways. The fuse comes off
  after 2 good checks or by itself in 30 minutes; a netfilter hook puts it back after the firmware rebuilds
  the filter table. `GUARD=0` / `FUSE=0` / `HEAL=0` in `net.conf` turn it off.
- **Watchdog:** when the router is alive but the VPN is not, services that take explicit alarms
  (healthchecks, Cronitor, OKchecker) get one right away, straight through the ISP. New «🤫 Silence test»
  button: 30 minutes without signals to check that the alarm really comes. The bot instructions now
  recommend tracker.ru (RU) and healthchecks.io (EN): a test on 12.10.2026 showed that OKchecker does not
  turn 3 hours of silence into an alarm. The morning summary says every day when the watchdog last heard
  from the router.
- **Fixes found by an acceptance run on a live router** (all three were there since v2.3.0):
  «Send direct» always answered «Could not add the site» although the site was added (`log` returned 1);
  after removing an exception the bot named another site (the list screen reused the variable);
  the «already in the country map» check never matched (`awk IP=…` is not set in `BEGIN`, now `-v`),
  so hints could suggest companies that already go direct and the site card missed company exceptions.
- **Plain names everywhere:** «Direct routes updated» says why in words («you added the company RU-CENTER»,
  «nightly check of company networks») and lists networks by company name; no registry numbers (AS…) in the
  bot's messages (a number only when the name is unknown).
- **Long buttons answer at once:** «Send direct / via VPN», «Remove exception», device switch, home country
  on/off and undo immediately replace the message with «⏳ what I am doing… no need to press again» and take
  the buttons away; while one long job runs, other long buttons answer «⏳ Still busy» and start nothing.
- **Readable hints:** the company name without registry codes («HCRU-AS - JSC _RU-CENTER_, RU» → «RU-CENTER»),
  the device that used it, the site name when the address tells it, and a plain tip which button to press.
  After «Send direct» the bot named another company (the network refresh reused the variable); the exception
  list and company screens show readable names too.
- **Hints work again:** the group is written as «@policy» (every device with a VPN policy), and the hint
  check took that word for a device name, so it never found a single connection. Now it reads the group
  like direct-routes.sh does.
- **Clearer bot settings:** ✅/⬜ are switches (a tap switches at once), «→» opens its own screen, «…» asks
  first. Turning off «Home country direct», erasing the hint history and turning the watchdog off now ask
  for confirmation (Cancel comes first). The watchdog is called «Connection watchdog»; the status screen no
  longer tells you to reboot the router while it restarts the VPN by itself; no more references to
  «🧪 Test alarm» where the service has none.
- Installer 0.8: the `guard` cron line and the `57-razvilka-fuse.sh` hook; removal takes the fuse off.
- **Razvilka is for TrustTunnel only:** it is tested only with TrustTunnel from this project in TUN mode, so the
  installer now checks for exactly that (and says what to do if it is missing or in SOCKS5 mode) instead of
  guessing among other tunnels, and no longer asks which interface is the VPN. The texts no longer mention
  other VPN protocols.
- **The installer speaks Russian and English:** `install.sh` asks for the language first (or `--lang=ru|en`),
  every question and hint of `configure.sh` follows it (yes is `y` or `д`), and the Razvilka commands it prints
  carry the same language.

## v2.3.2 — the router does not choke when the VPN drops at night

A real night on a 128 MB router: the VPN server became unreachable during the nightly Razvilka map build,
devices behind the kill switch retried DNS without a pause (over 2000 connections), memory went to zram,
the load reached 65 and the router hung.

- `tt-stats memguard` — **overload brake**: free memory below the threshold and a load average of
  `MEMGUARD_LOAD` (20) or more for 2 minutes → stops heavy optional jobs (`MEMGUARD_SHED`, by default the
  Razvilka map build) and lets short UDP conntrack entries expire in 5 s instead of 30 s for 10 minutes.
  UDP streams (QUIC, calls) use a separate timeout and are not affected. `MEMGUARD_LOAD=0` turns it off.
- Razvilka map build (`geo-build.sh`): does not start with less than `MIN_MEM_KB` (12000 kB) free or when the
  VPN does not answer. If the VPN dies or memory runs low during the build, it stops going online after
  2 failures in a row (before: a minute of waiting for every source, 20+ minutes in total), does not apply
  the result and tries again the next night. Runs with the lowest CPU priority.

## v2.3.1 — smarter memory guard

- `tt-stats memguard` no longer restarts a **small** client (below `MEMGUARD_SMALL_KB`, 5000 kB): then
  something else eats the memory, and a restart would only break connections.
- The VPN **pauses only if memory is still critical** (below `MEMGUARD_CRIT_KB`, by default 2/3 of the
  threshold). 3 alarms in 10 minutes with memory above that are only logged.
- **Nightly restart** of a bloated client: `memguard on` adds `/opt/etc/cron.daily/tt-memguard-nightly`, it
  restarts the client if it has grown above `MEMGUARD_NIGHT_KB` (12000 kB, `0` = off); `memguard off` removes it.
- Fix: the client size is read once per alarm. Before, a client that was restarting at that moment
  could be restarted again.
- The new values can be set in `mode.conf`; `tt-stats memguard` shows them.

## v2.3.0 — Razvilka (beta): home country direct, everything else via VPN

- New optional component **Razvilka** in [`razvilka/`](razvilka/README.md): sites of your own country go
  direct through the ISP, everything else through the VPN. The router builds the country network map itself
  every night (RIPE / ipverse, minus data centers); you control it from your own Telegram bot running on the
  router (sh + curl + jq, English and Russian): check a site, send it direct or via VPN, switch a device,
  get alerts when the VPN drops, optional "dead man's switch" watchdog by email.
- Works with any VPN connection in Keenetic, not only TrustTunnel. Off unless you install it.
- Own installer `razvilka-install.sh`: dry run (`--demo`), test into a folder (`--root`), settings backup,
  rollback by a manifest, automatic rollback if the VPN does not answer after installing, `--uninstall`.
- Released as `razvilka.tar.gz`; `configure.sh` offers to download it at the end of the setup.
- Beta: tested on Keenetic Hero 4G (KN-2310, 128 MB) and in a sandbox.

## v2.2.0 — update notifications

- The router now tells you when a new release is out (it never updates itself):
  `tt-stats status` shows an `Updates:` line, and a daily check (`/opt/etc/cron.daily/tt-stats-update-check`,
  installed by the installer when Entware cron is present) writes a note to the router's system log,
  once per new version. `tt-stats update-check` checks by hand.
- `MIN_VERSION` in the repository: installations older than it get an **IMPORTANT** note (serious fixes).
- The check reads only the version number (the redirect of `releases/latest`, not followed, plus `MIN_VERSION`);
  it downloads, runs and sends nothing. Only digits and dots are accepted from the answer.
- Memory guard: like the init script in v2.1.1, it no longer trusts a stale PID file after a crash
  (it would not start exactly when it is needed).

## v2.1.1 — VPN starts reliably after a crash

- `S99trusttunnel`: after a crash or power loss the old PID files stay on the USB drive. If one of those
  PIDs belonged to another process after the reboot, the script thought the client or the watchdog was
  "already running" and did not start the VPN at all. Now it checks the process command line
  (`/proc/PID/cmdline`), not just that the PID exists. Found on a real router after a hang.

## v2.1.0 — memory guard for 128 MB routers

- `tt-stats memguard on [KB]|off|status`: optional memory guard (`/opt/etc/init.d/S97tt-memguard`).
  When free memory (`MemAvailable`) drops below the threshold (default 10000 kB), it restarts only
  the client, which frees its buffers; 3 times in 10 minutes pauses the VPN for 15 minutes.
  Found on a real router: a long Steam download through the tunnel exhausted 128 MB and the router
  hung and rebooted in a loop. Log: `/opt/var/log/tt-memguard.log`.
- `tt-stats status` shows the memory guard state and free memory.
- README: troubleshooting for routers that hang during big downloads through the VPN.

## v2.0.2 — reliability fixes

- `S99trusttunnel`: the health check now has a total time limit (`--max-time`, 3 × `HC_CURL_TIMEOUT`).
  Before, only the connect time was limited: if the tunnel hung after connecting, `curl` could wait
  forever, and the watchdog stopped checking the tunnel and restarting the client.
- `S99trusttunnel`, `tt-stats`: stopping the watchdog works on firmware without `pkill`
  (fallback to `ps` + `kill`).
- README: troubleshooting for `Connection reset by peer` while downloading from GitHub; release and download badges.
- Issue template for bug reports.

## v2.0.1 — install statistics via GitHub Releases

- The scripts are attached to every release; `install.sh` and `tt-stats` download them
  from GitHub Releases, so GitHub counts downloads. Nothing about the router is sent anywhere.
- Install command: `curl -fsSL https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases/latest/download/install.sh | sh`
- Older tags without assets still install from raw files (automatic fallback).

## v2.0.0 — dashboard statistics (attach mode, published as part of v2.0.1)

First release of this extended version, based on
[TrustTunnel-Keenetic](https://github.com/artemevsevev/TrustTunnel-Keenetic) v1.4.0.

### Added
- **Attach mode for TUN**: the client attaches to the `opkgtunN` device that KeeneticOS
  creates for `OpkgTunN` (`device_name` + `use_existing = true`, client ≥ 1.0.62).
  The Keenetic web interface now shows traffic statistics for the TrustTunnel connection.
- `tt-stats` helper (`/opt/bin/tt-stats`): `status`, `enable [--reboot]`, `disable`, `reboot`.
  Safe switch from the classic setup: pre-checks, backup with MD5 sums, safety timer,
  verification with automatic rollback, boot guard (`S99ttstats-guard`).
- `TUN_MTU` in `mode.conf` (MTU of the device in attach mode).
- The installer downloads `tt-stats`, checks the client version for attach mode
  and shows the attach config lines and the kill switch recommendation.

### Changed
- `S99trusttunnel`: attach mode is read from the client config (`use_existing = true`).
  In attach mode the init script does not rename, bring down or delete `opkgtunN`
  (it belongs to KeeneticOS); it waits for the device, sets MTU and addresses,
  and creates the device itself only as a fallback.
- `010-trusttunnel.sh`: in attach mode only `tun0` is brought down before reload.
- The classic mode (no `use_existing`) works exactly as before.
