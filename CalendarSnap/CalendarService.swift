import Foundation
import EventKit
import UIKit

/// 추출한 일정을 애플 캘린더의 전용 "어린이집" 달력에 일괄 등록합니다.
/// 알림은 앱이 로컬 알림으로 직접 담당하므로 여기서는 이벤트만 추가합니다
/// (같은 알림이 두 번 울리는 것을 방지).
enum CalendarService {

    enum CalendarError: LocalizedError {
        case accessDenied
        case noWritableSource

        var errorDescription: String? {
            switch self {
            case .accessDenied:     return "캘린더 접근 권한이 없습니다. 설정 > CalendarSnap에서 허용해주세요."
            case .noWritableSource: return "일정을 추가할 수 있는 캘린더 계정을 찾지 못했습니다."
            }
        }
    }

    /// 일괄 등록 결과 요약.
    struct AddResult {
        var added: Int
        var skipped: Int   // 이미 등록되어 건너뛴 개수
    }

    // MARK: - 권한

    static func requestAccess() async -> Bool {
        let store = EKEventStore()
        // 배포 타깃 iOS 17: 전체 접근 API 사용 (중복 확인을 위해 읽기 권한 필요)
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    // MARK: - 일괄 등록

    /// 한 달치 일정을 아이별 전용 달력에 한 번에 추가.
    /// 같은 날짜·같은 제목은 중복으로 보고 건너뜁니다.
    @discardableResult
    static func addEvents(_ events: [ScannedEvent]) throws -> AddResult {
        guard isAuthorized else { throw CalendarError.accessDenied }
        guard !events.isEmpty else { return AddResult(added: 0, skipped: 0) }

        let store = EKEventStore()
        let cal = Calendar.current
        var result = AddResult(added: 0, skipped: 0)

        // 아이별로 캘린더를 분리 (iCloud 캘린더 공유로 가족과 자동 동기화 가능).
        // 아이 미지정(공통) 일정은 별도 달력을 만들지 않고 모든 아이 달력에 넣음.
        var groups = Dictionary(grouping: events, by: \.childName)
        if let common = groups.removeValue(forKey: ""), !groups.isEmpty {
            for key in groups.keys { groups[key, default: []] += common }
        } else if let common = groups[""], groups.count == 1 {
            groups = ["": common]   // 아이가 아예 없으면 기본 "어린이집" 달력 사용
        }

        // 아이 달력이 있는데 과거에 만들어진 기본 "어린이집" 달력이 남아 있으면 정리
        if !groups.keys.contains("") {
            removeLegacyDefaultCalendar(in: store)
        }

        for (childName, group) in groups {
            let calendar = try targetCalendar(in: store, childName: childName)
            let partial = try add(group, to: calendar, in: store, cal: cal)
            result.added += partial.added
            result.skipped += partial.skipped
        }
        try store.commit()
        return result
    }

    /// 아이 이름 없이 저장하던 시절의 기본 "어린이집" 달력 제거.
    /// (그 안의 일정은 이 앱이 미러링한 사본이며, 아이 달력에 다시 등록됨)
    private static func removeLegacyDefaultCalendar(in store: EKEventStore) {
        guard let legacy = store.calendars(for: .event).first(where: { $0.title == "어린이집" })
        else { return }
        try? store.removeCalendar(legacy, commit: false)
    }

    private static func add(_ events: [ScannedEvent], to calendar: EKCalendar,
                            in store: EKEventStore, cal: Calendar) throws -> AddResult {
        // 중복 방지: 대상 기간의 기존 이벤트 키(제목 + 날짜) 수집
        let sorted = events.sorted { $0.date < $1.date }
        let rangeStart = cal.startOfDay(for: sorted.first!.date)
        let rangeEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: sorted.last!.date)) ?? sorted.last!.date
        let predicate = store.predicateForEvents(withStart: rangeStart, end: rangeEnd, calendars: [calendar])
        var existingKeys = Set(store.events(matching: predicate).map { dedupKey(title: $0.title ?? "", date: $0.startDate, calendar: cal) })

        var result = AddResult(added: 0, skipped: 0)
        for event in events {
            let key = dedupKey(title: event.title, date: event.date, calendar: cal)
            if existingKeys.contains(key) {
                result.skipped += 1
                continue
            }

            let ekEvent = EKEvent(eventStore: store)
            ekEvent.calendar = calendar
            ekEvent.title = event.title
            ekEvent.notes = event.notes.isEmpty ? nil : event.notes

            if event.isAllDay {
                ekEvent.isAllDay = true
                ekEvent.startDate = cal.startOfDay(for: event.date)
                ekEvent.endDate = cal.startOfDay(for: event.date)
            } else {
                ekEvent.startDate = event.date
                ekEvent.endDate = event.date.addingTimeInterval(3600)
            }

            try store.save(ekEvent, span: .thisEvent, commit: false)
            existingKeys.insert(key)
            result.added += 1
        }
        return result
    }

    // MARK: - 전용 달력

    private static func targetCalendar(in store: EKEventStore, childName: String) throws -> EKCalendar {
        let trimmed = childName.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? "어린이집" : "\(trimmed) 어린이집"

        if let existing = store.calendars(for: .event).first(where: { $0.title == name }) {
            return existing
        }

        let newCalendar = EKCalendar(for: .event, eventStore: store)
        newCalendar.title = name
        newCalendar.cgColor = UIColor.systemOrange.cgColor

        guard let source = writableSource(in: store) else {
            throw CalendarError.noWritableSource
        }
        newCalendar.source = source

        try store.saveCalendar(newCalendar, commit: true)
        return newCalendar
    }

    /// 새 달력을 만들 수 있는 계정(소스). 로컬 > iCloud(CalDAV) 순으로 탐색.
    private static func writableSource(in store: EKEventStore) -> EKSource? {
        if let local = store.sources.first(where: { $0.sourceType == .local }) {
            return local
        }
        if let defaultSource = store.defaultCalendarForNewEvents?.source {
            return defaultSource
        }
        return store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first
    }

    private static func dedupKey(title: String, date: Date, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: date)
        return "\(title.trimmingCharacters(in: .whitespaces))|\(Int(day.timeIntervalSince1970))"
    }
}
