import Foundation
import Darwin

let root = URL(fileURLWithPath: CommandLine.arguments[1]), executable = URL(fileURLWithPath: CommandLine.arguments[2])
let queue = DispatchQueue(label: "terminal.launch.fixture")
var checks = [[String: Any]](), calls = [(String, String)](), refused = [String](), block = false
func check(_ name: String, _ condition: Bool) { let pass = condition; checks.append(["name": name, "passed": pass]); try? jsonData(["checks": checks]).write(to: root.appendingPathComponent("progress.json")); if !pass { fputs("Terminal launch check failed: \(name)\n", stderr); exit(1) } }
func rejects(_ name: String, _ run: () throws -> Void) { do { try run(); check(name, false) } catch { check(name, true) } }
if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "integration" { try runIntegration(root, executable); exit(0) }
if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "lifecycle" { try runLifecycle(root, executable); exit(0) }
let bridge = TerminalLaunchBridge(queue: queue, helper: executable, onLaunch: { id, script in
    if block { throw WispError("Terminal limit reached") }; calls.append((id, script.path)); return "abcdef0123456789abcdef0123456789"
}, onError: { refused.append($0) })
let generated = root.appendingPathComponent("Project space 'quote;literal/node_modules/.generated")
try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
let script = generated.appendingPathComponent("launchPackager.command"), env = generated.appendingPathComponent(".packager.env")
try Data("#!/bin/bash\nprintf 'must never execute' > /dev/null\n".utf8).write(to: script)
try Data("export RCT_METRO_PORT=18081\nexport PROJECT_ROOT=\"fixture\"\nexport REACT_NATIVE_PATH=\"fake\"\n".utf8).write(to: env)
let app = try queue.sync { try bridge.register("0123456789abcdef0123456789abcdef") }
let config = app.appendingPathComponent("Contents/Resources/bridge.json")
let configData = try Data(contentsOf: config), object = dictionary(configData)
check("private app capability has bounded strong randomness", (object["capability"] as? String)?.count == 72)
check("capability file is owner-only", (try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
check("socket root is owner-only", (try FileManager.default.attributesOfItem(atPath: app.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
check("valid generated script path including spaces and metacharacters", try TerminalLaunchBridge.validate(script.path).path == script.path)
let firstIdentity = try TerminalLaunchBridge.identity(script)
try Data("export RCT_METRO_PORT=18082\nexport PROJECT_ROOT=fixture\nexport REACT_NATIVE_PATH=fake\n".utf8).write(to: env)
check("duplicate identity distinguishes changed packager port", try TerminalLaunchBridge.identity(script) != firstIdentity)
func invoke(_ config: URL = config, _ file: URL = script) throws -> CommandResult { try command(executable.path, ["--request", config.path, file.path], timeout: 6) }
check("native helper request accepted", try invoke().status == 0)
check("authenticated origin ID and exact canonical script delivered", queue.sync { calls.count == 1 && calls[0].0 == "0123456789abcdef0123456789abcdef" && calls[0].1 == script.path })
var forged = object; forged["capability"] = "wrong"
let bad = root.appendingPathComponent("forged.json"); try jsonData(forged).write(to: bad)
check("forged capability is refused", try invoke(bad).status != 0)
check("forged capability never reaches launch callback", queue.sync { calls.count == 1 })
queue.sync { block = true }
check("origin/quota rejection reaches helper without spawning", try invoke().status != 0)
check("rejection reports only to originating terminal", queue.sync { refused == ["0123456789abcdef0123456789abcdef"] && calls.count == 1 })
queue.sync { block = false }
let invalid = generated.appendingPathComponent("arbitrary.command"); try Data("echo unsafe\n".utf8).write(to: invalid)
check("arbitrary command file rejected by live bridge", try invoke(config, invalid).status != 0)
rejects("relative paths rejected") { _ = try TerminalLaunchBridge.validate("launchPackager.command") }
try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: script.path)
rejects("group/world writable launch script rejected") { _ = try TerminalLaunchBridge.validate(script.path) }
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
try FileManager.default.removeItem(at: env)
rejects("missing adjacent environment rejected") { _ = try TerminalLaunchBridge.validate(script.path) }
try Data("export RCT_METRO_PORT=18081\nexport PROJECT_ROOT=fixture\nexport REACT_NATIVE_PATH=fake\n".utf8).write(to: env)
try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: env.path)
rejects("unsafe environment permissions rejected") { _ = try TerminalLaunchBridge.validate(script.path) }
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.path)
try Data(repeating: 120, count: 8193).write(to: env)
rejects("oversized environment rejected") { _ = try TerminalLaunchBridge.validate(script.path) }
try Data("export PROJECT_ROOT=fixture\n".utf8).write(to: env)
rejects("incomplete environment rejected") { _ = try TerminalLaunchBridge.validate(script.path) }
try Data("export RCT_METRO_PORT=18081\nexport PROJECT_ROOT=fixture\nexport REACT_NATIVE_PATH=fake\n".utf8).write(to: env)
let original = generated.appendingPathComponent("original"); try FileManager.default.moveItem(at: script, to: original)
try FileManager.default.createSymbolicLink(at: script, withDestinationURL: original)
rejects("symlink launcher rejected") { _ = try TerminalLaunchBridge.validate(script.path) }
try FileManager.default.removeItem(at: script); try FileManager.default.moveItem(at: original, to: script)
let priorCalls = queue.sync { calls.count }
let openResult = try command("/usr/bin/open", ["-a", app.path, script.path], timeout: 6)
check("real macOS open -a accepts owned session launcher app", openResult.status == 0)
let deadline = monotonic() + 8
while queue.sync(execute: { calls.count == priorCalls }) && monotonic() < deadline { Thread.sleep(forTimeInterval: 0.025) }
check("real macOS document event forwards exact request", queue.sync { calls.count == priorCalls + 1 && calls.last?.1 == script.path })
queue.sync { bridge.unregister("0123456789abcdef0123456789abcdef") }
check("origin teardown removes private launcher app", !FileManager.default.fileExists(atPath: app.path))
let stale = root.appendingPathComponent("stale.json"); try configData.write(to: stale)
check("revoked origin capability cannot launch", try invoke(stale).status != 0)
queue.sync { bridge.stop() }
check("stop removes owned IPC root", !FileManager.default.fileExists(atPath: app.deletingLastPathComponent().path))
rejects("stopped bridge cannot create new launchers") { _ = try queue.sync { try bridge.register("after-stop") } }
let report: [String: Any] = ["passed": true, "checks": checks, "realMetro": false, "productService": false, "realDeviceActions": false, "ownedMacOSLauncher": true]
try jsonData(report).write(to: root.appendingPathComponent("native.json")); print("Terminal launch native: \(checks.count) checks PASS")
