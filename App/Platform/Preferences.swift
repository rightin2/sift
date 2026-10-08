import Foundation

/// Settings keys and their defaults, shared by @AppStorage and the background watcher.
enum Prefs {
    /// 0 is solid, 1 is as see-through as stays readable.
    static let transparency = "transparency"
    static let remindersOn = "remindersOn"
    static let dailyOn = "dailyOn"
    static let dailyLimit = "dailyLimit"
    static let totalOn = "totalOn"
    static let totalLimit = "totalLimit"
    /// The folder reminders watch. Empty means Downloads.
    static let watchedFolder = "watchedFolder"
    static let lastDailyReminder = "lastDailyReminder"
    static let lastTotalReminder = "lastTotalReminder"

    static var defaults: [String: Any] {[
        transparency: 0.5,
        remindersOn: false,
        dailyOn: true,
        dailyLimit: 10,
        totalOn: false,
        totalLimit: 50,
        watchedFolder: "",
    ]}

    static func register() {
        UserDefaults.standard.register(defaults: defaults)
    }

    static var watchedFolderURL: URL {
        let path = UserDefaults.standard.string(forKey: watchedFolder) ?? ""
        return path.isEmpty
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            : URL(fileURLWithPath: path)
    }
}
