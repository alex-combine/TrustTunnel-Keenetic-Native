# TrustTunnel client with auth key support for MIPS routers

[🇷🇺 Русский](README_ru.md)

**Why.** In TrustTunnel 1.3 a server can let in only clients with an auth key (`client_random_auth_key`). The official clients for MIPS CPUs are built with OpenSSL, while the auth key code is enabled only with BoringSSL. So these clients **silently ignore** the key, and a server that requires it will not let the router in. This build is for MIPS little-endian (mipsel) — most Keenetic models; there is none for MIPS big-endian (`mips`) yet, and the ARM and x86 clients do not need it.

**What was done.** The same client sources (`7bde23f`, 1.3.0 + 2 commits) with two small patches:

- OpenSSL 4.0.2: `SSL_set_custom_client_random()` — a caller-supplied 32-byte ClientRandom in the ClientHello, TLS 1.3 only (as in AdGuard's BoringSSL patch), and `HKDF()` with BoringSSL's argument order;
- the client: the auth key code is built with OpenSSL.

Both went through four rounds of external code review and were checked live: with the right key the server accepts the client without an error, and it recognizes a wrong key (`validation failed` in its log; whether such a client gets in is up to the server rule).

> **The feature is new: so far it was checked on one router.** It is installed with automatic rollback.

## Install

The installer offers the build on a router that needs it (the default answer is "no"). By hand:

```bash
tt-stats keybuild            # what is installed and whether this router needs the build
tt-stats keybuild install    # install
tt-stats keybuild revert     # put the previous client back
```

`install` downloads `trusttunnel_client-authkey-mipsel` from the release, checks its `sha256`, test-starts it on the router, keeps the previous client in `/opt/trusttunnel_client/trusttunnel_client.official`, swaps the client and restarts the VPN. If the VPN does not come up in 90 seconds or fails 4 checks in a row in the next 10 minutes, the previous client comes back by itself. You can close SSH.

Then add the key to `[endpoint]` of the client config with `tt-stats apply` (it rolls back by itself too):

```bash
cp /opt/trusttunnel_client/trusttunnel_client.toml /opt/tmp/new.toml
# in /opt/tmp/new.toml, [endpoint]: client_random_auth_key = "<the key from the server, 64 hex>"
tt-stats apply /opt/tmp/new.toml
tt-stats selftest            # "auth key: set, this client build supports it"
```

Have your own build? `tt-stats keybuild install /path/to/file` (put `file.sha256` next to it, optionally).

## Build it yourself

Linux x86_64, about 10 GB of disk, about 45 minutes on 2 cores (measured, without the zig download). Needs `git`, `curl`, `python3`, `make`, `file` and `mipsel-linux-gnu-strip` (Debian/Ubuntu: `apt install binutils-mipsel-linux-gnu`). The script fetches the rest: zig 0.17.1 (checksum verified), Rust 1.95 + nightly with `rust-src`, conan 2.34, cmake, ninja.

```bash
./build.sh /path/to/workdir
```

If ziglang.org is slow (the script makes up to 10 tries and resumes), get `zig-x86_64-linux-0.17.1.tar.xz` another way and put it as `<workdir>/tools/zig.tar.xz`: the script resumes it and verifies the checksum.

The result is `trusttunnel_client-authkey-mipsel` + `.sha256`. Its checksum will not match the release file: the binary contains the paths of the work folder. Check: the binary does **not** contain `SSL_set_custom_client_random is unavailable` (only builds without key support do).

## Licenses

TrustTunnel client and OpenSSL — Apache License 2.0 ([LICENSE-Apache-2.0](LICENSE-Apache-2.0)); what was modified is in [NOTICE](NOTICE), the full diffs in [patches/](patches/).
