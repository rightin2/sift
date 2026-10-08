import CoreServices
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import SiftCore
import Synchronization
import UniformTypeIdentifiers

/// The small facts that make a decision quick: where a file came from, whether it was ever
/// opened, what it is, and whether an identical copy or an unzipped folder sits beside it.
struct FileFacts: Equatable, Sendable {
    var sourceSite: String?
    var sourceURL: URL?
    var lastOpened: Date?
    /// Spotlight knows the file and has no record of it being opened.
    var neverOpened = false
    /// "4032 × 3024", "12 pages", "3:42".
    var shape: String?
    /// Another file in the folder with exactly the same contents.
    var duplicateOf: String?
    /// An archive whose unzipped folder already sits beside it.
    var alreadyUnzipped = false

    /// Runs off the main thread. Leaving the card cancels it, hashing included.
    static func load(_ item: FileItem, siblings: [FileItem]) async -> FileFacts {
        let work = Task.detached(priority: .utility) {
            var facts = FileFacts()
            let origin = FileOrigin.read(item.url)
            facts.sourceSite = origin.site
            facts.sourceURL = origin.page
            if let metadata = MDItemCreateWithURL(kCFAllocatorDefault, item.url as CFURL) {
                // The last-used date alone is also set when a file is created or copied, so it
                // only counts once the file has really been opened.
                let opens = MDItemCopyAttribute(metadata, "kMDItemUseCount" as CFString) as? Int ?? 0
                facts.lastOpened = opens > 0 ? MDItemCopyAttribute(metadata, kMDItemLastUsedDate) as? Date : nil
                // "Never opened" only when Spotlight has indexed the file and counts no opens.
                let indexed = MDItemCopyAttribute(metadata, kMDItemDateAdded) != nil
                facts.neverOpened = indexed && opens == 0 && !item.isDirectory
                facts.shape = shape(of: item, metadata: metadata)
            } else {
                facts.shape = shape(of: item, metadata: nil)
            }
            guard !Task.isCancelled else { return facts }
            facts.alreadyUnzipped = isUnzipped(item, siblings: siblings)
            facts.duplicateOf = duplicate(of: item, among: siblings)
            return facts
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// File digests already worked out, keyed by path, size and modified time, so coming back
    /// to a card never reads the same big files again.
    private static let digests = Mutex<[String: Data]>([:])

    private static func shape(of item: FileItem, metadata: MDItem?) -> String? {
        let type = item.typeIdentifier.flatMap(UTType.init)
        if let metadata {
            if let width = MDItemCopyAttribute(metadata, kMDItemPixelWidth) as? Int,
               let height = MDItemCopyAttribute(metadata, kMDItemPixelHeight) as? Int {
                return "\(width) × \(height)"
            }
            if let pages = MDItemCopyAttribute(metadata, kMDItemNumberOfPages) as? Int, pages > 0 {
                return pages == 1 ? "1 page" : "\(pages) pages"
            }
            if let seconds = MDItemCopyAttribute(metadata, kMDItemDurationSeconds) as? Double, seconds > 0 {
                return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
            }
        }
        // Spotlight may not know the file yet, so read the cheap ones directly.
        if type?.conforms(to: .image) == true,
           let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            return "\(width) × \(height)"
        }
        if type?.conforms(to: .pdf) == true, let pages = PDFDocument(url: item.url)?.pageCount, pages > 0 {
            return pages == 1 ? "1 page" : "\(pages) pages"
        }
        return nil
    }

    /// "Invoice.zip" beside a folder called "Invoice".
    private static func isUnzipped(_ item: FileItem, siblings: [FileItem]) -> Bool {
        guard let type = item.typeIdentifier.flatMap(UTType.init), type.conforms(to: .archive) else { return false }
        var base = item.url.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        return siblings.contains { $0.isDirectory && $0.name == base }
    }

    /// The name of another file in the folder with exactly the same bytes, if there is one.
    /// Only files of the same size are compared, and very large ones are skipped.
    private static func duplicate(of item: FileItem, among siblings: [FileItem]) -> String? {
        guard !item.isDirectory, !item.isPackage, let size = item.size, size > 0, size <= 512_000_000 else { return nil }
        let candidates = siblings.filter { $0.id != item.id && $0.size == size && !$0.isDirectory && !$0.isPackage }
        guard !candidates.isEmpty, let mine = hash(item) else { return nil }
        for other in candidates {
            if Task.isCancelled { return nil }
            if hash(other) == mine { return other.name }
        }
        return nil
    }

    private static func hash(_ item: FileItem) -> Data? {
        // Keyed on the file as it is on disk now, not as it was scanned, so an edit is never missed.
        let now = try? item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(item.url.path)|\(now?.fileSize ?? -1)|\(now?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let known = digests.withLock({ $0[key] }) { return known }
        guard let handle = try? FileHandle(forReadingFrom: item.url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if Task.isCancelled { return nil }
            hasher.update(data: chunk)
        }
        let digest = Data(hasher.finalize())
        digests.withLock { $0[key] = digest }
        return digest
    }
}

extension FileItem {
    /// "Added today", "Added yesterday", "Added 3 weeks ago". Says "Modified" when the
    /// volume doesn't record when the file arrived.
    var addedPhrase: String? {
        guard let date = added ?? modified else { return nil }
        let verb = added == nil ? "Modified" : "Added"
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "\(verb) today" }
        if calendar.isDateInYesterday(date) { return "\(verb) yesterday" }
        return "\(verb) " + date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

extension FileFacts {
    /// "Never opened", "Opened 2 months ago", or nothing when unknown.
    var openedPhrase: String? {
        if let lastOpened {
            return "Opened " + lastOpened.formatted(.relative(presentation: .named, unitsStyle: .wide))
        }
        return neverOpened ? "Never opened" : nil
    }
}
