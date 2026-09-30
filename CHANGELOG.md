# Changelog

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
