import Foundation
import CryptoKit
import Darwin

struct PairingSettings: Codable {
    var totpSecret: String? = nil
    var rateLimits = PairingRateLimits()
    init() {}
    private enum CodingKeys: String, CodingKey { case totpSecret, rateLimits }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totpSecret = try c.decodeIfPresent(String.self, forKey: .totpSecret)
        rateLimits = try c.decodeIfPresent(PairingRateLimits.self, forKey: .rateLimits) ?? PairingRateLimits()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(totpSecret, forKey: .totpSecret)
        try c.encode(rateLimits, forKey: .rateLimits)
    }
}

struct PairingRateLimits: Codable {
    var postsPerIPPerMinute = 2
    var totpFailuresPerIPPerMinute = 2
    var ipCooldownSeconds = [600, 1800, 3600]
    var repeatWindowSeconds = 1800
    var globalTotpFailuresPerHour = 2
    var globalTotpLockoutSeconds = 3600
    init() {}
    private enum CodingKeys: String, CodingKey {
        case postsPerIPPerMinute, totpFailuresPerIPPerMinute, ipCooldownSeconds
        case repeatWindowSeconds, globalTotpFailuresPerHour, globalTotpLockoutSeconds
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postsPerIPPerMinute = try c.decodeIfPresent(Int.self, forKey: .postsPerIPPerMinute) ?? 2
        totpFailuresPerIPPerMinute = try c.decodeIfPresent(Int.self, forKey: .totpFailuresPerIPPerMinute) ?? 2
        ipCooldownSeconds = try c.decodeIfPresent([Int].self, forKey: .ipCooldownSeconds) ?? [600, 1800, 3600]
        repeatWindowSeconds = try c.decodeIfPresent(Int.self, forKey: .repeatWindowSeconds) ?? 1800
        globalTotpFailuresPerHour = try c.decodeIfPresent(Int.self, forKey: .globalTotpFailuresPerHour) ?? 2
        globalTotpLockoutSeconds = try c.decodeIfPresent(Int.self, forKey: .globalTotpLockoutSeconds) ?? 3600
    }
    func validate() throws {
        guard (1...1000).contains(postsPerIPPerMinute), (1...1000).contains(totpFailuresPerIPPerMinute),
              (1...1000).contains(globalTotpFailuresPerHour), (1...604800).contains(repeatWindowSeconds),
              (1...604800).contains(globalTotpLockoutSeconds), ipCooldownSeconds.count == 3,
              ipCooldownSeconds.allSatisfy({ (1...604800).contains($0) }),
              ipCooldownSeconds == ipCooldownSeconds.sorted() else {
            throw WispError("Invalid pairing.rateLimits: positive counts (1–1000), ordered three-tier cooldowns and durations (1–604800 seconds) required")
        }
    }
}

enum PairingDecision: Equatable {
    case accepted, denied, unavailable
    case throttled(Int)
}

// Call on a dedicated serial authentication queue. No timer, capture demand,
// or network-queue disk I/O; budgets expire only when a pairing request arrives.
final class PairingAuthenticator {
    private struct Source {
        var posts: [Double] = []
        var failures: [Double] = []
        var tier = -1
        var cooldownUntil: Double = 0
        var lastSeen: Double = 0
    }
    private struct State: Codable {
        var seedID: String
        var lastAcceptedStep: UInt64? = nil
        var failures: [Double] = []
        var lockedUntil: Double = 0
    }
    private let token: String
    private let limits: PairingRateLimits
    private let seed: Data?
    private let stateURL: URL
    private let wallClock: () -> Double
    private let steadyClock: () -> Double
    private let maxSources: Int
    private var sources: [String: Source] = [:]
    private var state: State
    private var storageHealthy = true
    var totpEnabled: Bool { seed != nil }
    var sourceCount: Int { sources.count } // deterministic bounded-state verification

    init(settings: PairingSettings, token: String, stateURL: URL,
         wallClock: @escaping () -> Double = { Date().timeIntervalSince1970 },
         steadyClock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, maxSources: Int = 1024) throws {
        try settings.rateLimits.validate()
        let configured = settings.totpSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configured.isEmpty { seed = nil }
        else {
            guard let decoded = Self.decodeBase32(configured), (20...64).contains(decoded.count) else {
                throw WispError("Invalid pairing.totpSecret: use a Base32 seed containing 20–64 bytes")
            }
            seed = decoded
        }
        self.token = token; limits = settings.rateLimits; self.stateURL = stateURL
        self.wallClock = wallClock; self.steadyClock = steadyClock; self.maxSources = maxSources
        let identity = seed.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
        state = State(seedID: identity)
        if seed != nil, FileManager.default.fileExists(atPath: stateURL.path) {
            do {
                let size = try stateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 65536 else { throw WispError("Pairing state too large") }
                let loaded = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
                guard loaded.failures.count <= 1000, loaded.failures.allSatisfy({ $0.isFinite && $0 >= 0 }),
                      loaded.lockedUntil.isFinite, loaded.lockedUntil >= 0 else { throw WispError("Invalid pairing state") }
                if loaded.seedID == identity { state = loaded }
            } catch {
                storageHealthy = false
                log("Cannot read pairing state; TOTP is unavailable until the Mac owner repairs pairing-state.json. Link pairing remains available.")
            }
        }
    }

    func authenticate(_ body: [String: Any], sourceAddress: String) -> PairingDecision {
        let now = steadyClock(), wall = wallClock(), sourceID = Self.sourceKey(sourceAddress)
        let lifetime = Double(limits.ipCooldownSeconds.last! + limits.repeatWindowSeconds + 60)
        sources = sources.filter { now - $0.value.lastSeen < lifetime }
        if sources[sourceID] == nil, sources.count >= maxSources { return .throttled(60) }
        var source = sources[sourceID] ?? Source()
        source.lastSeen = now
        source.posts.removeAll { now - $0 >= 60 }
        // Throttled requests don't move deadlines or consume credential budgets.
        guard source.posts.count < limits.postsPerIPPerMinute else {
            sources[sourceID] = source
            return .throttled(retry(after: source.posts[0] + 60 - now))
        }
        source.posts.append(now); sources[sourceID] = source
        // Explicit credential modes: a code can never bypass TOTP throttling
        // by being submitted through the high-entropy link-token path.
        if let candidate = body["token"] as? String, body["totp"] == nil {
            return Self.equal(candidate, token) ? .accepted : .denied
        }
        guard body["token"] == nil, body["totp"] != nil, let seed else { return .denied }
        guard storageHealthy else { return .unavailable }
        if state.lockedUntil > wall { return .throttled(retry(after: state.lockedUntil - wall)) }
        if source.cooldownUntil > now { return .throttled(retry(after: source.cooldownUntil - now)) }
        if source.tier >= 0, now - source.cooldownUntil >= Double(limits.repeatWindowSeconds) {
            source.tier = -1
        }
        source.failures.removeAll { now - $0 >= 60 }
        state.failures.removeAll { wall - $0 >= 3600 }
        // Also respect reduced limits after a settings edit/restart.
        if state.failures.count >= limits.globalTotpFailuresPerHour {
            let deadline = (state.failures.last ?? wall) + Double(limits.globalTotpLockoutSeconds)
            if deadline > state.lockedUntil {
                state.lockedUntil = deadline
                guard persist() else { return .unavailable }
            }
            let budgetUntil = state.failures[0] + 3600
            return .throttled(retry(after: max(state.lockedUntil, budgetUntil) - wall))
        }
        let code = body["totp"] as? String ?? ""
        let step = UInt64(max(0, floor(wall / 30)))
        var acceptedStep: UInt64?
        if code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) {
            for offset in [-1, 0, 1] {
                if offset == -1 && step == 0 { continue }
                let candidate = offset == -1 ? step - 1 : step + UInt64(offset)
                if Self.equal(code, Self.code(seed: seed, step: candidate)),
                   state.lastAcceptedStep.map({ candidate > $0 }) ?? true { acceptedStep = candidate }
            }
        }
        if let acceptedStep {
            state.lastAcceptedStep = acceptedStep
            guard persist() else { return .unavailable }
            source.failures.removeAll(); source.tier = -1; source.cooldownUntil = 0
            sources[sourceID] = source
            return .accepted
        }
        source.failures.append(now); state.failures.append(wall)
        if source.failures.count >= limits.totpFailuresPerIPPerMinute {
            source.tier = min(2, source.tier + 1)
            source.cooldownUntil = now + Double(limits.ipCooldownSeconds[source.tier])
            source.failures.removeAll()
        }
        sources[sourceID] = source
        if state.failures.count >= limits.globalTotpFailuresPerHour {
            state.lockedUntil = wall + Double(limits.globalTotpLockoutSeconds)
        }
        guard persist() else { return .unavailable }
        return .denied
    }

    private func persist() -> Bool {
        do {
            let dir = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            return true
        } catch {
            storageHealthy = false
            log("Cannot save pairing state; refusing TOTP authentication. Link pairing remains available.")
            return false
        }
    }
    private func retry(after seconds: Double) -> Int { max(1, Int(ceil(seconds))) }
    private static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func code(seed: Data, step: UInt64, digits: Int = 6) -> String {
        var counter = step.bigEndian
        let input = withUnsafeBytes(of: &counter) { Data($0) }
        let digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: input, using: SymmetricKey(data: seed)))
        let offset = Int(digest.last! & 15)
        let binary = (UInt32(digest[offset]) & 127) << 24 | UInt32(digest[offset + 1]) << 16 | UInt32(digest[offset + 2]) << 8 | UInt32(digest[offset + 3])
        let modulus: UInt32 = digits == 8 ? 100_000_000 : 1_000_000
        return String(format: "%0*d", digits, Int(binary % modulus))
    }
    static func decodeBase32(_ value: String) -> Data? {
        let text = value.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        let unpadded = text.prefix { $0 != "=" }
        let padding = text.count - unpadded.count
        guard text.dropFirst(unpadded.count).allSatisfy({ $0 == "=" }),
              padding == 0 || (text.count % 8 == 0 && padding == (8 - unpadded.count % 8) % 8),
              ![1, 3, 6].contains(unpadded.count % 8) else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var buffer: UInt32 = 0, bits = 0, output = Data()
        for byte in unpadded.utf8 {
            guard let index = alphabet.firstIndex(of: byte) else { return nil }
            buffer = (buffer << 5) | UInt32(index); bits += 5
            if bits >= 8 { bits -= 8; output.append(UInt8((buffer >> bits) & 255)) }
            buffer &= (1 << bits) - 1
        }
        guard buffer == 0 else { return nil }
        return output
    }
    static func sourceKey(_ address: String) -> String {
        // Numeric socket addresses only; IPv6 /64 grouping prevents suffix churn.
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return address }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return bytes[12...15].map(String.init).joined(separator: ".")
            }
            return bytes.prefix(8).map { String(format: "%02x", $0) }.joined() + "/64"
        }
        return "unknown"
    }
}
