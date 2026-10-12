import Foundation
import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var settings = Settings(); settings.port = 45152; settings.shareLAN = false
settings.projectDirectory = root.path; settings.pairingToken = "isolated-tls-link-credential"; settings.terminalEnabled = false
let service = Service(settings: settings, pairingStateURL: root.appendingPathComponent("pairing-state.json"), tlsDirectory: root.appendingPathComponent("tls"))
service.stateChanged = { state in
    if state == "Running" { print("Isolated production TLS service ready"); fflush(stdout) }
    else { log(state); exit(1) }
}
do { try service.start() } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
Darwin.signal(SIGTERM, SIG_IGN); stop.setEventHandler { service.stop { exit(0) } }; stop.resume()
dispatchMain()
