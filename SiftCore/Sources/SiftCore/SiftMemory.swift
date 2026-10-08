import Foundation

/// What Sift remembers about each folder between sifts: every Save and Ditch, keyed so it only
/// applies to the very same files. Stored as one small JSON file.
public struct SiftMemory: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// ~/Library/Application Support/Sift/memory.json
    public static var standard: SiftMemory {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SiftMemory(file: support.appendingPathComponent("Sift/memory.json"))
    }

    public func load(folder: URL) -> [String: Decision] {
        all()[Self.key(folder)] ?? [:]
    }

    /// Replaces what is remembered for `folder`. An empty memory forgets the folder.
    public func save(_ memory: [String: Decision], folder: URL) {
        var all = all()
        all[Self.key(folder)] = memory.isEmpty ? nil : memory
        write(all)
    }

    /// Saves several folders at once, e.g. every folder visited in one sift.
    public func save(_ memories: [(folder: URL, memory: [String: Decision])]) {
        var all = all()
        for entry in memories {
            all[Self.key(entry.folder)] = entry.memory.isEmpty ? nil : entry.memory
        }
        write(all)
    }

    /// Forgets `folder` and every folder inside it.
    public func forget(folder: URL) {
        let root = Self.key(folder)
        write(all().filter { $0.key != root && !$0.key.hasPrefix(root + "/") })
    }

    /// How many decisions are remembered for `folder`.
    public func count(folder: URL) -> Int {
        load(folder: folder).count
    }

    /// Every remembered folder at or inside `folder`, read in one go.
    public func tree(under folder: URL) -> [(folder: URL, memory: [String: Decision])] {
        let root = Self.key(folder)
        return all()
            .filter { $0.key == root || $0.key.hasPrefix(root + "/") }
            .map { (URL(fileURLWithPath: $0.key), $0.value) }
    }

    private func all() -> [String: [String: Decision]] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: Decision]].self, from: data)) ?? [:]
    }

    private func write(_ all: [String: [String: Decision]]) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func key(_ folder: URL) -> String {
        folder.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
