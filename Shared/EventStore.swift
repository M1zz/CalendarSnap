import Foundation
import WidgetKit

/// App Group UserDefaults에 일정을 JSON으로 저장/로드.
/// 저장 시 위젯 타임라인을 자동으로 갱신합니다.
struct EventStore {
    private static let key = "scannedEvents"

    /// 일정이 저장될 때마다 보내는 알림 — 가족 공유 동기화가 이를 듣고 변경분을 올린다.
    static let didSaveNotification = Notification.Name("EventStoreDidSave")

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroup.identifier)
    }

    static func load() -> [ScannedEvent] {
        guard let data = defaults?.data(forKey: key),
              let events = try? JSONDecoder().decode([ScannedEvent].self, from: data)
        else { return [] }
        return events.sorted { $0.date < $1.date }
    }

    static func save(_ events: [ScannedEvent]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults?.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: didSaveNotification, object: nil)
    }

    static func upcoming(limit: Int = 5) -> [ScannedEvent] {
        load().filter(\.isUpcoming).prefix(limit).map { $0 }
    }
}
