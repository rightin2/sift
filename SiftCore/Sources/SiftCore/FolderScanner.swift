import Foundation
import UniformTypeIdentifiers

public enum ScanError: Error, Equatable, Sendable {
    /// macOS refused access, usually because of Files and Folders privacy settings.
    case accessDenied
    case unreadable(String)
}

public enum FolderScanner {
    /// The orders a folder can be sifted in.
    public enum Order: String, CaseIterable, Sendable {
        case newest, oldest, largest, name, kind
    }

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey,
        .contentModificationDateKey, .addedToDirectoryDateKey, .contentTypeKey,
        .tagNamesKey, .isUserImmutableKey, .isUbiquitousItemKey,
    ]

    /// Lists the visible top-level entries of `folder`, newest arrivals first. Hidden files are skipped.
    public static func scan(_ folder: URL, order: Order = .newest) throws(ScanError) -> [FileItem] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            throw isPermissionError(error) ? .accessDenied : .unreadable(error.localizedDescription)
        }
        return sorted(urls.map(item(for:)), by: order)
    }

    static func item(for url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: Set(keys))
        // A package such as an .app is a folder on disk but a single thing to the user.
        let isPackage = (values?.isDirectory ?? false) && (values?.isPackage ?? false)
        let isDirectory = (values?.isDirectory ?? false) && !isPackage
        return FileItem(
            url: url,
            isDirectory: isDirectory,
            isPackage: isPackage,
            size: isDirectory ? nil : values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate,
            added: values?.addedToDirectoryDate,
            typeIdentifier: values?.contentType?.identifier,
            fileNumber: fileNumber(of: url),
            tags: values?.tagNames ?? [],
            isLocked: values?.isUserImmutable ?? false,
            isInCloud: values?.isUbiquitousItem ?? false)
    }

    static func fileNumber(of url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// Newest arrivals first, by date added to the folder, then modified date, then name.
    public static func sorted(_ items: [FileItem]) -> [FileItem] {
        sorted(items, by: .newest)
    }

    public static func sorted(_ items: [FileItem], by order: Order) -> [FileItem] {
        func date(_ item: FileItem) -> Date { item.added ?? item.modified ?? .distantPast }
        func byName(_ a: FileItem, _ b: FileItem) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        func kind(_ item: FileItem) -> String {
            if item.isDirectory { return "0" }
            return item.typeIdentifier.flatMap { UTType($0)?.localizedDescription } ?? "~"
        }
        return items.sorted { a, b in
            switch order {
            case .newest:
                return date(a) != date(b) ? date(a) > date(b) : byName(a, b)
            case .oldest:
                return date(a) != date(b) ? date(a) < date(b) : byName(a, b)
            case .largest:
                let sizeA = a.size ?? -1, sizeB = b.size ?? -1
                return sizeA != sizeB ? sizeA > sizeB : byName(a, b)
            case .name:
                return byName(a, b)
            case .kind:
                let kindA = kind(a), kindB = kind(b)
                if kindA != kindB { return kindA.localizedStandardCompare(kindB) == .orderedAscending }
                return date(a) != date(b) ? date(a) > date(b) : byName(a, b)
            }
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileReadNoPermission.rawValue {
            return true
        }
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError) ?? ns
        return posix.domain == NSPOSIXErrorDomain
            && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }
}
