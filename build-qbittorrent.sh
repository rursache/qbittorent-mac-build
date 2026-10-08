#!/bin/bash
set -euo pipefail

# Wrapped in main() so `curl | bash` parses the whole script before running anything:
# a truncated download fails instead of running half, and no command can eat the rest from stdin
main() {

# =============================================================================
# Build qBittorrent for macOS from source
# Produces: qBittorrent.app next to this script, or in the current directory when piped
#
# Usage:   ./build-qbittorrent.sh                          # builds latest release tag
#          ./build-qbittorrent.sh --master                 # builds master branch
#          ./build-qbittorrent.sh --master --spoof 5.0.5   # builds master, trackers see 5.0.5
#          ./build-qbittorrent.sh --libtorrent 2.1.2       # pins a specific libtorrent version
# Prereqs: Xcode CLI tools, Homebrew
# Time:    ~1.5 minutes on Apple Silicon (M4), a bit more with --master
# =============================================================================

START_TIME=$(date +%s)
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # Piped from curl, put the app in the caller's cwd
    OUTPUT_DIR="$PWD"
fi
NPROC=$(sysctl -n hw.ncpu)
LIBTORRENT_VERSION="v2.0.15"     # fallback
QBITTORRENT_TAG="release-5.2.4"  # fallback

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Parse arguments
USE_MASTER=false
SPOOF_VERSION=""
LIBTORRENT_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --master)
            USE_MASTER=true
            shift
            ;;
        --spoof)
            shift
            SPOOF_VERSION="${1:-}"
            # Each part ends up as a C++ literal and a single peer ID char (0-9, A-Z), so 0-35 without leading zeros
            if ! [[ "$SPOOF_VERSION" =~ ^(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]] \
                || (( BASH_REMATCH[1] > 35 || BASH_REMATCH[2] > 35 || BASH_REMATCH[3] > 35 )); then
                echo "Error: --spoof requires X.Y.Z with each part 0-35 and no leading zeros (e.g. 5.0.5)"
                exit 1
            fi
            shift
            ;;
        --libtorrent)
            shift
            LIBTORRENT_OVERRIDE="${1:-}"
            LIBTORRENT_OVERRIDE="${LIBTORRENT_OVERRIDE#v}"
            if ! [[ "$LIBTORRENT_OVERRIDE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "Error: --libtorrent requires a version in X.Y.Z format (e.g. 2.1.2)"
                exit 1
            fi
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: build-qbittorrent.sh [--master] [--spoof X.Y.Z] [--libtorrent X.Y.Z]"
            exit 1
            ;;
    esac
done

if $USE_MASTER; then
    QBITTORRENT_CLONE_ARGS=(--depth 1 --branch master)
    info_branch="master"
else
    # Fetch the latest stable release-* tag from GitHub
    LATEST_TAG=$(git ls-remote --tags --sort=-v:refname \
        https://github.com/qbittorrent/qBittorrent.git 'refs/tags/release-*' \
        | sed 's|.*/||' | awk '/^release-[0-9]+\.[0-9]+\.[0-9]+$/ && !found { print; found=1 }') || true
    if [[ -n "$LATEST_TAG" ]]; then
        QBITTORRENT_TAG="$LATEST_TAG"
    else
        warn "Could not look up the latest qBittorrent tag, using fallback $QBITTORRENT_TAG"
    fi
    QBITTORRENT_CLONE_ARGS=(--depth 1 --branch "$QBITTORRENT_TAG")
    info_branch="$QBITTORRENT_TAG"
fi

# Pick libtorrent: explicit --libtorrent wins, master gets the latest 2.x,
# release tags stay on 2.0.x which is what qBittorrent release CI tests against
if [[ -n "$LIBTORRENT_OVERRIDE" ]]; then
    LIBTORRENT_VERSION="v$LIBTORRENT_OVERRIDE"
else
    if $USE_MASTER; then
        LT_PATTERN='^v2\.[0-9]+\.[0-9]+$'
    else
        LT_PATTERN='^v2\.0\.[0-9]+$'
    fi
    LATEST_LT=$(git ls-remote --tags --sort=-v:refname \
        https://github.com/arvidn/libtorrent.git 'refs/tags/v2.*' \
        | sed 's|.*/||' | awk -v re="$LT_PATTERN" '$0 ~ re && !found { print; found=1 }') || true
    if [[ -n "$LATEST_LT" ]]; then
        LIBTORRENT_VERSION="$LATEST_LT"
    else
        warn "Could not look up the latest libtorrent tag, using fallback $LIBTORRENT_VERSION"
    fi
fi

# -----------------------------------------------------------------------------
# Step 1: Install Homebrew dependencies
# -----------------------------------------------------------------------------
if [[ -n "$SPOOF_VERSION" ]]; then
    info "Building qBittorrent: $info_branch with libtorrent $LIBTORRENT_VERSION (tracker spoof: $SPOOF_VERSION)"
else
    info "Building qBittorrent: $info_branch with libtorrent $LIBTORRENT_VERSION"
fi
info "Step 1/5: Installing Homebrew dependencies..."

# Only the Qt modules qBittorrent uses, the `qt` meta formula pulls in ~80 formulae including QtWebEngine
BREW_DEPS=(cmake ninja qtbase qtsvg qttools qttranslations openssl@3 zlib boost pkg-config)
HOMEBREW_PREFIX="$(brew --prefix)"
MISSING_DEPS=()
for dep in "${BREW_DEPS[@]}"; do
    # opt/ links exist for every installed formula, checking them is much faster than `brew list`
    [[ -d "$HOMEBREW_PREFIX/opt/$dep" ]] || MISSING_DEPS+=("$dep")
done
if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    info "  Installing: ${MISSING_DEPS[*]}"
    brew install "${MISSING_DEPS[@]}" </dev/null
else
    info "  All dependencies already installed"
fi

OPENSSL_PREFIX="$HOMEBREW_PREFIX/opt/openssl@3"
ZLIB_PREFIX="$HOMEBREW_PREFIX/opt/zlib"
BOOST_PREFIX="$HOMEBREW_PREFIX/opt/boost"
QT_BIN="$HOMEBREW_PREFIX/opt/qtbase/bin"
# Split Qt kegs are all linked into one cmake dir, Qt6Config finds Svg/LinguistTools next to it
QT6_DIR="$HOMEBREW_PREFIX/lib/cmake/Qt6"
[[ -f "$QT6_DIR/Qt6Config.cmake" ]] || error "Qt CMake files missing in $QT6_DIR, run: brew link qtbase qtsvg qttools"

info "  Qt:      $QT6_DIR"
info "  OpenSSL: $OPENSSL_PREFIX"
info "  Boost:   $BOOST_PREFIX"

# -----------------------------------------------------------------------------
# Step 2: Set up work directory
# -----------------------------------------------------------------------------
WORKDIR="$(mktemp -d -t qbt-build)"
trap 'cd /; rm -rf "$WORKDIR"' EXIT
trap 'exit 130' INT TERM
info "Step 2/5: Setting up build directory at $WORKDIR"
cd "$WORKDIR"

# Fetch qBittorrent first so a bad tag or a failed spoof patch stops before anything compiles
git clone "${QBITTORRENT_CLONE_ARGS[@]}" \
    https://github.com/qbittorrent/qBittorrent.git "$WORKDIR/qBittorrent"

# Patch tracker-reported version if --spoof is set
# This only changes the peer_fingerprint (peer ID) and HTTP user_agent sent to
# trackers, the About dialog and all other UI keep showing the real version
if [[ -n "$SPOOF_VERSION" ]]; then
    info "  Patching tracker version to $SPOOF_VERSION..."
    SPOOF_MAJOR="${SPOOF_VERSION%%.*}"
    SPOOF_REST="${SPOOF_VERSION#*.}"
    SPOOF_MINOR="${SPOOF_REST%%.*}"
    SPOOF_BUGFIX="${SPOOF_REST#*.}"

    SESSION_FILE="$WORKDIR/qBittorrent/src/base/bittorrent/sessionimpl.cpp"

    # sed exits 0 even when nothing matches, so make sure upstream still has the code we patch
    grep -qF 'generate_fingerprint(PEER_ID, QBT_VERSION_MAJOR, QBT_VERSION_MINOR, QBT_VERSION_BUGFIX, QBT_VERSION_BUILD)' "$SESSION_FILE" \
        || error "Cannot spoof: peer fingerprint code not found in sessionimpl.cpp, upstream changed it"
    grep -qF 'QStringLiteral("qBittorrent/" QBT_VERSION_2)' "$SESSION_FILE" \
        || error "Cannot spoof: user agent code not found in sessionimpl.cpp, upstream changed it"

    # Replace peer fingerprint: generate_fingerprint("qB", MAJOR, MINOR, BUGFIX, BUILD)
    # with hardcoded spoofed values
    sed -i '' -E \
        "s|generate_fingerprint\(PEER_ID, QBT_VERSION_MAJOR, QBT_VERSION_MINOR, QBT_VERSION_BUGFIX, QBT_VERSION_BUILD\)|generate_fingerprint(PEER_ID, ${SPOOF_MAJOR}, ${SPOOF_MINOR}, ${SPOOF_BUGFIX}, 0)|" \
        "$SESSION_FILE"

    # Replace user-agent: "qBittorrent/" QBT_VERSION_2 becomes "qBittorrent/SPOOF_VERSION"
    sed -i '' -E \
        "s|QStringLiteral\(\"qBittorrent/\" QBT_VERSION_2\)|QStringLiteral(\"qBittorrent/${SPOOF_VERSION}\")|" \
        "$SESSION_FILE"

    info "  Peer ID spoofed to: qB ${SPOOF_MAJOR}.${SPOOF_MINOR}.${SPOOF_BUGFIX}.0"
    info "  User-Agent spoofed to: qBittorrent/${SPOOF_VERSION}"
fi

# -----------------------------------------------------------------------------
# Step 3: Build libtorrent-rasterbar (static)
# -----------------------------------------------------------------------------
info "Step 3/5: Building libtorrent-rasterbar $LIBTORRENT_VERSION (static)..."

# The release tarball already includes submodules and is far smaller than a recursive clone
LT_TARBALL="https://github.com/arvidn/libtorrent/releases/download/$LIBTORRENT_VERSION/libtorrent-rasterbar-${LIBTORRENT_VERSION#v}.tar.gz"
mkdir -p "$WORKDIR/libtorrent"
if ! curl -fsSL --retry 3 "$LT_TARBALL" | tar -xz -C "$WORKDIR/libtorrent" --strip-components=1; then
    warn "libtorrent release tarball unavailable, falling back to git clone"
    rm -rf "$WORKDIR/libtorrent"
    git clone --branch "$LIBTORRENT_VERSION" --depth 1 --recurse-submodules \
        https://github.com/arvidn/libtorrent.git "$WORKDIR/libtorrent"
fi

# -w silences libtorrent's -Weverything, which otherwise floods the terminal with ~1000 warnings
cmake -S "$WORKDIR/libtorrent" -B "$WORKDIR/libtorrent/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_CXX_FLAGS="-w" \
    -DCMAKE_INSTALL_PREFIX="$WORKDIR/libtorrent-install" \
    -DCMAKE_PREFIX_PATH="$OPENSSL_PREFIX;$BOOST_PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -Ddeprecated-functions=OFF

cmake --build "$WORKDIR/libtorrent/build" --parallel "$NPROC"
cmake --install "$WORKDIR/libtorrent/build"

# -----------------------------------------------------------------------------
# Step 4: Build qBittorrent
# -----------------------------------------------------------------------------
info "Step 4/5: Building qBittorrent ($info_branch)..."

# libtorrent-install goes first so a Homebrew libtorrent-rasterbar never wins, and the Homebrew
# prefix itself stays out so /opt/homebrew/lib/libssl (possibly openssl@4) is not picked up
cmake -S "$WORKDIR/qBittorrent" -B "$WORKDIR/qBittorrent/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$WORKDIR/libtorrent-install;$OPENSSL_PREFIX;$BOOST_PREFIX;$ZLIB_PREFIX" \
    -DQt6_DIR="$QT6_DIR" \
    -DGUI=ON \
    -DTESTING=OFF

cmake --build "$WORKDIR/qBittorrent/build" --parallel "$NPROC"

APP_PATH="$WORKDIR/qBittorrent/build/qbittorrent.app"

if [[ ! -d "$APP_PATH" ]]; then
    error "Build failed, qbittorrent.app not found at $APP_PATH"
fi

info "  Build successful: $APP_PATH"

# -----------------------------------------------------------------------------
# Step 5: Bundle into standalone .app
# -----------------------------------------------------------------------------
info "Step 5/5: Bundling with macdeployqt and ad-hoc signing..."

# Deploy only the plugins qBittorrent uses. Left alone, macdeployqt copies every plugin in Homebrew's
# shared plugin dir and cannot resolve split-keg frameworks like QtSvg, so the app falls back to /opt/homebrew
QT_PLUGINS="$("$QT_BIN/qtpaths6" --query QT_INSTALL_PLUGINS)"
QT_PLUGIN_LIST=(
    platforms/libqcocoa
    styles/libqmacstyle
    iconengines/libqsvgicon
    imageformats/libqsvg
    imageformats/libqico
    imageformats/libqicns
    imageformats/libqjpeg
    imageformats/libqgif
    tls/libqopensslbackend
    tls/libqsecuretransportbackend
    tls/libqcertonlybackend
    sqldrivers/libqsqlite
    networkinformation/libqapplenetworkinformation
)
[[ -f "$QT_PLUGINS/platforms/libqcocoa.dylib" ]] || error "Qt cocoa platform plugin not found in $QT_PLUGINS"
DEPLOY_ARGS=()
for plugin in "${QT_PLUGIN_LIST[@]}"; do
    src="$QT_PLUGINS/$plugin.dylib"
    [[ -f "$src" ]] || continue
    mkdir -p "$APP_PATH/Contents/PlugIns/${plugin%/*}"
    install -m 644 "$src" "$APP_PATH/Contents/PlugIns/$plugin.dylib"
    DEPLOY_ARGS+=("-executable=$APP_PATH/Contents/PlugIns/$plugin.dylib")
done

"$QT_BIN/macdeployqt" "$APP_PATH" -no-plugins -no-strip -no-codesign "${DEPLOY_ARGS[@]}"

# One deep ad-hoc sign instead of macdeployqt spawning codesign per binary
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

FINAL_APP="$OUTPUT_DIR/qBittorrent.app"
rm -rf "$FINAL_APP"
mv "$APP_PATH" "$FINAL_APP"

# -----------------------------------------------------------------------------
# Done!
# -----------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START_TIME ))
MINS=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))

echo ""
info "========================================"
info "  Build complete! (${MINS}m ${SECS}s)"
info "========================================"
info ""
info "  .app: $FINAL_APP"
if [[ -n "$SPOOF_VERSION" ]]; then
    info "  Tracker version: $SPOOF_VERSION (spoofed)"
fi
info ""
info "  To install:"
info "    rm -rf /Applications/qBittorrent.app && cp -R \"$FINAL_APP\" /Applications/"
info ""
# The EXIT trap removes the build directory

}

main "$@"
