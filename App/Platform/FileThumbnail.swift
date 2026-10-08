@preconcurrency import QuickLookThumbnailing
import SwiftUI

/// Quick Look thumbnails, kept in memory so a card can fly off without flashing an icon.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private var previewable: [URL: Bool] = [:]

    /// True when Quick Look can draw a real thumbnail, not just the Finder icon,
    /// which is the best sign it can preview the file.
    func canPreview(_ url: URL, scale: CGFloat) async -> Bool {
        if let known = previewable[url] { return known }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 64, height: 64), scale: scale, representationTypes: .thumbnail)
        let drawn = (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)) != nil
        previewable[url] = drawn
        return drawn
    }

    func image(_ url: URL, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, side))
    }

    @discardableResult
    func load(_ url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        if let hit = image(url, side: side) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .all)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        else { return nil }
        cache.setObject(image, forKey: key(url, side))
        return image
    }

    private func key(_ url: URL, _ side: CGFloat) -> NSString {
        "\(url.path)#\(Int(side))" as NSString
    }
}

/// A Quick Look thumbnail. Shows the Finder icon until the thumbnail is ready.
struct FileThumbnail: View {
    let url: URL
    var side: CGFloat = 64

    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Image(nsImage: image ?? ThumbnailCache.shared.image(url, side: side) ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .task(id: url) {
                image = await ThumbnailCache.shared.load(url, side: side, scale: scale)
            }
    }
}
