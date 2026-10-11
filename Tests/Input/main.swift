import Foundation
import ApplicationServices
import Darwin

// Exercise the actual shortcut policy with inert host effects: no app launch,
// discovery, permission prompt, focus change or HID posting occurs in this suite.
var checks: [[String: Any]] = []
func check(_ name: String, _ pass: @autoclosure () -> Bool) {
    let ok = pass(); checks.append(["name": name, "passed": ok]); if !ok { fputs("FAIL: \(name)\n", stderr) }
}
let expected: Set<String> = ["tap", "drag", "touch_down", "touch_move", "touch_up", "key", "text", "home", "shake", "rotate", "appearance", "accessibility_swipe"]
check("Stream allowlist includes Shake and preserves all prior controls", DeviceInput.supportedTypes == expected)
check("Unknown, shell and settings messages are not input commands", ["unknown", "terminal", "exec", "settings"].allSatisfy { !DeviceInput.supportedTypes.contains($0) })
let first = DeviceWindow(id: 101, pid: 901, title: "First iPhone", bounds: CGRect(x: 30, y: 60, width: 414, height: 896), crop: CGRect(x: 0, y: 30, width: 414, height: 866))
let second = DeviceWindow(id: 102, pid: 901, title: "Second iPhone", bounds: CGRect(x: 500, y: 60, width: 390, height: 844), crop: CGRect(x: 0, y: 30, width: 390, height: 814))
var calls: [String] = [], focused: DeviceWindow?, codes: [CGKeyCode] = [], flags: [CGEventFlags] = []
func attempt(_ platform: String, trusted: Bool = true, window: DeviceWindow? = first, focusOK: Bool = true) -> String? {
    calls = []; focused = nil; codes = []; flags = []
    do {
        try DeviceInput.performShake(platform: platform, trusted: trusted, window: window, focus: { target in
            calls.append("focus"); focused = target; return focusOK
        }, key: { code, modifiers in
            calls.append("key"); codes.append(code); flags.append(modifiers)
        })
        return nil
    } catch { return error.localizedDescription }
}
check("iOS Shake is accepted", attempt("ios") == nil)
check("Selected simulator is focused before the shortcut", calls == ["focus", "key"] && focused == first)
check("Shake sends ANSI Z exactly once", codes == [6])
check("Shake has exactly Control and Command, not Shift or Option", flags.count == 1 && flags[0] == [.maskControl, .maskCommand])
check("Second iOS target is accepted", attempt("ios", window: second) == nil)
check("Same-process simulator windows keep independent targeting", focused == second && focused != first && calls == ["focus", "key"])
check("Android Shake returns an explicit error", attempt("android") == "Shake is iOS-only")
check("Android cannot focus or post a shortcut", calls.isEmpty && focused == nil && codes.isEmpty)
check("Unknown platforms fail closed", attempt("unknown") == "Shake is iOS-only" && calls.isEmpty)
check("Platform matching is exact", attempt("iOS") == "Shake is iOS-only" && calls.isEmpty)
check("Missing Accessibility returns an input error", attempt("ios", trusted: false)?.contains("Accessibility permission") == true)
check("Missing permission never focuses or sends keys", calls.isEmpty && codes.isEmpty)
check("Missing window is rejected", attempt("ios", window: nil)?.contains("visible iOS Simulator window") == true)
check("Missing window never focuses or sends keys", calls.isEmpty && codes.isEmpty)
check("Failed focus is rejected", attempt("ios", focusOK: false)?.contains("Cannot focus the selected") == true)
check("Failed focus cannot send the shortcut to another host app", calls == ["focus"] && codes.isEmpty)
check("A new attempt works after a focus failure", attempt("ios", window: second) == nil && focused == second && codes == [6])
// Test the SAME complete CGEvent sequence used by the production dispatcher,
// without posting any event. Checking only Z down/up missed sticky modifiers.
let shake = try DeviceInput.keyboardEvents(codes[0], flags: flags[0])
func keyCodes(_ events: [CGEvent]) -> [Int64] { events.map { $0.getIntegerValueField(.keyboardEventKeycode) } }
check("Shake emits six events including modifier press and release", shake.count == 6)
check("Shake key order: Control down, Command down, Z down/up, Command up, Control up", keyCodes(shake) == [59, 55, 6, 6, 55, 59])
check("Modifier keys use native flagsChanged events", shake.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
let control: CGEventFlags = .maskControl, both: CGEventFlags = [.maskControl, .maskCommand]
check("Modifier flags track each press and reverse-order release", shake.map(\.flags) == [control, both, both, both, control, []])
check("Z has one key-down and one key-up with the exact chord flags", shake[2].type == .keyDown && shake[3].type == .keyUp && shake[2].flags == both && shake[3].flags == both)
check("Command release retains only Control", shake[4].type == .flagsChanged && shake[4].flags == control && shake[4].getIntegerValueField(.keyboardEventKeycode) == 55)
check("Final Control release clears ALL synthetic modifier flags", shake.last?.type == .flagsChanged && shake.last?.flags == [] && shake.last?.getIntegerValueField(.keyboardEventKeycode) == 59)
check("Every generated event is non-repeating", shake.allSatisfy { $0.getIntegerValueField(.keyboardEventAutorepeat) == 0 })
var repeatedOK = true
for _ in 0..<200 {
    let next = try DeviceInput.keyboardEvents(6, flags: both)
    repeatedOK = repeatedOK && keyCodes(next) == [59,55,6,6,55,59] && next.last?.flags == []
}
check("Repeated Shake sequences always end released with no inherited flags", repeatedOK)
// All currently used native shortcuts share this helper; prevent regressions
// in paste, rotation, the Home fallback and ordinary unmodified keyboard input.
let paste = try DeviceInput.keyboardEvents(9, flags: .maskCommand)
check("Paste emits Command down, V down/up, Command up", keyCodes(paste) == [55,9,9,55] && paste.map(\.type) == [.flagsChanged,.keyDown,.keyUp,.flagsChanged])
check("Paste finishes with Command released", paste.map(\.flags) == [.maskCommand,.maskCommand,.maskCommand,[]])
for code: CGKeyCode in [123,124] {
    let rotate = try DeviceInput.keyboardEvents(code, flags: .maskCommand)
    check("Rotation key \(code) keeps its key and releases Command", keyCodes(rotate) == [55,Int64(code),Int64(code),55] && rotate[1].flags == .maskCommand && rotate[2].type == .keyUp && rotate.last?.flags == [])
}
let home = try DeviceInput.keyboardEvents(4, flags: [.maskCommand,.maskShift])
check("Home fallback presses Shift/Command and releases in reverse order", keyCodes(home) == [56,55,4,4,55,56])
check("Home fallback preserves its chord and clears final flags", home.map(\.flags) == [.maskShift,[.maskCommand,.maskShift],[.maskCommand,.maskShift],[.maskCommand,.maskShift],.maskShift,[]])
for code: CGKeyCode in [51,36,48,53,123,124,125,126,115,119,116,121] {
    let plain = try DeviceInput.keyboardEvents(code)
    check("Plain key \(code) remains a neutral down/up pair", keyCodes(plain) == [Int64(code),Int64(code)] && plain.map(\.type) == [.keyDown,.keyUp] && plain.allSatisfy { $0.flags == [] })
}
let modifierCodes: [CGKeyCode] = [59,58,56,55], modifierFlags: [CGEventFlags] = [.maskControl,.maskAlternate,.maskShift,.maskCommand]
for mask in 0..<16 {
    let selected = (0..<4).filter { mask & (1 << $0) != 0 }
    var chord: CGEventFlags = []; selected.forEach { chord.insert(modifierFlags[$0]) }
    let sequence = try DeviceInput.keyboardEvents(6, flags: chord)
    let expectedKeys = selected.map { Int64(modifierCodes[$0]) } + [6,6] + selected.reversed().map { Int64(modifierCodes[$0]) }
    check("Modifier combination \(mask) has balanced keys and a neutral final state", keyCodes(sequence) == expectedKeys && sequence.count == 2+selected.count*2 && sequence[selected.count].flags == chord && sequence[selected.count+1].type == .keyUp && sequence.last?.flags == [])
}
var keyboardErrorReported = false
do {
    try DeviceInput.performShake(platform: "ios", trusted: true, window: first, focus: { _ in true }, key: { _,_ in
        throw WispError("fixture keyboard allocation failure")
    })
} catch { keyboardErrorReported = error.localizedDescription == "fixture keyboard allocation failure" }
check("Keyboard construction errors propagate instead of claiming successful input", keyboardErrorReported)

let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "hostEffects": false], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
exit(passed ? 0 : 1)
