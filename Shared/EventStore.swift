import Foundation
import WidgetKit

/// App Group UserDefaults에 일정을 JSON으로 저장/로드.
/// 저장 시 위젯 타임라인을 자동으로 갱신합니다.
struct EventStore {
    private static let key = "scannedEvents"

    /// 저장 시 호출되는 동기화 훅 (앱에서 가족 공유 업로드용으로 설정, 위젯에서는 nil).
    static var onSave: (([ScannedEvent]) -> Void)?

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroup.identifier)
    }

    static func load() -> [ScannedEvent] {
        guard let data = defaults?.data(forKey: key),
              let events = try? JSONDecoder().decode([ScannedEvent].self, from: data)
        else { return [] }
        return events.sorted { $0.date < $1.date }
    }

    /// - Parameter notifySync: false면 동기화 훅을 건너뜀 (원격 변경 반영 시 에코 루프 방지).
    static func save(_ events: [ScannedEvent], notifySync: Bool = true) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults?.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
        if notifySync { onSave?(events) }
    }

    static func upcoming(limit: Int = 5) -> [ScannedEvent] {
        load().filter(\.isUpcoming).prefix(limit).map { $0 }
    }
}
