# GoFile Downloader for macOS

A native macOS app written in Swift 6 and SwiftUI for downloading files and folders from [GoFile](https://gofile.io) (`https://gofile.io/d/<id>`), with concurrent downloads, resumable transfers, automatic retries, and zero third-party dependencies.

## Features

- **Recursive Album Downloads** — Resolves GoFile links and nested subfolders while preserving directory structure locally and sanitizing invalid path characters.
- **Automatic Filename Deduplication** — Resolves case-insensitive filename collisions within each folder by appending ` (1)`, ` (2)`, etc. before the extension.
- **Password-Protected Links** — Supports password-protected GoFile albums (SHA-256 hashed client-side) and highlights the password field automatically when one is required.
- **Resumable Transfers (`.part` files)** — Streams downloads to `.part` files and resumes interrupted transfers using HTTP `Range` (`206 Partial Content`) requests. Handles `416 Range Not Satisfiable` automatically and verifies completeness against `Content-Length` before moving files into place.
- **Skip Existing Files** — Automatically skips files at the destination whose size matches the expected remote size (and re-downloads mismatched sizes).
- **Concurrent Worker Pool & Smart Retries** — Downloads multiple files in parallel with configurable concurrency and retry counts, using jittered exponential backoff with longer cooldowns for HTTP `421`, `429`, and `503` responses.
- **Native macOS UI** — Live per-file and overall progress, smoothed transfer speeds, ETA estimates, multi-select row context menu (retry/resume, re-download from scratch, reveal in Finder, open file, copy filenames/links), and a collapsible timestamped event log.
- **Launch Arguments** — Supports pre-filling URLs, passwords, output folders, and auto-starting downloads from the command line.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16.0 or later (Swift 6.0)

## Building & Running

### Xcode

1. Open `GoFileDownloader.xcodeproj` in Xcode.
2. Select the **GoFileDownloader** scheme.
3. Build and run (`⌘R`).

> Local builds default to ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) with Hardened Runtime enabled in Release and App Sandbox disabled, so no Apple Developer account is required locally. For distribution and notarization on other Macs, override `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`, and `PRODUCT_BUNDLE_IDENTIFIER` on `xcodebuild`.

### Command Line

```bash
xcodebuild \
  -project GoFileDownloader.xcodeproj \
  -scheme GoFileDownloader \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build \
  build
```

The built Universal (`arm64` + `x86_64`) app bundle will be located at `build/Build/Products/Release/GoFileDownloader.app`.

## Usage

1. Paste a GoFile album URL (`https://gofile.io/d/<id>`) into the URL field (or click the clipboard icon).
2. Enter a password if the album is password-protected.
3. Choose a destination folder (defaults to `~/Downloads/GoFile`).
4. Click **Download** (or press `Return`). Press `Esc` or click **Cancel** to stop active transfers while keeping `.part` files for later resume.

### Row Actions

- **Double-click** a row to reveal the file (or `.part` file) in Finder.
- **Right-click** one or more rows to **Retry / Resume**, **Re-download from Scratch**, **Reveal in Finder**, **Open File**, **Copy Filename(s)**, or **Copy Download Link(s)**.

### Settings

Open Settings via the **Settings** button in the footer bar or `⌘,`:

| Setting | Default | Range |
| --- | --- | --- |
| Download Folder | `~/Downloads/GoFile` | Any directory |
| Concurrent Downloads | `3` | `1`–`8` |
| Max Retries per File | `3` | `0`–`10` |

Preferences are persisted in `UserDefaults`.

### Command-Line Launch Arguments

You can launch the app pre-configured from Terminal:

| Flag | Description |
| --- | --- |
| `--url <url>` | Pre-fill the GoFile album URL |
| `--password <password>` | Pre-fill the album password |
| `--output <path>` | Override the destination download folder |
| `--autostart` | Automatically start downloading after launch |

Example:

```bash
open build/Build/Products/Release/GoFileDownloader.app --args \
  --url "https://gofile.io/d/xxxxxx" \
  --output ~/Downloads/GoFile \
  --autostart
```

## Project Structure

```text
GoFileDownloader/
├── GoFileDownloaderApp.swift   # App entry point, WindowGroup/Settings scenes, launch arguments
├── ContentView.swift           # Main window UI, file table, context menus, event log
├── SettingsView.swift          # Settings form for folder, concurrency, and retries
├── DownloadStore.swift         # @Observable @MainActor state store, metrics, and session lifecycle
├── Formatters.swift            # Byte count, transfer speed, ETA, and timestamp formatting
├── Assets.xcassets/            # App icon and accent color
└── Core/
    ├── GoFileConfig.swift            # API constants, headers, defaults, and adaptive chunk sizes
    ├── GoFileAPI.swift               # Guest token creation, website token signing, recursive album resolution
    ├── FilenameResolver.swift        # Case-insensitive per-folder filename deduplication
    ├── ChunkedURLSessionStream.swift # Backpressure-bounded URLSessionDataDelegate chunk stream
    ├── DiskFileWriter.swift          # Off-pool serial disk writes, fsync, and cancellable MD5 hashing
    ├── FileDownloader.swift          # Streaming downloader with isolated .part staging and HTTP Range resume
    └── DownloadEngine.swift          # Concurrent TaskGroup scheduler and jittered exponential backoff

GoFileDownloaderTests/
├── Support/
│   └── MockURLProtocol.swift         # Thread-safe per-session URLProtocol mock
├── GoFileAPITests.swift              # URL parsing, token/password hashing, headers, chunk sizes
├── FilenameResolverTests.swift       # Case-insensitive filename collision & UTF-8 bound tests
├── ContentsParsingTests.swift        # Mocked folder resolution, password states, pagination & depth guards
├── FileDownloaderTests.swift         # Streaming, backpressure, resume, 416, MD5, symlink & staging tests
├── DownloadEngineTests.swift         # Concurrency limits, retries, backoff, and cancellation tests
├── DownloadStoreTests.swift          # Session lifecycle, errors, retry deadlock, and metrics tests
├── FormattersTests.swift             # Byte count, speed, ETA, and timestamp formatting tests
└── LiveSmokeTests.swift              # Opt-in live end-to-end GoFile API smoke test
```

## Testing

Tests use Apple's **Swift Testing** framework. Run unit tests in Xcode (`⌘U`) or from the command line:

```bash
xcodebuild test \
  -project GoFileDownloader.xcodeproj \
  -scheme GoFileDownloader \
  -destination 'platform=macOS' \
  -derivedDataPath build
```

`LiveSmokeTests` makes live network requests against the GoFile API and is skipped by default. To enable it, pass `GOFILE_LIVE_TESTS=1` (and optionally `GOFILE_LIVE_URL` / `GOFILE_LIVE_PASSWORD`):

```bash
GOFILE_LIVE_TESTS=1 xcodebuild test \
  -project GoFileDownloader.xcodeproj \
  -scheme GoFileDownloader \
  -destination 'platform=macOS' \
  -derivedDataPath build
```
