# qBittorrent macOS Build Script

qBittorrent macOS builds are no longer being published but you can now make your own!

## One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/rursache/qbittorent-mac-build/master/build-qbittorrent.sh | bash
```

Or build from qBittorrent's `master` branch (bleeding edge):

```bash
curl -fsSL https://raw.githubusercontent.com/rursache/qbittorent-mac-build/master/build-qbittorrent.sh | bash -s -- --master
```

## Manual Usage

```bash
git clone https://github.com/rursache/qbittorent-mac-build.git
cd qbittorent-mac-build
./build-qbittorrent.sh            # builds latest release tag
./build-qbittorrent.sh --master   # builds master branch
```

The resulting `qBittorrent.app` will be placed next to the script.

## What it does

| Step | Description |
|------|-------------|
| 1 | Installs Homebrew dependencies (`cmake`, `ninja`, `qt`, `openssl@3`, `zlib`, `boost`, `pkg-config`) |
| 2 | Creates a temporary build directory |
| 3 | Builds [libtorrent-rasterbar](https://github.com/arvidn/libtorrent) as a static library (latest 2.0.x tag, auto-detected) |
| 4 | Clones and builds [qBittorrent](https://github.com/qbittorrent/qBittorrent) (latest release tag or master, auto-detected) |
| 5 | Bundles Qt frameworks into the `.app` via `macdeployqt` and ad-hoc signs it |

The build directory is automatically cleaned up after the `.app` is copied out.

## Requirements

- macOS (Apple Silicon or Intel)
- [Xcode Command Line Tools](https://developer.apple.com/xcode/) (`xcode-select --install`)
- [Homebrew](https://brew.sh)

## Build Time

~2-3 minutes on Apple Silicon (M4).

## Notes

- The script always auto-detects the **latest** qBittorrent release tag and libtorrent 2.0.x tag from GitHub. Hardcoded fallback versions are used only if the lookup fails.
- No signing identity is needed. The app is ad-hoc signed (`codesign --sign -`) which is sufficient for local use.
- Every build is a clean build from scratch.
