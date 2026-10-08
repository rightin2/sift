import Foundation
import Observation
import SiftCore

/// Watches one folder (Downloads by default) while reminders are on, counting what arrived
/// today and what it holds in total, and hands the counts to `Reminders`.
@MainActor @Observable
final class DownloadWatcher {
    static let shared = DownloadWatcher()

    private(set) var folder: URL?
    private(set) var newToday = 0
    private(set) var total = 0
    /// False when macOS refuses access to the folder.
    private(set) var canRead = true

    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var pending: Task<Void, Never>?

    /// Downloads still arriving don't count until they finish.
    private nonisolated static let inProgress: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]

    func start(watching folder: URL) {
        stop()
        self.folder = folder
        let descriptor = open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.refreshSoon() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        // A slow tick catches midnight and anything the folder events miss.
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        }
        refresh()
    }

    func stop() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        folder = nil
    }

    /// Waits for a burst of changes (a download writing, a batch being moved) to settle.
    private func refreshSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    func refresh() {
        guard let folder else { return }
        let startOfDay = Calendar.current.startOfDay(for: .now)
        Task {
            let counts = await Task.detached { () -> (today: Int, total: Int)? in
                guard let items = try? FolderScanner.scan(folder) else { return nil }
                let finished = items.filter { !Self.inProgress.contains($0.url.pathExtension.lowercased()) }
                let today = finished.filter { ($0.added ?? $0.modified ?? .distantPast) >= startOfDay }.count
                return (today, finished.count)
            }.value
            guard self.folder == folder else { return }
            guard let counts else {
                canRead = false
                return
            }
            canRead = true
            newToday = counts.today
            total = counts.total
            Reminders.shared.check(newToday: counts.today, total: counts.total, folder: folder)
        }
    }
}
