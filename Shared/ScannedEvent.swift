import Foundation

/// 달력 사진에서 추출된 일정 하나를 나타내는 모델.
/// 앱 타깃과 위젯 타깃이 함께 사용합니다.
struct ScannedEvent: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var date: Date
    var rawText: String

    var isUpcoming: Bool { date >= Date() }
}

enum AppGroup {
    /// ⚠️ 본인 팀에 맞는 App Group ID로 변경하세요 (양쪽 타깃 entitlements도 동일하게).
    static let identifier = "group.com.devkoan.calendarsnap"
}
