import Foundation
import Security
import Network
import CryptoKit

// This is a private, app-local CA; it is NEVER installed in a trust store.
// Only the public .cer is exportable. Identity import is memory-only on macOS 15.
final class TLSIdentity {
    static var directory: URL { Settings.file.deletingLastPathComponent().appendingPathComponent("tls", isDirectory: true) }
    let identity: sec_identity_t
    let certificate: Data
    let fingerprint: String
    init(directory: URL = TLSIdentity.directory, addresses: Set<String> = localAddresses(), hostname: String = ProcessInfo.processInfo.hostName) throws {
        guard #available(macOS 15, *) else { throw WispError("Simwisp HTTPS requires macOS 15 or newer (memory-only TLS keys). No key was installed.") }
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw WispError("Unsafe Simwisp TLS directory") }
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        let ips = addresses.union(["127.0.0.1", "::1"]).filter { $0.range(of: "^[0-9a-fA-F:.]+$", options: .regularExpression) != nil }.sorted()
        var dns = ["localhost"]
        if hostname.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil, !dns.contains(hostname) { dns.append(hostname) }
        let names = dns.sorted().map { "DNS:" + $0 } + ips.map { "IP:" + $0 }
        for name in ["root.key", "root.pem", "root.cer", "server.key", "server.pem", "server.p12", "server.passphrase", "names.json"] where fm.fileExists(atPath: file(name).path) {
            guard try file(name).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw WispError("Unsafe Simwisp TLS file") }
        }
        func openssl(_ arguments: [String]) throws {
            let result = try command("/usr/bin/openssl", arguments, timeout: 20)
            guard result.status == 0 else { throw WispError("Cannot prepare Simwisp HTTPS certificate (openssl exit \(result.status)). Existing trust was not modified.") }
        }
        func valid(_ name: String, seconds: Int) -> Bool {
            guard fm.fileExists(atPath: file(name).path) else { return false }
            return (try? command("/usr/bin/openssl", ["x509", "-checkend", String(seconds), "-noout", "-in", file(name).path]))?.status == 0
        }
        let rootExists = fm.fileExists(atPath: file("root.pem").path), keyExists = fm.fileExists(atPath: file("root.key").path)
        guard rootExists == keyExists else { throw WispError("Incomplete Simwisp local CA; restore both root.pem and root.key on the Mac. It was not silently replaced.") }
        // Work in a private sibling. A failed generation cannot leave a half-written identity.
        let work = file("generation-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        func temp(_ name: String) -> URL { work.appendingPathComponent(name) }
        let config = """
        [req]
        distinguished_name=dn
        prompt=no
        [dn]
        CN=Simwisp
        [root]
        basicConstraints=critical,CA:true,pathlen:0
        keyUsage=critical,keyCertSign,cRLSign
        subjectKeyIdentifier=hash
        [server]
        basicConstraints=critical,CA:false
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=\(names.joined(separator: ","))
        authorityKeyIdentifier=keyid,issuer
        """
        try Data(config.utf8).write(to: temp("openssl.cnf"))
        if !rootExists {
            // LibreSSL prompt=no uses the config DN even with -subj. Give the
            // CA a distinct DN so clients can distinguish leaf from issuer.
            try Data(config.replacingOccurrences(of: "CN=Simwisp\n", with: "CN=Simwisp Local CA\n").utf8).write(to: temp("root.cnf"))
            try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650", "-subj", "/CN=Simwisp Local CA", "-config", temp("root.cnf").path, "-extensions", "root", "-keyout", temp("root.key").path, "-out", temp("root.pem").path])
            try Data(contentsOf: temp("root.key")).write(to: file("root.key"), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file("root.key").path)
            try Data(contentsOf: temp("root.pem")).write(to: file("root.pem"), options: .atomic)
        }
        guard valid("root.pem", seconds: 86400) else { throw WispError("Simwisp local CA has expired or is invalid; explicit certificate renewal and client trust setup are required.") }
        let savedNames = (try? Data(contentsOf: file("names.json"))).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        if !valid("server.pem", seconds: 7 * 86400) || savedNames != names || !fm.fileExists(atPath: file("server.p12").path) || !fm.fileExists(atPath: file("server.key").path) || !fm.fileExists(atPath: file("server.passphrase").path) {
            try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj", "/CN=Simwisp", "-keyout", temp("server.key").path, "-out", temp("server.csr").path])
            var random = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw WispError("Secure TLS randomness unavailable") }
            random[0] &= 0x7f
            let serial = "0x" + random.map { String(format: "%02x", $0) }.joined()
            try openssl(["x509", "-req", "-sha256", "-days", "365", "-in", temp("server.csr").path, "-CA", file("root.pem").path, "-CAkey", file("root.key").path, "-set_serial", serial, "-extfile", temp("openssl.cnf").path, "-extensions", "server", "-out", temp("server.pem").path])
            var passwordBytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, passwordBytes.count, &passwordBytes) == errSecSuccess else { throw WispError("Secure TLS randomness unavailable") }
            try Data(Data(passwordBytes).base64EncodedString().utf8).write(to: temp("server.passphrase"))
            try openssl(["pkcs12", "-export", "-inkey", temp("server.key").path, "-in", temp("server.pem").path, "-out", temp("server.p12").path, "-passout", "file:" + temp("server.passphrase").path])
            for name in ["server.key", "server.pem", "server.p12", "server.passphrase"] {
                try Data(contentsOf: temp(name)).write(to: file(name), options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(name).path)
            }
            try JSONEncoder().encode(names).write(to: file("names.json"), options: .atomic)
        }
        try openssl(["x509", "-in", file("root.pem").path, "-outform", "DER", "-out", temp("root.cer").path])
        certificate = try Data(contentsOf: temp("root.cer"))
        try certificate.write(to: file("root.cer"), options: .atomic)
        fingerprint = SHA256.hash(data: certificate).map { String(format: "%02X", $0) }.joined(separator: ":")
        let data = try Data(contentsOf: file("server.p12"))
        var imported: CFArray?
        let options: [CFString: Any] = [kSecImportExportPassphrase: try String(contentsOf: file("server.passphrase"), encoding: .utf8), kSecImportToMemoryOnly: true]
        let importStatus = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
        guard importStatus == errSecSuccess else { throw WispError("TLS memory-only identity import failed (\(importStatus))") }
        guard               let items = imported as? [[String: Any]], let value = items.first?[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID(), let identity = sec_identity_create(value as! SecIdentity) else { throw WispError("Cannot load the Simwisp TLS identity into memory") }
        self.identity = identity
    }
    func options() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
        return options
    }
}
