import Foundation

// Inspector IDs never cross the browser boundary. Handles are scoped to one
// upstream generation; client admission additionally requires prior delivery.
final class MetroObjectReferences {
    static let limit = 4096
    private var ids: [String: String] = [:], reverse: [String: String] = [:], order: [String] = []
    var count: Int { ids.count }
    func remember(_ id: String) -> String {
        if let ref = reverse[id] { return ref }
        let ref = UUID().uuidString
        ids[ref] = id; reverse[id] = ref; order.append(ref)
        if order.count > Self.limit { let old = order.removeFirst(); if let raw = ids.removeValue(forKey: old) { reverse.removeValue(forKey: raw) } }
        return ref
    }
    func resolve(_ ref: String) -> String? { ids[ref] }
    func clear() { ids.removeAll(); reverse.removeAll(); order.removeAll() }
    func decorate(_ value: [String: Any]) -> [String: Any] {
        var output = value
        if let id = output.removeValue(forKey: "objectId") as? String { output["object_ref"] = remember(id) }
        return output
    }
}

enum MetroObjectCodec {
    static func identifier(_ value: Any?) -> String? {
        guard let id = value as? String, !id.isEmpty, id.utf8.count <= 2048,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return id
    }
    static func properties(_ raw: [String: Any], references: MetroObjectReferences) -> [String: Any] {
        let own = raw["result"] as? [[String: Any]] ?? [], internalValues = raw["internalProperties"] as? [[String: Any]] ?? []
        var properties: [[String: Any]] = [], bytes = 0, truncated = own.count > 1000 || internalValues.count > 128
        for (index, item) in (Array(own.prefix(1000)) + Array(internalValues.prefix(128))).enumerated() {
            var p: [String: Any] = ["name": MetroCodec.text(item["name"], limit: 1024), "internal": index >= min(1000, own.count)]
            for flag in ["enumerable", "configurable", "writable", "isOwn", "wasThrown"] { if let b = item[flag] as? Bool { p[flag] = b } }
            for field in ["value", "get", "set", "symbol"] { if let value = item[field] as? [String: Any] { p[field] = references.decorate(MetroCodec.argument(value)) } }
            // No Runtime.evaluate/callFunctionOn and no automatic getter call.
            let size = jsonData(p).count
            guard bytes + size <= 120_000 else { truncated = true; break }
            bytes += size; properties.append(p)
        }
        return ["properties": properties, "truncated": truncated]
    }
    static func handles(_ entry: [String: Any]) -> [String] {
        let values = (entry["arguments"] as? [[String: Any]] ?? []) + (entry["properties"] as? [[String: Any]] ?? []).flatMap { p in ["value", "get", "set", "symbol"].compactMap { p[$0] as? [String: Any] } }
        return values.compactMap { $0["object_ref"] as? String }
    }
}
