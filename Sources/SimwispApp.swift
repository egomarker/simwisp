import SwiftUI
import AppKit
import ApplicationServices

final class Controller: ObservableObject {
    static let shared = Controller()
    @Published var settings = Settings.load()
    @Published var state = "Starting"
    @Published var sessions: [[String: Any]] = []
    @Published var cpu: Double = 0
    @Published var memory: UInt64 = 0
    @Published var screenPermission = false
    @Published var inputPermission = false
    private(set) var panelVisible = false
    private var panelRefreshes: UInt64 = 0
    private var service: Service?
    private var timer: Timer?
    private var usage = Usage()
    private var started = false
    init() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--port"), index + 1 < args.count, let port = Int(args[index + 1]), (1024...65535).contains(port) { settings.port = port }
        if args.contains("--lan") { settings.shareLAN = true }
        if args.contains("--terminal") { settings.terminalEnabled = true }
        if args.contains("--no-terminal") { settings.terminalEnabled = false }
        if let index = args.firstIndex(of: "--project-dir"), index + 1 < args.count { settings.projectDirectory = args[index + 1] }
        if let index = args.firstIndex(of: "--android-sdk"), index + 1 < args.count { settings.androidSDK = args[index + 1] }
    }
    func start() {
        guard !started else { return }; started = true
        screenPermission = CGPreflightScreenCaptureAccess(); inputPermission = AXIsProcessTrusted()
        let service = Service(settings: settings); self.service = service
        service.stateChanged = { [weak self] state in DispatchQueue.main.async { self?.state = state } }
        do { try service.start() } catch { state = error.localizedDescription; started = false; service.stop() }
        if panelVisible { startPanelRefresh() }
        log("Listening on \(settings.shareLAN ? "LAN" : "localhost") port \(settings.port); terminal \(settings.terminalEnabled == true ? "enabled" : "disabled")")
    }
    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible { startPanelRefresh() }
        else { timer?.invalidate(); timer = nil; publishPanelState() }
    }
    private func startPanelRefresh() {
        guard panelVisible else { return }
        timer?.invalidate(); usage = Usage()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPanel() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        refreshPanel()
    }
    private func refreshPanel() {
        guard panelVisible else { return }
        panelRefreshes &+= 1
        usage.sample(); cpu = usage.cpu; memory = usage.memory
        screenPermission = CGPreflightScreenCaptureAccess(); inputPermission = AXIsProcessTrusted()
        service?.snapshots { [weak self] rows in
            DispatchQueue.main.async { guard let self, self.panelVisible else { return }; self.sessions = rows }
        }
        publishPanelState()
    }
    private func publishPanelState() { service?.updatePanelState(visible: panelVisible, refreshing: timer != nil, count: panelRefreshes) }
    func stop(completion: @escaping () -> Void = {}) {
        timer?.invalidate(); timer = nil; publishPanelState(); started = false
        guard let old = service else { state = "Stopped"; completion(); return }
        service = nil; state = "Stopping"
        old.stop { self.state = "Stopped"; self.sessions = []; completion() }
    }
    func restart() { stop { self.settings.save(); self.start() } }
    var baseURL: String { "http://\(settings.shareLAN ? localAddress() ?? "127.0.0.1" : "127.0.0.1"):\(settings.port)" }
    var pairingURL: String { baseURL + "/#pair=" + settings.pairingToken }
    func openBrowser() { if let url = URL(string: pairingURL) { NSWorkspace.shared.open(url) } }
    func copyURL() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pairingURL, forType: .string) }
    func chooseProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Choose project"
        panel.directoryURL = URL(fileURLWithPath: settings.projectDirectory)
        if panel.runModal() == .OK, let url = panel.url { settings.projectDirectory = url.path; restart() }
    }
    func requestScreen() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func requestInput() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}

struct StatusPanel: View {
    @ObservedObject var controller: Controller
    @State private var portText = ""
    @State private var showSettings = false
    @State private var contentHeight: CGFloat = 360
    @State private var availableHeight = max(1, (NSScreen.main?.visibleFrame.height ?? 900) - 24)
    private var popupHeight: CGFloat { min(contentHeight, availableHeight) }
    var body: some View {
        // Measure the complete intrinsic content, not a flexible session
        // ScrollView (whose ideal height does not grow with its rows).
        ScrollView(.vertical) {
            panelContent
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PanelHeight.self, value: geometry.size.height)
                })
        }
        .scrollDisabled(contentHeight <= availableHeight)
        .scrollIndicators(contentHeight > availableHeight ? .automatic : .hidden)
        .frame(width: 360, height: popupHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelVisibility(size: CGSize(width: 360, height: popupHeight), screenHeightChanged: { availableHeight = $0 }) { controller.setPanelVisible($0) })
        .onPreferenceChange(PanelHeight.self) { height in
            guard height.isFinite, height > 0 else { return }
            let measured = ceil(height)
            if abs(contentHeight - measured) > 0.5 { contentHeight = measured }
        }
        .onAppear { portText = String(controller.settings.port) }
        .onDisappear { controller.setPanelVisible(false) }
    }
    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) { Text("Simwisp").font(.headline); Text("Native simulator streaming").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Circle().fill(controller.state == "Running" ? Color.green : Color.orange).frame(width: 7, height: 7)
            }
            HStack {
                Text(controller.state).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Text("ScreenCaptureKit").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 3) { Text("CPU").font(.caption2).foregroundStyle(.secondary); Text(String(format: "%.1f%%", controller.cpu)).font(.system(.title3, design: .rounded)).monospacedDigit() }
                VStack(alignment: .leading, spacing: 3) { Text("MEMORY").font(.caption2).foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: Int64(controller.memory), countStyle: .memory)).font(.system(.title3, design: .rounded)).monospacedDigit() }
                Spacer()
                Text("App process\n100% = one core").font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.trailing)
            }
            Divider()
            HStack { Text("STREAMED SESSIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Text(String(controller.sessions.count)).font(.caption).foregroundStyle(.secondary) }
            if controller.sessions.isEmpty {
                Text("No active streams. Open the browser workspace and choose a device.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 10) {
                    ForEach(controller.sessions.indices, id: \.self) { index in
                        let row = controller.sessions[index]
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "iphone").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row["name"] as? String ?? "Device").font(.callout.weight(.medium))
                                Text(row["state"] as? String ?? "Streaming").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(row["peer"] as? String ?? "").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(row["fps"] as? Int ?? 0) fps").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !controller.screenPermission || !controller.inputPermission {
                Divider()
                if !controller.screenPermission { Button("Allow Screen Recording…") { controller.requestScreen() } }
                if !controller.inputPermission { Button("Allow Accessibility…") { controller.requestInput() } }
                Text("macOS may require quitting and reopening after permission changes.").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            Text(controller.baseURL).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Open workspace", systemImage: "arrow.up.right.square") { controller.openBrowser() }.buttonStyle(.borderedProminent).tint(.orange)
                Button("Copy link", systemImage: "doc.on.doc") { controller.copyURL() }.buttonStyle(.bordered)
            }
            DisclosureGroup("Server settings", isExpanded: $showSettings) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Share on local network", isOn: $controller.settings.shareLAN).onChange(of: controller.settings.shareLAN) { controller.restart() }
                    Toggle("Allow Mac terminal access", isOn: Binding(get: { controller.settings.terminalEnabled == true }, set: { controller.settings.terminalEnabled = $0; controller.restart() }))
                    Text("Terminal access lets paired browsers run commands as your Mac user. Enable only for trusted browsers.").font(.caption2).foregroundStyle(.secondary)
                    Text("Links authorize control. LAN HTTP is unencrypted; use only a trusted network or an encrypted tunnel.").font(.caption2).foregroundStyle(.secondary)
                    HStack { Text("Port"); TextField("4141", text: $portText).frame(width: 70); Button("Apply") { if let port = Int(portText), (1024...65535).contains(port) { controller.settings.port = port; controller.restart() } }.disabled(!(Int(portText).map { (1024...65535).contains($0) } ?? false)) }
                    Button("Choose project directory…") { controller.chooseProject() }
                    Text(controller.settings.projectDirectory).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }.padding(.top, 8)
            }.font(.callout)
            HStack {
                Button(controller.state == "Stopped" ? "Start server" : "Stop server") { if controller.state == "Stopped" { controller.start() } else { controller.stop() } }
                Spacer(); Button("Quit Simwisp") { NSApplication.shared.terminate(nil) }
            }.font(.caption)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PanelHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// A MenuBarExtra window can stay mounted while hidden, so SwiftUI onAppear /
// onDisappear alone are not a reliable visibility signal. Observe its actual
// key-window lifetime; closing or resigning the popup stops the refresher.
private struct PanelVisibility: NSViewRepresentable {
    let size: CGSize
    let screenHeightChanged: (CGFloat) -> Void
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> PanelVisibilityView { let view = PanelVisibilityView(); updateNSView(view, context: context); return view }
    func updateNSView(_ view: PanelVisibilityView, context: Context) {
        view.changed = changed; view.screenHeightChanged = screenHeightChanged; view.preferredSize = size
        view.requestResize()
    }
    static func dismantleNSView(_ view: PanelVisibilityView, coordinator: ()) { view.detach() }
}
private final class PanelVisibilityView: NSView {
    var changed: ((Bool) -> Void)?
    var screenHeightChanged: ((CGFloat) -> Void)?
    var preferredSize = CGSize.zero
    private var resizeScheduled = false
    private var observers: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); detach()
        guard let window else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.changed?(true); self?.requestResize() })
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.changed?(false) })
        }
        observers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in self?.requestResize() })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.requestResize() })
        DispatchQueue.main.async { [weak self, weak window] in
            self?.changed?(window?.isVisible == true && window?.isKeyWindow == true); self?.requestResize()
        }
    }
    func requestResize() {
        guard window?.isVisible == true, !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in self?.resizeScheduled = false; self?.resizeToContent() }
    }
    private func resizeToContent() {
        guard let window, window.isVisible, preferredSize.width > 0, preferredSize.height > 0 else { return }
        let area = (window.screen ?? NSScreen.main)?.visibleFrame
        let limit = max(1, (area?.height ?? 900) - 24)
        screenHeightChanged?(limit)
        let size = CGSize(width: preferredSize.width, height: min(preferredSize.height, limit))
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else { return }
        // Grow down from the existing menu-bar anchor, without animation.
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.maxX - frame.width, y: window.frame.maxY - frame.height)
        if let area {
            frame.origin.x = max(area.minX, min(frame.origin.x, area.maxX - frame.width))
            frame.origin.y = max(area.minY + 12, min(frame.origin.y, area.maxY - frame.height))
        }
        window.setFrame(frame, display: true, animate: false)
    }
    func detach() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        changed?(false)
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signals: [DispatchSourceSignal] = []
    private var cleaningUp = false
    private var readyToQuit = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let identifier = Bundle.main.bundleIdentifier ?? "io.simwisp.app"
        let pid = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != pid && !$0.isTerminated }) {
            fputs("Simwisp is already running (PID \(existing.processIdentifier)); refusing a duplicate instance.\n", stderr)
            readyToQuit = true; NSApplication.shared.terminate(nil); return
        }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }; source.resume(); signals.append(source)
        }
        Controller.shared.start()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToQuit { return .terminateNow }
        if !cleaningUp {
            cleaningUp = true
            // Cancel this first quit so AppKit does not enter its modal terminate
            // loop while ScreenCaptureKit cleanup needs main-actor execution.
            Controller.shared.stop {
                self.readyToQuit = true
                RunLoop.main.perform { sender.terminate(nil) }
            }
        }
        return .terminateCancel
    }
}

@main
struct SimwispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var controller = Controller.shared
    var body: some Scene {
        MenuBarExtra("Simwisp", systemImage: "sparkles") { StatusPanel(controller: controller) }.menuBarExtraStyle(.window)
    }
}
