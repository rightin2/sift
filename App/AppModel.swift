import AppKit
import Observation
import SiftCore
import SwiftUI

/// Which screen is showing and the actions that move between them.
@MainActor @Observable
final class AppModel {
    enum Screen {
        case start
        case sifting(FolderStack)
        case done(FolderStack)
        case empty(URL)
        case accessNeeded(URL)
    }

    var screen: Screen = .start
    /// The confirm sheet is up. Closing it without moving anything catches up on folder changes
    /// that were held back while it was open.
    var isConfirming = false {
        didSet { if oldValue && !isConfirming && !isTrashing { catchUp() } }
    }
    var isTrashing = false
    /// How far the move to the Trash has got.
    private(set) var trashProgress: (done: Int, total: Int)?
    /// A plain-language problem to show in an alert: what failed and what to do.
    var problem: String? {
        // The alert must not open behind Quick Look.
        didSet { if problem != nil { QuickLookPanel.shared.close() } }
    }
    /// A quiet one-line note under the card, such as "1 new file joined at the end".
    private(set) var notice: String?
    /// "Ditch the rest" waiting for a yes. Folder changes wait until it is answered.
    var isAskingToDitchRest = false {
        didSet { if oldValue && !isAskingToDitchRest { catchUp() } }
    }
    /// Exactly what "Ditch the rest" asked about, so a file arriving while it asks is never included.
    private(set) var ditchRestIDs: Set<URL> = []
    /// "Start this folder over" waiting for a yes.
    var isAskingToStartOver = false {
        didSet {
            if isAskingToStartOver { QuickLookPanel.shared.close() }
            if oldValue && !isAskingToStartOver { catchUp() }
        }
    }
    /// Ditched folders, not opened this sift, that hold files saved in an earlier one.
    /// Worked out when the confirm sheet opens.
    private(set) var rememberedWarnings: [KeptInsideTossed] = []
    /// The folder being scanned before it opens, for a quiet "Opening" note.
    private(set) var opening: URL?
    /// Quit was chosen while files were moving, so Sift quits once they have all moved.
    @ObservationIgnored private var quitWhenDone = false
    /// Bumped by every open, so a slow scan that finishes after a newer open is dropped.
    @ObservationIgnored private var openCount = 0
    /// Bumped by every step into a folder, so only the latest request steps in.
    @ObservationIgnored private var enterCount = 0
    /// The decision just undone, so the card can slide back in from the side it left.
    private(set) var undoneDecision: Decision?
    /// Counts undos, so a card still flying to its tray can be cleared.
    private(set) var undoCount = 0
    /// The latest command from the Sift menu, picked up by the sifting screen.
    private(set) var command: SiftKey?
    private(set) var commandCount = 0
    /// The find field is showing, and what it holds.
    var isFinding = false
    var findText = ""
    /// Sift's main window is the one taking keys (not Settings, a sheet or Quick Look).
    var isMainWindowKey = false

    /// The Sift menu's single-key commands only work while the main window is in front,
    /// so a key pressed in Settings or a sheet never decides anything.
    var canUseSiftKeys: Bool { isSifting && isMainWindowKey && !isFinding && !isConfirming && !isTrashing }
    /// Folders sifted lately, newest first.
    private(set) var recentFolders: [URL] =
        (UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []).map { URL(fileURLWithPath: $0) }

    private let trasher = SystemTrasher()
    private let memoryStore = SiftMemory.standard
    private let folderWatcher = FolderSyncWatcher()
    @ObservationIgnored private var rememberTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    static let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    static let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]

    /// The one model, for reminder and menu bar actions that start outside any view.
    static weak var shared: AppModel?
    /// Opens or brings forward the main window. Set by views that can reach `openWindow`.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    init() {
        Self.shared = self
        // `-SiftOpen <folder>` on launch opens that folder straight away, for testing.
        if let path = UserDefaults.standard.string(forKey: "SiftOpen") {
            open(URL(fileURLWithPath: path))
        }
    }

    // MARK: State

    var stack: FolderStack? {
        switch screen {
        case .sifting(let stack), .done(let stack): stack
        default: nil
        }
    }

    /// Changes whenever a different screen should cross-fade in. Moving between subfolders does not,
    /// but reopening a folder does, so every new sift gets fresh key and swipe handlers.
    var screenKey: String {
        switch screen {
        case .start: "start"
        case .sifting(let stack): "sifting:\(ObjectIdentifier(stack).hashValue)"
        case .done(let stack): "done:\(ObjectIdentifier(stack).hashValue)"
        case .empty(let folder): "empty:\(folder.path)"
        case .accessNeeded(let folder): "access:\(folder.path)"
        }
    }

    var isSifting: Bool {
        if case .sifting = screen { true } else { false }
    }

    var canUndo: Bool { activeStack?.canUndo ?? false }

    /// "Undo ditch", "Undo 46 saves" and so on, for the button and the Edit menu.
    var undoTitle: String {
        guard let stack = activeStack, stack.canUndo else { return "Undo" }
        let size = stack.lastStepSize
        let isDitch = stack.lastDecision == .toss
        if size > 1 { return "Undo \(size) \(isDitch ? "ditches" : "saves")" }
        return isDitch ? "Undo ditch" : "Undo save"
    }

    /// The sift in progress, while it can still change. Nothing changes while files are moving.
    var activeStack: FolderStack? {
        guard case .sifting(let stack) = screen, !isConfirming, !isTrashing else { return nil }
        return stack
    }

    /// The order folders are sifted in, kept between launches.
    var order: FolderScanner.Order =
        FolderScanner.Order(rawValue: UserDefaults.standard.string(forKey: "order") ?? "") ?? .newest {
        didSet {
            UserDefaults.standard.set(order.rawValue, forKey: "order")
            withAnimation(Theme.Motion.base) { stack?.reorder(order) }
        }
    }

    /// A download a browser is still writing. It can be saved but not ditched until it finishes.
    static func isDownloading(_ item: FileItem) -> Bool {
        item.isUnfinishedDownload && (item.modified ?? .distantPast) > Date.now.addingTimeInterval(-86_400)
    }

    // MARK: Commands and notices

    /// Sends a Sift menu command to the sifting screen.
    func send(_ key: SiftKey) {
        command = key
        commandCount += 1
    }

    func show(notice text: String) {
        noticeTask?.cancel()
        withAnimation(Theme.Motion.fast) { notice = text }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.Motion.base) { notice = nil }
        }
    }

    // MARK: Reminders, the menu bar and Finder

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        openMainWindow?()
        NSApp.activate()
    }

    /// From a reminder or the menu bar. Opens the watched folder, unless you are partway
    /// through sifting something, which is left as it is.
    func siftWatchedFolder() {
        let folder = Prefs.watchedFolderURL.resolvingSymlinksInPath().standardizedFileURL
        let partway = isSifting && (stack?.decidedCount ?? 0) > 0
        let alreadyThere = isSifting && stack?.root.folder == folder
        if !partway && !alreadyThere { open(folder) }
        showWindow()
    }

    /// A folder opened with Sift from Finder, or dropped on the Dock icon or the window.
    func openFromFinder(_ url: URL) {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
            .map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false
        guard isFolder else {
            problem = "Sift sifts folders. Drop a folder, not a single file."
            return
        }
        open(url)
        showWindow()
    }

    /// Starts or stops watching the folder to match the Reminders settings.
    func applyReminderSettings() {
        if UserDefaults.standard.bool(forKey: Prefs.remindersOn) {
            DownloadWatcher.shared.start(watching: Prefs.watchedFolderURL)
        } else {
            DownloadWatcher.shared.stop()
        }
    }

    // MARK: Opening

    /// Opens a folder. The scan runs off the main thread, so a big folder never freezes the window.
    func open(_ folder: URL) {
        guard !isTrashing else { return }
        rememberNow()
        // Resolve links such as /tmp, so folder paths compare the same everywhere.
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL
        openCount += 1
        let ticket = openCount
        let order = order
        opening = folder
        Task {
            let scanned = await Task.detached { () -> Result<[FileItem], ScanError> in
                do throws(ScanError) { return .success(try FolderScanner.scan(folder, order: order)) } catch { return .failure(error) }
            }.value
            // A newer open, or a move to the Bin that started meanwhile, wins.
            guard ticket == openCount else { return }
            opening = nil
            guard !isTrashing else { return }
            show(folder, scanned)
        }
    }

    private func show(_ folder: URL, _ scanned: Result<[FileItem], ScanError>) {
        // Decisions made in the old sift while this folder was scanning are saved before it goes.
        rememberNow()
        switch scanned {
        case .success(let items):
            isConfirming = false
            isAskingToDitchRest = false
            isAskingToStartOver = false
            isFinding = false
            findText = ""
            addRecent(folder)
            guard !items.isEmpty else {
                folderWatcher.stop()
                screen = .empty(folder)
                return
            }
            let root = SiftSession(folder: folder, items: items)
            root.recall(memoryStore.load(folder: folder))
            let stack = FolderStack(root: root)
            stack.order = order
            let store = memoryStore
            stack.recall = { store.load(folder: $0) }
            screen = .sifting(stack)
            watchCurrentFolder()
        case .failure(.accessDenied):
            screen = .accessNeeded(folder)
        case .failure:
            problem = "Sift couldn't open \(folder.lastPathComponent). Choose another folder."
        }
    }

    func chooseFolder() {
        guard !isTrashing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Sift"
        panel.directoryURL = Self.downloads
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Forgets every decision for the folder being sifted and starts it again from scratch.
    func startFolderOver() {
        guard let stack, !isTrashing else { return }
        let folder = stack.root.folder
        rememberTask?.cancel()
        memoryStore.forget(folder: folder)
        screen = .start
        open(folder)
    }

    /// How many items in `folder` have no remembered decision, for the start screen.
    func newCount(in folder: URL) async -> Int? {
        let store = memoryStore
        return await Task.detached {
            guard let items = try? FolderScanner.scan(folder) else { return nil }
            let memory = store.load(folder: folder.resolvingSymlinksInPath().standardizedFileURL)
            return items.count { $0.remembered(in: memory) == nil }
        }.value
    }

    private func addRecent(_ folder: URL) {
        recentFolders.removeAll { $0 == folder }
        recentFolders.insert(folder, at: 0)
        recentFolders = Array(recentFolders.prefix(6))
        UserDefaults.standard.set(recentFolders.map(\.path), forKey: "recentFolders")
    }

    // MARK: Memory between sifts

    /// Saves decisions a moment after the last change, so quitting never loses them.
    private func rememberSoon() {
        rememberTask?.cancel()
        rememberTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            rememberNow()
        }
    }

    func rememberNow() {
        rememberTask?.cancel()
        guard let stack else { return }
        memoryStore.save(stack.memories)
    }

    // MARK: Keeping up with the folder

    /// Watches whichever folder is being sifted, so new downloads join the queue. A new watch
    /// catches up straight away on anything that changed while the folder was unwatched.
    func watchCurrentFolder() {
        guard case .sifting(let stack) = screen else { return folderWatcher.stop() }
        let session = stack.current
        if folderWatcher.watch(session.folder, onChange: { [weak self] in self?.syncFolder(session) }) {
            syncFolder(session)
        }
    }

    /// Stops watching, unless another sift has already taken over (its screen fades in
    /// before the old one finishes fading out).
    func stopWatching(for owner: FolderStack) {
        if case .sifting(let current) = screen, current !== owner { return }
        folderWatcher.stop()
    }

    /// Picks up folder changes that waited while a question or the confirm sheet was open.
    private func catchUp() {
        if let stack = activeStack { syncFolder(stack.current) }
    }

    private func syncFolder(_ session: SiftSession) {
        // Nothing joins or leaves while "Ditch the rest" or "Start over" waits for an answer.
        guard let stack = activeStack, stack.current === session, !isAskingToDitchRest, !isAskingToStartOver else { return }
        let folder = session.folder
        let order = order
        Task {
            let scanned = await Task.detached { try? FolderScanner.scan(folder, order: order) }.value
            guard let stack = activeStack, stack.current === session,
                  !isAskingToDitchRest, !isAskingToStartOver else { return }
            guard let scanned else {
                // The folder you are in has gone: step back up, and the folder above, now
                // watched and synced, lets go of it and everything decided inside it.
                if !FileManager.default.fileExists(atPath: folder.path), stack.canLeave {
                    leave()
                    show(notice: "\(folder.lastPathComponent) is no longer there.")
                }
                return
            }
            let result = withAnimation(Theme.Motion.base) { stack.sync(session, with: scanned) }
            if result.added > 0 {
                show(notice: result.added == 1 ? "1 new file joined at the end" : "\(result.added) new files joined at the end")
            }
            if result.added + result.removed > 0 { rememberSoon() }
        }
    }

    // MARK: Deciding

    /// Returns false when nothing was decided, e.g. ditching a file that is still downloading.
    @discardableResult
    func decide(_ decision: Decision) -> Bool {
        guard let stack = activeStack, let item = stack.current.current else { return false }
        if decision == .toss, Self.isDownloading(item) {
            show(notice: "Still downloading. You can ditch it once it finishes.")
            return false
        }
        undoneDecision = nil
        let wasFinished = stack.current.isFinished
        stack.decide(decision)
        rememberSoon()
        // The starting folder asks to confirm once its last open item is decided. Changing a
        // decision later doesn't ask again, and a finished subfolder waits for you to go back up.
        if !wasFinished, stack.current.isFinished, !stack.canLeave { finish() }
        return true
    }

    /// How many items "save the rest" or "ditch the rest" would decide here.
    func restCount(_ decision: Decision) -> Int {
        guard let stack = activeStack else { return 0 }
        return stack.current.restCount(skipping: decision == .toss ? Self.isDownloading : { _ in false })
    }

    /// ⌥S saves the rest straight away; ⌥D asks first, about exactly the files left now.
    func askToDecideRest(_ decision: Decision) {
        guard let stack = activeStack else { return }
        guard restCount(decision) > 0 else {
            let downloading = decision == .toss && stack.current.remainingCount > 0
            return show(notice: downloading
                ? "Still downloading. You can ditch them once they finish."
                : "Nothing left to decide here.")
        }
        guard decision == .toss else { return decideRest(.keep) }
        let session = stack.current
        ditchRestIDs = Set(session.items.filter { session.decisions[$0.id] == nil && !Self.isDownloading($0) }.map(\.id))
        // The question must not open behind Quick Look.
        QuickLookPanel.shared.close()
        isAskingToDitchRest = true
    }

    func decideRest(_ decision: Decision) {
        guard let stack = activeStack else { return }
        undoneDecision = nil
        let wasFinished = stack.current.isFinished
        let asked = ditchRestIDs
        let count = withAnimation(Theme.Motion.base) {
            stack.decideRest(decision, skipping: decision == .toss ? { Self.isDownloading($0) || !asked.contains($0.id) } : { _ in false })
        }
        guard count > 0 else { return }
        show(notice: "\(decision == .keep ? "Saved" : "Ditched") \(count) \(count == 1 ? "item" : "items"). ⌘Z takes it back.")
        rememberSoon()
        if !wasFinished, stack.current.isFinished, !stack.canLeave { finish() }
    }

    /// Takes back the most recent decision, reopening its folder if you have moved away.
    func undo() {
        guard canUndo, let stack = activeStack else { return }
        undoneDecision = stack.lastDecision
        undoCount += 1
        withAnimation(Theme.Motion.base) { _ = stack.undo() }
        watchCurrentFolder()
        rememberSoon()
    }

    // MARK: Moving the highlight

    /// Moves the highlight up or down without deciding. Returns false at either end.
    @discardableResult
    func move(by offset: Int) -> Bool {
        guard let stack = activeStack else { return false }
        undoneDecision = nil
        return stack.current.move(by: offset)
    }

    @discardableResult
    func moveToUndecided(forward: Bool) -> Bool {
        guard let stack = activeStack else { return false }
        undoneDecision = nil
        if stack.current.moveToUndecided(forward: forward) { return true }
        show(notice: forward ? "Nothing undecided below." : "Nothing undecided above.")
        return true
    }

    @discardableResult
    func moveToEdge(first: Bool) -> Bool {
        guard let stack = activeStack else { return false }
        undoneDecision = nil
        return stack.current.moveToEdge(first: first)
    }

    /// Jumps to a file anywhere in this sift, e.g. one picked from a tray's list.
    func reveal(_ id: URL) {
        guard let stack = activeStack else { return }
        undoneDecision = nil
        withAnimation(Theme.Motion.base) { stack.reveal(id) }
        watchCurrentFolder()
    }


    /// Highlights an item clicked in the column view, at whichever level it sits.
    func select(_ item: FileItem, in session: SiftSession) {
        guard let stack = activeStack else { return }
        undoneDecision = nil
        if session !== stack.current { leave(to: session) }
        session.select(item.id)
    }

    /// Highlights the first item whose name contains `text`, or the next one after the
    /// highlight. Returns false when nothing matches.
    @discardableResult
    func find(_ text: String, next: Bool = false) -> Bool {
        guard let stack = activeStack, !text.isEmpty else { return false }
        let session = stack.current
        let items = session.items
        let start = next ? min(session.cursor + 1, items.count) : 0
        let order = Array(items.indices.dropFirst(start)) + Array(items.indices.prefix(start))
        guard let index = order.first(where: { items[$0].name.localizedCaseInsensitiveContains(text) }) else {
            return false
        }
        undoneDecision = nil
        session.select(items[index].id)
        return true
    }

    // MARK: Moving between folders

    /// Steps into a folder in the current list, optionally highlighting one file inside it.
    /// A folder not visited yet is scanned off the main thread first. Returns false when there
    /// is nothing to step into.
    @discardableResult
    func enter(_ folder: FileItem, selecting id: URL? = nil) -> Bool {
        guard let stack = activeStack, folder.isDirectory else { return false }
        if stack.hasVisited(folder) {
            stepIn(folder, items: [], on: stack, selecting: id)
            return true
        }
        enterCount += 1
        let ticket = enterCount
        let parent = stack.current
        let focus = parent.current?.id
        let order = order
        let url = folder.url
        Task {
            let scanned = await Task.detached { () -> Result<[FileItem], ScanError> in
                do throws(ScanError) { return .success(try FolderScanner.scan(url, order: order)) } catch { return .failure(error) }
            }.value
            // Only the latest request steps in, and only if nothing moved or was decided meanwhile.
            guard ticket == enterCount, activeStack === stack, stack.current === parent,
                  parent.current?.id == focus else { return }
            switch scanned {
            case .success(let items):
                stepIn(folder, items: items, on: stack, selecting: id)
            case .failure(.accessDenied):
                problem = "Sift can't read \(folder.name). Allow access in System Settings, then try again."
            case .failure:
                problem = "Sift couldn't open \(folder.name). It may have moved. Choose another folder."
            }
        }
        return true
    }

    private func stepIn(_ folder: FileItem, items: [FileItem], on stack: FolderStack, selecting id: URL?) {
        withAnimation(Theme.Motion.base) {
            stack.enter(folder, items: items)
            if let id { stack.current.select(id) }
        }
        undoneDecision = nil
        watchCurrentFolder()
    }

    /// Steps back up one level. Returns false at the top.
    @discardableResult
    func leave() -> Bool {
        guard let stack = activeStack, stack.canLeave else { return false }
        withAnimation(Theme.Motion.base) { stack.leave() }
        undoneDecision = nil
        watchCurrentFolder()
        return true
    }

    func leave(to session: SiftSession) {
        guard let stack = activeStack else { return }
        withAnimation(Theme.Motion.base) { stack.leave(to: session) }
        undoneDecision = nil
        watchCurrentFolder()
    }

    /// Opens a folder picked in the column view, from any level on the current path.
    func open(_ folder: FileItem, from session: SiftSession) {
        guard let stack = activeStack else { return }
        if let onPath = stack.path.first(where: { $0.folder == folder.url }) {
            leave(to: onPath)
        } else {
            leave(to: session)
            enter(folder)
        }
    }

    // MARK: Finishing

    /// Ends the pass, early or at the last file. Asks before anything goes to the Trash.
    func finish() {
        guard case .sifting(let stack) = screen, !isTrashing else { return }
        // The sheet must not open behind Quick Look.
        QuickLookPanel.shared.close()
        if stack.tossed.isEmpty {
            rememberNow()
            folderWatcher.stop()
            screen = .done(stack)
        } else {
            // Memory is read once for the whole sift, then narrowed to each ditched folder.
            let remembered = memoryStore.tree(under: stack.root.folder)
            rememberedWarnings = stack.rememberedKeptInsideTossedFolders { folder in
                let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
                return remembered.filter { $0.folder.path == path || $0.folder.path.hasPrefix(path + "/") }
            }
            isConfirming = true
        }
    }

    /// Keeps a file (or a whole folder) from the confirm sheet. Ignored once files are moving.
    func rescue(_ item: FileItem) {
        guard !isTrashing else { return }
        stack?.change(item.id, to: .keep)
        rememberSoon()
    }

    /// Ditches a file again from the confirm sheet, after a change of mind.
    func reDitch(_ item: FileItem) {
        guard !isTrashing else { return }
        stack?.change(item.id, to: .toss)
        rememberSoon()
    }

    func confirmTrash() async {
        guard case .sifting(let stack) = screen, !isTrashing else { return }
        isTrashing = true
        folderWatcher.stop()
        trashProgress = (0, stack.tossed.count)
        await stack.moveTossedToTrash(using: trasher) { done, total in
            self.trashProgress = (done, total)
        }
        isTrashing = false
        trashProgress = nil
        if !stack.trashed.isEmpty { Sounds.trash() }
        rememberNow()
        if quitWhenDone { return NSApp.reply(toApplicationShouldTerminate: true) }
        // Only move on if the same sift is still showing.
        guard case .sifting(let current) = screen, current === stack else { return }
        isConfirming = false
        screen = .done(stack)
        let count = stack.failedInPlace.count
        if count > 0 {
            problem = "\(count) \(count == 1 ? "file" : "files") didn't go to the Bin. Choose Review ditched to see why."
        }
    }

    /// Quit waits for files that are moving, so none is left half-recorded.
    func shouldQuit() -> NSApplication.TerminateReply {
        guard isTrashing else { return .terminateNow }
        quitWhenDone = true
        return .terminateLater
    }

    /// When files in the Bin can still be put back, from Finder's own setting.
    static var recoverableUntil: String {
        if UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "FXRemoveOldTrashItems") == true,
           let date = Calendar.current.date(byAdding: .day, value: 30, to: .now) {
            return "until \(date.formatted(.dateTime.day().month(.abbreviated)))"
        }
        return "until you empty the Bin"
    }

    /// Puts one file back. Returns where it landed, or nil (with a problem shown) if it couldn't.
    @discardableResult
    func putBack(_ file: TrashedFile) -> URL? {
        guard let stack else { return nil }
        do {
            let landed = try stack.putBack(file, using: trasher)
            rememberNow()
            return landed
        } catch {
            problem = "Sift couldn't put back \(file.item.name). Find it in the Bin in Finder and choose Put Back."
            return nil
        }
    }

    /// Puts back everything still in the Trash. Returns where each file landed.
    @discardableResult
    func putBackAll() -> [URL: URL] {
        guard let stack else { return [:] }
        var landings: [URL: URL] = [:]
        let stuck = stack.putBackAll(using: trasher) { file, url in landings[file.id] = url }
        rememberNow()
        if !stuck.isEmpty {
            problem = "Sift couldn't put back \(stuck.joined(separator: ", ")). Find \(stuck.count == 1 ? "it" : "them") in the Bin in Finder and choose Put Back."
        }
        return landings
    }

    func startOver() {
        guard !isTrashing else { return }
        rememberNow()
        folderWatcher.stop()
        isConfirming = false
        isFinding = false
        findText = ""
        screen = .start
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}
