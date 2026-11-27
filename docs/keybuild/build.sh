#!/bin/bash
# Build the TrustTunnel client for Keenetic MIPS (mipsel) routers with auth key support.
# Usage: ./build.sh [WORKDIR]   (default ./work; needs Linux x86_64, ~25 GB, 1-2 hours on 2 cores)
# Needs: git, curl, python3 (venv), make, file, sha256sum, and mipsel-linux-gnu-strip
#        (Debian/Ubuntu: apt install binutils-mipsel-linux-gnu)
set -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mkdir -p "${1:-./work}" && cd "${1:-./work}" && pwd)
CLIENT_REPO="https://github.com/TrustTunnel/TrustTunnelClient.git"
CLIENT_COMMIT="7bde23f"          # 1.3.0 + 2 commits, the sources of the released build
ZIG_VER="0.17.1"; ZIG_SHA="3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a"
RUST_VER="1.95"; JOBS="${JOBS:-2}"
step() { echo "=== $(date +%T) $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
command -v mipsel-linux-gnu-strip >/dev/null || die "mipsel-linux-gnu-strip not found (apt install binutils-mipsel-linux-gnu)"

step "1 tools: zig $ZIG_VER, Rust $RUST_VER + nightly rust-src, conan/cmake/ninja"
mkdir -p "$W/tools" && cd "$W/tools" || exit 1
if [ ! -x zig/zig ]; then
    # ziglang.org can be slow or stall: resume, give up on a stalled try after 30 s, up to 10 tries
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        curl -fsSL -C - --speed-limit 1000 --speed-time 30 -o zig.tar.xz \
            "https://ziglang.org/download/$ZIG_VER/zig-x86_64-linux-$ZIG_VER.tar.xz" && \
            echo "$ZIG_SHA  zig.tar.xz" | sha256sum -c --quiet 2>/dev/null && break
        echo "zig download try $_i failed, retrying..."; sleep 5
    done
    echo "$ZIG_SHA  zig.tar.xz" | sha256sum -c --quiet || die "zig download or checksum failed"
    tar -xf zig.tar.xz && rm zig.tar.xz && ln -sfn "zig-x86_64-linux-$ZIG_VER" zig
fi
[ -x venv/bin/conan ] || { python3 -m venv venv && venv/bin/pip install -q "conan==2.34.0" cmake ninja pyyaml tqdm; } || die "python tools"
export RUSTUP_HOME="$W/tools/rustup" CARGO_HOME="$W/tools/cargo"
if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
    curl -fsSL https://sh.rustup.rs -o rustup-init.sh && \
    sh rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain "$RUST_VER" || die "rustup"
    "$CARGO_HOME/bin/rustup" toolchain install nightly --profile minimal --component rust-src || die "nightly"
fi
export PATH="$W/tools/zig:$W/tools/venv/bin:$CARGO_HOME/bin:$PATH"
export CONAN_HOME="$W/conan_home" CMAKE_BUILD_PARALLEL_LEVEL="$JOBS" CMAKE_POLICY_VERSION_MINIMUM=3.5

step "2 client sources at $CLIENT_COMMIT"
[ -d "$W/TrustTunnelClient/.git" ] || git clone -q "$CLIENT_REPO" "$W/TrustTunnelClient" || die "clone"
cd "$W/TrustTunnelClient" && git fetch -q --tags origin && git checkout -q "$CLIENT_COMMIT" || die "checkout"
for f in "$HERE"/patches/client-*.patch; do
    git apply --reverse --check "$f" 2>/dev/null && continue
    git apply "$f" || die "client patch $(basename "$f")"
done

step "3 conan profile and AdGuard recipes"
mkdir -p "$CONAN_HOME"
[ -f "$CONAN_HOME/profiles/default" ] || conan profile detect >/dev/null || die "conan profile"
grep -q BROKEN_CLANG_ATOMICS "$CONAN_HOME/profiles/default" || printf '\n[conf]\n# 32-bit MIPS: no __atomic_is_lock_free in zig compiler-rt; OpenSSL uses its lock fallback\nopenssl/*:tools.build:cflags=["-DBROKEN_CLANG_ATOMICS"]\n' >> "$CONAN_HOME/profiles/default"
printf 'tools.build:jobs=%s\n' "$JOBS" > "$CONAN_HOME/global.conf"
./scripts/bootstrap_conan_deps.py > "$W/log_bootstrap.txt" 2>&1 || die "bootstrap, see $W/log_bootstrap.txt"

step "4 OpenSSL recipe + our patch"
REV=$(conan list 'openssl/4.0.2@adguard/oss#*' --format=json | python3 -c 'import json,sys; d=json.load(sys.stdin)["Local Cache"]["openssl/4.0.2@adguard/oss"]["revisions"]; print(max(d, key=lambda k: d[k]["timestamp"]))') || die "recipe revision"
EXP=$(conan cache path "openssl/4.0.2@adguard/oss#$REV") && ESRC=$(conan cache path --folder export_source "openssl/4.0.2@adguard/oss#$REV") || die "recipe path"
R="$W/openssl-recipe"; rm -rf "$R" && mkdir -p "$R" && cp -a "$EXP"/. "$R"/ && cp -a "$ESRC"/. "$R"/ || die "recipe copy"
cp "$HERE"/patches/openssl-*.patch "$R/patches/" || die "openssl patch"
[ "$(ls "$R/patches" | wc -l)" -eq 2 ] || die "expected the AdGuard MIPS patch + ours, got: $(ls "$R/patches")"
(cd "$R" && conan export . --version 4.0.2 --user adguard --channel oss) || die "recipe export"

step "5 build (musl-cross-mipsel)"
rm -rf cmake-build-musl-cross-mipsel-relwithdebinfo
make PRESET=musl-cross-mipsel-relwithdebinfo SKIP_BOOTSTRAP=1 all > "$W/log_build.txt" 2>&1 || die "build, see $W/log_build.txt"
B=cmake-build-musl-cross-mipsel-relwithdebinfo/trusttunnel/trusttunnel_client
mipsel-linux-gnu-strip -o "$W/trusttunnel_client-authkey-mipsel" "$B" || die "strip"
grep -q 'SSL_set_custom_client_random is unavailable' "$W/trusttunnel_client-authkey-mipsel" && die "the build has no auth key support"
(cd "$W" && sha256sum trusttunnel_client-authkey-mipsel > trusttunnel_client-authkey-mipsel.sha256)
file "$W/trusttunnel_client-authkey-mipsel"; cat "$W/trusttunnel_client-authkey-mipsel.sha256"
echo "Install on the router: tt-stats keybuild install /opt/tmp/trusttunnel_client-authkey-mipsel"
