# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

An extended version of TrustTunnel-Keenetic (by Artem Evsevev): a shell-script-based TrustTunnel client installer and service manager for Keenetic routers running Entware. It supports two operation modes: SOCKS5 proxy and TUN tunnel interface. TUN mode has two variants: **attach mode** (the client attaches to the `opkgtunN` device created by KeeneticOS, so the web UI shows traffic statistics) and the **classic mode** (the client creates `tun0`, the init script renames it).

Installer output and code comments are in English. The README exists in English (`README.md`) and Russian (`README_ru.md`) — keep both in sync.

## Architecture

The system has five main components:

1. **install.sh** — Bootstrap installer. Detects the latest GitHub release (or accepts `--dev`/`--version` flags), downloads configure.sh, and executes it.

2. **configure.sh** — Interactive configuration script. Expects `REPO_URL` env var from install.sh. Checks prerequisites (curl, Entware, ndmc), prompts for mode selection (SOCKS5 vs TUN), auto-detects free Keenetic interface indices via `ndmc`, installs init scripts and WAN hooks, generates `mode.conf`, and optionally downloads the TrustTunnel client binary.

3. **S99trusttunnel** — Entware init script (`/opt/etc/init.d/`). Manages the client process lifecycle with a watchdog that implements linear backoff (10s→300s, max 10 retries). Attach mode is on when the client config has `use_existing = true` (single source of truth): `ensure_device` waits for the KeeneticOS-owned `opkgtunN`, sets MTU (`TUN_MTU`) and addresses; the device is never renamed, brought down or deleted. In the classic TUN mode, handles renaming `tun0` → `opkgtunN` for Keenetic recognition. Runs periodic health checks (HTTP connectivity via curl) and auto-restarts on failure. The `watchdog` subcommand is an internal entrypoint — the `start` action calls `$0 watchdog &` to launch it as a background process.

4. **010-trusttunnel.sh** — WAN hook (`/opt/etc/ndm/wan.d/`). Triggers service reload when the WAN interface comes up, ensuring client reconnects after network changes. In attach mode only `tun0` is brought down before reload.

5. **tt-stats** — helper installed to `/opt/bin/tt-stats`. `status` (read-only diagnostics), `enable [--reboot]` (safe switch to attach mode: pre-checks, backup to `backup-classic/` with MD5SUMS, 10-minute safety timer, verification with automatic rollback, boot guard `S99ttstats-guard`), `disable` (restore the classic setup), `reboot` (pre-flight checks, then reboot). Downloads the scripts from `TTS_REPO_URL` (set by configure.sh).

### Data Flow

```
install.sh → downloads → configure.sh → installs → S99trusttunnel + 010-trusttunnel.sh
                                       → generates → mode.conf
                                       → downloads → trusttunnel_client binary
```

### Key Runtime Paths on Router

- Client binary: `/opt/trusttunnel_client/trusttunnel_client`
- Client config: `/opt/trusttunnel_client/trusttunnel_client.toml`
- Mode config: `/opt/trusttunnel_client/mode.conf`
- tt-stats backup / log: `/opt/trusttunnel_client/backup-classic/`, `/opt/var/log/tt-stats.log`
- Log file: `/opt/var/log/trusttunnel.log` (512KB rotation)
- PID files: `/opt/var/run/trusttunnel.pid`, `trusttunnel_watchdog.pid`

## Shell Scripting Conventions

- All scripts must be **POSIX sh compatible** — no bashisms
- Use `#!/opt/bin/sh` shebang for router scripts (Entware path)
- Process management uses PID files with SIGTERM/SIGKILL fallback pattern
- Error cleanup via `trap` handlers
- Interface index detection parses `ndmc -c 'show interface'` output
- Before publishing, run `shellcheck -s sh` on all scripts and `sh -n` under BusyBox ash on a router
- Anything that changes a working router must keep an automatic rollback path

## Release Process

Push a tag matching `v*` (e.g., `v1.0.0`) to trigger the GitHub Actions workflow (`.github/workflows/release.yml`) which creates a GitHub Release with auto-generated notes via `softprops/action-gh-release@v2`.

## Service Control (on router)

```sh
/opt/etc/init.d/S99trusttunnel start|stop|restart|reload|status|check
```

- `reload` — soft restart: kills the client process, watchdog detects it and respawns. Falls back to full `restart` if watchdog is dead.
- `check` — conditional reload: calls `reload` only if the client is not running (not the same as `status`)
