import AppKit
import UserNotifications

/// "Time to sift" notifications: when enough files arrive in a day, or the folder passes a
/// limit. Each rule reminds at most once a day. "Sift now" opens the folder in Sift.
@MainActor
final class Reminders: NSObject {
    static let shared = Reminders()

    private let center = UNUserNotificationCenter.current()
    private nonisolated static let category = "time-to-sift"
    private nonisolated static let siftNow = "sift-now"

    private(set) var isAllowed = false
    /// macOS hasn't asked yet, as opposed to the user having turned notifications off.
    private(set) var notAskedYet = true

    func setUp() {
        center.delegate = self
        let siftNow = UNNotificationAction(identifier: Self.siftNow, title: "Sift now", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [siftNow], intentIdentifiers: []),
        ])
        Task { await refreshPermission() }
    }

    /// Asks macOS for permission the first time; later calls just report the answer.
    @discardableResult
    func requestPermission() async -> Bool {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshPermission()
        return isAllowed
    }

    func refreshPermission() async {
        let status = await center.notificationSettings().authorizationStatus
        isAllowed = status == .authorized || status == .provisional
        notAskedYet = status == .notDetermined
    }

    func check(newToday: Int, total: Int, folder: URL) {
        let defaults = UserDefaults.standard
        // Only count a reminder as sent when macOS will actually show it.
        guard defaults.bool(forKey: Prefs.remindersOn), isAllowed else { return }
        let today = Calendar.current.startOfDay(for: .now).timeIntervalSinceReferenceDate
        let name = folder.lastPathComponent

        if defaults.bool(forKey: Prefs.dailyOn),
           newToday >= defaults.integer(forKey: Prefs.dailyLimit),
           defaults.double(forKey: Prefs.lastDailyReminder) < today {
            defaults.set(today, forKey: Prefs.lastDailyReminder)
            post(body: "\(newToday) new \(newToday == 1 ? "file" : "files") landed in \(name) today.")
            return
        }
        if defaults.bool(forKey: Prefs.totalOn),
           total > defaults.integer(forKey: Prefs.totalLimit),
           defaults.double(forKey: Prefs.lastTotalReminder) < today {
            defaults.set(today, forKey: Prefs.lastTotalReminder)
            post(body: "\(name) is holding \(total) items, past your limit of \(defaults.integer(forKey: Prefs.totalLimit)).")
        }
    }

    func sendTest(folder: URL, newToday: Int, total: Int) {
        post(body: "\(newToday) new today and \(total) items in \(folder.lastPathComponent). This is a test reminder.")
    }

    private func post(body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Time to sift"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.category
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension Reminders: UNUserNotificationCenterDelegate {
    /// Show the banner even while Sift is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking the reminder or "Sift now" opens the watched folder in Sift.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard action == Self.siftNow || action == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { AppModel.shared?.siftWatchedFolder() }
    }
}
