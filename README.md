# Simwisp

**Your simulators, a little closer.**

A native macOS menu-bar app that brings live iOS and Android simulators into a lightweight browser workspace. Capture, input, and networking run in Swift; the browser stays plain HTML, CSS, and JavaScript.

## At a glance

- **Native capture** — ScreenCaptureKit, bounded frame buffers, JPEG streaming, and adaptive pacing up to 60 FPS.
- **Multiple devices** — view iOS and Android simulators side by side, with resizable panels and independent connections.
- **Real controls** — taps, drags, Home, rotation, appearance, keyboard/text input, and Android two-finger gestures.
- **Menu-bar only** — no normal server window; inspect sessions, permissions, and process usage from the menu.
- **Quiet when idle** — capture and background discovery stop after the final streaming client disconnects. Popup monitoring stops when the popup closes.
- **A lightweight workspace** — light, dark, and system themes; no frontend frameworks, package installation, external fonts, or CDN dependencies.
- **Paired access** — local-only by default, with optional network sharing and browser pairing.

## Requirements

| Requirement | Purpose |
| --- | --- |
| macOS 14 or newer | Native app and ScreenCaptureKit capture |
| Xcode with a working `xcrun swiftc` | Build the app; discover and run iOS simulators |
| Android SDK / Emulator, optional | Discover, boot, and control Android emulators |
| Screen Recording permission | Capture simulator windows |
| Accessibility permission | Send simulator input |

Run in a logged-in graphical macOS session. Keep the simulator windows open and unminimized.

No Python environment, Bun/Node runtime, or browser dependencies are required to build or run Simwisp.

## Build and run

```bash
git clone https://github.com/egomarker/simwisp.git
cd simwisp
make check
open build/Simwisp.app
```

`make check` compiles the app, bundles the browser resources, ad-hoc signs it, and verifies the signature. The app appears in the menu bar.

**Before rebuilding an existing installation, quit Simwisp from its menu-bar menu.** Keep your simulator windows open.

### Share with another device

```bash
open build/Simwisp.app --args --lan
```

`--args` is an option for macOS's `open` command: everything after it is passed to Simwisp. Here, Simwisp receives `--lan`.

You can also change **Share on local network** in the app's server settings. Saved settings are reused on subsequent launches; omitting `--lan` does not override a previously saved sharing preference.

### Connect a browser

1. Open Simwisp's menu-bar panel.
2. Grant Screen Recording and Accessibility access when needed. macOS may require quitting and reopening the app after a permission change.
3. Choose **Open workspace**, or **Copy link** to open the pairing link on another device.
4. Select a running simulator from the sidebar. Use **Add simulator** to boot another device.

The default port is **4141**. Only one controlling browser connection is supported per device; a new connection replaces the previous one. Keep one controller per device to avoid competing reconnects.

## Launch options

Pass options after `open build/Simwisp.app --args`:

| Option | Description |
| --- | --- |
| `--lan` | Enable sharing on network interfaces |
| `--port 4242` | Set the listening port; allowed range: 1024–65535 |
| `--project-dir /path/to/project` | Select an Xcode project directory for project-app detection |
| `--android-sdk /path/to/sdk` | Set the Android SDK location explicitly |

For example:

```bash
open build/Simwisp.app --args --lan --port 4242
```

Without an explicit SDK path, discovery checks `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Library/Android/sdk`, and `~/.androidsdk`. The SDK's own `adb` is used.

Launch options apply to a newly started instance. Quit the existing app before relaunching with different options.

## Privacy and pairing

Simwisp serves the workspace and simulator streams directly from your Mac; it does not need a cloud service.

- Pairing links authorize simulator control. Treat them as private credentials.
- APIs require authentication, and WebSocket upgrades and mutating requests enforce same-origin checks.
- Browser authentication uses an HttpOnly, SameSite Strict cookie.
- LAN transport is **unencrypted HTTP**. Use it only on a trusted network, or through an encrypted tunnel; do not expose the port directly to the internet.
- Settings, including the pairing token, are stored outside the repository at `~/Library/Application Support/Simwisp/settings.json`.

## Performance and lifecycle

Streaming is paced by frame deadlines and browser acknowledgements, with bounded encoding and socket buffers. Slow connections can reduce FPS and JPEG quality automatically; 60 FPS is a target, not a guarantee on every network or device.

When the final client disconnects, capture is torn down and the discovery timer is cancelled. The menu-bar popup's monitoring timer exists only while the popup is visible/key. Browser device-list requests still perform on-demand discovery.

Idle lifecycle verification measured approximately **0.01–0.02% of one CPU core** on the development Mac. The panel's CPU display uses **100% = one core**; measurements are app-process usage, not total simulator or system usage.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No frames / device window unavailable | Screen Recording permission; simulator window open and unminimized |
| Frames work, input does not | Accessibility permission; selected simulator window and focus |
| Android devices missing | SDK path, emulator running, and the SDK's `adb devices` output |
| Repeated reconnects | Another browser may be controlling the same device |
| Port already in use | Quit the existing Simwisp instance or choose another `--port` |
| New launch options have no effect | `open` reused an existing instance; quit and relaunch |
| Capture cleanup error | Quit and reopen Simwisp before starting new streams |

## Project layout

```text
Sources/                 Native app, capture, input, discovery, HTTP and streams
Resources/Web/           Browser workspace: HTML, CSS, and JavaScript
Resources/Info.plist      App metadata and menu-bar-only configuration
Resources/device-sizes.json
Makefile                 Build, signature verification, and launch targets
```

Useful targets:

```bash
make check   # Build, sign, and verify
make run     # Build and open using saved settings
make clean   # Remove build output; quit the app first
```

## Development status

**Early development build — version 0.1.0.** Live capture, pairing, multi-device streaming, disconnect/reconnect, and idle cleanup have been exercised on Apple Silicon. The host-architecture build recipe also supports compiling on Intel, but Intel runtime behavior has not been verified.

Some native control combinations still need broader verification, particularly Android rotation and iOS text entry. Terminal sessions and legacy capture backends are intentionally excluded.

The repository contains production source and browser resources only; generated logs, diagnostics, review reports, and app bundles are not checked in.
