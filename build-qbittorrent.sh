#!/bin/bash
set -euo pipefail

main() {

START_TIME=$(date +%s)
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    OUTPUT_DIR="$PWD"
fi
NPROC=$(sysctl -n hw.ncpu)
ARCH=$(uname -m)
LIBTORRENT_VERSION="v2.0.15"
QBITTORRENT_TAG="release-5.3.0"
QT_VERSION="6.12.0"
BOOST_VERSION="1.92.0"
OPENSSL_VERSION="3.6.5"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

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
            if ! [[ "$SPOOF_VERSION" =~ ^(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]] \
                || (( BASH_REMATCH[1] > 35 || BASH_REMATCH[2] > 35 || BASH_REMATCH[3] > 35 )); then
                echo "Error: --spoof requires X.Y.Z with each part 0-35 and no leading zeros (e.g. 5.3.0)"
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

xcode-select -p >/dev/null 2>&1 && xcrun --find clang >/dev/null 2>&1 \
    || error "Xcode Command Line Tools are missing, run: xcode-select --install"
/usr/bin/python3 -c 'import venv' >/dev/null 2>&1 \
    || error "/usr/bin/python3 is not usable, reinstall the Command Line Tools: xcode-select --install"

WORKDIR="$(mktemp -d -t qbt-build)"
TOOLS="$WORKDIR/tools"
DEPS="$WORKDIR/deps"
LOGS="$WORKDIR/logs"
mkdir -p "$DEPS" "$LOGS"

kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        kill_tree "$child"
    done
    kill "$1" 2>/dev/null || true
}
cleanup() {
    local pid
    for pid in $(jobs -p); do
        kill_tree "$pid"
    done
    wait 2>/dev/null || true
    cd /
    rm -rf "$WORKDIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
cd "$WORKDIR"

export PATH="$TOOLS/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH \
    DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH CC CXX CFLAGS CXXFLAGS LDFLAGS
export PYTHONWARNINGS=ignore PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1 PYTHONDONTWRITEBYTECODE=1

start_job() {
    local name="$1"
    shift
    "$@" >"$LOGS/$name.log" 2>&1 &
    echo $! >"$LOGS/$name.pid"
}
wait_job() {
    local name="$1"
    if ! wait "$(cat "$LOGS/$name.pid")"; then
        tail -25 "$LOGS/$name.log" >&2
        error "Step '$name' failed (log above)"
    fi
}

latest_tag() {
    git ls-remote --tags --sort=-v:refname "$1" "refs/tags/$2" 2>/dev/null \
        | sed 's|.*/||' | awk -v re="$3" '$0 ~ re && !found { print; found=1 }' || true
}

info "Looking up the latest versions..."

if $USE_MASTER; then
    LT_PATTERN='^v2\.[0-9]+\.[0-9]+$'
else
    LT_PATTERN='^v2\.0\.[0-9]+$'
    latest_tag https://github.com/qbittorrent/qBittorrent.git 'release-*' '^release-[0-9]+\.[0-9]+\.[0-9]+$' >"$LOGS/v_qbt" &
fi
[[ -z "$LIBTORRENT_OVERRIDE" ]] && latest_tag https://github.com/arvidn/libtorrent.git 'v2.*' "$LT_PATTERN" >"$LOGS/v_lt" &
latest_tag https://github.com/boostorg/boost.git 'boost-1.*' '^boost-1\.[0-9]+\.[0-9]+$' >"$LOGS/v_boost" &
latest_tag https://github.com/openssl/openssl.git 'openssl-3.*' '^openssl-3\.[0-9]+\.[0-9]+$' >"$LOGS/v_openssl" &
wait

lookup() { [[ -s "$LOGS/$1" ]] && cat "$LOGS/$1" || true; }

if $USE_MASTER; then
    QBITTORRENT_CLONE_ARGS=(--depth 1 --branch master)
    info_branch="master"
else
    LATEST_TAG=$(lookup v_qbt)
    if [[ -n "$LATEST_TAG" ]]; then
        QBITTORRENT_TAG="$LATEST_TAG"
    else
        warn "Could not look up the latest qBittorrent tag, using fallback $QBITTORRENT_TAG"
    fi
    QBITTORRENT_CLONE_ARGS=(--depth 1 --branch "$QBITTORRENT_TAG")
    info_branch="$QBITTORRENT_TAG"
fi

if [[ -n "$LIBTORRENT_OVERRIDE" ]]; then
    LIBTORRENT_VERSION="v$LIBTORRENT_OVERRIDE"
else
    LATEST_LT=$(lookup v_lt)
    if [[ -n "$LATEST_LT" ]]; then
        LIBTORRENT_VERSION="$LATEST_LT"
    else
        warn "Could not look up the latest libtorrent tag, using fallback $LIBTORRENT_VERSION"
    fi
fi

LATEST_BOOST=$(lookup v_boost)
if [[ -n "$LATEST_BOOST" ]]; then
    BOOST_VERSION="${LATEST_BOOST#boost-}"
else
    warn "Could not look up the latest Boost tag, using fallback $BOOST_VERSION"
fi

LATEST_OPENSSL=$(lookup v_openssl)
if [[ -n "$LATEST_OPENSSL" ]]; then
    OPENSSL_VERSION="${LATEST_OPENSSL#openssl-}"
else
    warn "Could not look up the latest OpenSSL tag, using fallback $OPENSSL_VERSION"
fi

QT_PREFIX="$DEPS/qt"
BOOST_PREFIX="$DEPS/boost"
OPENSSL_PREFIX="$DEPS/openssl"
LT_PREFIX="$DEPS/libtorrent"

if [[ -n "$SPOOF_VERSION" ]]; then
    info "Building qBittorrent: $info_branch with libtorrent $LIBTORRENT_VERSION (tracker spoof: $SPOOF_VERSION)"
else
    info "Building qBittorrent: $info_branch with libtorrent $LIBTORRENT_VERSION"
fi
info "Everything is built in $WORKDIR and removed when the script exits"

fetch_qbittorrent() {
    git clone -q "${QBITTORRENT_CLONE_ARGS[@]}" \
        https://github.com/qbittorrent/qBittorrent.git "$WORKDIR/qBittorrent"
    [[ -n "$SPOOF_VERSION" ]] || return 0

    local major="${SPOOF_VERSION%%.*}"
    local rest="${SPOOF_VERSION#*.}"
    local minor="${rest%%.*}"
    local bugfix="${rest#*.}"
    local session_file="$WORKDIR/qBittorrent/src/base/bittorrent/sessionimpl.cpp"

    grep -qF 'generate_fingerprint(PEER_ID, QBT_VERSION_MAJOR, QBT_VERSION_MINOR, QBT_VERSION_BUGFIX, QBT_VERSION_BUILD)' "$session_file" \
        || error "Cannot spoof: peer fingerprint code not found in sessionimpl.cpp, upstream changed it"
    grep -qF 'QStringLiteral("qBittorrent/" QBT_VERSION_2)' "$session_file" \
        || error "Cannot spoof: user agent code not found in sessionimpl.cpp, upstream changed it"

    sed -i '' -E \
        "s|generate_fingerprint\(PEER_ID, QBT_VERSION_MAJOR, QBT_VERSION_MINOR, QBT_VERSION_BUGFIX, QBT_VERSION_BUILD\)|generate_fingerprint(PEER_ID, ${major}, ${minor}, ${bugfix}, 0)|" \
        "$session_file"
    sed -i '' -E \
        "s|QStringLiteral\(\"qBittorrent/\" QBT_VERSION_2\)|QStringLiteral(\"qBittorrent/${SPOOF_VERSION}\")|" \
        "$session_file"
}

fetch_libtorrent() {
    local src="$WORKDIR/libtorrent"
    mkdir -p "$src"
    if ! curl -fsSL --retry 3 \
        "https://github.com/arvidn/libtorrent/releases/download/$LIBTORRENT_VERSION/libtorrent-rasterbar-${LIBTORRENT_VERSION#v}.tar.gz" \
        | tar -xz -C "$src" --strip-components=1; then
        echo "libtorrent release tarball unavailable, falling back to git clone"
        rm -rf "$src"
        git clone -q --branch "$LIBTORRENT_VERSION" --depth 1 --recurse-submodules \
            https://github.com/arvidn/libtorrent.git "$src"
    fi
}

fetch_boost() {
    local major="${BOOST_VERSION%%.*}"
    local rest="${BOOST_VERSION#*.}"
    local minor="${rest%%.*}"
    local patch="${rest#*.}"
    mkdir -p "$BOOST_PREFIX/include" "$BOOST_PREFIX/lib/cmake/Boost-$BOOST_VERSION"
    if ! curl -fsSL --retry 3 "https://github.com/boostorg/boost/releases/download/boost-$BOOST_VERSION/boost-$BOOST_VERSION-b2-nodocs.tar.xz" \
        | tar -xJ -C "$BOOST_PREFIX/include" --strip-components=1 "boost-$BOOST_VERSION/boost"; then
        rm -rf "$BOOST_PREFIX/include/boost"
        curl -fsSL --retry 3 "https://archives.boost.io/release/$BOOST_VERSION/source/boost_${BOOST_VERSION//./_}.tar.gz" \
            | tar -xz -C "$BOOST_PREFIX/include" --strip-components=1 "boost_${BOOST_VERSION//./_}/boost"
    fi
    [[ -f "$BOOST_PREFIX/include/boost/version.hpp" ]]

    cat >"$BOOST_PREFIX/lib/cmake/Boost-$BOOST_VERSION/BoostConfig.cmake" <<EOF
set(Boost_VERSION $BOOST_VERSION)
set(Boost_VERSION_STRING $BOOST_VERSION)
set(Boost_VERSION_MAJOR $major)
set(Boost_VERSION_MINOR $minor)
set(Boost_VERSION_PATCH $patch)
set(Boost_MAJOR_VERSION $major)
set(Boost_MINOR_VERSION $minor)
set(Boost_SUBMINOR_VERSION $patch)
set(Boost_INCLUDE_DIR "$BOOST_PREFIX/include")
set(Boost_INCLUDE_DIRS "$BOOST_PREFIX/include")
set(Boost_FOUND TRUE)
if(NOT TARGET Boost::headers)
    add_library(Boost::headers INTERFACE IMPORTED)
    set_target_properties(Boost::headers PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "$BOOST_PREFIX/include")
endif()
if(NOT TARGET Boost::boost)
    add_library(Boost::boost INTERFACE IMPORTED)
    set_target_properties(Boost::boost PROPERTIES INTERFACE_LINK_LIBRARIES Boost::headers)
endif()
EOF
    cat >"$BOOST_PREFIX/lib/cmake/Boost-$BOOST_VERSION/BoostConfigVersion.cmake" <<EOF
set(PACKAGE_VERSION $BOOST_VERSION)
if(PACKAGE_FIND_VERSION VERSION_GREATER PACKAGE_VERSION)
    set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
    set(PACKAGE_VERSION_COMPATIBLE TRUE)
    if(PACKAGE_FIND_VERSION VERSION_EQUAL PACKAGE_VERSION)
        set(PACKAGE_VERSION_EXACT TRUE)
    endif()
endif()
EOF
}

build_openssl() {
    local src="$WORKDIR/openssl"
    mkdir -p "$src"
    curl -fsSL --retry 3 "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
        | tar -xz -C "$src" --strip-components=1
    cd "$src"
    ./Configure "darwin64-$ARCH-cc" no-shared no-tests no-docs no-apps no-module no-legacy \
        no-quic no-cms no-ts no-srp no-ct no-comp no-engine no-ui-console no-ssl3 no-weak-ssl-ciphers \
        no-idea no-mdc2 no-rc5 no-seed no-whirlpool no-camellia no-aria no-sm2 no-sm3 no-sm4 \
        --prefix="$OPENSSL_PREFIX" --libdir=lib --openssldir=/etc/ssl
    make -j"$NPROC" build_libs
    make install_dev
}

install_tools() {
    /usr/bin/python3 -m venv "$TOOLS"
    "$TOOLS/bin/pip" install -q aqtinstall cmake ninja
}

install_qt() {
    local latest
    latest=$(aqt list-qt mac desktop --latest-version 2>/dev/null || true)
    if [[ "$latest" =~ ^6\.[0-9]+\.[0-9]+$ ]]; then
        QT_VERSION="$latest"
    else
        echo "Could not look up the latest Qt version, using fallback $QT_VERSION"
    fi
    echo "$QT_VERSION" >"$LOGS/v_qt"
    aqt install-qt mac desktop "$QT_VERSION" clang_64 --outputdir "$WORKDIR/qt-install" \
        --archives qtbase qtsvg qttools qttranslations qtdeclarative
    ln -s "$WORKDIR/qt-install/$QT_VERSION/macos" "$QT_PREFIX"
}

info "Step 1/5: Fetching sources and dependencies in parallel..."
start_job qbittorrent fetch_qbittorrent
start_job libtorrent-src fetch_libtorrent
start_job boost fetch_boost
start_job openssl build_openssl
start_job tools install_tools

wait_job qbittorrent
if [[ -n "$SPOOF_VERSION" ]]; then
    info "  Tracker version patched: peer ID qB ${SPOOF_VERSION}.0, user agent qBittorrent/${SPOOF_VERSION}"
fi
wait_job tools
start_job qt install_qt
wait_job libtorrent-src
wait_job boost
info "  Boost $BOOST_VERSION headers ready"

CMAKE_COMMON=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local"
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF
)

wait_job openssl
info "  OpenSSL $OPENSSL_VERSION built"

info "Step 2/5: Building libtorrent-rasterbar $LIBTORRENT_VERSION (static)..."
cmake -S "$WORKDIR/libtorrent" -B "$WORKDIR/libtorrent/build" \
    "${CMAKE_COMMON[@]}" \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_CXX_FLAGS="-w" \
    -DCMAKE_INSTALL_PREFIX="$LT_PREFIX" \
    -DCMAKE_PREFIX_PATH="$OPENSSL_PREFIX;$BOOST_PREFIX" \
    -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -Ddeprecated-functions=OFF \
    >"$LOGS/libtorrent-configure.log" 2>&1 \
    || { tail -25 "$LOGS/libtorrent-configure.log" >&2; error "libtorrent configure failed"; }
cmake --build "$WORKDIR/libtorrent/build" --parallel "$NPROC"
cmake --install "$WORKDIR/libtorrent/build" >/dev/null

wait_job qt
QT_VERSION=$(cat "$LOGS/v_qt")
info "  Qt $QT_VERSION ready"
[[ -f "$QT_PREFIX/lib/cmake/Qt6/Qt6Config.cmake" ]] || error "Qt CMake files missing in $QT_PREFIX"

info "Step 3/5: Building qBittorrent ($info_branch)..."
cmake -S "$WORKDIR/qBittorrent" -B "$WORKDIR/qBittorrent/build" \
    "${CMAKE_COMMON[@]}" \
    -DCMAKE_PREFIX_PATH="$LT_PREFIX;$OPENSSL_PREFIX;$BOOST_PREFIX;$QT_PREFIX" \
    -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
    -DGUI=ON \
    -DTESTING=OFF \
    >"$LOGS/qbittorrent-configure.log" 2>&1 \
    || { tail -25 "$LOGS/qbittorrent-configure.log" >&2; error "qBittorrent configure failed"; }
cmake --build "$WORKDIR/qBittorrent/build" --parallel "$NPROC"

APP_PATH="$WORKDIR/qBittorrent/build/qbittorrent.app"
[[ -d "$APP_PATH" ]] || error "Build failed, qbittorrent.app not found at $APP_PATH"

info "Step 4/5: Bundling Qt into the app..."

QT_PLUGIN_LIST=(
    platforms/libqcocoa
    styles/libqmacstyle
    iconengines/libqsvgicon
    imageformats/libqsvg
    imageformats/libqico
    imageformats/libqicns
    imageformats/libqjpeg
    imageformats/libqgif
    tls/libqsecuretransportbackend
    tls/libqcertonlybackend
    sqldrivers/libqsqlite
    networkinformation/libqapplenetworkinformation
)
[[ -f "$QT_PREFIX/plugins/platforms/libqcocoa.dylib" ]] || error "Qt cocoa platform plugin not found in $QT_PREFIX/plugins"
DEPLOY_ARGS=()
for plugin in "${QT_PLUGIN_LIST[@]}"; do
    src="$QT_PREFIX/plugins/$plugin.dylib"
    [[ -f "$src" ]] || continue
    mkdir -p "$APP_PATH/Contents/PlugIns/${plugin%/*}"
    install -m 644 "$src" "$APP_PATH/Contents/PlugIns/$plugin.dylib"
    DEPLOY_ARGS+=("-executable=$APP_PATH/Contents/PlugIns/$plugin.dylib")
done

"$QT_PREFIX/bin/macdeployqt" "$APP_PATH" -no-plugins -no-strip -no-codesign "${DEPLOY_ARGS[@]}" \
    >"$LOGS/macdeployqt.log" 2>&1 \
    || { tail -25 "$LOGS/macdeployqt.log" >&2; error "macdeployqt failed"; }

if otool -L "$APP_PATH/Contents/MacOS/qbittorrent" "$APP_PATH"/Contents/PlugIns/*/*.dylib \
    | grep -E "^[[:space:]]+(/opt/homebrew|/usr/local|/opt/local|$WORKDIR)" >&2; then
    error "The app links against libraries outside the bundle (listed above)"
fi

info "Step 5/5: Thinning, signing and moving the app..."
while IFS= read -r -d '' bin; do
    if [[ "$(lipo -archs "$bin" 2>/dev/null)" == *" "* ]]; then
        lipo -thin "$ARCH" "$bin" -output "$bin.thin" && mv "$bin.thin" "$bin"
    fi
done < <(find "$APP_PATH/Contents" -type f -print0)
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

FINAL_APP="$OUTPUT_DIR/qBittorrent.app"
rm -rf "$FINAL_APP"
mv "$APP_PATH" "$FINAL_APP"

ELAPSED=$(( $(date +%s) - START_TIME ))

echo ""
info "========================================"
info "  Build complete! ($(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s)"
info "========================================"
info ""
info "  .app: $FINAL_APP"
info "  Qt $QT_VERSION, libtorrent $LIBTORRENT_VERSION, OpenSSL $OPENSSL_VERSION, Boost $BOOST_VERSION"
if [[ -n "$SPOOF_VERSION" ]]; then
    info "  Tracker version: $SPOOF_VERSION (spoofed)"
fi
info ""
info "  To install:"
info "    rm -rf /Applications/qBittorrent.app && cp -R \"$FINAL_APP\" /Applications/"
info ""

}

main "$@"
