import AppKit
import Darwin
import SiftCore
import SwiftUI
import UniformTypeIdentifiers

/// The card for a file Quick Look cannot draw, such as a disk image: the facts that help you
/// decide, including the website it came from, which you can open or copy.
struct InfoCard: View {
    let item: FileItem
    let facts: FileFacts?

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            // The icon gives up height first, so a small window never clips the card.
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .scaledToFit()
                .frame(maxWidth: Theme.Symbol.fileIcon, maxHeight: Theme.Symbol.fileIcon)
                .layoutPriority(-1)

            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                row("Kind") { Text(kind) }
                if let size = item.size {
                    row("Size") { Text(size.formatted(.byteCount(style: .file))) }
                }
                if let added = item.added {
                    row("Added") { Text(added.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())) }
                } else if let modified = item.modified {
                    row("Modified") { Text(modified.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())) }
                }
                if let opened = facts?.openedPhrase {
                    row("Last opened") { Text(opened.replacingOccurrences(of: "Opened ", with: "")) }
                }
                if let site = facts?.sourceSite {
                    row("Downloaded from") {
                        HStack(spacing: Theme.Space.s) {
                            if let page = facts?.sourceURL {
                                Link(site, destination: page)
                                    .help("Open \(page.absoluteString)")
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(page.absoluteString, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .frame(width: Theme.Size.rowHitHeight, height: Theme.Size.rowHitHeight)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(RowButtonStyle())
                                .accessibilityLabel("Copy the address")
                                .help("Copy the address")
                            } else {
                                Text(site)
                            }
                        }
                    }
                }
            }
            .font(.callout)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var kind: String {
        let described = item.typeIdentifier.flatMap(UTType.init)?.localizedDescription ?? "Document"
        return described.prefix(1).uppercased() + described.dropFirst()
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(Theme.secondary)
                .gridColumnAlignment(.trailing)
            value()
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Where a download came from, as Safari, Chrome and Firefox record it on the file.
enum FileOrigin {
    /// The site (without "www.") and the page the download started from, when recorded.
    static func read(_ url: URL) -> (site: String?, page: URL?) {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return (nil, nil) }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard read > 0,
              let sources = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return (nil, nil) }
        // The last entry is usually the page you were on; the first is the file's own address.
        let addresses = sources.compactMap(URL.init(string:)).filter { $0.scheme == "https" || $0.scheme == "http" }
        guard let page = addresses.last ?? addresses.first, let host = page.host() else { return (nil, nil) }
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, page)
    }

    static func site(of url: URL) -> String? { read(url).site }
}
