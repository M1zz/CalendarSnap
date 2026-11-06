//
//  CalendarSnapSpec.swift
//  CalendarSnap
//
//  LeeoKit 계약(LeeoAppSpec) 준수 — 이 앱의 공통 기능 설정값 단일 소스.
//  피드백/리뷰 시스템 구현은 전부 LeeoKit에 있고, 앱은 이 설정만 제공한다.
//
//  ⚠️ 피드백 접수(제출/인박스)가 실제로 동작하려면 아래 컨테이너를
//  Apple 개발자 포털에서 만들고 타겟 iCloud capability(CloudKit)에 추가해야 한다.
//  리뷰 요청·만족도 프롬프트는 CloudKit 없이도 즉시 동작한다.
//

import Foundation
import LeeoKit

enum CalendarSnapSpec: LeeoAppSpec {
    static let appName = "CalendarSnap"
    static let developerEmail = "leeo@kakao.com"

    /// 앱 전용 iCloud 컨테이너 (번들 ID 기반). 포털에서 동일 식별자로 생성 필요.
    static let feedback = LeeoFeedbackConfig(
        containerIdentifier: "iCloud.com.Ysoup.FeedbackHub", appIdentifier: "com.devkoan.CalendarSnap"
    )

    /// docs/ 를 GitHub Pages로 서비스한다 (docs/privacy.html, docs/support.html).
    /// 계정 개념이 없는 앱이라 createsAccounts = false, 삭제 안내 페이지도 불필요.
    static let legal = LeeoLegalConfig(
        privacyURL: URL(string: "https://m1zz.github.io/CalendarSnap/privacy.html")!,
        supportURL: URL(string: "https://m1zz.github.io/CalendarSnap/support.html")!,
        marketingURL: URL(string: "https://m1zz.github.io/CalendarSnap/")!
    )

    /// App Store 앱 ID — 리뷰 남기기·친구에게 소개하기 링크.
    static let appStoreID: String? = "6789881830"

    /// **알림장 찍기는 무료로, 둘째 아이는 Plus, 가족과 함께 보기는 Pro.**
    ///
    /// 무료 · Plus · Pro 세 칸, 유료 칸마다 주 · 월 · 연 구독과 평생 (→ PurchaseManager 상품 ID).
    /// 칸마다 무엇이 열리는지는 `PlanFeature.tier` 한 곳에 있다. 1.0.7 빌드 6 까지 받은 사람은 Pro 다.
    /// 팁은 따로 혼자 돈다(아래 `tipJar`) — 기능을 열지 않으므로 권한 상품에 넣지 않는다.
    static let monetization = LeeoMonetization.freemiumSubscription(
        LeeoSubscriptionConfig(
            productIDs: PurchaseManager.productIDs,
            // 자체 약관이 없으므로 애플 표준 사용권 계약(EULA). 구독을 파는 앱의 심사 필수 항목.
            termsURL: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!,
            entitlementIDs: Set(PurchaseManager.tierByProduct.keys),
            gate: LeeoGatePolicy(
                freeLimits: [PlanFeature.moreChildren.rawValue: Plan.freeChildLimit],
                proOnly: Set(PlanFeature.allCases.filter { $0 != .moreChildren }.map(\.rawValue))),
            // 위젯과 함께 읽는 통.
            cacheSuiteName: AppGroup.identifier))
    /// 금고가 위젯과 함께 쓰는 공유 컨테이너도 백업한다.
    static let appGroups = ["group.com.devkoan.calendarsnap"]

    /// 개발자 응원(팁). 소모성 세 가지, 작은 것부터. 기능을 열지 않는다 — 권한 상품과 따로 혼자 돈다(`startStandalone`).
    @MainActor static let tipJar = LeeoTipJar(config: LeeoTipJarConfig(productIDs: [
        "com.devkoan.CalendarSnap.tip.small", "com.devkoan.CalendarSnap.tip.medium", "com.devkoan.CalendarSnap.tip.large",
    ]))

    /// 익명 사용 통계 → FeedbackHub. 없으면 bootstrap 이 스냅샷·app_open 을 건너뛴다.
    static let analytics: any LeeoAnalytics = LeeoUsageAnalytics(spec: CalendarSnapSpec.self)
}
