import Quartz
import SwiftUI

/// A live Quick Look preview of one file: pages for PDFs, playback for video, text for documents.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // The normal style draws the full preview: tables for spreadsheets, pages for documents.
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
