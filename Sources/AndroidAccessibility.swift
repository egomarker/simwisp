import Foundation

// Explicit menu requests only: no discovery hooks, subscriptions, or timers.
enum AndroidAccessibility {
    typealias Runner = (String, [String], Double) throws -> CommandResult
    static let talkBackService = "com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService"
    enum Setting: String, Codable, CaseIterable {
        case talkback, textSize = "text_size", boldFont = "bold_font", highContrast = "high_contrast"
    }
    struct Change: Decodable { let setting: Setting; let enabled: Bool }
    static func change(_ body: Data) throws -> Change {
        guard body.count <= 256 else { throw WispError("Accessibility request is too large") }
        return try JSONDecoder().decode(Change.self, from: body)
    }
    private static func run(_ adb: String, _ serial: String, _ args: [String], using runner: Runner) throws -> String {
        guard DeviceControl.validADBSerial(serial) else { throw WispError("Invalid Android device identifier") }
        let result = try runner(adb, ["-s", serial, "shell", "settings"] + args, 3)
        guard result.status == 0, result.output.count <= 16_384,
              let text = String(data: result.output, encoding: .utf8),
              !(text + "\n" + String(decoding: result.error, as: UTF8.self)).lowercased().components(separatedBy: .newlines).contains(where: { $0.hasPrefix("error") || $0.contains("exception:") || $0.hasPrefix("exception while") || $0.hasPrefix("permission denial") }) else {
            throw WispError("Android accessibility command failed. Reopen the menu to read its current state.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func number(_ value: String, fallback: Double) throws -> Double {
        if value == "null" { return fallback }
        guard let number = Double(value), number.isFinite else { throw WispError("Android returned an invalid accessibility value") }
        return number
    }
    static func read(adb: String, serial: String,
                     using runner: Runner = { try command($0, $1, timeout: $2) }) throws -> [String: Bool] {
        let services = try run(adb, serial, ["get", "secure", "enabled_accessibility_services"], using: runner)
        let enabled = try number(run(adb, serial, ["get", "secure", "accessibility_enabled"], using: runner), fallback: 0)
        let scale = try number(run(adb, serial, ["get", "system", "font_scale"], using: runner), fallback: 1)
        let weight = try number(run(adb, serial, ["get", "secure", "font_weight_adjustment"], using: runner), fallback: 0)
        let contrast = try number(run(adb, serial, ["get", "secure", "high_text_contrast_enabled"], using: runner), fallback: 0)
        let talkback = services.split(separator: ":").contains { component in
            let parts = component.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            let name = parts[1].hasPrefix(".") ? String(parts[0]) + String(parts[1]) : String(parts[1])
            return String(parts[0]) + "/" + name == talkBackService
        }
        return [Setting.talkback.rawValue: enabled == 1 && talkback,
                Setting.textSize.rawValue: abs(scale - 2) < 0.001,
                Setting.boldFont.rawValue: weight >= 300,
                Setting.highContrast.rawValue: contrast == 1]
    }
    static func set(_ change: Change, adb: String, serial: String,
                    using runner: Runner = { try command($0, $1, timeout: $2) }) throws -> [String: Any] {
        let commands: [[String]]
        switch change.setting {
        case .talkback:
            // V1 deliberately replaces/removes the whole enabled-services list.
            commands = change.enabled
                ? [["put", "secure", "enabled_accessibility_services", talkBackService], ["put", "secure", "accessibility_enabled", "1"]]
                : [["delete", "secure", "enabled_accessibility_services"], ["put", "secure", "accessibility_enabled", "0"]]
        case .textSize: commands = [["put", "system", "font_scale", change.enabled ? "2.0" : "1.0"]]
        case .boldFont: commands = [["put", "secure", "font_weight_adjustment", change.enabled ? "300" : "0"]]
        case .highContrast: commands = [["put", "secure", "high_text_contrast_enabled", change.enabled ? "1" : "0"]]
        }
        for args in commands {
            let output = try run(adb, serial, args, using: runner)
            guard output.isEmpty || (args.first == "delete" && output.hasPrefix("Deleted ") && output.hasSuffix(" rows")) else {
                throw WispError("Android did not confirm the setting. Reopen the menu to read its current state.")
            }
        }
        // No readback or polling after a write; only the affected row changes.
        return ["setting": change.setting.rawValue, "enabled": change.enabled]
    }
}
