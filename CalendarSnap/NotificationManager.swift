import Foundation
import UserNotifications

/// 추출된 일정에 대해 로컬 알림을 등록합니다.
enum NotificationManager {

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 각 일정 30분 전 + 정각에 알림 예약. 과거 일정은 건너뜀.
    static func schedule(for events: [ScannedEvent]) async {
        let center = UNUserNotificationCenter.current()

        // 이전에 이 앱이 등록한 일정 알림 제거 후 재등록
        let pending = await center.pendingNotificationRequests()
        let ours = pending.filter { $0.identifier.hasPrefix("calendarsnap.") }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ours)

        for event in events where event.date > Date() {
            await add(center: center, event: event, offsetMinutes: 30, suffix: "pre")
            await add(center: center, event: event, offsetMinutes: 0, suffix: "now")
        }
    }

    private static func add(center: UNUserNotificationCenter,
                            event: ScannedEvent,
                            offsetMinutes: Int,
                            suffix: String) async {
        let fireDate = event.date.addingTimeInterval(TimeInterval(-offsetMinutes * 60))
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = offsetMinutes > 0 ? "곧 시작: \(event.title)" : event.title
        content.body = offsetMinutes > 0
            ? "\(offsetMinutes)분 후 일정이 있습니다."
            : "지금 일정 시간입니다."
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: "calendarsnap.\(event.id.uuidString).\(suffix)",
            content: content,
            trigger: trigger)

        try? await center.add(request)
    }
}
