import Foundation

/// Moves files to the Trash and back. Tests swap in a version that uses a scratch folder.
public protocol Trasher: Sendable {
    /// Moves `url` to the Trash and returns where it ended up, when macOS reports it.
    func trash(_ url: URL) throws -> URL?
    /// Moves a trashed file back to its original location.
    func restore(_ trashURL: URL, to original: URL) throws
}

/// The real Trash. Never deletes: `trashItem` is the only removal path.
public struct SystemTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    public func restore(_ trashURL: URL, to original: URL) throws {
        try FileManager.default.moveItem(at: trashURL, to: original)
    }
}
