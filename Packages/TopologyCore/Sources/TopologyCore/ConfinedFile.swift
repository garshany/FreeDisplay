import Foundation

/// Whether a file operation stays inside one folder, decided from what a path reaches on disk at
/// the moment of the operation rather than from its text. A path can read "inside the folder"
/// while a directory along it has been replaced by a symbolic link to somewhere else: anything
/// that removes or moves files there (the ICC profile Trash and its undo) asks these first.
///
/// The folder itself may be a link — it is resolved once, and its real location is the boundary.
/// Nothing below it may be: every directory between it and the file must be a real directory,
/// and the file a regular file. Pure Foundation (`FileManager` attributes don't follow links).
public enum ConfinedFile {
    /// A file's identity on its volume: the same file, whatever path or link reaches it.
    public struct Identity: Hashable, Sendable {
        public let device: Int
        public let inode: Int

        public init(device: Int, inode: Int) {
            self.device = device
            self.inode = inode
        }
    }

    /// Why a path isn't a file confined to the folder.
    public enum Refusal: Error, Hashable, Sendable {
        /// The path doesn't lead below the folder at all.
        case outsideFolder
        /// Something between the folder and the file is a symbolic link, or not a directory.
        case linkedDirectory
        /// The file itself is a symbolic link, or not a regular file.
        case notARegularFile
        /// Nothing is there.
        case missing
    }

    /// The folder's real location (its own links resolved): the boundary every check uses.
    public static func boundary(of folder: URL) -> URL {
        folder.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The identity of what `url` names, its links followed; nil when nothing is there.
    public static func identity(of url: URL) -> Identity? {
        identity(atPath: url.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    /// The real location of the regular file `url` names — reached from `folder` through real
    /// directories only — for an operation to act on instead of the path as given. Throws a
    /// `Refusal` otherwise.
    public static func resolve(_ url: URL, inside folder: URL) throws -> URL {
        let root = boundary(of: folder)
        let components = try relativeComponents(of: url, inside: folder, root: root)
        var path = root.path
        for (index, name) in components.enumerated() {
            path = (path as NSString).appendingPathComponent(name)
            guard let type = type(atPath: path) else { throw Refusal.missing }
            if index < components.count - 1 {
                guard type == .typeDirectory else { throw Refusal.linkedDirectory }
            } else {
                guard type == .typeRegular else { throw Refusal.notARegularFile }
            }
        }
        return URL(fileURLWithPath: path)
    }

    /// Where a file that is to be put back at `url` lands — for restoring one: the directories on
    /// the way that already exist must be real directories (missing ones are for the caller to
    /// create), and nothing may be at `url` itself. Returns the real location. Throws a `Refusal`.
    public static func resolveDestination(_ url: URL, inside folder: URL) throws -> URL {
        let root = boundary(of: folder)
        let components = try relativeComponents(of: url, inside: folder, root: root)
        var path = root.path
        for (index, name) in components.enumerated() {
            path = (path as NSString).appendingPathComponent(name)
            let type = type(atPath: path)
            if index < components.count - 1 {
                guard let type else { continue }  // created by the caller, as a real directory
                guard type == .typeDirectory else { throw Refusal.linkedDirectory }
            } else if type != nil {
                throw Refusal.notARegularFile  // something (a file, a link) already took its place
            }
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Private

    /// `url`'s path components below the folder, matched against the folder as written or its
    /// real location (a URL may already be in either form). Empty, or not below it: refused.
    private static func relativeComponents(of url: URL, inside folder: URL, root: URL) throws -> [String] {
        let target = url.standardizedFileURL.pathComponents
        for base in [folder.standardizedFileURL.pathComponents, root.pathComponents]
        where target.count > base.count && Array(target.prefix(base.count)) == base {
            return Array(target.dropFirst(base.count))
        }
        throw Refusal.outsideFolder
    }

    /// The type of the item at `path` itself — a link is reported as a link, never followed.
    private static func type(atPath path: String) -> FileAttributeType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attributes[.type] as? FileAttributeType
    }

    private static func identity(atPath path: String) -> Identity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let device = number(attributes[.systemNumber]),
              let inode = number(attributes[.systemFileNumber]) else { return nil }
        return Identity(device: device, inode: inode)
    }

    /// Foundation reports these as `Int` (an `NSNumber` on Darwin) or `UInt64` (elsewhere); only
    /// equality matters here, so the bit pattern is kept as is.
    private static func number(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as UInt64: return Int(truncatingIfNeeded: value)
        case let value as NSNumber: return value.intValue
        default: return nil
        }
    }
}
