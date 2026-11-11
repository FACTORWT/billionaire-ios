import Foundation
import UserNotifications

enum NotificationScheduler {
    static let hourKey = "reminder_hour"
    static let enabledKey = "reminder_enabled"
    static let identifier = "daily_streak_reminder"

    static var defaultHour: Int { 19 }

    static func currentHour() -> Int {
        let v = UserDefaults.standard.object(forKey: hourKey) as? Int
        return v ?? defaultHour
    }

    static func isEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        on ? schedule(hour: currentHour()) : cancel()
    }

    static func setHour(_ hour: Int) {
        UserDefaults.standard.set(hour, forKey: hourKey)
        if isEnabled() { schedule(hour: hour) }
    }

    static func requestPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                if settings.authorizationStatus == .authorized, isEnabled() {
                    schedule(hour: currentHour())
                }
                return
            }
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                if granted, isEnabled() { schedule(hour: currentHour()) }
            }
        }
    }

    static func schedule(hour: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = "Tu imperio no se construye solo"
        content.body = "Tienes decisiones pendientes hoy. Mantén tu racha y sube tu reputación."
        content.sound = .default

        var comps = DateComponents()
        comps.hour = hour
        comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger), withCompletionHandler: nil)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
