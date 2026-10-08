import Foundation

/// One entry in the folder being sifted: a file, a folder, or a package such as an app.
public struct FileItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    /// A folder macOS shows as one file, such as an .app bundle. Not a directory to sift into.
    public let isPackage: Bool
    /// Bytes on disk for files. Nil for folders, which are not measured.
    public let size: Int64?
    public let modified: Date?
    /// When the item landed in this folder, e.g. when a download finished.
    public let added: Date?
    /// Uniform type identifier, e.g. "com.adobe.pdf".
    public let typeIdentifier: String?
    /// The file system's number for this item, used to make sure the file trashed is the one the user saw.
    public let fileNumber: UInt64?
    /// Finder tags, such as "Red" or "Work".
    public let tags: [String]
    /// Locked in Finder's Get Info.
    public let isLocked: Bool
    /// Synced with iCloud Drive, so trashing it also removes it from other devices.
    public let isInCloud: Bool

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    /// Matches this file in a later sift: the same name, the same file on disk and, for a plain
    /// file, the same modified time, so a file rewritten in place counts as new. Folders and
    /// packages change their modified time whenever something inside changes, so it is left out.
    public var memoryKey: String {
        guard !isDirectory, !isPackage, let modified else { return sameFileKey }
        return "\(sameFileKey)|\(Int(modified.timeIntervalSince1970))"
    }

    /// Name and file number only: the same file, edited or not. Also the key Sift used before
    /// it added modified times.
    public var sameFileKey: String { "\(name)|\(fileNumber.map(String.init) ?? "-")" }

    /// This file's remembered decision. Falls back to the older key, so decisions saved before
    /// modified times were added still count once.
    public func remembered(in memory: [String: Decision]) -> Decision? {
        memory[memoryKey] ?? memory[sameFileKey]
    }

    /// Whether `memory` remembers saving this very file, even if it was edited since.
    public func wasSaved(in memory: [String: Decision]) -> Bool {
        let base = sameFileKey
        return memory.contains { key, decision in
            decision == .keep && (key == base
                || (key.hasPrefix(base + "|") && key.dropFirst(base.count + 1).allSatisfy(\.isNumber)))
        }
    }

    /// A browser's placeholder for a download that hasn't finished.
    public var isUnfinishedDownload: Bool {
        Self.downloadExtensions.contains(url.pathExtension.lowercased())
    }

    public static let downloadExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]

    public init(
        url: URL,
        isDirectory: Bool = false,
        isPackage: Bool = false,
        size: Int64? = nil,
        modified: Date? = nil,
        added: Date? = nil,
        typeIdentifier: String? = nil,
        fileNumber: UInt64? = nil,
        tags: [String] = [],
        isLocked: Bool = false,
        isInCloud: Bool = false
    ) {
        self.url = url
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.modified = modified
        self.added = added
        self.typeIdentifier = typeIdentifier
        self.fileNumber = fileNumber
        self.tags = tags
        self.isLocked = isLocked
        self.isInCloud = isInCloud
    }
}

extension URL {
    /// True when this URL sits somewhere below `folder`.
    public func isInside(_ folder: URL) -> Bool {
        comparablePath.hasPrefix(folder.comparablePath + "/")
    }

    /// The path without "/private" in front of /var, /tmp and /etc, worked out from the text
    /// alone. `standardizedFileURL` only drops it from paths that exist, so an existing folder
    /// and a file that has gone would otherwise never match.
    var comparablePath: String {
        let path = standardized.path
        for prefix in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}
