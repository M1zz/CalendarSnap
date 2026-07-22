import SwiftUI
import LeeoKit

@main
struct CalendarSnapApp: App {
    init() {
        // 리뷰/만족도 프롬프트 타이밍용 실행 기록
        LeeoEngagement.shared.registerLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 사용량이 쌓이면 "즐겁게 쓰고 계신가요?" → 만족 시 리뷰 / 아쉬움 시 피드백
                .leeoSatisfactionCheck(CalendarSnapSpec.self)
        }
    }
}
