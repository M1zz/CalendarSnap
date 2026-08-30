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

    /// 완전 무료 — 앱에 StoreKit·결제 코드가 없다. 페이월/복원 의무도 없음.
    static let monetization = LeeoMonetization.free
}
