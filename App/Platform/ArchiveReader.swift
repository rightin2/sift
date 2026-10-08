import Foundation

/// Archive listings read once and kept, so the card knows whether there is anything to show
/// and the contents open instantly.
@MainActor
enum ArchiveCache {
    private static var listings: [URL: ArchiveReader.Listing] = [:]
    private static var unreadable: Set<URL> = []
    /// Listings still being read, so a second caller waits for the same bsdtar run.
    private static var reading: [URL: Task<ArchiveReader.Listing?, Never>] = [:]

    /// The archive's listing, or nil when bsdtar can't read it.
    static func listing(for url: URL) async -> ArchiveReader.Listing? {
        if let hit = listings[url] { return hit }
        if unreadable.contains(url) { return nil }
        if let running = reading[url] { return await running.value }
        let task = Task { try? await ArchiveReader.list(url) }
        reading[url] = task
        let listing = await task.value
        reading[url] = nil
        if let listing { listings[url] = listing } else { unreadable.insert(url) }
        return listing
    }
}

/// Lists what is inside an archive with the system's bsdtar, which reads zip, tar, gzip, bzip2,
/// 7-Zip, RAR, xar (.pkg and .xip) and ISO images. Nothing is ever extracted.
enum ArchiveReader {
    struct Entry: Sendable {
        let path: String
        let name: String
        let isFolder: Bool
        let children: [Entry]
    }

    struct Listing: Sendable {
        let entries: [Entry]
        let count: Int
        /// True when the archive held more entries than were read.
        let truncated: Bool
    }

    enum Failure: Error {
        case unreadable
    }

    static let limit = 20_000

    static func list(_ url: URL) async throws -> Listing {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-tf", url.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Read line by line and stop at the limit, so a huge archive never fills memory.
            var lines: [String] = []
            var truncated = false
            for try await line in output.fileHandleForReading.bytes.lines {
                guard lines.count < limit else {
                    truncated = true
                    process.terminate()
                    break
                }
                lines.append(line)
            }
            process.waitUntilExit()
            guard truncated || process.terminationStatus == 0 else { throw Failure.unreadable }
            return tree(from: lines, truncated: truncated)
        }.value
    }

    /// Turns tar's flat "folder/sub/file" lines into a tree, skipping macOS zip clutter.
    static func tree(from lines: [String], truncated: Bool = false) -> Listing {
        final class Node {
            var children: [String: Node] = [:]
            var order: [String] = []
            var isFolder = false
        }
        let root = Node()
        var count = 0
        for line in lines.prefix(limit) {
            let parts = line.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
            guard let first = parts.first, first != "__MACOSX", parts.last != ".DS_Store" else { continue }
            var node = root
            for (index, part) in parts.enumerated() {
                if node.children[part] == nil {
                    node.children[part] = Node()
                    node.order.append(part)
                    count += 1
                }
                node = node.children[part]!
                if index < parts.count - 1 || line.hasSuffix("/") { node.isFolder = true }
            }
        }
        func freeze(_ node: Node, at prefix: String) -> [Entry] {
            node.order.map { name -> Entry in
                let child = node.children[name]!
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                return Entry(
                    path: path, name: name, isFolder: child.isFolder || !child.children.isEmpty,
                    children: freeze(child, at: path))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return Listing(entries: freeze(root, at: ""), count: count, truncated: truncated || lines.count > limit)
    }
}
