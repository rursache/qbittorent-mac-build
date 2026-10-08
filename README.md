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

Or spoof the tracker version (e.g. build master but report as 5.0.5 to trackers):

```bash
curl -fsSL https://raw.githubusercontent.com/rursache/qbittorent-mac-build/master/build-qbittorrent.sh | bash -s -- --master --spoof 5.0.5
```

Or pin a specific libtorrent version:

```bash
curl -fsSL https://raw.githubusercontent.com/rursache/qbittorent-mac-build/master/build-qbittorrent.sh | bash -s -- --libtorrent 2.1.2
```

## Manual Usage

```bash
git clone https://github.com/rursache/qbittorent-mac-build.git
cd qbittorent-mac-build
./build-qbittorrent.sh                        # builds latest release tag
./build-qbittorrent.sh --master               # builds master branch
./build-qbittorrent.sh --master --spoof 5.0.5 # builds master, trackers see v5.0.5
./build-qbittorrent.sh --libtorrent 2.1.2     # pins libtorrent 2.1.2
```

The resulting `qBittorrent.app` is placed next to the script, or in the current directory when piped from curl

## Options

| Flag | Effect |
|------|--------|
| `--master` | Build qBittorrent `master` instead of the latest release tag |
| `--spoof X.Y.Z` | Report X.Y.Z to trackers (peer ID and user agent), each part 0-35 |
| `--libtorrent X.Y.Z` | Build against a specific libtorrent version instead of the auto-detected one |

## What it does

| Step | Description |
|------|-------------|
| 1 | Installs missing Homebrew dependencies (`cmake`, `ninja`, `qtbase`, `qtsvg`, `qttools`, `qttranslations`, `openssl@3`, `zlib`, `boost`, `pkg-config`) |
| 2 | Creates a temporary build directory and fetches [qBittorrent](https://github.com/qbittorrent/qBittorrent) (latest release tag or master, auto-detected), applying the `--spoof` patch if requested |
| 3 | Builds [libtorrent-rasterbar](https://github.com/arvidn/libtorrent) as a static library (latest 2.0.x for release builds, latest 2.x for `--master`, or the version given with `--libtorrent`) |
| 4 | Builds qBittorrent |
| 5 | Bundles the Qt frameworks and plugins qBittorrent needs into the `.app` via `macdeployqt` and ad-hoc signs it |

The build directory is removed when the script exits, whether the build succeeded or not

## Requirements

- macOS (Apple Silicon or Intel)
- [Xcode Command Line Tools](https://developer.apple.com/xcode/) (`xcode-select --install`)
- [Homebrew](https://brew.sh)

## Build Time

About 1.5 minutes for a release build and a bit over 2 minutes for `--master` (libtorrent 2.1) on Apple Silicon (M4)

## Notes

- The script always auto-detects the **latest** qBittorrent release tag and libtorrent tag from GitHub (2.0.x for release builds since that is what qBittorrent release CI tests against, latest 2.x for `--master`), hardcoded fallback versions are used only if the lookup fails
- No signing identity is needed, the app is ad-hoc signed (`codesign --sign -`) which is enough for local use
- Every build is a clean build from scratch
- The app is self-contained and does not load anything from Homebrew at runtime
- **Version spoofing**: `--spoof X.Y.Z` makes the client report a different version to trackers (peer ID and user agent), useful when trackers whitelist only specific versions. The About dialog and all other UI keep showing the real version
- **Upgrading**: remove the old app before copying the new one (`rm -rf /Applications/qBittorrent.app`), `cp -R` over an existing bundle merges stale files into it
