import Foundation

/// 선택한 날의 일정을 카카오톡 등 메신저용 텍스트로 공유.
enum EventSharing {

    /// 하루치 일정 텍스트 요약 (달력 탭 "이 날 일정 공유하기").
    static func daySummary(for events: [ScannedEvent], on day: Date) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "ko_KR")
        dayFormatter.dateFormat = "M/d(E)"

        guard !events.isEmpty else {
            return "📅 \(dayFormatter.string(from: day)) — 일정이 없어요."
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "ko_KR")
        timeFormatter.dateFormat = "a h:mm"

        var out = ["📅 \(dayFormatter.string(from: day)) 아이 일정"]
        for event in events.sorted(by: { $0.date < $1.date }) {
            var line = "· " + (event.isAllDay ? "종일" : timeFormatter.string(from: event.date))
            if !event.childName.isEmpty { line += " [\(event.childName)]" }
            line += " \(event.title)"
            if !event.notes.isEmpty { line += " (\(event.notes))" }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - 구버전 파일 가져오기 (.aischedule)
// 내보내기 UI는 제거됐지만, 구버전 사용자가 보낸 파일은 계속 열 수 있도록 유지.

/// 아이일정 사용자끼리 주고받던 데이터 패키지 (구버전 호환).
struct SchedulePackage: Codable {
    var type = "aischedule"
    var version = 1
    var children: [String] = []
    var events: [ScannedEvent] = []
}

extension EventSharing {
    static let packageExtension = "aischedule"

    static func importPackage(from data: Data) throws -> SchedulePackage {
        let package = try JSONDecoder().decode(SchedulePackage.self, from: data)
        guard package.type == "aischedule" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return package
    }
}
