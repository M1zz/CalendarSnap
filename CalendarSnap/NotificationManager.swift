import Foundation
import UserNotifications

/// 추출된 일정에 대해 로컬 알림을 등록합니다.
/// 알림 시점은 사용자의 ReminderSettings(전날 저녁/당일 아침 등)를 따릅니다.
enum NotificationManager {

    /// iOS 앱당 예약 가능한 로컬 알림 상한(64)에 여유를 둔 값.
    private static let maxScheduled = 60

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 설정에 따라 각 일정의 알림을 예약. 과거 시각·상한 초과분은 건너뜁니다.
    /// - Returns: 실제로 예약된 알림 개수.
    @discardableResult
    static func schedule(for events: [ScannedEvent], settings: ReminderSettings) async -> Int {
        let center = UNUserNotificationCenter.current()

        // 이전에 이 앱이 등록한 일정 알림 제거 후 재등록
        let pending = await center.pendingNotificationRequests()
        let ours = pending.filter { $0.identifier.hasPrefix("calendarsnap.") }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ours)

        // 모든 (일정 × 알림옵션)을 알림시각 오름차순으로 모아 가까운 것부터 상한까지 예약
        struct Pending {
            let event: ScannedEvent
            let option: ReminderOption
            let fireDate: Date
        }

        let now = Date()
        let queue = events
            .flatMap { event in
                settings.reminders(for: event).map { Pending(event: event, option: $0.option, fireDate: $0.fireDate) }
            }
            .filter { $0.fireDate > now }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(maxScheduled)

        var scheduled = 0
        for item in queue {
            await add(center: center,
                      event: item.event,
                      option: item.option,
                      fireDate: item.fireDate)
            scheduled += 1
        }
        return scheduled
    }

    /// 예약된(다가오는) 일정 알림 개수.
    static func pendingCount() async -> Int {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.filter { $0.identifier.hasPrefix("calendarsnap.") }.count
    }

    private static func add(center: UNUserNotificationCenter,
                            event: ScannedEvent,
                            option: ReminderOption,
                            fireDate: Date) async {
        let content = UNMutableNotificationContent()
        let prefix = event.childName.trimmingCharacters(in: .whitespaces)
        content.title = prefix.isEmpty ? event.title : "\(prefix) · \(event.title)"
        content.body = option.notificationBody(for: event)
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: "calendarsnap.\(event.id.uuidString).\(option.rawValue)",
            content: content,
            trigger: trigger)

        try? await center.add(request)
    }
}
