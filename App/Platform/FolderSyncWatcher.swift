import AppKit
import Foundation

/// Watches the folder being sifted, so files that arrive (or vanish) mid-sift are noticed.
/// Waits for a burst of changes to settle before reporting once.
@MainActor
final class FolderSyncWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var onChange: (@MainActor () -> Void)?
    private(set) var folder: URL?

    /// Watches `folder`, or keeps watching it and swaps in the new handler. Returns true when a
    /// new watch started, so the caller can catch up on anything that changed while unwatched.
    @discardableResult
    func watch(_ folder: URL, onChange: @escaping @MainActor () -> Void) -> Bool {
        guard folder != self.folder else {
            self.onChange = onChange
            return false
        }
        stop()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        self.folder = folder
        self.onChange = onChange
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.pending?.cancel()
                self?.pending = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    self?.onChange?()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        pending?.cancel()
        onChange = nil
        folder = nil
    }
}

/// Finder's own sounds, so moving to the Bin sounds the way it does in Finder.
@MainActor
enum Sounds {
    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif",
        byReference: true)

    static func trash() { trashSound?.play() }
}
