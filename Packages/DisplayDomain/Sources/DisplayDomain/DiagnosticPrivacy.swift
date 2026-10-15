import Foundation

/// Redaction, not anonymization: free-form names and unrelated paths can still identify a user.
/// Credentials are always removed. Hardware identifiers are an explicit export/copy choice.
public struct DiagnosticPrivacy: Sendable, Equatable {
    public var removeSerials: Bool
    public var removeUUIDs: Bool
    public var removeRegistryPaths: Bool
    public var knownSecrets: [String]
    public var knownSerials: [String]

    public init(removeSerials: Bool = true, removeUUIDs: Bool = true, removeRegistryPaths: Bool = true,
                knownSecrets: [String] = [], knownSerials: [String] = []) {
        self.removeSerials = removeSerials
        self.removeUUIDs = removeUUIDs
        self.removeRegistryPaths = removeRegistryPaths
        self.knownSecrets = knownSecrets
        self.knownSerials = knownSerials
    }

    private var removesOpaqueIdentifiers: Bool { removeSerials || removeUUIDs }

    public func redact(_ text: String) -> String {
        var text = text
        for value in knownSecrets where !value.isEmpty {
            text = text.replacingOccurrences(of: value, with: "<redacted>")
        }
        if removeSerials {
            for value in knownSerials where !value.isEmpty {
                text = replace("(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: value) + "(?![\\p{L}\\p{N}])", in: text)
            }
        }
        // URLs are omitted wholesale: userinfo, query, fragment and device-specific path may be secrets.
        text = replace(#"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>\"']+"#, in: text)
        // Header credentials can use any scheme and include spaces/commas (e.g. Digest).
        text = replace(#"(?im)([\"']?(?:proxy-)?authorization[\"']?\s*[:=][ \t]*)(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\r\n]+)"#, in: text, template: "$1<redacted>")
        text = replace(#"(?i)\bBearer\s+[^\s,;\"']+"#, in: text)
        text = replace(#"(?im)([\"']?(?:[a-z0-9_-]*(?:token|password|secret|credential|api[_ -]?key))[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#, in: text, template: "$1<redacted>")
        if removeUUIDs {
            text = replace(#"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, in: text)
        }
        if removesOpaqueIdentifiers {
            text = replace(#"(?im)([\"']?[^\s\"':=]*edid[\"']?\s*[:=]\s*)(?:<[^>]*>|\"[^\"]*\"|[^\r\n]+)"#, in: text, template: "$1<redacted>")
        }
        if removeSerials {
            text = replace(#"(?im)([\"']?[^\s\"':=]*(?:serial(?:[ _-]?number)?)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\r\n,;]+)"#, in: text, template: "$1<redacted>")
        }
        if removeRegistryPaths {
            text = replace(#"(?i)(?:IOService:|IODeviceTree:)[^\s\"'<>]+"#, in: text)
        }
        return text
    }

    /// Format-aware so JSON, JSONL and plist remain readable after redaction. Unknown binary is omitted.
    public func redactedArtifact(_ data: Data, pathExtension: String) -> Data? {
        if pathExtension.lowercased() == "plist" {
            guard let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
            return try? PropertyListSerialization.data(fromPropertyList: object(value), format: .xml, options: 0)
        }
        if pathExtension.lowercased() == "json" {
            guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
            return try? JSONSerialization.data(withJSONObject: object(value), options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed])
        }
        if pathExtension.lowercased() == "jsonl" {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            var lines: [String] = []
            for line in text.split(separator: "\n") {
                guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]),
                      let encoded = try? JSONSerialization.data(withJSONObject: object(value), options: [.sortedKeys, .fragmentsAllowed]),
                      let output = String(data: encoded, encoding: .utf8) else { return nil }
                lines.append(output)
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return nil }
        return Data(redact(text).utf8)
    }

    public func object(_ value: Any, key: String? = nil) -> Any {
        if let key {
            let lower = key.lowercased()
            if ["token", "password", "secret", "credential", "apikey", "api_key", "authorization"].contains(where: lower.contains) {
                return "<redacted>"
            }
            if (removeSerials && lower.contains("serial")) || (removesOpaqueIdentifiers && lower.contains("edid")) { return "<redacted>" }
            if removeUUIDs && lower.contains("uuid") { return "<redacted>" }
            if removeRegistryPaths && (lower.contains("ioservicepath") || lower.contains("registrypath")) { return "<redacted>" }
        }
        if let dictionary = value as? [String: Any] {
            // Redacted identifiers can collide as dictionary keys: retain every value under a unique key.
            var result: [String: Any] = [:]
            for original in dictionary.keys.sorted() {
                let sanitized = redact(original)
                var name = sanitized
                var suffix = 0
                while result[name] != nil { suffix += 1; name = "\(sanitized) (\(suffix))" }
                result[name] = object(dictionary[original]!, key: original)
            }
            return result
        }
        if let array = value as? [Any] { return array.map { object($0) } }
        if let string = value as? String { return redact(string) }
        // EDID/other opaque plist blobs may embed identifiers that text matching cannot inspect.
        if value is Data { return "<binary omitted>" }
        return value
    }

    private func replace(_ pattern: String, in text: String, template: String = "<redacted>") -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

extension DiagnosticPrivacy {
    /// Typed report metadata survives localization; untyped imported reports can supply labels.
    public func redactedReport(_ report: InfoReport, serialLabels: Set<String> = [], uuidLabels: Set<String> = [],
                               registryLabels: Set<String> = [], opaqueLabels: Set<String> = [],
                               opaqueSectionPrefixes: [String] = [], placeholder: String = "<redacted>") -> InfoReport {
        var result = report
        result.title = redact(result.title)
        result.header = result.header.map(redact)
        result.footer = result.footer.map(redact)
        if removesOpaqueIdentifiers {
            result.sections.removeAll { section in
                section.containsOpaqueIdentifiers || opaqueSectionPrefixes.contains { section.title.hasPrefix($0) }
            }
        }
        result.sections = result.sections.map { section in
            var section = section
            section.title = redact(section.title)
            section.rows = section.rows.map { row in
                var row = row
                let hidden: Bool
                switch row.identifier {
                case .serial: hidden = removeSerials
                case .uuid, .record: hidden = removeUUIDs
                case .registryPath: hidden = removeRegistryPaths
                case .opaque: hidden = removesOpaqueIdentifiers
                case nil: hidden = false
                }
                if hidden || (removeSerials && serialLabels.contains(row.label))
                    || (removeUUIDs && uuidLabels.contains(row.label))
                    || (removeRegistryPaths && registryLabels.contains(row.label))
                    || ((removeSerials || removeUUIDs) && opaqueLabels.contains(row.label)) {
                    row.value = placeholder
                } else { row.value = redact(row.value) }
                row.label = redact(row.label)
                return row
            }
            section.notes = section.notes.map(redact)
            return section
        }
        return result
    }
}
