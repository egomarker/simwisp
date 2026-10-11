import Foundation
import AppKit
import ApplicationServices

// Global HID mouse input must be serialized across devices. A new gesture
// releases any prior pointer instead of leaving the host mouse pressed.
final class DeviceInput {
    static let supportedTypes: Set<String> = ["tap", "drag", "touch_down", "touch_move", "touch_up", "key", "text", "home", "shake", "app_switcher", "rotate", "appearance", "accessibility_swipe"]

    // Isolate the shortcut policy from host effects so tests never focus or control a real device.
    static func performShake(platform: String, trusted: Bool, window: DeviceWindow?, focus: (DeviceWindow) -> Bool, key: (CGKeyCode, CGEventFlags) throws -> Void) throws {
        guard platform == "ios" else { throw WispError("Shake is iOS-only") }
        guard trusted, let window else { throw WispError("Shake requires Accessibility permission and a visible iOS Simulator window") }
        guard focus(window) else { throw WispError("Cannot focus the selected iOS Simulator window for Shake") }
        try key(6, [.maskControl, .maskCommand]) // ANSI Z: Simulator's Control–Command–Z shortcut.
    }

    static func performAppSwitcher(platform: String, trusted: Bool, window: DeviceWindow?, focus: (DeviceWindow) -> Bool, key: (CGKeyCode, CGEventFlags, Int) throws -> Void) throws {
        guard platform == "ios" else { throw WispError("App switcher is iOS-only") }
        guard trusted, let window else { throw WispError("App switcher requires Accessibility permission and a visible iOS Simulator window") }
        guard focus(window) else { throw WispError("Cannot focus the selected iOS Simulator window for App switcher") }
        try key(4, [.maskShift, .maskCommand], 2) // ANSI H twice, holding both modifiers throughout.
    }

    let devices: Devices
    let queue = DispatchQueue(label: "Simwisp.input", qos: .userInteractive)
    private var gesture: (
        id: String,
        window: DeviceWindow,
        point: CGPoint,
        started: Double,
        yOffset: CGFloat
    )?
    private var adbInputSizes: [String: (checked: Double, width: Int, height: Int)] = [:]
    init(devices: Devices) { self.devices = devices }
    func cancel(_ id: String) {
        queue.async {
            if let state = self.gesture, state.id == id { self.mouse(.leftMouseUp, state.point); self.gesture = nil }
        }
    }
    private func mouse(_ kind: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    // Construct the entire chord before posting anything: modifier releases must
    // not depend on whether a later CGEvent allocation succeeds. A private source
    // avoids inheriting stale synthetic modifier flags from the host session.
    static func keyboardEvents(_ code: CGKeyCode, flags: CGEventFlags = [], presses: Int = 1) throws -> [CGEvent] {
        guard (1...2).contains(presses) else { throw WispError("Keyboard shortcut requires one or two presses") }
        guard let source = CGEventSource(stateID: .privateState) else { throw WispError("Cannot create keyboard event source") }
        let modifiers: [(CGKeyCode, CGEventFlags)] = [(59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand)]
        let pressed = modifiers.filter { flags.contains($0.1) }
        var events: [CGEvent] = [], held: CGEventFlags = []
        func append(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) throws {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { throw WispError("Cannot create keyboard event") }
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            events.append(event)
        }
        for (key, modifier) in pressed {
            held.insert(modifier)
            try append(key, down: true, flags: held)
        }
        for _ in 0..<presses {
            try append(code, down: true, flags: flags)
            try append(code, down: false, flags: flags)
        }
        // Keep modifiers held across both presses, then send their actual
        // flagsChanged key-up events in reverse order, clearing the final flags.
        for (key, modifier) in pressed.reversed() {
            held.remove(modifier)
            try append(key, down: false, flags: held)
        }
        return events
    }
    // Inject posting/sleep only for inert tests; production uses this same dispatcher.
    // Allocate all events before the first post, so releases cannot be skipped by
    // a later allocation failure. This runs exclusively on the serial input queue.
    static func sendKeyboard(_ code: CGKeyCode, flags: CGEventFlags = [], presses: Int = 1, post: (CGEvent) -> Void, sleep: (TimeInterval) -> Void) throws {
        let events = try keyboardEvents(code, flags: flags, presses: presses)
        for (index, event) in events.enumerated() {
            post(event)
            // The only extended gap is between the first key-up and second key-down.
            let betweenPresses = event.type == .keyUp && index + 1 < events.count && events[index + 1].type == .keyDown
            sleep(betweenPresses ? 0.12 : 0.01)
        }
    }
    private func key(_ code: CGKeyCode, flags: CGEventFlags = [], presses: Int = 1) throws {
        try Self.sendKeyboard(code, flags: flags, presses: presses,
                              post: { $0.post(tap: .cghidEventTap) }, sleep: { Thread.sleep(forTimeInterval: $0) })
    }
    @discardableResult private func focus(_ window: DeviceWindow, verify: Bool = false) -> Bool {
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        let app = AXUIElementCreateApplication(window.pid)
        if verify { AXUIElementSetMessagingTimeout(app, 0.2) }
        var target: AXUIElement?
        for root in axAttribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            if let frame = axFrame(root), abs(frame.minX - window.bounds.minX) < 5, abs(frame.minY - window.bounds.minY) < 5,
               !verify || (abs(frame.width - window.bounds.width) < 5 && abs(frame.height - window.bounds.height) < 5) {
                AXUIElementPerformAction(root, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, root)
                target = root
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.06)
        guard verify else { return true }
        // Never send a host shortcut to a different app or simulator window if focusing failed.
        guard let target, let focused = axAttribute(app, kAXFocusedWindowAttribute), CFEqual(target, focused),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else { return false }
        return true
    }
    private func adb(_ id: String, _ args: [String]) throws -> CommandResult {
        guard let adb = devices.adb else { throw WispError("Android SDK adb unavailable") }
        let result = try command(adb, ["-s", id] + args, timeout: 8)
        if result.status != 0 { throw WispError(String(decoding: result.error, as: UTF8.self)) }
        return result
    }
    private func adbInputSize(_ id: String, landscape: Bool) throws -> (Int, Int) {
        // ADB gestures require Android display pixels, not the Quartz-sized
        // browser canvas. Resolve these on demand only on the input queue.
        let size: (checked: Double, width: Int, height: Int)
        if let cached = adbInputSizes[id], monotonic() - cached.checked < 8 { size = cached }
        else {
            let output = try adb(id, ["shell", "wm", "size"]).text
            // The last size is the effective override, when one is present.
            guard let line = output.components(separatedBy: .newlines).last(where: { $0.range(of: "[0-9]+x[0-9]+", options: .regularExpression) != nil }),
                  let range = line.range(of: "[0-9]+x[0-9]+", options: .regularExpression) else { throw WispError("Cannot read Android input dimensions") }
            let numbers = line[range].split(separator: "x").compactMap { Int($0) }
            guard numbers.count == 2, numbers[0] > 0, numbers[1] > 0 else { throw WispError("Invalid Android input dimensions") }
            size = (monotonic(), numbers[0], numbers[1]); adbInputSizes[id] = size
        }
        return landscape ? (max(size.width, size.height), min(size.width, size.height)) : (min(size.width, size.height), max(size.width, size.height))
    }
    func perform(_ message: [String: Any], id: String, completion: @escaping ([String: Any]?) -> Void) {
        queue.async {
            do { completion(try self.handle(message, id: id)) }
            catch { completion(["type": "input_error", "message": error.localizedDescription]); log("Input: \(error.localizedDescription)") }
        }
    }
    private func handle(_ m: [String: Any], id: String) throws -> [String: Any]? {
        guard let type = m["type"] as? String, let device = devices.device(id) else { throw WispError("Device is not available") }
        let android = device.platform == "android"
        let window = devices.window(id)
        func number(_ key: String) -> Double { clamp((m[key] as? NSNumber)?.doubleValue ?? 0) }
        switch type {
        case "touch_down":
            guard AXIsProcessTrusted(), let window else {
                throw WispError("Live input requires Accessibility and a visible device window")
            }

            if let state = gesture {
                mouse(.leftMouseUp, state.point)
                gesture = nil
            }

            var point = window.point(number("x"), number("y"))

            // For iOS only: if the gesture begins within 10pt of the
            // bottom of the iOS content, shift the entire gesture 20pt down.
            let contentBottom = window.bounds.minY + window.crop.maxY
            let yOffset: CGFloat =
                !android && point.y >= contentBottom - 10 ? 20 : 0

            point.y += yOffset

            mouse(.leftMouseDown, point)

            gesture = (
                id: id,
                window: window,
                point: point,
                started: monotonic(),
                yOffset: yOffset
            )
        case "touch_move":
            if var state = gesture, state.id == id {
                var point = state.window.point(number("x"), number("y"))
                point.y += state.yOffset

                if point != state.point {
                    mouse(.leftMouseDragged, point)
                    state.point = point
                    gesture = state
                }
            }
        case "touch_up":
            if let state = gesture, state.id == id {
                var point = state.window.point(number("x"), number("y"))
                point.y += state.yOffset

                if point != state.point {
                    mouse(.leftMouseDragged, point)
                }

                Thread.sleep(
                    forTimeInterval: max(
                        0,
                        0.02 - (monotonic() - state.started)
                    )
                )

                mouse(.leftMouseUp, point)
                gesture = nil
            }
        case "tap", "drag":
            guard let window, AXIsProcessTrusted() else { throw WispError("Input requires a visible window and Accessibility permission") }
            let first = window.point(number(type == "tap" ? "x" : "x1"), number(type == "tap" ? "y" : "y1"))
            if let state = gesture { mouse(.leftMouseUp, state.point); gesture = nil }
            mouse(.leftMouseDown, first)
            if type == "drag" {
                let end = window.point(number("x2"), number("y2"))
                for step in 1...20 { let t = Double(step) / 20; mouse(.leftMouseDragged, CGPoint(x: first.x + (end.x - first.x) * t, y: first.y + (end.y - first.y) * t)); Thread.sleep(forTimeInterval: 0.015) }
                mouse(.leftMouseUp, end)
            } else { Thread.sleep(forTimeInterval: 0.025); mouse(.leftMouseUp, first) }
        case "accessibility_swipe":
            guard android else { return nil }
            let (w, h) = try adbInputSize(id, landscape: window?.landscape ?? false)
            _ = try adb(id, ["shell", "input", "swipe", String(Int(number("x1") * Double(w))), String(Int(number("y1") * Double(h))), String(Int(number("x2") * Double(w))), String(Int(number("y2") * Double(h))), "300"])
        case "key":
            let name = (m["key"] as? String ?? "").lowercased()
            if android {
                let map = ["home": "KEYCODE_HOME", "back": "KEYCODE_BACK", "return": "KEYCODE_ENTER", "enter": "KEYCODE_ENTER", "delete": "KEYCODE_DEL", "backspace": "KEYCODE_DEL", "escape": "KEYCODE_ESCAPE", "space": "KEYCODE_SPACE", "tab": "KEYCODE_TAB", "arrowleft": "KEYCODE_DPAD_LEFT", "arrowright": "KEYCODE_DPAD_RIGHT", "arrowup": "KEYCODE_DPAD_UP", "arrowdown": "KEYCODE_DPAD_DOWN"]
                if let key = map[name] { _ = try adb(id, ["shell", "input", "keyevent", key]) }
            } else {
                guard AXIsProcessTrusted(), let window else { throw WispError("Keyboard input requires Accessibility") }
                focus(window)
                let map: [String: CGKeyCode] = ["backspace": 51, "delete": 51, "return": 36, "enter": 36, "tab": 48, "escape": 53, "arrowleft": 123, "arrowright": 124, "arrowdown": 125, "arrowup": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121]
                if let code = map[name] { try key(code) }
            }
        case "text":
            let text = m["text"] as? String ?? ""
            guard text.utf8.count <= 16_384 else { throw WispError("Text is too long") }
            if android {
                // Quote one remote shell argument rather than interpolating user input as a command.
                let encoded = text.replacingOccurrences(of: " ", with: "%s").replacingOccurrences(of: "'", with: "'\\''")
                _ = try adb(id, ["shell", "input text '\(encoded)'"])
            } else {
                guard AXIsProcessTrusted(), let window else { throw WispError("Typing requires Accessibility") }
                focus(window)
                // Simulator forwards paste reliably; Unicode CGEvent injection is not
                // equivalent to UIKit text input. Preserve the user's clipboard if
                // nobody else changes it before the Simulator consumes the paste.
                let board = NSPasteboard.general
                let previous = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
                    let copy = NSPasteboardItem()
                    for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                    return copy
                }
                board.clearContents(); board.setString(text, forType: .string)
                let count = board.changeCount
                try key(9, flags: .maskCommand)
                Thread.sleep(forTimeInterval: 0.25)
                if board.changeCount == count { board.clearContents(); if !previous.isEmpty { board.writeObjects(previous) } }
            }
        case "home":
            if android { _ = try adb(id, ["shell", "input", "keyevent", "KEYCODE_HOME"]) }
            else {
                let result = try command("/usr/bin/xcrun", ["simctl", "launch", id, "com.apple.springboard"], timeout: 8)
                if result.status != 0, let window { focus(window); try key(4, flags: [.maskCommand, .maskShift]) }
            }
        case "shake":
            try Self.performShake(platform: device.platform, trusted: AXIsProcessTrusted(), window: window,
                                  focus: { self.focus($0, verify: true) }, key: { try self.key($0, flags: $1) })
        case "app_switcher":
            try Self.performAppSwitcher(platform: device.platform, trusted: AXIsProcessTrusted(), window: window,
                                        focus: { self.focus($0, verify: true) }, key: { try self.key($0, flags: $1, presses: $2) })
        case "appearance":
            let mode = m["mode"] as? String == "light" ? "light" : "dark"
            if android { _ = try adb(id, ["shell", "cmd", "uimode", "night", mode == "dark" ? "yes" : "no"]) }
            else { _ = try command("/usr/bin/xcrun", ["simctl", "ui", id, "appearance", mode]) }
        case "rotate":
            guard let window else { return ["type": "rotate_failed"] }
            if android {
                // Rotate the emulator window/skin as well as Android's orientation.
                // Merely setting user_rotation leaves a sideways picture inside a
                // portrait host window. Console rotate advances the skin 90 degrees.
                _ = try adb(id, ["shell", "settings", "put", "system", "accelerometer_rotation", "1"])
                for _ in 0..<(window.landscape ? 3 : 1) {
                    _ = try adb(id, ["emu", "rotate"])
                    Thread.sleep(forTimeInterval: 0.12)
                }
            } else {
                guard AXIsProcessTrusted() else { return ["type": "rotate_failed"] }
                focus(window)
                // Simulator's public keyboard shortcuts avoid AppleScript Automation and an XCTest harness.
                try key(window.landscape ? 124 : 123, flags: .maskCommand)
            }
            devices.invalidate()
            let deadline = monotonic() + 4
            while monotonic() < deadline {
                if let updated = devices.window(id), updated.landscape != window.landscape { return ["type": "rotated", "landscape": updated.landscape] }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return ["type": "rotate_failed"]
        default: break
        }
        return nil
    }
}
