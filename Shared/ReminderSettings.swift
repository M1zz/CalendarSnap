import Foundation

/// 일정마다 언제 알림을 받을지 정하는 옵션.
enum ReminderOption: String, CaseIterable, Codable, Identifiable {
    case dayBeforeEvening   // 전날 오후 8시 (준비물 챙기기)
    case morningOf          // 당일 오전 7시 30분
    case hourBefore         // 1시간 전 (시간 지정 일정만)
    case atTime             // 정시 (시간 지정 일정만)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dayBeforeEvening: return "전날 저녁 (준비물 챙기기)"
        case .morningOf:        return "당일 아침"
        case .hourBefore:       return "1시간 전"
        case .atTime:           return "일정 시각 정각"
        }
    }

    var systemImage: String {
        switch self {
        case .dayBeforeEvening: return "moon.stars"
        case .morningOf:        return "sunrise"
        case .hourBefore:       return "clock"
        case .atTime:           return "bell"
        }
    }

    /// 종일 일정에도 적용 가능한 옵션인지 (하루 단위 알림).
    var appliesToAllDay: Bool {
        switch self {
        case .dayBeforeEvening, .morningOf: return true
        case .hourBefore, .atTime:          return false
        }
    }

    /// 해당 일정에 대해 이 옵션의 알림이 울릴 시각을 계산.
    func fireDate(for event: ScannedEvent, calendar: Calendar = .current) -> Date? {
        switch self {
        case .dayBeforeEvening:
            guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: event.date) else { return nil }
            return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: dayBefore)
        case .morningOf:
            return calendar.date(bySettingHour: 7, minute: 30, second: 0, of: event.date)
        case .hourBefore:
            guard !event.isAllDay else { return nil }
            return event.date.addingTimeInterval(-3600)
        case .atTime:
            guard !event.isAllDay else { return nil }
            return event.date
        }
    }

    /// 알림 본문 문구.
    func notificationBody(for event: ScannedEvent) -> String {
        let base: String
        switch self {
        case .dayBeforeEvening: base = "내일 일정이에요. 준비물을 미리 챙겨주세요."
        case .morningOf:        base = "오늘 일정이에요."
        case .hourBefore:       base = "1시간 뒤 일정이에요."
        case .atTime:           base = "지금 시작하는 일정이에요."
        }
        return event.notes.isEmpty ? base : "\(base)\n📌 \(event.notes)"
    }
}

/// 아이 목록 + 알림 시점 + 캘린더 미러링 여부.
struct ReminderSettings: Codable, Equatable {
    /// 등록된 아이 이름 목록 (다자녀 지원).
    var childNames: [String] = []
    var options: Set<ReminderOption> = [.dayBeforeEvening, .morningOf]
    /// 애플 캘린더에도 일정을 추가할지 여부 (아이별 캘린더로 분리 생성).
    var mirrorToCalendar: Bool = true

    static let `default` = ReminderSettings()

    /// 해당 일정에 대해 (옵션, 알림시각) 쌍 목록. 시간순 정렬.
    func reminders(for event: ScannedEvent, calendar: Calendar = .current) -> [(option: ReminderOption, fireDate: Date)] {
        ReminderOption.allCases
            .filter { options.contains($0) }
            .compactMap { opt in opt.fireDate(for: event, calendar: calendar).map { (opt, $0) } }
            .sorted { $0.fireDate < $1.fireDate }
    }
}

// 구버전(childName 단일 문자열) 저장 데이터 마이그레이션.
extension ReminderSettings {
    enum CodingKeys: String, CodingKey {
        case childNames, childName, options, mirrorToCalendar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let names = try c.decodeIfPresent([String].self, forKey: .childNames) {
            childNames = names
        } else if let old = try c.decodeIfPresent(String.self, forKey: .childName),
                  !old.trimmingCharacters(in: .whitespaces).isEmpty {
            childNames = [old]
        } else {
            childNames = []
        }
        options = try c.decodeIfPresent(Set<ReminderOption>.self, forKey: .options)
            ?? [.dayBeforeEvening, .morningOf]
        mirrorToCalendar = try c.decodeIfPresent(Bool.self, forKey: .mirrorToCalendar) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(childNames, forKey: .childNames)
        try c.encode(options, forKey: .options)
        try c.encode(mirrorToCalendar, forKey: .mirrorToCalendar)
    }
}

/// App Group UserDefaults에 알림 설정을 저장/로드.
enum ReminderSettingsStore {
    private static let key = "reminderSettings"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroup.identifier)
    }

    static func load() -> ReminderSettings {
        guard let data = defaults?.data(forKey: key),
              let settings = try? JSONDecoder().decode(ReminderSettings.self, from: data)
        else { return .default }
        return settings
    }

    static func save(_ settings: ReminderSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults?.set(data, forKey: key)
    }
}
