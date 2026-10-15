import Foundation

public struct DiagnosticExportManifest: Codable, Sendable, Equatable {
    public var removeSerials: Bool
    public var removeUUIDs: Bool
    public var removeRegistryPaths: Bool
    public var credentialsRemoved = true
    public var omittedArtifacts: [String]
    public var notice = "Redaction is not anonymization. Review names and free text before sharing."
}

public enum DiagnosticExport {
    /// Operates on a private staging directory, never on the original support/system files.
    /// Failure aborts export rather than leaving an unreviewed artifact in the archive.
    public static func redactStagedDirectory(_ staging: URL, privacy: DiagnosticPrivacy) throws -> DiagnosticExportManifest {
        let root = staging.resolvingSymlinksInPath()
        let manager = FileManager.default
        func collect(_ directory: URL, path: [String] = []) throws -> [(url: URL, relative: String)] {
            let entries = try manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var result: [(url: URL, relative: String)] = []
            for entry in entries {
                result.append((entry, (path + [entry.lastPathComponent]).joined(separator: "/")))
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true {
                    result.append(contentsOf: try collect(entry, path: path + [entry.lastPathComponent]))
                }
            }
            return result
        }
        let files = try collect(root)
        var omitted: [String] = []
        for (file, relative) in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                omitted.append(privacy.redact(relative)); try manager.removeItem(at: file); continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                omitted.append(privacy.redact(relative)); try manager.removeItem(at: file); continue
            }
            let data = try Data(contentsOf: file)
            if let redacted = privacy.redactedArtifact(data, pathExtension: file.pathExtension) {
                try redacted.write(to: file, options: .atomic)
            } else {
                omitted.append(privacy.redact(relative)); try manager.removeItem(at: file)
            }
        }
        // Deepest paths first, so a renamed directory cannot invalidate an unprocessed child URL.
        for file in files.map(\.url).sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) where manager.fileExists(atPath: file.path) {
            let name = privacy.redact(file.lastPathComponent).replacingOccurrences(of: "/", with: "_")
            guard name != file.lastPathComponent else { continue }
            var destination = file.deletingLastPathComponent().appendingPathComponent(name)
            var suffix = 0
            while manager.fileExists(atPath: destination.path) {
                suffix += 1
                destination = file.deletingLastPathComponent().appendingPathComponent("\(name) (\(suffix))")
            }
            try manager.moveItem(at: file, to: destination)
        }
        return DiagnosticExportManifest(removeSerials: privacy.removeSerials, removeUUIDs: privacy.removeUUIDs,
            removeRegistryPaths: privacy.removeRegistryPaths, omittedArtifacts: omitted.sorted())
    }
}
