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

Or spoof the tracker version (e.g. build master but report as 5.3.0 to trackers):

```bash
curl -fsSL https://raw.githubusercontent.com/rursache/qbittorent-mac-build/master/build-qbittorrent.sh | bash -s -- --master --spoof 5.3.0
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
./build-qbittorrent.sh --master --spoof 5.3.0 # builds master, trackers see v5.3.0
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

Nothing gets installed on your Mac. All dependencies are downloaded or built inside a temporary directory that is deleted when the script exits, whether the build succeeded or not

| Step | Description |
|------|-------------|
| 1 | In parallel: fetches [qBittorrent](https://github.com/qbittorrent/qBittorrent) (latest release tag or master, applying the `--spoof` patch if requested), the [libtorrent](https://github.com/arvidn/libtorrent) source, Boost headers, builds a static OpenSSL 3 and sets up `cmake`, `ninja` and [aqtinstall](https://github.com/miurahr/aqtinstall) in a throwaway Python venv, which then downloads the official prebuilt Qt 6 |
| 2 | Builds libtorrent-rasterbar as a static library (latest 2.0.x for release builds, latest 2.x for `--master`, or the version given with `--libtorrent`) |
| 3 | Builds qBittorrent |
| 4 | Bundles the Qt frameworks and plugins qBittorrent needs into the `.app` via `macdeployqt` |
| 5 | Thins the universal Qt binaries down to your Mac's architecture, ad-hoc signs the app and moves it next to the script (or the current directory when piped) |

## Requirements

- macOS (Apple Silicon or Intel)
- [Xcode Command Line Tools](https://developer.apple.com/xcode/) (`xcode-select --install`)
- About 3 GB of free disk space during the build

No Homebrew, no global installs. Even if Homebrew is installed, the script ignores it so nothing from `/opt/homebrew` or `/usr/local` ends up in the app

## Build Time

About 2.5 minutes on Apple Silicon (M4) for a release build, every run starts from nothing. Dependencies download and build in parallel, so most of that time is compiling libtorrent and qBittorrent

## Notes

- The script always auto-detects the **latest** qBittorrent release tag, libtorrent tag (2.0.x for release builds since that is what qBittorrent release CI tests against, latest 2.x for `--master`), Qt 6, Boost and OpenSSL 3 versions, hardcoded fallback versions are used only if a lookup fails
- Every build is a clean build from scratch, nothing is cached between runs
- No signing identity is needed, the app is ad-hoc signed (`codesign --sign -`) which is enough for local use
- The app is self-contained, the script fails if anything in it links to a library outside the bundle
- **Version spoofing**: `--spoof X.Y.Z` makes the client report a different version to trackers (peer ID and user agent), useful when trackers whitelist only specific versions. The About dialog and all other UI keep showing the real version
- **Upgrading**: remove the old app before copying the new one (`rm -rf /Applications/qBittorrent.app`), `cp -R` over an existing bundle merges stale files into it
