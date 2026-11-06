//
//  Plan.swift
//  아이일정 (앱 · 위젯 함께)
//
//  아이일정의 어느 칸(무료 · Plus · Pro)을 쓰는가. **앱과 위젯이 함께 읽는 한 줄짜리 상태.**
//
//   · 무료: 알림장 사진으로 한 달 일정 넣기(횟수 제한 없음), 아이 1명, 캘린더 등록, 전날 저녁 · 당일 아침 알림
//   · Plus: 아이 여러 명, 아이 사진 프로필, 1시간 전 · 정각 알림
//   · Pro:  Plus 전부 + 초대해서 함께 보기, 홈 화면 위젯
//
//  StoreKit 은 여기 없다. 위젯은 결제를 조회할 수 없으므로 앱(`PurchaseManager`)이 영수증을 읽고
//  App Group 에 칸 한 줄을 적어 두면 위젯은 그것만 읽는다.
//
//  ⚠️ 이 한 줄은 거울이지 권한의 근거가 아니다. 앱은 켜질 때마다 영수증을 다시 읽고 덮어쓴다.
//

import Foundation

/// 칸. 값이 클수록 더 많이 연다. Pro 는 Plus 를 전부 포함한다.
enum PlanTier: Int, Comparable, CaseIterable {
    case free = 0
    case plus = 1
    case pro = 2

    static func < (lhs: PlanTier, rhs: PlanTier) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .free: String(localized: "무료")
        case .plus: String(localized: "아이일정 Plus")
        case .pro:  String(localized: "아이일정 Pro")
        }
    }
}

/// 값을 받고 여는 것들. 페이월 · 설정 · 위젯이 이 목록 하나만 본다.
///
/// ⚠️ 잠그지 않는 것: 사진으로 일정 넣기, 캘린더 등록, 기본 알림, 이미 넣은 아이 · 일정 보기 · 지우기,
///    그날 일정 텍스트 공유, 일정 파일 내보내기, 공유에 초대받아 함께 보기.
enum PlanFeature: String, CaseIterable, Identifiable {
    case moreChildren
    case childPhoto
    case extraReminders
    case familySharing
    case widget

    var id: String { rawValue }

    /// 이 기능을 여는 가장 낮은 칸.
    var tier: PlanTier {
        switch self {
        case .moreChildren, .childPhoto, .extraReminders: .plus
        case .familySharing, .widget:                     .pro
        }
    }

    /// 그 칸에서 새로 열리는 것들 (페이월 카드 차례).
    static func opened(by tier: PlanTier) -> [PlanFeature] { allCases.filter { $0.tier == tier } }

    /// 이 알림 시점을 켜는 데 필요한 기능. 기본 알림(전날 저녁 · 당일 아침)은 nil.
    static func required(for option: ReminderOption) -> PlanFeature? {
        option.appliesToAllDay ? nil : .extraReminders
    }
}

enum Plan {
    /// 무료로 등록할 수 있는 아이 수.
    static let freeChildLimit = 1

    /// 잠긴 위젯을 누르면 가는 곳. 그 자리에서 Pro 페이월이 뜬다 (→ ContentView.onOpenURL).
    static let paywallURL = URL(string: "calendarsnap://paywall/widget")!

    private static let tierKey = "plan.tier"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppGroup.identifier) }

    /// 적혀 있는 칸. **nil 은 '무료'가 아니라 '아직 애플에게 안 물어봤다'** 이다.
    /// 그 차이를 잃으면 영수증 조회가 늦은 순간 산 사람(과 지금까지 쓰던 사람)이 잠긴다.
    static var cachedTier: PlanTier? {
        (defaults?.object(forKey: tierKey) as? Int).flatMap(PlanTier.init(rawValue:))
    }

    /// 영수증 확인 결과를 적는다. `PurchaseManager` 만 부른다.
    static func setTier(_ tier: PlanTier) {
        guard defaults?.object(forKey: tierKey) as? Int != tier.rawValue else { return }
        defaults?.set(tier.rawValue, forKey: tierKey)
    }

    /// **확실히 잠긴 것만 잠근다.** 아직 모르면 열어 둔다.
    /// 화면 없이 도는 곳(위젯 · 알림 예약)이 쓴다. 화면은 `PurchaseManager.allows` 를 본다.
    static func surelyLacks(_ feature: PlanFeature) -> Bool {
        guard let tier = cachedTier else { return false }
        return tier < feature.tier
    }
}
