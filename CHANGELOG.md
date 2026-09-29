# Changelog

## v2.0.0 — dashboard statistics (attach mode)

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
