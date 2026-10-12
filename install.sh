#!/bin/sh

set -e

GITHUB_REPO="alex-combine/TrustTunnel-Keenetic-Native"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}"
FALLBACK_REF="main"

# --- Version determination ---
RELEASE_TAG=""
TT_LANG="${TT_LANG:-}"

# Support --version <tag> flag
while [ $# -gt 0 ]; do
    case "$1" in
        --dev)
            RELEASE_TAG="main"
            shift
            ;;
        --version)
            shift
            RELEASE_TAG="$1"
            shift
            ;;
        --lang=*)
            TT_LANG="${1#--lang=}"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# --- Language: Russian or English for the whole installer ---
if [ "$TT_LANG" != ru ] && [ "$TT_LANG" != en ]; then
    printf "Язык / Language: 1) Русский  2) English [1]: "
    if read lang_choice < /dev/tty 2>/dev/null; then
        case "$lang_choice" in 2|en|EN|e|E) TT_LANG=en ;; *) TT_LANG=ru ;; esac
    else
        echo ""; TT_LANG=en
    fi
fi
L() { if [ "$TT_LANG" = ru ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

if [ -n "$RELEASE_TAG" ]; then
    echo "$(L 'Выбрана версия' 'Version specified'): ${RELEASE_TAG}"
else
    # Auto-detect latest release via GitHub API
    API_RESPONSE=$(curl -fsSL --connect-timeout 10 --max-time 15 \
        "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null) || API_RESPONSE=""
    RELEASE_TAG=$(echo "$API_RESPONSE" | grep '"tag_name"' | \
        sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
fi

if [ -n "$RELEASE_TAG" ]; then
    REPO_URL="${RAW_BASE}/${RELEASE_TAG}"
    echo "=== $(L 'Установщик TrustTunnel для Keenetic' 'TrustTunnel Installer for Keenetic') (${RELEASE_TAG}) ==="
else
    echo "$(L 'Внимание: не удалось узнать последний выпуск. Беру ветку' 'Warning: failed to determine the latest release. Using branch') ${FALLBACK_REF}."
    REPO_URL="${RAW_BASE}/${FALLBACK_REF}"
    echo "=== $(L 'Установщик TrustTunnel для Keenetic' 'TrustTunnel Installer for Keenetic') (${FALLBACK_REF}) ==="
fi
echo ""

# --- Download and run configure.sh from release ---
CONFIGURE_SCRIPT=$(mktemp /tmp/tt_configure.XXXXXX)
trap "rm -f '$CONFIGURE_SCRIPT'" EXIT

echo "$(L 'Скачиваю скрипт настройки...' 'Downloading configuration script...')"
# Releases carry the scripts as assets (since v2.0.1): GitHub counts their downloads,
# which is the only install statistics. Nothing about the router is sent anywhere.
if [ -n "$RELEASE_TAG" ] && [ "$RELEASE_TAG" != "main" ] && \
   curl -fsSL "https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/configure.sh" \
        -o "$CONFIGURE_SCRIPT" 2>/dev/null; then
    REPO_URL="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}"
else
    curl -fsSL "$REPO_URL/configure.sh" -o "$CONFIGURE_SCRIPT"
fi
chmod +x "$CONFIGURE_SCRIPT"

REPO_URL="$REPO_URL" TT_LANG="$TT_LANG" sh "$CONFIGURE_SCRIPT"
