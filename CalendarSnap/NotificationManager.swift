import Foundation
import UserNotifications

/// 추출된 일정에 대해 로컬 알림을 등록합니다.
/// 알림 시점은 사용자의 ReminderSettings(전날 저녁/당일 아침 등)를 따릅니다.
/// 여기에 더해, 새 달이 다가오는데 그 달 일정이 비어 있으면 일정표를 찍으라고 알립니다.
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

        // 칸이 내려가 잠긴 알림 시점(1시간 전 · 정각 → Plus)은 켜져 있어도 울리지 않는다.
        var settings = settings
        settings.options = settings.options.filter { option in
            PlanFeature.required(for: option).map { !Plan.surelyLacks($0) } ?? true
        }

        let now = Date()
        let nudges = monthStartNudges(events: events, now: now)
        for nudge in nudges { await add(center: center, nudge: nudge) }

        let queue = events
            .flatMap { event in
                settings.reminders(for: event).map { Pending(event: event, option: $0.option, fireDate: $0.fireDate) }
            }
            .filter { $0.fireDate > now }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(maxScheduled - nudges.count)

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

    // MARK: - 새 달 일정표 알림

    /// 새 달 1일을 앞두고 "일정표를 찍어 두세요" 하고 알리는 한 번.
    struct MonthStartNudge: Equatable {
        /// 새 달의 1일.
        let monthStart: Date
        /// 1일까지 남은 날 (3 · 2 · 1 · 0).
        let daysLeft: Int
        let fireDate: Date
    }

    /// 월 초가 언제인지 헷갈리지 않게, **새 달 1일의 사흘 전부터 당일까지** 하루 한 번 알린다.
    /// 그 달 일정이 하나라도 들어와 있으면 알리지 않는다 — 일정이 바뀔 때마다 다시 예약하므로 넣는 순간 멎는다.
    /// 앱을 한동안 안 열어도 이어지도록 다음 두 달 치를 본다.
    static func monthStartNudges(events: [ScannedEvent], now: Date,
                                 calendar: Calendar = .app) -> [MonthStartNudge] {
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        return (1...2).flatMap { ahead -> [MonthStartNudge] in
            guard let monthStart = calendar.date(byAdding: .month, value: ahead, to: thisMonth),
                  !events.contains(where: { calendar.isDate($0.date, equalTo: monthStart, toGranularity: .month) })
            else { return [] }
            return (0...3).reversed().compactMap { daysLeft in
                // 앞선 날은 저녁 8시(알림장을 받아 온 시간), 1일 당일은 아침 7시 30분.
                guard let day = calendar.date(byAdding: .day, value: -daysLeft, to: monthStart),
                      let fireDate = calendar.date(bySettingHour: daysLeft == 0 ? 7 : 20,
                                                   minute: daysLeft == 0 ? 30 : 0, second: 0, of: day),
                      fireDate > now
                else { return nil }
                return MonthStartNudge(monthStart: monthStart, daysLeft: daysLeft, fireDate: fireDate)
            }
        }
    }

    /// "12월 1일 화요일 · 3일 후" — 날짜와 남은 날은 시스템이 그 언어로 적는다.
    static func body(for nudge: MonthStartNudge) -> String {
        let relative = RelativeDateTimeFormatter()
        relative.dateTimeStyle = .named
        relative.locale = AppLocale.locale
        relative.calendar = .app
        let day = nudge.monthStart.formatted(.dateTime.month(.wide).day().weekday(.wide).inApp)
        return "\(day) · \(relative.localizedString(from: DateComponents(day: nudge.daysLeft)))"
    }

    private static func add(center: UNUserNotificationCenter, nudge: MonthStartNudge) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "새 달 일정표를 찍어 두세요")
        content.body = body(for: nudge)
        content.sound = .default

        let components = Calendar.app.dateComponents(
            [.year, .month, .day, .hour, .minute], from: nudge.fireDate)
        let month = Calendar.app.dateComponents([.year, .month], from: nudge.monthStart)
        let request = UNNotificationRequest(
            identifier: "calendarsnap.month.\(month.year ?? 0)-\(month.month ?? 0).\(nudge.daysLeft)",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        try? await center.add(request)
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

        let components = Calendar.app.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: "calendarsnap.\(event.id.uuidString).\(option.rawValue)",
            content: content,
            trigger: trigger)

        try? await center.add(request)
    }
}
