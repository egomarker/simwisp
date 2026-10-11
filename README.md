# Simwisp

**Your simulators, a little closer.**

A native macOS menu-bar app that brings live iOS and Android simulators into a lightweight browser workspace. Capture, input, and networking run in Swift; the browser stays plain HTML, CSS, and JavaScript.

## At a glance

- **Native capture** — ScreenCaptureKit, bounded frame buffers, JPEG streaming, and adaptive pacing up to 60 FPS.
- **Multiple devices** — view iOS and Android simulators side by side, with resizable panels and independent connections.
- **Real controls** — taps, drags, Home, rotation, appearance, keyboard/text input, and Android two-finger gestures.
- **Menu-bar only** — no normal server window; inspect sessions, permissions, and process usage from the menu.
- **Quiet when idle** — capture and background discovery stop after the final streaming client disconnects. Popup monitoring stops when the popup closes. Terminal I/O uses readiness notifications, not polling.
- **Optional Mac terminals** — login shells with tabs, resizing, themes, reconnect replay and explicit session cleanup. Renderer assets load only when a terminal is opened.
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

No Python environment, Bun/Node runtime, or dependency installation is required to build or run Simwisp. The optional terminal renderer (xterm and fit addon) is bundled locally with its licenses.

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

### Enable Mac terminals

Terminal access is **disabled by default**. Enable **Allow Mac terminal access** in the menu-bar server settings (saved), or opt in for a launch:

```bash
open build/Simwisp.app --args --lan --terminal
```

Refresh your browser, then choose the icon-and-**Terminal** button in the sidebar. There is no bottom terminal bar. Terminals run on the **host Mac**, not inside a simulator. They start a login shell in `--project-dir` (your home directory by default). You can add up to eight tabs, pin the terminal beside simulators, resize it, and adjust its font size.

**Enabling this grants every paired browser shell access as your Mac user.** Use only trusted browsers and networks. `--no-terminal` disables access for a launch, even if it was saved as enabled.

Collapsing the panel preserves tabs. Closing a tab terminates its shell and foreground job; page reloads reconnect to the existing shell. Disconnected shells expire after 30 minutes. While disconnected, PTY reading is suspended; output-producing commands may block when the kernel buffer fills, rather than wasting CPU draining invisible output.

### Connect a browser

1. Open Simwisp's menu-bar panel.
2. Grant Screen Recording and Accessibility access when needed. macOS may require quitting and reopening the app after a permission change.
3. Choose **Open workspace**, or **Copy link** to open the pairing link on another device.
4. Select a running simulator from the sidebar. Use **Add simulator** to boot another device.

The default port is **4141**. Only one controlling browser connection is supported per device; a new connection replaces the previous one. Keep one controller per device to avoid competing reconnects.

### Authenticator pairing (optional)

The first launch of this version adds a disabled `pairing` group to `~/Library/Application Support/Simwisp/settings.json`, preserving the existing token, preferences and unknown top-level owner fields. You can also add the following group **alongside the existing fields**. Keep the existing `pairingToken`: it authorizes links and existing browser cookies. Restart Simwisp after editing; settings are not polled or hot-reloaded.

```json
"pairing": {
  "totpSecret": null,
  "rateLimits": {
    "postsPerIPPerMinute": 2,
    "totpFailuresPerIPPerMinute": 2,
    "ipCooldownSeconds": [600, 1800, 3600],
    "repeatWindowSeconds": 1800,
    "globalTotpFailuresPerHour": 2,
    "globalTotpLockoutSeconds": 3600
  }
}
```

Replace `null` with a **unique, private Base32 secret containing 20–64 bytes**, generated with a trusted local tool/password manager; enroll the same seed in your authenticator using **SHA-1, six digits, 30 seconds**. Do not use public test/example seeds or online key generators. Missing, null or blank seeds disable TOTP and hide its browser choice. Settings are owner-only (`0600`); neither the seed nor accepted codes are returned by the server or written to logs. Saved settings are pretty-printed, keeping seed and limits together. Old settings remain compatible and their pairing token is preserved. Invalid JSON/types are not silently replaced with new credentials; invalid seeds/limits prevent server startup until corrected.

The unauthenticated screen offers **Pairing link** or **Authenticator code** when configured. The server accepts the current step ±1 for clock skew and exchanges either credential for the same HttpOnly/SameSite Strict browser cookie. A successfully accepted step cannot be reused, including after restart; wait for a fresh step when pairing another browser. This is an **alternative credential, not two-factor authentication**. With terminals enabled, either method grants Mac-user shell access. TOTP does not encrypt HTTP or prevent real-time phishing; use only a trusted LAN or an encrypted tunnel.

Limits apply only to `POST /api/pair`, never simulator/terminal traffic or already-paired requests:

- **Two POSTs in a rolling 60 seconds per socket IP**, including valid/invalid link and TOTP requests. Forwarded headers and changing source ports do not change identity; IPv6 identities group by /64 if used by the transport.
- **Two failed TOTP verifications in 60 seconds/IP** start a 10-minute cooldown, escalating to 30 then 60 minutes. The repeat window starts **when the previous cooldown ends**; after 30 quiet post-expiry minutes the tier resets. Successful TOTP clears that IP's failure streak/tier, not global failure history.
- **Two failed TOTP verifications across all IPs in a rolling hour** block new TOTP pairing for **one hour from the triggering failure**. Two typos or another LAN client can intentionally cause this lockout. At these defaults it normally dominates the shorter IP cooldowns. Link pairing retains its normal POST budget, and existing browser sessions remain usable.
- Reject throttled attempts immediately with `429` and `Retry-After`; blocked requests never extend cooldown/global deadlines or count as additional credential failures. The second incorrect credential returns generic `401`, with subsequent TOTP attempts throttled. All counts/durations above are editable; counts must be 1–1000, durations 1–604800 seconds, and the three IP cooldowns ordered.

Replay protection, global failed-attempt history and the global lock deadline persist in owner-only `pairing-state.json` next to settings, scoped to the decoded seed. Per-IP state is a bounded in-memory cache, expiring only on pairing requests; restarting resets IP budgets but not the persisted global/replay protection. Authentication and atomic state writes run on a separate serial queue, with **no timer, background polling or network/capture-queue sleep**. An unreadable/unwritable state file fails TOTP closed (`503`), while link pairing still works. Do not delete/edit state to bypass limits; repair permissions on the Mac if needed, or wait for lock expiry. `make test` runs deterministic pairing tests (RFC TOTP vectors, migration, boundaries, cooldowns, restart persistence, replay and fail-closed behavior) without launching the app.

## Launch options

Pass options after `open build/Simwisp.app --args`:

| Option | Description |
| --- | --- |
| `--lan` | Enable sharing on network interfaces |
| `--port 4242` | Set the listening port; allowed range: 1024–65535 |
| `--project-dir /path/to/project` | Select the project-app detection directory and terminal working directory |
| `--terminal` | Enable Mac shell access for paired browsers (default disabled) |
| `--no-terminal` | Disable Mac shell access, overriding saved preferences |
| `--android-sdk /path/to/sdk` | Set the Android SDK location explicitly |

For example:

```bash
open build/Simwisp.app --args --lan --port 4242
```

Without an explicit SDK path, discovery checks `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Library/Android/sdk`, and `~/.androidsdk`. The SDK's own `adb` is used.

Launch options apply to a newly started instance. Quit the existing app before relaunching with different options.

## Privacy and pairing

Simwisp serves the workspace and simulator streams directly from your Mac; it does not need a cloud service.

- Pairing links authorize simulator control and, when explicitly enabled on the Mac, host shell access. Treat them as private credentials.
- APIs require authentication, and WebSocket upgrades and mutating requests enforce same-origin checks.
- Browser authentication uses an HttpOnly, SameSite Strict cookie.
- LAN transport is **unencrypted HTTP**. Use it only on a trusted network, or through an encrypted tunnel; do not expose the port directly to the internet.
- Settings, including the pairing token, are stored outside the repository at `~/Library/Application Support/Simwisp/settings.json`.

## Android TalkBack inspector

On an Android stream, the **A11y** control opens an accessibility pane below the simulator. By default it shows only **TALKBACK SAYS**, reserving exactly three speech lines so incoming text cannot change the pane or simulator size. Longer text scrolls inside it. The grip inside the pane's top edge resizes it without consuming layout space; drag upward to enlarge/downward to shrink, use Up/Down (Shift for larger steps), or double-click/press Enter to reset. Compact and expanded heights are remembered separately per device in this browser, safely clamped when the viewport changes. On very short viewports the pane is capped to preserve simulator/toolbar space. **More…** reveals the observed label, role (when available), tooltip, package/class, bounds, properties and actions; the pane expands in layout flow and the displayed simulator shrinks proportionally. It never covers the stream. **Less** restores the compact view. iOS has no inspector control.

This reads TalkBack's diagnostic logs, **not** an authoritative current selection or full accessibility tree. TalkBack must be enabled with verbose diagnostic logging; Simwisp does not enable it, alter device settings, or clear logs automatically. Without matching events the pane explains that it is waiting. Composed TTS fallback is labeled separately from exact `action=SPEAK`. Password-node content is hidden; no raw logs/history are persisted.

Monitoring is native, bounded and readiness-driven: one serial-targeted ADB reader exists only when that pane is open **and its Android stream is active**. Closing the pane while video continues, pausing/hiding the stream, losing its window, disconnecting, replacing the controller or stopping the server cancels reading and terminates the child. No background logcat reader, parser, polling timer or accessibility sending remains when monitoring is off. Inspector JS/CSS loads locally only on first open. Reconnection opts in only for a pane that is still open. The native popup reports listening/recent sending/paused/error in that Android session's existing details.

## Performance and lifecycle

Streaming is paced by frame deadlines and browser acknowledgements, with bounded encoding and socket buffers. Slow connections can reduce FPS and JPEG quality automatically; 60 FPS is a target, not a guarantee on every network or device.

When the final simulator streaming client disconnects, capture is torn down and the discovery timer is cancelled. The menu-bar popup's monitoring timer exists only while the popup is visible/key. Browser device-list requests still perform on-demand discovery.

Original no-terminal idle lifecycle verification measured approximately **0.01–0.02% of one CPU core** on the development Mac. A later explicitly sampled terminal review measured **0.0423% with one idle terminal** and **0.0444% with two**, with unchanged PTY I/O counters and no capture demand. Sampling itself adds work; these are short observations, not universal CPU guarantees. The panel's CPU display uses **100% = one core**; measurements are app-process usage, not total simulator or system usage.

Terminal connections never count as simulator streaming demand. PTY reads/writes and child exits are dispatch-event driven on a separate queue; idle terminals do not poll. Cursor blinking and smooth scrolling are disabled. Shell output waits for browser parsing acknowledgements, with at most one bounded chunk in flight; input and replay buffers are capped at 64 KiB. Connected terminal sockets use a low-frequency keepalive; disconnected retention and ACK deadlines are one-shot timers. Actual shell commands naturally consume CPU when doing work.

Only one Simwisp app instance may run at a time; duplicate launches exit without starting another server.

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
Sources/                 Native app, capture, input, discovery, HTTP, PTYs and streams
Sources/TerminalHost.c    Small native controlling-terminal/login-shell helper
Resources/Web/           Browser workspace: HTML, CSS, and JavaScript
Resources/Info.plist      App metadata and menu-bar-only configuration
Resources/device-sizes.json
Makefile                 Build, signature verification, and launch targets
```

Useful targets:

```bash
make check   # Build, sign, and verify
make test    # Native pairing + accessibility regressions; no app launch
make test-browser-accessibility # Optional isolated browser/transport fixtures
make run     # Build and open using saved settings
make clean   # Remove build output; quit the app first
```

The optional browser target requires existing Google Chrome and Node.js 22+ on macOS, and a free loopback port 45151. It serves synthetic simulator frames and TalkBack events with the real native HTTP/reader/coordinator code; it does not launch an app bundle or control a device. Override the executable with `make NODE=/path/to/node test-browser-accessibility`. To separately check an existing Android ADB connection, run `NODE=/path/to/node Tests/Browser/run.sh --real-adb`; logcat then runs only while the test pane and fixture stream are open, without changing device settings or injecting navigation. A fresh real speech event still needs manual confirmation. Set `TEST_OUTPUT=/path/outside-the-repository` to retain screenshots/JSON; otherwise temporary fixtures and profiles are removed. Tests do not certify live capture FPS.

## Development status

**Early development build — version 0.2.0.** Live capture, pairing, multi-device streaming, disconnect/reconnect, and idle cleanup have been exercised on Apple Silicon. The host-architecture build recipe also supports compiling on Intel, but Intel runtime behavior has not been verified.

Some native control combinations still need broader verification, particularly Android rotation and iOS text entry. Terminal PTY/security/lifecycle and desktop/mobile browser controls have been exercised on Apple Silicon. Terminal access is optional and disabled by default; legacy capture backends remain excluded.

The repository contains production source and browser resources only; generated logs, diagnostics, review reports, and app bundles are not checked in.
