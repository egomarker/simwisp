# Simwisp

**Your simulators, a little closer.**

A native macOS menu-bar app that brings live iOS and Android simulators into a lightweight browser workspace. Capture, input, and networking run in Swift; the browser stays plain HTML, CSS, and JavaScript.

## At a glance

- **Native capture** — ScreenCaptureKit → VideoToolbox H.264 → WebCodecs, bounded frame buffers, and adaptive pacing up to 60 FPS.
- **Multiple devices** — view iOS and Android simulators side by side, with resizable panels, independent connections and confirmed per-device Stop controls.
- **Real controls** — taps, drags, Home, iOS Shake and App switcher, rotation, appearance, keyboard/text input, and Android Back/Menu/App switcher/two-finger gestures.
- **Menu-bar only** — no normal server window; inspect sessions, permissions, and process usage from the menu.
- **Quiet when idle** — capture and background discovery stop after the final streaming client disconnects. Popup monitoring stops when the popup closes. Terminal I/O uses readiness notifications, not polling.
- **Optional Mac terminals** — login shells with tabs, resizing, themes, reconnect replay and explicit session cleanup. Renderer assets load only when a terminal is opened.
- **A lightweight workspace** — light, dark, and system themes; no frontend frameworks, package installation, external fonts, or CDN dependencies.
- **Paired access** — local-only by default, with optional network sharing and browser pairing.

## Requirements

| Requirement | Purpose |
| --- | --- |
| macOS 15 or newer | Native capture and memory-only HTTPS identity import |
| Current browser with H.264 WebCodecs support | Decode video over trusted HTTPS (Chrome/Edge/Safari; capability checked at connection) |
| Xcode with a working `xcrun swiftc` | Build the app; discover and run iOS simulators |
| Android SDK / Emulator, optional | Discover, boot, and control Android emulators |
| Screen Recording permission | Capture simulator windows |
| Accessibility permission | Send simulator input |

Window capture and Current touch input need a logged-in graphical Mac session and open, unminimized simulator windows. The Android scrcpy capture/input combination does not require a host emulator window.

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
3. Choose **Export public HTTPS certificate…** and explicitly trust the exported local CA on every client (including this Mac’s browser). See below.
4. Choose **Open workspace**, or **Copy link** to open the **HTTPS** pairing link on another device.
5. Select a running simulator from the sidebar. Use **Add simulator** to boot another device.

The default port is **4141**. Only one controlling browser connection is supported per device; a new connection replaces the previous one. Keep one controller per device to avoid competing reconnects.

### HTTPS and certificate trust

HTTPS/WSS is the only transport; there is no plaintext or JPEG fallback. On first start, Simwisp generates a private local CA and a server identity using the Mac’s built-in OpenSSL. They persist under `~/Library/Application Support/Simwisp/tls/`, outside the repository; the directory is `0700` and private files are `0600`. Keys are loaded into memory, not imported into your login/system keychain. No certificate trust, package or browser is installed automatically.

Export **only** `Simwisp-Local-CA.cer` using **Export public HTTPS certificate…** in the menu-bar panel, or the public `/simwisp-ca.cer` route. Compare its SHA-256 fingerprint with the native panel before trusting it. **Never share** `root.key`, `server.key`, `server.p12` or `server.passphrase` or delete the CA to solve a browser warning. Each client must deliberately trust the public CA:

- **macOS:** manually import the public certificate in Keychain Access and set its SSL trust; reopen the browser if needed.
- **iPhone/iPad:** explicitly install the transferred public certificate profile, then enable its full trust under **Settings → General → About → Certificate Trust Settings**. Device-management policy may restrict this.
- **Windows/Android:** explicitly import the public CA in the appropriate user/device trusted-root certificate store. Browser and managed-device trust policies differ.

Then open the HTTPS link using a name/IP covered by the certificate. A warning-page bypass is **not** a reliable WebCodecs secure-context solution. Unsupported/insecure browsers show a clear explanation rather than silently switching pipelines. Trusting this CA authorizes certificates signed by this Mac; keep its private key private and enroll only devices you control.

The CA is reused across launches. Server certificates include localhost, the Mac hostname and current interface IPs (including VPN IPv4 addresses); they are renewed before expiry or after address changes on server restart without changing the CA. New interface addresses may require restarting the server. A damaged/expired CA fails closed and needs explicit repair/renewal and client enrollment, not silent replacement. Pairing remains required after TLS trust, and old link tokens/cookie derivation are preserved; old HTTP bookmarks must change to HTTPS.

### Android capture and input backends

Each Android panel has a **Backends** control in its telemetry/footer row. Capture and input are independent:

- **Capture:** Auto / scrcpy / Mac window (ScreenCaptureKit + VideoToolbox) / JPEG (Android emulator JPEG70 + Mac VideoToolbox) / Raw (experimental emulator-host RGBA + Mac VideoToolbox).
- **Input:** Auto / scrcpy / Current (Mac mouse events plus the existing serial-scoped ADB key/text commands).

Both default to **Auto**, which prefers a compatible scrcpy server that successfully starts for the selected emulator, and falls back to the existing method if unavailable. The popover shows actual methods and the fallback/error reason. Explicit **scrcpy** reports unavailability rather than silently choosing Current. A failed Auto attempt is latched for that connection, not retried in an idle loop; reselect/reconnect after fixing the installation. Capture can fall back separately while control continues through a control-only scrcpy session. iOS is unchanged.

Install scrcpy yourself if desired; Simwisp never installs or upgrades it. The private wire implementation is pinned to **scrcpy 5.0.1** and its matching **scrcpy-server** JAR. It detects Homebrew's Apple Silicon/Intel paths and PATH installs with a matching share directory. Other versions/missing JARs explain the failure and Auto uses Current. No Python, OpenCV, PyAV, FFmpeg executable or scrcpy desktop window is used. The existing Android SDK adb remains the device transport, always with the selected serial.

Selections are saved **per AVD in this browser**, keyed by the AVD name rather than the reusable emulator serial; other browsers keep independent preferences. Switching reconnects only that panel, cancels/releases its gesture, and joins the old scrcpy process before starting another. Closing, replacing, pausing or stopping the selected stream tears down its owned sockets/process/tunnel/JAR. Only the session's own forward port/file is removed, never another scrcpy session or the ADB server. Closed streams do not leave scrcpy running. The existing TLS, pairing, one-controller policy, TalkBack pane gate and browser WebCodecs pipeline remain in use.

Native capture forwards framed Baseline/no-B H.264 into AVCC without decoding/re-encoding on the Mac. Encoded scrcpy output is forwarded on arrival, not rate-limited again by the pull-based window encoder scheduler. Natural IDRs keep the same browser decoder; only source/session/configuration or reference-chain discontinuities advance its epoch. The FPS tooltip distinguishes configured target from measured sent FPS; `/api/sessions` also exposes `sent_fps` and source/queue/drop/reset counters. At most four encoded access units /8MiB are queued; losing any reference invalidates the chain until a new IDR. Recovery uses RESET_VIDEO with rate limiting. Resolution/rotation session metadata and epochs invalidate stale frames. scrcpy uses the Mac-window crop pixel budget as its long-edge limit, preserving the Android display aspect ratio and allowing codec-alignment rounding (not arbitrary stretching). Both capture backends share the same even-coded-pixel quality→bitrate formula, clamped to0.5–40Mbps, with an explicit owner-requested trial exception: scrcpy quality1 requests200000bit/s (200kbps, about25KB/s) with maximum I/P-frame QP44 (`video-qp-i-max=44,video-qp-p-max=44`), with explicit **normal CBR** (`bitrate-mode=2`, not frame-dropping mode3). This is a QP ceiling, not fixedQP44 or a guaranteed bandwidth cap. Before every scrcpy **video** startup, Simwisp runs serial-scoped `adb shell setprop debug.stagefright.enableshaping 0` and verifies the property readback, preventing Android's VBR quality-floor rewrite. Failure is visible and capture does not start silently with shaping enabled. This debug property is **emulator/device-wide**, can affect other Android encoders, may require a debuggable emulator, and is **not restored** on disconnect (reset it manually or reboot). Control-only scrcpy never writes it. Mac-window quality1 retains its500000bit/s minimum. Other qualities use the shared curve and default bitrate/QP settings; control-only scrcpy input does not request QP bounds. A411×914 window requests max_size914 rather than the old1920 setting. Stable host-window resizing updates only that device’s video source after a350ms debounce; rotation alone does not restart it. Without a window, the source retains its last known window budget, or starts with the initial browser dimensions (360×800 fallback). Decoder-dimension feedback never changes this budget. Control-only scrcpy sessions do not restart for window resizing. Capture remains capped at the requested1–60FPS. Diagnostics include requested/actual dimensions, target bitrate, requested maxQP/mode (not proof of accepted format or measured per-frame QP) and encoded/keyframe byte counters; even CBR is a target, not a hard per-second traffic cap. The shared Mac/scrcpy frontend rate is actual received valid video-packet bytes divided by monotonic elapsed time (not an assumed1s timer tick), with a fresh window on reconnect. It counts the24-byte Simwisp frame header even for packets dropped before rendering, but excludes JSON/control/WebSocket/TLS/TCP overhead. Displayed KB/s and MB/s use decimal1000/1000000 bytes; this is not raw H.264 bitrate or total network-interface traffic. Rendered FPS is likewise normalized by elapsed time. User setting changes are debounced; sustained adaptive FPS/quality changes restart the owned encoder/session at most once per five seconds. Android MediaCodec may encode in software: lower CPU/latency and real headless/Safari behavior are not guaranteed by this integration.

**Emulator Raw (experimental, manual-only):** selects the emulator-host `EmulatorController/streamScreenshot` RGBA8888 API, bypassing both guest JPEG compression and Mac JPEG decoding. Auto never selects Raw, and Raw is not an input option. JPEG and all existing capture/input choices remain available. The final Quality/FPS controls, hardware-preferred VideoToolbox H.264 encoder, 3600-frame GOP, explicit recovery and browser transport are shared with Mac-window/JPEG. Scrcpy input stays independent and control-only; this capture source performs no ADB capture, guest installation, root request, shaping-property change or input RPC.

Raw discovers only private, current-user emulator runtime records matching the selected emulator serial and a live QEMU PID. It requires exactly one authenticated local endpoint with an existing Bearer token; missing/ambiguous identity, incompatible HTTP/2/authentication, malformed images or transport failure fail visibly and latch until reconnect/resume. It never edits emulator credentials/JWT/JWKS, accepts a browser-provided endpoint or token, or falls back to another capture mode. One persistent macOS `/usr/bin/curl` HTTP/2 client owns each raw stream; no Node/Python/gRPC package is installed or needed at runtime. Curl config/proxies are disabled. The token goes through a private stdin pipe, not argv, a file, a URL, diagnostics or logs. Only a tiny non-secret screenshot request is stored in an owned0700 temporary directory (file0600); closing/replacing/pausing/stopping joins only the owned process and encoder and removes it. Tests use existing Node22/Chrome and an owned loopback HTTP/2 peer, not a real emulator.

The source is change-driven. The receiver validates uncompressed gRPC/protobuf framing, RGBA8888/display0, dimensions/byte count, sequence and timestamp bounds, with at most4096pixels on either edge and32MiB of packed pixels per image; oversized images fail instead of silently changing resolution. It retains one replaceable pending image plus one cached CIImage, one encode/write in flight and the existing bounded encoder pool. The API supplies an already display-oriented packed bitmap; the Mac preserves its left-to-right/top-to-bottom row layout without an extra mirror, row-shuffle or rotation. The installed proto has a legacy “bottom up” comment, but applying another vertical flip inverted the real emulator output. Regression fixtures use four asymmetric corners matching the observed bitmap layout. No emulator display/rotation settings are changed. Window-size changes use the existing350ms budget debounce; losing a window retains the last or initial browser budget (360×800 fallback). Actual raw dimensions may differ slightly due to aspect-ratio scaling. Scrcpy input uses physical display coordinates, never raw/coded dimensions.

With Data saver OFF, the Mac continuously produces NEW H.264 encodes/PTS from the latest pixels at the requested output ceiling, even while the raw API sends nothing; no encoded packet is replayed. With Data saver ON, no new producer update means no new encode, except explicit recovery. Raw does not run a full-image equality scan: duplicate producer updates can still encode. Output FPS/quality adaptation never restarts the raw stream or encoder; a real size/source change can. An inactive-display empty image disables old cached output until a fresh active image arrives. There is an8s initial-image deadline, but no frame-arrival timeout after a valid inactive/active notification: static streams may legitimately stay silent indefinitely. Socket/process termination and malformed replacement pixels invalidate the cache. Stream silence alone cannot distinguish a genuinely static display from a stuck producer; frame age remains honest, with no synthetic capture heartbeats/counters.

`/api/sessions` exposes separate source-frame/raw-pixel-byte, superseded-image, encoder-creation, new H.264/cached-image encode, queue and source-age diagnostics. Zero JPEG encode/decode counters identify the removed stages. Local RGBA traffic is **not** the browser's H.264 bandwidth counter: at410×911×4×60 it is about89.6MB/s, scales with pixels/update rate, and may incur substantial protobuf/pipe/copy overhead. The upstream API has no requested-FPS cap; output pacing bounds Mac encodes, not emulator render events or local raw traffic. **Lower total CPU, 60 distinct motion frames/sec, end-to-end latency, hidden/minimized/headless real-emulator behavior and Safari/VPN acceptance remain unproven.** Existing emulator-host throughput results and synthetic integration tests are not those measurements. Do not call this zero-copy, an automatic JPEG replacement, or a measured CPU improvement.

**Emulator JPEG (manual-only, opt-in):** captures Android's display inside the selected emulator using a bundled, source-built ADB-launched DEX helper, mirrors display0 into one persistent, non-secure Surface/ImageReader, encodes newly produced buffers with Android Bitmap JPEG at fixed **quality70**, and streams framed independent JPEGs over serial-scoped ADB. The Mac validates JPEG byte/dimension bounds, decodes with ImageIO/CIImage and feeds the **existing VideoToolbox H.264 encoder and browser WebCodecs transport**. The Quality slider still controls final Mac H.264; it never changes intermediate JPEG70. There is no Android MediaCodec video encoder, scrcpy video stream, Mac-window crop, gRPC credential or shaping-property write on this capture path. Auto never selects JPEG, and JPEG is not an input option. Input remains Auto/scrcpy/Current; scrcpy control-only input avoids host-window dependencies. Missing scrcpy can fall back for Auto input without replacing manual JPEG capture. Explicit JPEG failures remain visible and latched until reconnect/resume; they never silently switch capture to Mac window or scrcpy.

JPEG needs Android14/API34+ with the hidden static DisplayManager mirroring API, shell CAPTURE_VIDEO_OUTPUT permission, exactly one physical display, the emulator running and its Android display active. The helper inherits the existing ADB UID and never requests root. The persistent mirror was also tested with UID/GID2000, zero effective capabilities and the normal enforcing shell SELinux domain on Android16/API36; other Android versions/devices still require compatibility testing. Unsupported mirroring fails visibly; there is no silent per-frame screenshot fallback. Secure/protected layers are excluded. Unsupported APIs/permissions, failed/empty captures, broken transport and malformed images report errors; an inactive Android screen is not automatically woken. Builds optionally compile the bundled helper using an existing JDK (JAVA_HOME or Android Studio) and Android SDK platform34+ / build-tools (ANDROID_SDK_ROOT, ANDROID_HOME or standard Mac SDK paths); nothing is downloaded or installed by the build. Without those build tools the Mac/iOS app still builds, but the manual JPEG option explains that its helper is absent. Set REQUIRE_ANDROID_JPEG=1 to make helper availability a strict build requirement. The helper source, Apache2 attribution and reproducible build script are under Resources/Android/ and scripts/build-android-jpeg.sh.

The helper creates one persistent RGBA ImageReader mirror and consumes only newly produced buffers, capped at the requested1–60FPS without catch-up bursts. Image availability wakes a handler; acquireLatestImage drops superseded buffers. Three producer buffers, one reusable packed RGBA buffer/Bitmap and one bounded JPEG buffer limit work and allocations. RGBA row padding is stripped without swapping channels; each acquired image is released before JPEG compression or a blocked ADB write. Display dimensions/rotation/activity are checked every250ms and a geometry change releases/recreates the mirror. A missing initial frame fails after5s. While the display is static,1s bounded monotonic SWH1 heartbeats keep the8s host read deadline and10s stalled-writer watchdog alive; heartbeats never increment source-frame counts, mark capture ready or refresh source frame age. An idle mirror may produce zero fresh Android frames/sec. **With Data saver OFF, the Mac still encodes/sends at the requested FPS using the latest available decoded image, just like Mac window.** Every newer received JPEG replaces it; identical JPEG bytes reuse the decoded image without another ImageIO decode. Each H.264 frame is a new VideoToolbox encode with a new timestamp/reference state, never a replayed encoded packet. **Only Data saver ON suppresses unchanged image encodes and may idle at0FPS**; an explicit recovery/keyframe request may send one new IDR from the current image. This preserves event-driven Android capture/JPEG work, not zero Mac encode/network cost. The host retains one replaceable pending JPEG and one decoded image, with at most one decode/encode/write in flight; Mac-side encode pacing compensates small timer jitter without accumulating drift, and rebases missed deadlines without catch-up bursts and consumes pending JPEGs only on admitted work. The most recent image remains usable across static periods while framed transport is healthy; failure, cancellation or the8s transport deadline disables the cache. Corrupt newly received JPEGs fail visibly instead of freezing on older pixels. Source frames/JPEG bytes, idle heartbeats, JPEG decodes, cached-image H.264 encodes, total H.264 encodes and actual sent/rendered FPS are separate counters; re-encoding never increments fresh-source counts or resets source-frame age. Data saver JPEG byte equality is not a universal visual-change detector. Motion throughput and CPU savings require measurement. Intermediate JPEG traffic is local and is not the browser's bandwidth counter. Rotation updates frame dimensions/decoder epoch and refreshes control-only input geometry without changing the gesture's frozen coordinates. Host-window resizing updates the long-edge budget after350ms; without a window it retains the last budget or initial browser dimensions (360×800 fallback), capped at4096. Final H.264 uses the Mac bitrate curve (including its500kbps minimum), not the scrcpy-specific200kbps quality1 trial. The helper follows the user-requested FPS cap, not transient adaptive output FPS. Congestion/recovery changes only local H.264 pacing/bitrate, preserving the mirror, cached pixels and native encoder. Explicit user FPS-cap changes remain debounced source reconfigurations; actual geometry/lifecycle/failure changes still replace invalid state. Quality changes need no source restart. JPEG diagnostics include native encoder creation counts.

Each JPEG session owns a unique private /data/local/tmp directory, JAR, PID and process name. Closing, replacing, pausing, disconnecting or stopping joins only that source/encoder and removes its files; signals verify the exact owned process identity. Remote file removal is best-effort if ADB/the emulator has disconnected; the helper also exits on a broken pipe or stalled-output watchdog. No APK/system installation, ADB server restart, clipboard/power change or global cleanup is used. Current touch input still requires its host window/permissions. Hidden/minimized/headless capture, sustained real-motion quality/latency and Safari acceptance are **not certified** by synthetic integration tests; JPEG is a lossy intermediate. Prior Android-side benchmarks at~410×914 demonstrated60 fresh capture/JPEG completions per second at Q80/Q95, not this integrated Q70 path or60 distinct app-rendered updates. Synthetic JPEG→Mac hardware H.264→Chrome/WebCodecs tests exercise the production pipeline at60FPS separately from those guest benchmarks.

scrcpy input uses persistent touch/key packets, bounded UTF-8 text chunks, and two separate pointer IDs for TalkBack two-finger swipes. Unicode support depends on Android's injection implementation; there is no automatic host/device clipboard synchronization. Appearance retains its existing ADB command. Rotate uses scrcpy with direct capture; with Mac-window capture it retains the emulator-skin rotation command so the window geometry stays aligned. Control-only mode reads actual Android display dimensions once at startup/reconnect. It has no cache TTL or gesture-time ADB calls: rotation completion and changed, valid dimension notifications schedule a debounced asynchronous lookup on a separate worker; duplicate settings are ignored. Browser/window dimensions are hints, never trusted Android coordinates. The last validated geometry remains available during refresh/failure and each gesture freezes one snapshot through DOWN/MOVEs/UP (including both fingers). Superseded results cannot replace a newer change; refresh work is joined at teardown. `/api/sessions` input counters expose geometry, pending refresh and errors. An unannounced external Android resolution change requires a known dimension notification or reconnect; ordinary Mac-window scaling does not expire the cache. A hybrid using Mac-window capture or Current touch input still needs the corresponding host window/permissions.

### React Native console

Run a development Metro server on this Mac at the standard **127.0.0.1:8081** endpoint and stream its simulator/emulator in Simwisp. When a compatible target is discovered, a custom icon appears at the end of that device's lower control bar. Its tooltip/accessibility label is exactly **React-Native console**. Discovery is shared across all streamed devices: immediately on active stream startup (coalesced/debounced during reconnects), then every 30 seconds after the preceding scan completes. It reads metadata only; absent Metro means no icon, and removing the final active stream stops the discovery timer. Failed scans preserve the last successful buttons.

Android targets also match the exact React Native model/OS label (for example, **sdk_gphone64_arm64 - 16 - API 36**) read using serial-scoped ADB system properties during the existing eight-second device-tool cache refresh. The AVD display name and emulator serial remain unchanged. Missing/failed/invalid property reads supply no alias. Identical labels across running emulators require the picker even if only one has an open browser view; a peer with unreadable model properties also makes alias-based mapping inconclusive and requires confirmation; an explicit advertised serial takes precedence and attachment still requires the selected active stream.

Click the icon to create/focus a **Console · App · Device** tab in the existing Terminal popup. Multiple targets or indistinguishable devices require an explicit picker; no first result is silently selected. Confirmed bindings and open-tab descriptors are session-scoped. Console-only use does **not** load xterm, create a shell, require Mac terminal access, or consume the independent eight-terminal quota. The **+** action remains Mac-terminal-only; up to eight console tabs/active upstream targets are allowed independently. Mixed tabs share font size, resize, pinning and the scrolling tab strip.

Console tabs show bounded read-only JavaScript logs/info/warnings/errors and exceptions with expandable source/stack details. Local filters/search, Pause/Resume, Clear and Auto-scroll do not send commands to the app. Pause continues bounded collection; inactive or collapsed panes do no log-row rendering. Retention is at most 5,000 entries/5 MiB per tab and 300 live log rows in a windowed Older/Newer view; dropped entries are counted. Resizing preserves the retained page and reading position; Auto-scroll stays pinned to the newest entry until the user scrolls away or explicitly disables it. Older/Newer navigate the retained ranges independently of the top visible row. No console history is persisted. Closing a tab or explicitly removing its simulator ends the subscription; the last subscriber closes the shared upstream connection. Transient video reconnects retain tabs. Browser reload restores explicitly opened console descriptors without saving log contents or automatically choosing a different app.

Objects/functions/arrays show the supplied inline preview and independent native disclosure arrows, like React Native DevTools. **Only expanding an object** requests its own property descriptors via **Runtime.getProperties**; nested values and [[Prototype]] have separate lazy disclosures. Buffered/replayed objects can be inspected while their runtime references remain valid. Properties are evaluated at expansion time, **not frozen at logging time**. Already loaded tree pages are reused on collapse/reopen; an evicted view can be explicitly expanded/retried again. Runtime/context changes and expired references report unavailability, never fabricate historical values. Object expansion does not change the existing source/stack disclosure. Strings/values/names are always inserted as text; no getters/functions are explicitly invoked by Simwisp and no evaluate/callFunctionOn/debugger commands are exposed. Legacy/runtime-specific Hermes property inspection itself may execute getters; descriptor behavior and actual installed RN/Hermes/Safari compatibility still require manual validation.

Native object IDs stay private: opaque handles are scoped to an upstream generation and only admitted after delivery to the requesting subscriber. Limits: 16 admitted 4KiB client messages at a time (including coalesced log/property ACKs); 4,096 handles per upstream/subscriber; one property result/request/ACK per subscriber, at most 64 upstream calls, 5-second request and 10-second result-ACK deadlines; 1,000 own +128 internal descriptors and a 128KiB response cap with explicit truncation. The browser caches at most 128 property responses/1MiB **inside the existing combined 5MiB log budget**; it renders 100 fields/page, at most 2,000 property rows, with bounded depth/cycle handling. No eager snapshots, property polling or persisted object history. Clear/tab close/disconnect cancel queued work; stale callbacks cannot revive cleared views.

The native backend alone queries Metro's loopback /json/list and resolves private inspector URLs; the remote browser never receives or submits debugger URLs. Discovery has a 5-second/1 MiB/64-target limit and coalesces concurrent calls. Dedicated authenticated, origin-checked **/ws/metro-console** traffic is isolated from video/input and **/ws/pty**, with one read-only **Runtime.enable** per upstream connection and allowlisted, user-triggered **Runtime.getProperties** requests. No evaluate, debugger, explicit accessor/function evaluation, reload, LAN/port scan, native logs or global attach menu is exposed. Pending output is independently limited to 512 entries/1 MiB per subscriber, using one outstanding entry ACK; slow subscribers cannot enqueue unbounded writes or block other targets. Runtime reconnects use capped backoff/shared metadata, never per-tab discovery polls. No debugger-takeover commands are sent; refused attachment is reported. Inspector ownership behavior is runtime/version-specific and still needs manual validation.

Real React Native/Hermes versions may expose different metadata or refuse a second inspector. V1 deliberately supports the standard loopback endpoint only. Missing/inconclusive mapping or attachment reports unavailability rather than guessing. Actual application/runtime compatibility and Safari behavior still need owner validation after deliberate rebuild/relaunch and browser reload. The localhost transport exception does not relax Simwisp's browser HTTPS/WSS/auth policy or allow client-selected hosts.

### Stop a simulator

The power icon beside each running device in **Your devices** asks for confirmation before shutting it down. The bottom toolbar's **Close** button only closes that browser view; it does not stop the device. Stop targets exactly the selected iOS UDID (`simctl shutdown <UDID>`) or Android emulator serial (`adb -s <serial> emu kill`). Other devices, browser views and Mac terminals are not stopped. Unsaved app state may be lost.

The selected view and inspector are removed, its saved open-view entry is cleared, and the device list refreshes once after success. Existing viewers receive an intentional-stop notification rather than reconnecting. Native shutdown waits for that device's capture cleanup, including a recently disconnected/replaced view or pending startup. If cleanup has not settled within 20 seconds, the request fails without scheduling a later shutdown; refresh and retry. A failed shutdown leaves the row available for reopening or retrying, with an error rather than automatic reconnection.

Android Stop distinguishes command acceptance from completion. After a successful serial-targeted kill, it waits up to **eight monotonic seconds**, including inventory command time, for that exact serial to disappear from a valid all-state ADB inventory. If it remains (including offline/unauthorized), or inventory checks fail, the UI shows a neutral **Stop requested; awaiting confirmation** rather than claiming shutdown failed or succeeded. **Refresh devices** performs one fresh authenticated read-only status check for that pending action; confirmed serial absence changes the message to **Stopped**. Offline disappearance from the running-device list alone is not confirmation. No kill is repeated and no background status poll is retained. A further successful refresh dismisses the resolved message; fresh refresh also dismisses prior command errors/window warnings. Failed, cached or stale refresh responses cannot clear/reclassify a newer action. A genuine kill-command failure still shows an error.

On iOS, Simwisp closes only a freshly reidentified, unambiguous selected Simulator window, preserving its actual AX identity across shutdown and checking the selected device is still shut down immediately before close. The adapter reads the full AX window list and all CG layers, including floating Simulator windows. Menu/toolbar/helper surfaces are excluded only when corroborated by an explicitly read AX non-window role and matching bounds/title; generic small, hidden, unnamed or unmatched surfaces still block shared-app quitting. A uniquely identified selected window may be closed despite an unrelated unknown compositor surface, but that uncertainty never authorizes app quit. A normal Simulator quit is requested only after fresh all-window and all-device checks find no remaining windows, no booted/transitional iOS devices and no pending Simwisp launches. Minimized, hidden and other-Space windows count; incomplete inventories, unresolved duplicate device names/windows, missing permissions, close failures or multiple Simulator processes leave the app running. An initial inspection/ambiguity warning can be resolved by a later complete, empty post-shutdown inventory; an actual close failure is never overridden. All-device state is checked again inside the pending-launch guard immediately before the final native window/application recheck. No force quit, app activation, host shortcut or idle polling is used. Successful shutdown with inconclusive window cleanup displays a warning. Accessibility and Screen Recording permissions are required for reliable window inspection; device shutdown can still succeed without them. Checks are conservative snapshots, not an atomic lock against external Xcode/simctl activity. Verify actual native window behavior manually before relying on shared-app quitting.

### Shake an iOS simulator

The **Shake** icon next to Home in each iOS simulator's bottom controls sends **Control–Command–Z** to that simulator's Mac window. It requires Accessibility permission and an open, visible simulator window. Simwisp verifies the selected window is focused before sending the shortcut; if focusing fails, no keys are sent. Control and Command are explicitly pressed and then released after Z key-up, with the final modifier flags cleared. Android has no Shake button and the native backend rejects Shake requests for Android.

### Open the iOS app switcher

The **App switcher** icon (overlapping app cards) sits beside Home and Shake in each iOS simulator's bottom controls. It holds **Shift + Command**, presses and releases **H twice** with a **120 ms pause** between the presses, then explicitly releases Command and Shift, ending with cleared modifier flags. Both H presses target the same verified, focused simulator window on the serial input queue. Accessibility permission and a visible simulator window are required; a failed focus sends no keys. Android reuses the same App switcher icon but sends an ADB keyevent instead; it never posts this iOS shortcut.

### Android navigation controls

Android controls are ordered **Rotate → Home → Back → App switcher → Menu**, followed by appearance and the existing controls. **Back** and **Menu** have custom icons; **App switcher** reuses the iOS overlapping-app-cards icon. With Current input, each sends `adb -s <id> shell input keyevent <code>` through that panel's emulator serial: **Back = 4**, **App switcher = 187**, **Menu = 82**. The previously focused panel does not choose the target. With scrcpy input they send the same key codes over the persistent control socket instead. Neither method uses host keyboard shortcuts or Accessibility/focus requirements. iOS has no Back/Menu buttons and keeps its own App switcher shortcut. Whether Menu opens anything depends on the Android app's handling of the legacy KEYCODE_MENU.

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

The unauthenticated screen offers **Pairing link** or **Authenticator code** when configured. The server accepts the current step ±1 for clock skew and exchanges either credential for the same Secure/HttpOnly/SameSite Strict browser cookie. A successfully accepted step cannot be reused, including after restart; wait for a fresh step when pairing another browser. This is an **alternative credential, not two-factor authentication**. With terminals enabled, either method grants Mac-user shell access. TLS encrypts the transport, but TOTP does not prevent real-time phishing; keep pairing links and trusted clients private.

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
- Browser authentication uses a Secure, HttpOnly, SameSite Strict cookie.
- Workspace, video and terminal traffic use **HTTPS/WSS**, with deliberate local-CA trust on each client. Keep pairing links private and do not expose the port directly to the internet.
- Settings, including the pairing token, are stored outside the repository at `~/Library/Application Support/Simwisp/settings.json`.

## Android TalkBack inspector

On an Android stream, the **A11y** control opens an accessibility pane below the simulator. By default it shows only **TALKBACK SAYS**, reserving exactly three speech lines so incoming text cannot change the pane or simulator size. Longer text scrolls inside it. The grip inside the pane's top edge resizes it without consuming layout space; drag upward to enlarge/downward to shrink, use Up/Down (Shift for larger steps), or double-click/press Enter to reset. Compact and expanded heights are remembered separately per device in this browser, safely clamped when the viewport changes. On very short viewports the pane is capped to preserve simulator/toolbar space. **More…** reveals the observed label, role (when available), tooltip, package/class, bounds, properties and actions; the pane expands in layout flow and the displayed simulator shrinks proportionally. It never covers the stream. **Less** restores the compact view. iOS has no inspector control.

This reads TalkBack's diagnostic logs, **not** an authoritative current selection or full accessibility tree. TalkBack must be enabled with verbose diagnostic logging; Simwisp does not enable it, alter device settings, or clear logs automatically. Without matching events the pane explains that it is waiting. Composed TTS fallback is labeled separately from exact `action=SPEAK`. Password-node content is hidden; no raw logs/history are persisted.

Monitoring is native, bounded and readiness-driven: one serial-targeted ADB reader exists only when that pane is open **and its Android stream is active**. Closing the pane while video continues, pausing/hiding the stream, losing its window, disconnecting, replacing the controller or stopping the server cancels reading and terminates the child. No background logcat reader, parser, polling timer or accessibility sending remains when monitoring is off. Inspector JS/CSS loads locally only on first open. Reconnection opts in only for a pane that is still open. The native popup reports listening/recent sending/paused/error in that Android session's existing details.

## Performance and lifecycle

Streaming uses H.264 Baseline without B-frames, with an explicit zero-reorder SPS for low-latency WebCodecs output. The existing 1–95 quality control selects a resolution-scaled target bitrate (about 6 Mbps at 1080×1920/q20), not image compression. Hardware encoding is preferred where available. Capture keeps the latest pixels; one encode and one local socket write may be active per stream, backed by a three-buffer pixel pool. Native one-shot deadlines pace at the requested FPS ceiling, skipping missed deadlines rather than replaying a burst. There is **no per-frame video ACK gate**: the browser decodes reference frames independently, keeps at most one decoded output for the next animation frame, and closes every superseded, displayed or stale VideoFrame. Receiver feedback is cumulative every **250 ms**, not a permission to send each next frame. Terminal parsing ACKs are separate and unchanged.

Mac-window, Emulator JPEG and Emulator Raw capture share a **3600-frame automatic keyframe interval** (about60seconds at60FPS; longer at lower cadence), with no additional one-second time cap. Repeated short-GOP IDRs can replace a refined static image with a coarsely quantized reference at low bitrate; lengthening the GOP avoids that pumping without extra capture/decoding or changing requested FPS, JPEG70 or the quality→bitrate curve. Startup, real source/geometry changes and explicit decoder/transport recovery still force immediate keyframes; they never wait for the automatic interval. Upstream scrcpy video encoding is unchanged.

Video transport debt is bounded at **120 frames / 1 MiB**, with a single larger IDR allowed alone within the existing hard packet/socket limits. Outstanding metadata survives encoder-epoch changes; old receipts may retire delivered bytes but cannot tune a replacement decoder. Decoder backlog is bounded at **48 pending frames / 8 MiB** (one larger packet may enter alone) and **16 decode inputs**, including the initial asynchronous capability probe. Native capability notification replays settings/readiness after asynchronous device discovery. If admission fails after encoding a P-frame, the server forces a fresh IDR instead of continuing a broken reference chain. This routine Mac/JPEG reference refresh, and a Data saver toggle, keep the same decoder epoch/configuration; genuine source changes, pause/resume and an explicit browser decoder-recovery request still advance the epoch. Outstanding transport debt survives either kind of recovery. Decode overload or **more than two seconds without pending output** resets the decoder and requests a new epoch/IDR; heartbeats cannot hide that stall, including at 1 FPS or in Data saver. An unanswered recovery or unreceived/blocked native write after about **three seconds** reconnects rather than retaining indefinite stale video. No routine decoder flush is used. Server/client pacing versions are negotiated; rebuild the app and reload existing browser tabs together when activating this change.

Data saver skips unchanged images on Mac-window and JPEG capture. With it off, both encode the latest available image continuously at the configured cadence, even if the source has not changed. Neither replays cached encoded P-frames. The upstream scrcpy display source is change-driven even when this setting is off; its finite idle-frame repetition is not a continuous 60fps source. Simwisp reports actual transmitted/rendered frames, never inflates FPS by repainting a cached image. Continuous static-screen encoded output would require additional source support; use Mac window capture when that behavior is required. Idle Data saver with no pending output does not trigger recovery. Slow local writes, finite transport budgets and receiver overload can reduce FPS/bitrate quality; sustained healthy feedback restores them up to the user's targets. TCP can still head-of-line block on loss: **60 FPS and low live latency are targets, not guarantees**, and this architecture alone does not certify Safari or real internet performance. Text sharpness, bandwidth, GPU cost and latency depend on workload and client.

Capture teardown tracks startup, running and terminal states. Closing a simulator window ends only that capture; already-stopped streams are not stopped again, failed starts detach their output, and overlapping cleanup callers await the same teardown. Unexpected cleanup failures remain visible in logs and `/api/status` capture `last_cleanup_error`, but do not block capture startup for unrelated devices.

When the final simulator streaming client disconnects, capture is torn down and the discovery timer is cancelled. The menu-bar popup's monitoring timer exists only while the popup is visible/key. Browser device-list requests still perform on-demand discovery.

Historical JPEG-build no-terminal idle lifecycle verification measured approximately **0.01–0.02% of one CPU core** on the development Mac. A later explicitly sampled terminal review measured **0.0423% with one idle terminal** and **0.0444% with two**, with unchanged PTY I/O counters and no capture demand. Sampling itself adds work; these are short observations, not universal CPU guarantees. The panel's CPU display uses **100% = one core**; measurements are app-process usage, not total simulator or system usage.

Terminal connections never count as simulator streaming demand. PTY reads/writes and child exits are dispatch-event driven on a separate queue; idle terminals do not poll. Cursor blinking and smooth scrolling are disabled. Shell output waits for browser parsing acknowledgements, with at most one bounded chunk in flight; input and replay buffers are capped at 64 KiB. Connected terminal sockets use a low-frequency keepalive; disconnected retention and ACK deadlines are one-shot timers. Actual shell commands naturally consume CPU when doing work.

Only one Simwisp app instance may run at a time; duplicate launches exit without starting another server.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Certificate warning / insecure context | Explicitly trust the exported public CA; use its matching HTTPS name/IP, not HTTP or a warning bypass |
| H.264 unsupported | Update/use a browser with H.264 WebCodecs support; no fallback is retained |
| No frames / device window unavailable | Screen Recording permission; simulator window open and unminimized |
| Frames work, input does not | Accessibility permission; selected simulator window and focus |
| Android devices missing | SDK path, emulator running, and the SDK's `adb devices` output |
| Repeated reconnects | Another browser may be controlling the same device |
| Port already in use | Quit the existing Simwisp instance or choose another `--port` |
| New launch options have no effect | `open` reused an existing instance; quit and relaunch |
| Capture stopped / window closed | Reopen the simulator window; its stream can restart without quitting Simwisp |
| Unexpected capture cleanup error | Inspect `/api/status` capture `last_cleanup_error` and logs; domain/code identify the affected capture |

## Project layout

```text
Sources/                 Native app, capture, H.264, input, discovery, HTTPS, PTYs and streams
Sources/TerminalHost.c    Small native controlling-terminal/login-shell helper
Resources/Web/           Browser workspace: HTML, CSS, and JavaScript
Resources/Info.plist      App metadata and menu-bar-only configuration
Resources/device-sizes.json
Makefile                 Build, signature verification, and launch targets
```

Useful targets:

```bash
make check   # Build, sign, and verify
make test    # Native Metro policy + pairing + accessibility + input + capture + stop + H.264/TLS + pacing; no app launch
make test-stream-flow # Clock-driven pacing, cumulative feedback, budgets and RTT simulations
make test-video-quality # Optional real-codec detailed motion/static/motion regression for native JPEG + Mac-window (~40s)
VIDEO_QUALITY_STATIC_FRAMES=4200 make test-video-quality # Also crosses the automatic GOP boundary (~2.5min)
make test-decoder # Optional isolated decoder fault/lifecycle tests (existing Node)
make test-tls # Optional production HTTPS/auth fixture (existing Node; port45152)
make test-browser-accessibility # Optional isolated browser/transport fixtures
make test-device-control # Inert production AX/CG adapter + shutdown/window/quit-policy checks
make test-browser-device-control # Production API/stream + responsive Stop fixtures (Node22/Chrome, port45152)
make test-android # Native protocol/socket/process/control + JPEG + Raw tests with owned fake peers (Node22)
make test-android-jpeg-surface # Pure host-JVM RGBA stride/color-byte/pacing checks; existing JDK + Android SDK needed
make test-android-jpeg # Synthetic JPEG→ImageIO→VideoToolbox→WebCodecs + manual UI/lifecycle checks
make test-android-raw # Synthetic authenticated HTTP2 RGBA→VideoToolbox→WebCodecs + idle/colour/UI/lifecycle checks
make test-android-parity # Shared bitrate curve, host resize/rotation, headless fallback and independent input budgets
make test-android-performance # 60fps paced source → native HTTPS → WebCodecs/render regression; idle/resume and reset counters
ANDROID_BROWSER=1 make test-android # Full native service/WebCodecs/UI tests, all four combinations (Chrome)
make test-metro-native # Inert metadata/mapping/normalization/queue tests
make test-metro-console # Owned fake Metro + HTTPS/CDP/Chrome/mixed-tab tests (ports 45152/45153)
make run     # Build and open using saved settings
make clean   # Remove build output; quit the app first
```

The input suite tests Android Back/Menu/App switcher eligibility, exact per-serial numeric keyevents and command-error propagation with inert ADB callbacks, plus iOS Shake/App switcher eligibility, focus-before-shortcut ordering, the actual complete keyboard event sequences (modifier down, key down/up, modifier release with neutral final flags), App switcher's two H presses and 120 ms held-modifier pause through the production dispatcher, repeated requests/paste/rotation/Home/plain-key regressions and Android/missing-permission/window/focus rejection with inert host callbacks; it never focuses or controls a real simulator.

The device-control suites also exercise the actual metadata adapter with floating/mixed CG layers, AX-backed menu/toolbar surfaces, duplicate geometry, untitled/minimized/hidden/other-Space windows, malformed records, opaque AX identity reuse and initially uncertain-to-fresh-empty shutdown races. AX test proxies are never queried or acted upon. The suites inject inert command/window/discovery/SCK effects into the production lifecycle: no real simulator shutdown, window close, Simulator quit, host input or shell is performed. API tests exercise authentication/origin, duplicate requests, capture/startup/disconnect barriers, cleanup timeout/retry and pending-launch races. Browser tests exercise confirmation/Cancel, touch/Enter/Space, responsive light/dark controls, selected-view/cache removal, terminal isolation, warnings/errors and intentional-stop reconnect suppression. They do not certify actual native window closure, simulator shutdown or Safari behavior.

The optional browser target requires existing Google Chrome and Node.js 22+ on macOS, and a free loopback port 45151. It serves native-encoded synthetic H.264 frames and TalkBack events over HTTPS/WSS with the real native transport/reader/coordinator code; it does not launch an app bundle or control a device. Override the executable with `make NODE=/path/to/node test-browser-accessibility`. To separately check an existing Android ADB connection, run `NODE=/path/to/node Tests/Browser/run.sh --real-adb`; logcat then runs only while the test pane and fixture stream are open, without changing device settings or injecting navigation. A fresh real speech event still needs manual confirmation. Set `TEST_OUTPUT=/path/outside-the-repository` to retain screenshots/JSON; otherwise temporary fixtures and profiles are removed. Node trusts only the temporary fixture CA via its process environment; Chrome pins only the temporary fixture leaf SPKI. Neither changes OS/browser trust stores. The decoder fixture uses inert WebCodecs/socket mocks to exercise independent submission, latest-only rendering, elapsed output stalls, malformed packets, stale outputs/probes, bounded probe/decoder queues, pause/destruction and missing support. The pacing unit suite uses a deterministic clock with 40/100/400 ms simulated round trips; the browser/transport fixture also delays cumulative telemetry and withholds it while a TLS endpoint stops reading. These are isolated tests, not a live WAN benchmark. The TLS fixture exercises the actual service, authentication/origin checks, Secure cookies, resource delivery and plaintext rejection without allocating a shell or starting capture/discovery. Tests do not certify real-client certificate enrollment, live capture FPS, Safari/Android decoding or real device input.

The Metro fixture uses only an owned fake loopback server on 45153 and an inert production service on 45152, with synthetic H.264 and a synthetic PTY protocol (no host shell, real Metro subscription, device control or trust-store modification). It checks shared discovery, malformed/oversized/redirected inventories, forged bindings/URLs/commands, eight-upstream limits, slow-subscriber eviction, last-subscriber cleanup, escaped logs/exceptions, local controls, keyboard activation, hidden-tab no-render behavior, mixed restoration/quotas/PTY ACK-resize-input, responsive previews and device-associated teardown. Actual React Native integration is not certified by those synthetic tests.

## Development status

**Early development build — version 0.2.0.** Live capture, pairing, multi-device streaming, disconnect/reconnect, and idle cleanup have been exercised on Apple Silicon. The host-architecture build recipe also supports compiling on Intel, but Intel runtime behavior has not been verified.

Some native control combinations still need broader verification, particularly Android rotation and iOS text entry. Terminal PTY/security/lifecycle and desktop/mobile browser controls have been exercised on Apple Silicon. Terminal access is optional and disabled by default; the old JPEG pipeline has been removed rather than kept as a fallback.

The repository contains production source and browser resources only; generated logs, diagnostics, review reports, and app bundles are not checked in.
