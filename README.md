# TrustTunnel on Keenetic routers — with dashboard statistics

[![Release](https://img.shields.io/github/v/release/alex-combine/TrustTunnel-Keenetic-Native)](https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/alex-combine/TrustTunnel-Keenetic-Native/total)](https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases)
[![License](https://img.shields.io/github/license/alex-combine/TrustTunnel-Keenetic-Native)](LICENSE)

[🇷🇺 Инструкция на русском языке](README_ru.md)

> An extended version of [TrustTunnel-Keenetic](https://github.com/artemevsevev/TrustTunnel-Keenetic) by Artem Evsevev.
>
> **What is new:** the TUN connection (OpkgTunN) finally shows real traffic statistics in the Keenetic web interface — the classic setup always shows 0.
> Existing installations switch with one command, with automatic rollback if anything goes wrong.
> Jump to: [Dashboard statistics](#dashboard-statistics-attach-mode) · [Upgrading an existing router](#upgrading-a-router-with-the-classic-setup)

## Prerequisites

Before installing on the router, you must:
1. Install Entware on the router: [Entware Installation Guide](https://help.keenetic.com/hc/en-us/articles/360021214160-Installing-the-Entware-package-system-repository-on-a-USB-drive)
2. To use in Proxy mode, install the "Proxy client" component on the router.
3. Install curl:
   ```bash
   opkg update
   opkg install curl
   ```
4. Install and configure the TrustTunnel server on a VPS (see below)

### 1. Installing Server on VPS

On a Linux VPS (x86_64 or aarch64), run:

```bash
curl -fsSL https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh | sh -s -
```

The server will be installed in `/opt/trusttunnel`. Run the setup wizard:

```bash
cd /opt/trusttunnel/
sudo ./setup_wizard
```

The wizard will prompt for:
- Listen address (default `0.0.0.0:443`)
- User credentials
- Path for storing filtering rules
- Certificate selection (Let's Encrypt, self-signed, or existing)

Set up autostart via systemd:

```bash
cp /opt/trusttunnel/trusttunnel.service.template /etc/systemd/system/trusttunnel.service
sudo systemctl daemon-reload
sudo systemctl enable --now trusttunnel
```

#### Setting up Let's Encrypt with Auto-renewal

Install Certbot:

```bash
sudo apt update
sudo apt install -y certbot
```

Get a certificate (replace `example.com` with your domain):

```bash
sudo certbot certonly --standalone -d example.com
```

Certificates will be saved in:
- `/etc/letsencrypt/live/example.com/fullchain.pem`
- `/etc/letsencrypt/live/example.com/privkey.pem`

Specify the paths in the TrustTunnel configuration (`hosts.toml`):

```toml
[[main_hosts]]
hostname = "example.com"
cert_chain_path = "/etc/letsencrypt/live/example.com/fullchain.pem"
private_key_path = "/etc/letsencrypt/live/example.com/privkey.pem"
```

Configure automatic server restart after certificate renewal:

```bash
sudo certbot reconfigure --deploy-hook "systemctl reload trusttunnel"
```

Verify auto-renewal works:

```bash
sudo certbot renew
```

#### Exporting Configuration for the Client

After configuring the server, export the configuration for the client:

```bash
cd /opt/trusttunnel/
./trusttunnel_endpoint vpn.toml hosts.toml -c client_name -a server_public_ip --format toml > config.toml
```

This will create a `config.toml` file that you need to transfer to the router.

### 2. Installing Client on Keenetic

Run a single command on the router:

```bash
curl -fsSL https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases/latest/download/install.sh | sh
```

> The scripts are downloaded from GitHub Releases, so GitHub counts downloads — this is the only usage statistics. Nothing about your router is sent anywhere.

> The script automatically detects the latest stable version (GitHub Release).
> To install a specific version:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/alex-combine/TrustTunnel-Keenetic-Native/main/install.sh | sh -s -- --version v2.0.2
> ```

> To install from the `main` branch (latest dev version):
> ```bash
> curl -fsSL https://raw.githubusercontent.com/alex-combine/TrustTunnel-Keenetic-Native/main/install.sh | sh -s -- --dev
> ```

The installation script will perform the following:
1. Stop the running TrustTunnel service (if running)
2. Prompt to select the operation mode (SOCKS5 or TUN); during reconfiguration, the current mode is proposed by default
3. Automatically determine occupied interfaces (Proxy for SOCKS5, OpkgTun for TUN) and propose the first free index
4. Download and install autostart scripts (`S99trusttunnel`, `010-trusttunnel.sh`) and the `tt-stats` helper (`/opt/bin/tt-stats`)
5. Save the selected mode to `/opt/trusttunnel_client/mode.conf`
6. Prompt to create an interface (ProxyN for SOCKS5 or OpkgTunN for TUN) in Keenetic; when changing the mode or index, it will delete the old interface
7. Prompt to install/update the TrustTunnel client (supported architectures: x86_64, aarch64, armv7, mips, mipsel)

### Mode Comparison

| | SOCKS5 (ProxyN) | TUN (OpkgTunN) |
|---|---|---|
| Keenetic Interface | ProxyN (Proxy0 by default) | OpkgTunN (OpkgTun0 by default) |
| Traffic Type | TCP via SOCKS5 proxy | All traffic (TCP/UDP/ICMP) via TUN |
| Performance | Lower (userspace proxy) | Higher (kernel TUN) |
| Compatibility | All Keenetic versions with Entware | Keenetic firmware v5+ with OpkgTun support |
| Requirements | — | `ip-full` package in Entware, IP address from VPN server |

#### Client Configuration

Generate the configuration from the file exported from the server:

```bash
cd /opt/trusttunnel_client/
./setup_wizard --mode non-interactive --endpoint_config config.toml --settings trusttunnel_client.toml
```

Detailed documentation: https://github.com/TrustTunnel/TrustTunnel

#### Configuration for SOCKS5 Mode

The SOCKS proxy listener must be configured in `trusttunnel_client.toml`:

```toml
[listener]

[listener.socks]
address = "127.0.0.1:1080"
username = ""
password = ""
```

There should be no `[listener.tun]` section in the file.

#### Configuration for TUN Mode

The TUN listener must be configured in `trusttunnel_client.toml`:

```toml
[listener]

[listener.tun]
device_name = "opkgtun0"
use_existing = true
bound_if = ""
included_routes = []
excluded_routes = []
change_system_dns = false
mtu_size = 1280
```

- `device_name` + `use_existing` turn on **attach mode**: the client uses the `opkgtunN` device that KeeneticOS created for `OpkgTunN`, so the web interface shows traffic statistics (client ≥ 1.0.62; `N` = `TUN_IDX` from `mode.conf`). Without these two lines the classic mode is used. Details: [Dashboard statistics](#dashboard-statistics-attach-mode).
- `included_routes = []` is required in attach mode — routing is done by KeeneticOS.
- Recommended at the top of the file: `killswitch_enabled = true` (see [Kill switch](#recommended-kill-switch)).

There should be no `[listener.socks]` section in the file.

Check the start:
```bash
./trusttunnel_client -c trusttunnel_client.toml
```

After configuration, start the service:
```bash
/opt/etc/init.d/S99trusttunnel start
```

### Manual Configuration in Keenetic Web Interface

#### SOCKS5 Mode

If you skipped automatic interface creation during installation, add the proxy connection manually:

1. Open the Keenetic web interface
2. Go to **Other connections** -> **Proxy connections**
3. Add a new SOCKS5 proxy connection with address `127.0.0.1` and port `1080` (interface name ProxyN, where N is the index from `mode.conf`)
4. Configure traffic routing through this connection

#### TUN Mode

The installer creates the OpkgTunN interface (N = index from `mode.conf`, default is 0); KeeneticOS creates its `opkgtunN` device for it, and in attach mode the client connects to that device. In the classic mode the interface comes alive after the client starts and `tun0` is renamed to `opkgtunN`. For manual configuration via CLI:

```bash
ndmc -c 'interface OpkgTunN'
ndmc -c 'interface OpkgTunN description "TrustTunnel TUN N"'
ndmc -c 'interface OpkgTunN ip address <TUN_IP> 255.255.255.255'
ndmc -c 'interface OpkgTunN ip global auto'
ndmc -c 'interface OpkgTunN ip mtu 1280'
ndmc -c 'interface OpkgTunN ip tcp adjust-mss pmtu'
ndmc -c 'interface OpkgTunN security-level public'
ndmc -c 'interface OpkgTunN up'
ndmc -c 'ip route default OpkgTunN'
```

> **Important:** The `ip route default` command is necessary for Keenetic's policy-based routing to work correctly through OpkgTunN.

## Dashboard statistics (attach mode)

### The problem

In TUN mode the Keenetic web interface (**Other connections → OpkgTunN**) always shows **0** traffic, although the VPN works. The CLI confirms that the firmware does not count anything:

```
ndmc -c 'show interface OpkgTun0 stat'
    rxbytes: 0
  timestamp: 0.000000
```

Why: KeeneticOS creates its own kernel device `opkgtunN` for the `OpkgTunN` interface and collects statistics **only for that device**. The classic setup lets the client create `tun0`, deletes the firmware device and renames `tun0` → `opkgtunN`. Routing works (the name matches), but the firmware no longer counts the device.

### The fix

Since version **1.0.62** the TrustTunnel client can attach to an existing TUN device instead of creating its own:

```
Classic:  client ──creates──> tun0 ──renamed──> opkgtun0      (firmware device deleted)   → dashboard: 0
Attach:   KeeneticOS ──creates──> opkgtun0 <──attaches── client                           → dashboard: real traffic
```

```toml
[listener.tun]
device_name = "opkgtun0"   # N = TUN_IDX from mode.conf
use_existing = true
included_routes = []       # required: with an existing device the client does not manage routes
```

Without `included_routes = []` the client stops with `Managed routing for an existing TUN device requires sport rule support`. Routing does not change: KeeneticOS routes through `OpkgTunN` in both modes, only the owner of the device changes.

**Tested on:** Keenetic Hero 4G (KN-2310), KeeneticOS 5.1.6 (mips), TrustTunnel client 1.1.7. After the switch and one reboot `show interface OpkgTun0 stat` shows a growing `timestamp`, `rxbytes` equals the kernel counter `/sys/class/net/opkgtun0/statistics/rx_bytes` byte for byte, and the web interface draws the traffic graph.

### New installation

Run `install.sh`, choose TUN, add the lines above to the client config and start the service. The installer creates `OpkgTunN`, and KeeneticOS creates its device right away. Check:

```bash
tt-stats status
```

If it says `not yet`, reboot the router once: `tt-stats reboot`.

### Upgrading a router with the classic setup

For routers set up with the original TrustTunnel-Keenetic (or an older version of this one). Your client config and settings are kept; only the attach lines are added.

```bash
curl -fsSL https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases/latest/download/tt-stats -o /opt/bin/tt-stats
chmod +x /opt/bin/tt-stats
tt-stats status            # read-only: what is there now
tt-stats enable --reboot   # switch safely, then reboot once
```

One reboot is needed because the classic script has deleted the firmware device; KeeneticOS recreates it at boot. Until the reboot the VPN already works in attach mode, only the counters stay at 0.

**How `tt-stats enable` protects your connection:**

1. **Checks first, changes nothing if any check fails:** TUN mode, client ≥ 1.0.62, `OpkgTunN` exists in KeeneticOS, the VPN works right now.
2. **Backup:** `S99trusttunnel`, `010-trusttunnel.sh`, client config and `mode.conf` go to `/opt/trusttunnel_client/backup-classic/` with `MD5SUMS`.
3. **New files are prepared before the service is touched:** the attach-capable scripts are downloaded and syntax-checked (`sh -n`).
4. **Safety timer:** if the switch does not report success within 10 minutes, the classic setup is restored.
5. **Verification:** the VPN must answer within 90 s, the client log must confirm the attach, then 3 checks over 60 s. Any failure → automatic rollback.
6. **Boot guard** (`/opt/etc/init.d/S99ttstats-guard`): after a reboot, if the VPN does not come up within 4 minutes, the classic setup is restored.
7. **`--reboot`** runs pre-flight checks (attach mode on, backup intact, boot guard installed, VPN works, settings saved) and only then reboots.

Manual rollback at any time:

```bash
tt-stats disable
```

All actions are logged to `/opt/var/log/tt-stats.log`.

| Command | What it does |
|---|---|
| `tt-stats status` | Mode, client version, device, VPN check, KeeneticOS counters, whether statistics work (read-only) |
| `tt-stats enable [--reboot]` | Safe switch to attach mode with automatic rollback |
| `tt-stats disable` | Restore the classic setup from the backup |
| `tt-stats reboot` | Pre-flight checks, then router reboot |
| `tt-stats version` | Helper version |

### Recommended: kill switch

Put `killswitch_enabled = true` at the top of `trusttunnel_client.toml`. With `false`, when the VPN server is unreachable, the client may let traffic go directly through the ISP. This setting is independent of attach mode, but worth checking while you are here — `tt-stats status` shows it.

### FAQ

- **Does attach mode change routing, policies or the firewall?** No. KeeneticOS routes through `OpkgTunN` in both modes; only who creates the device changes.
- **My client is older than 1.0.62.** `tt-stats enable` refuses to switch. Update the client (`install.sh` offers it), then run it again.
- **SOCKS5 mode?** Attach mode applies to TUN mode only.
- **MTU?** In attach mode the device MTU comes from `TUN_MTU` in `mode.conf`; `tt-stats enable` sets it from `mtu_size` of the client config and keeps `interface OpkgTunN ip mtu` equal to it.
- **What if the VPN server itself is down right after a reboot?** The boot guard cannot tell a server outage from a failed switch, so it restores the classic setup to be safe. When the server is back, run `tt-stats enable --reboot` again.
- **How do I go back?** `tt-stats disable` (or restore the files from `/opt/trusttunnel_client/backup-classic/` by hand).

## File Structure

```
/opt/
├── bin/
│   └── tt-stats                    # Dashboard statistics helper: status / enable / disable
├── etc/
│   ├── init.d/
│   │   ├── S99trusttunnel          # Main init script
│   │   └── S99ttstats-guard        # Boot guard (created by tt-stats enable)
│   └── ndm/
│       └── wan.d/
│           └── 010-trusttunnel.sh  # Hook on WAN up
├── var/
│   ├── run/
│   │   ├── trusttunnel.pid         # Client PID
│   │   ├── trusttunnel_watchdog.pid # Watchdog PID
│   │   ├── trusttunnel_hc_state    # Health check state
│   │   └── trusttunnel_start_ts    # Client start time (for WAN hook grace period)
│   └── log/
│       ├── trusttunnel.log         # Work log (rotates at 512 KB)
│       ├── trusttunnel.log.old     # Previous log after rotation
│       └── tt-stats.log            # tt-stats log (switches, rollbacks, boot guard)
└── trusttunnel_client/
    ├── trusttunnel_client          # Client binary
    ├── trusttunnel_client.toml     # Configuration
    ├── mode.conf                   # Operation mode (socks5/tun), TUN_IDX, PROXY_IDX, TUN_MTU, HC settings
    └── backup-classic/             # Classic setup backup made by tt-stats enable (+ MD5SUMS)
```

## Manual Installation

If you prefer manual installation instead of the script:

```bash
VERSION="v2.0.2"  # Specify the required version (GitHub Release tag)

# Create directories
mkdir -p /opt/etc/init.d
mkdir -p /opt/etc/ndm/wan.d
mkdir -p /opt/var/run
mkdir -p /opt/var/log

# Init script
curl -fsSL "https://raw.githubusercontent.com/alex-combine/TrustTunnel-Keenetic-Native/${VERSION}/S99trusttunnel" -o /opt/etc/init.d/S99trusttunnel
chmod +x /opt/etc/init.d/S99trusttunnel

# WAN hook
curl -fsSL "https://raw.githubusercontent.com/alex-combine/TrustTunnel-Keenetic-Native/${VERSION}/010-trusttunnel.sh" -o /opt/etc/ndm/wan.d/010-trusttunnel.sh
chmod +x /opt/etc/ndm/wan.d/010-trusttunnel.sh

# Dashboard statistics helper
mkdir -p /opt/bin
curl -fsSL "https://raw.githubusercontent.com/alex-combine/TrustTunnel-Keenetic-Native/${VERSION}/tt-stats" -o /opt/bin/tt-stats
chmod +x /opt/bin/tt-stats

# Ensure the client is executable
chmod +x /opt/trusttunnel_client/trusttunnel_client
```

## Usage

### Service Management

```bash
# Start (client + watchdog)
/opt/etc/init.d/S99trusttunnel start

# Stop (client + watchdog)
/opt/etc/init.d/S99trusttunnel stop

# Full restart
/opt/etc/init.d/S99trusttunnel restart

# Soft restart (only client, watchdog will restart it)
/opt/etc/init.d/S99trusttunnel reload

# Check status
/opt/etc/init.d/S99trusttunnel status
```

### Viewing Logs

```bash
# Current log
cat /opt/var/log/trusttunnel.log

# Real-time
tail -f /opt/var/log/trusttunnel.log
```

The log is automatically rotated when it reaches 512 KB: the current file is renamed to `trusttunnel.log.old`.

## How It Works

### Autostart on Boot
- Entware automatically runs all `S*` scripts in `/opt/etc/init.d/` at startup
- The `S99trusttunnel` script runs last (99 = high priority)

### Watchdog (Restart on Crash)
- After the client starts, a background watchdog process starts
- Checks every 10 seconds if the client is alive
- On crash, automatically restarts with linear backoff: 10s, 20s, 30s... up to 300s (max 10 attempts)
- Additionally checks real connectivity through the tunnel (health check)

### WAN Reconnection
- Keenetic calls scripts from `/opt/etc/ndm/wan.d/` on WAN up
- The `010-trusttunnel.sh` script initiates a client restart, with several protections:
  - **Skip own interface** — if the WAN event is triggered by our own `OpkgTunN`, no restart occurs (prevents an infinite loop)
  - **Grace period** — if the client was started less than 30 seconds ago, the restart is skipped
  - **Service state check** — restart only if the watchdog is active (service is running)
- In TUN mode: interfaces `opkgtunN`/`tun0` are brought down before restarting
- The watchdog will pick up and start the client again

### Health Check (Connectivity Monitoring)

The watchdog checks not only the process liveness but also real connectivity through the tunnel:

- **TUN mode**: HTTP request via the `opkgtunN` interface (`curl --interface`)
- **SOCKS5 mode**: HTTP request via proxy (`curl --socks5`, default `127.0.0.1:1080`, configurable via `HC_SOCKS5_PROXY`)

Both modes use a lightweight connectivity-check endpoint (HTTP 204, no body).

Default parameters:

| Parameter | Value | Description |
|---|---|---|
| `HC_ENABLED` | `yes` | Enable/disable health check |
| `HC_INTERVAL` | `30` | Check interval (seconds) |
| `HC_FAIL_THRESHOLD` | `3` | Consecutive failures before reconnecting |
| `HC_GRACE_PERIOD` | `60` | Pause without checks after (re)start |
| `HC_TARGET_URL` | `http://connectivitycheck.gstatic.com/generate_204` | URL for connectivity check |
| `HC_CURL_TIMEOUT` | `5` | Curl timeout (seconds) |
| `HC_SOCKS5_PROXY` | `127.0.0.1:1080` | SOCKS5 proxy address for checking (SOCKS5 mode) |

To configure, uncomment and change the parameters in `/opt/trusttunnel_client/mode.conf`.

To completely disable health check:
```
HC_ENABLED="no"
```

The current health check status is shown in the `status` output:
```bash
/opt/etc/init.d/S99trusttunnel status
# Health check: ok (2025-01-15 12:34:56)
```

### TUN Mode (OpkgTunN)

**Attach mode** (`use_existing = true` in the client config):
- KeeneticOS creates the `opkgtunN` device for the `OpkgTunN` interface (when the interface is created and at every boot)
- The init script waits for the device (up to 15 seconds), sets MTU (`TUN_MTU`) and addresses, and starts the client
- The client attaches to the device; KeeneticOS counts its traffic and shows it in the web interface
- If the device is missing, the init script creates it itself so the VPN keeps working (statistics appear after one reboot)

**Classic mode** (no `use_existing`):
- TrustTunnel Client creates a `tun0` interface
- The init script waits for `tun0` to appear (up to 30 seconds) and renames it to `opkgtunN` (N = index from `mode.conf`)
- Keenetic recognizes `opkgtunN` as an `OpkgTunN` interface and applies routing/firewall
- The watchdog checks and fixes an unrenamed `tun0` on every cycle

### Duplicate Protection
- A PID file prevents starting multiple instances
- Check via `pidof` as a fallback

## Disabling Autostart

```bash
# Temporarily (until next reboot)
/opt/etc/init.d/S99trusttunnel stop

# Permanently
# Change ENABLED=yes to ENABLED=no in the script
# or delete/rename the script:
mv /opt/etc/init.d/S99trusttunnel /opt/etc/init.d/_S99trusttunnel
```

## Troubleshooting

### Download fails: `Connection reset by peer`

If the install command stops with `curl: (35) Recv failure: Connection reset by peer` (or a timeout), your provider interrupts connections to GitHub. The router itself is fine. What you can do:

1. Run the command again a few times — the resets are often intermittent.
2. Download the release files on a computer from the [Releases](https://github.com/alex-combine/TrustTunnel-Keenetic-Native/releases/latest) page (`install.sh`, `configure.sh`, `S99trusttunnel`, `010-trusttunnel.sh`, `tt-stats`), copy them to the router (for example with WinSCP or `scp` into `/opt/tmp/`) and follow [Manual Installation](#manual-installation).
3. If the router already has a working VPN connection, send `github.com` and `githubusercontent.com` through it (Routing → DNS routes in the Keenetic web interface) and run the command again.

### Client doesn't start
```bash
# Check permissions
ls -la /opt/trusttunnel_client/

# Try to run manually
/opt/trusttunnel_client/trusttunnel_client -c /opt/trusttunnel_client/trusttunnel_client.toml

# Check the log
cat /opt/var/log/trusttunnel.log
```

### Watchdog isn't working
```bash
# Check processes
ps | grep trusttunnel

# Check PID files
cat /opt/var/run/trusttunnel_watchdog.pid
```

### WAN hook doesn't trigger
```bash
# Check permissions
ls -la /opt/etc/ndm/wan.d/

# Check that Keenetic supports ndm hooks
# (requires installed opt package in firmware)
```

### TUN interface doesn't appear (TUN mode)
```bash
# Check the current mode and TUN_IDX in mode.conf
cat /opt/trusttunnel_client/mode.conf

# Check for tun0 / opkgtunN
ip link show tun0
ip link show opkgtunN  # N = TUN_IDX from mode.conf

# Check that ip-full is installed
opkg list-installed | grep ip-full

# Try to rename manually (replace N with index)
ip link set tun0 down
ip link set tun0 name opkgtunN
ip link set opkgtunN up

# Check the log for rename errors
logread | grep TrustTunnel | tail -20
```

### Health check causes frequent reconnections

If the tunnel works, but the health check regularly detects failures and restarts the client:

```bash
# Increase the failure threshold and check interval in /opt/trusttunnel_client/mode.conf:
HC_FAIL_THRESHOLD=5
HC_INTERVAL=60

# Or completely disable health check:
HC_ENABLED="no"

# Restart the service after changing settings:
/opt/etc/init.d/S99trusttunnel restart
```

### The web interface shows 0 traffic for OpkgTunN
```bash
tt-stats status
```
- `Attach mode: no` → see [Upgrading a router with the classic setup](#upgrading-a-router-with-the-classic-setup)
- `Attach mode: yes`, statistics `not yet` → reboot once: `tt-stats reboot`
- `Client version ... TOO OLD` → update the client to 1.0.62 or newer

### OpkgTunN isn't visible in the Keenetic web interface
```bash
# Check that the interface is created in Keenetic (replace N with index from mode.conf)
ndmc -c 'show interface' | grep OpkgTunN

# If not — create it manually (replace N and IP)
ndmc -c 'interface OpkgTunN'
ndmc -c 'interface OpkgTunN ip address 172.16.219.2 255.255.255.255'
ndmc -c 'interface OpkgTunN ip global auto'
ndmc -c 'interface OpkgTunN ip mtu 1280'
ndmc -c 'interface OpkgTunN ip tcp adjust-mss pmtu'
ndmc -c 'interface OpkgTunN security-level public'
ndmc -c 'interface OpkgTunN up'
ndmc -c 'ip route default OpkgTunN'
ndmc -c 'system configuration save'
```

## Credits

Based on [TrustTunnel-Keenetic](https://github.com/artemevsevev/TrustTunnel-Keenetic) by Artem Evsevev (MIT). Attach mode relies on `use_existing` in the [TrustTunnel](https://github.com/TrustTunnel/TrustTunnel) client.
