#!/bin/bash
set -euo pipefail

# =============================================================================
# Build qBittorrent for macOS from source
# Produces: qBittorrent.app next to this script
#
# Usage:   ./build-qbittorrent.sh                          # builds latest release tag
#          ./build-qbittorrent.sh --master                 # builds master branch
#          ./build-qbittorrent.sh --master --spoof 5.0.5   # builds master, trackers see 5.0.5
# Prereqs: Xcode CLI tools, Homebrew
# Time:    ~2-3 minutes on Apple Silicon (M4)
# =============================================================================

START_TIME=$(date +%s)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
NPROC=$(sysctl -n hw.ncpu)
WORKDIR="$(pwd)/qbt-build"
LIBTORRENT_VERSION="v2.0.11"  # fallback
QBITTORRENT_TAG="release-5.1.4"  # fallback

# Parse arguments
USE_MASTER=false
SPOOF_VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --master)
            USE_MASTER=true
            shift
            ;;
        --spoof)
            shift
            SPOOF_VERSION="${1:-}"
            if [[ -z "$SPOOF_VERSION" ]] || ! [[ "$SPOOF_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "Error: --spoof requires a version in X.Y.Z format (e.g. 5.0.5)"
                exit 1
            fi
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--master] [--spoof X.Y.Z]"
            exit 1
            ;;
    esac
done

if $USE_MASTER; then
    QBITTORRENT_BRANCH="master"
    QBITTORRENT_CLONE_ARGS=(--depth 1 --branch master)
    info_branch="master"
else
    # Fetch the latest release-* tag from GitHub
    LATEST_TAG=$(git ls-remote --tags --sort=-v:refname \
        https://github.com/qbittorrent/qBittorrent.git 'refs/tags/release-*' \
        | head -n1 | sed 's|.*/||')
    if [ -n "$LATEST_TAG" ]; then
        QBITTORRENT_TAG="$LATEST_TAG"
    fi
    QBITTORRENT_BRANCH="$QBITTORRENT_TAG"
    QBITTORRENT_CLONE_ARGS=(--depth 1 --branch "$QBITTORRENT_TAG")
    info_branch="$QBITTORRENT_TAG"
fi

# Fetch the latest libtorrent 2.0.x tag from GitHub
LATEST_LT=$(git ls-remote --tags --sort=-v:refname \
    https://github.com/arvidn/libtorrent.git 'refs/tags/v2.0.*' \
    | grep -v '\^{}' | head -n1 | sed 's|.*/||')
if [ -n "$LATEST_LT" ]; then
    LIBTORRENT_VERSION="$LATEST_LT"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# -----------------------------------------------------------------------------
# Step 1: Install Homebrew dependencies
# -----------------------------------------------------------------------------
if [[ -n "$SPOOF_VERSION" ]]; then
    info "Building qBittorrent: $info_branch (tracker spoof: $SPOOF_VERSION)"
else
    info "Building qBittorrent: $info_branch"
fi
info "Step 1/5: Installing Homebrew dependencies..."

BREW_DEPS="cmake ninja qt openssl@3 zlib boost pkg-config"
for dep in $BREW_DEPS; do
    if brew list "$dep" &>/dev/null; then
        info "  $dep already installed"
    else
        info "  Installing $dep..."
        brew install "$dep"
    fi
done

# Resolve Homebrew paths
QT_PREFIX="$(brew --prefix qt)"
OPENSSL_PREFIX="$(brew --prefix openssl@3)"
ZLIB_PREFIX="$(brew --prefix zlib)"
BOOST_PREFIX="$(brew --prefix boost)"

info "  Qt:      $QT_PREFIX"
info "  OpenSSL: $OPENSSL_PREFIX"
info "  Boost:   $BOOST_PREFIX"

# -----------------------------------------------------------------------------
# Step 2: Set up work directory
# -----------------------------------------------------------------------------
info "Step 2/5: Setting up build directory at $WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# -----------------------------------------------------------------------------
# Step 3: Build libtorrent-rasterbar (static)
# -----------------------------------------------------------------------------
info "Step 3/5: Building libtorrent-rasterbar $LIBTORRENT_VERSION (static)..."

git clone --branch "$LIBTORRENT_VERSION" --depth 1 --recurse-submodules \
    https://github.com/arvidn/libtorrent.git "$WORKDIR/libtorrent"

cmake -S "$WORKDIR/libtorrent" -B "$WORKDIR/libtorrent/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_INSTALL_PREFIX="$WORKDIR/libtorrent-install" \
    -DCMAKE_PREFIX_PATH="$OPENSSL_PREFIX;$BOOST_PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -Ddeprecated-functions=OFF

cmake --build "$WORKDIR/libtorrent/build" --parallel "$NPROC"
cmake --install "$WORKDIR/libtorrent/build"

# -----------------------------------------------------------------------------
# Step 4: Clone and build qBittorrent
# -----------------------------------------------------------------------------
info "Step 4/5: Building qBittorrent ($info_branch)..."

git clone "${QBITTORRENT_CLONE_ARGS[@]}" \
    https://github.com/qbittorrent/qBittorrent.git "$WORKDIR/qBittorrent"

# Patch tracker-reported version if --spoof is set
# This only changes the peer_fingerprint (peer ID) and HTTP user_agent sent to
# trackers. The About dialog and all other UI keep showing the real version.
if [[ -n "$SPOOF_VERSION" ]]; then
    info "  Patching tracker version to $SPOOF_VERSION..."
    SPOOF_MAJOR="${SPOOF_VERSION%%.*}"
    SPOOF_REST="${SPOOF_VERSION#*.}"
    SPOOF_MINOR="${SPOOF_REST%%.*}"
    SPOOF_BUGFIX="${SPOOF_REST#*.}"

    SESSION_FILE="$WORKDIR/qBittorrent/src/base/bittorrent/sessionimpl.cpp"

    # Replace peer fingerprint: generate_fingerprint("qB", MAJOR, MINOR, BUGFIX, BUILD)
    # with hardcoded spoofed values
    sed -i '' -E \
        "s|generate_fingerprint\(PEER_ID, QBT_VERSION_MAJOR, QBT_VERSION_MINOR, QBT_VERSION_BUGFIX, QBT_VERSION_BUILD\)|generate_fingerprint(PEER_ID, ${SPOOF_MAJOR}, ${SPOOF_MINOR}, ${SPOOF_BUGFIX}, 0)|" \
        "$SESSION_FILE"

    # Replace user-agent: "qBittorrent/" QBT_VERSION_2 → "qBittorrent/SPOOF_VERSION"
    sed -i '' -E \
        "s|QStringLiteral\(\"qBittorrent/\" QBT_VERSION_2\)|QStringLiteral(\"qBittorrent/${SPOOF_VERSION}\")|" \
        "$SESSION_FILE"

    info "  Peer ID spoofed to: qB ${SPOOF_MAJOR}.${SPOOF_MINOR}.${SPOOF_BUGFIX}.0"
    info "  User-Agent spoofed to: qBittorrent/${SPOOF_VERSION}"
fi

cmake -S "$WORKDIR/qBittorrent" -B "$WORKDIR/qBittorrent/build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX;$OPENSSL_PREFIX;$BOOST_PREFIX;$ZLIB_PREFIX;$WORKDIR/libtorrent-install" \
    -DGUI=ON \
    -DTESTING=OFF

cmake --build "$WORKDIR/qBittorrent/build" --parallel "$NPROC"

APP_PATH="$WORKDIR/qBittorrent/build/qbittorrent.app"

if [ ! -d "$APP_PATH" ]; then
    error "Build failed — qbittorrent.app not found at $APP_PATH"
fi

info "  Build successful: $APP_PATH"

# -----------------------------------------------------------------------------
# Step 5: Bundle into standalone .app
# -----------------------------------------------------------------------------
info "Step 5/5: Bundling with macdeployqt and ad-hoc signing..."

"$QT_PREFIX/bin/macdeployqt" "$APP_PATH" -no-strip -always-overwrite

# Ad-hoc sign so macOS allows the app to run
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

# Copy .app next to the build script
FINAL_APP="$SCRIPT_DIR/qBittorrent.app"
rm -rf "$FINAL_APP"
cp -R "$APP_PATH" "$FINAL_APP"

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
info "    cp -R \"$FINAL_APP\" /Applications/"
info ""

# Cleanup build directory
info "Cleaning up build directory..."
rm -rf "$WORKDIR"
