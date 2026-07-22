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
    static let developerEmail = "mizzking75@gmail.com"

    /// 앱 전용 iCloud 컨테이너 (번들 ID 기반). 포털에서 동일 식별자로 생성 필요.
    static let feedback = LeeoFeedbackConfig(
        containerIdentifier: "iCloud.com.Ysoup.FeedbackHub", appIdentifier: "com.devkoan.CalendarSnap"
    )
}
