import Foundation
import SwiftUI

/// 달력 사진에서 추출된 일정 하나를 나타내는 모델.
/// 앱 타깃과 위젯 타깃이 함께 사용합니다.
struct ScannedEvent: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var date: Date
    /// 시간이 없는 일정(소풍·현장학습 등)은 종일 일정으로 처리합니다.
    var isAllDay: Bool = false
    /// 준비물·메모 (예: "도시락, 돗자리 지참").
    var notes: String = ""
    /// 어느 아이의 일정인지 (빈 문자열 = 공통).
    var childName: String = ""
    /// 매주 반복되는 특별활동 등 반복 일정 여부.
    var isRecurring: Bool = false
    var rawText: String

    var isUpcoming: Bool {
        // 종일 일정은 당일 자정까지 "다가오는 일정"으로 취급
        let reference = isAllDay
            ? Calendar.current.startOfDay(for: date).addingTimeInterval(24 * 60 * 60)
            : date
        return reference >= Date()
    }
}

// 커스텀 디코딩을 확장에 두어 메모버와이즈 이니셜라이저를 유지합니다.
// (구버전 저장 데이터에 새 키가 없어도 안전하게 로드)
extension ScannedEvent {
    enum CodingKeys: String, CodingKey {
        case id, title, date, isAllDay, notes, childName, isRecurring, rawText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        isAllDay = try c.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        childName = try c.decodeIfPresent(String.self, forKey: .childName) ?? ""
        isRecurring = try c.decodeIfPresent(Bool.self, forKey: .isRecurring) ?? false
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText) ?? ""
    }
}

// MARK: - 아이별 색상

extension ScannedEvent {
    /// 아이 순서 기반 팔레트 (앱·위젯 공통).
    static let childPalette: [Color] = [.orange, .teal, .purple, .pink, .indigo, .mint]

    /// 등록된 아이 목록에서의 순서로 색을 정함. 미등록/공통은 주황.
    static func color(for childName: String, children: [String]) -> Color {
        guard let index = children.firstIndex(of: childName) else { return .orange }
        return childPalette[index % childPalette.count]
    }

    func color(children: [String]) -> Color {
        Self.color(for: childName, children: children)
    }
}

enum AppGroup {
    /// ⚠️ 본인 팀에 맞는 App Group ID로 변경하세요 (양쪽 타깃 entitlements도 동일하게).
    static let identifier = "group.com.devkoan.calendarsnap"
}
