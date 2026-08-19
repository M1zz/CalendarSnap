import CloudKit
import SwiftUI
import UIKit
import LeeoKit

@main
struct CalendarSnapApp: App {
    // 가족 초대 링크(CKShare) 수락은 씬 델리게이트로만 전달돼서 어댑터가 필요하다.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

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
        // 앱을 열 때마다 가족 공유 중인 일정을 맞춘다 (공유 중이 아니면 아무 일도 하지 않음)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await FamilyShareService.shared.syncIfNeeded() }
        }
    }
}

/// 씬 델리게이트를 끼워 넣기 위한 최소한의 앱 델리게이트.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ShareSceneDelegate.self
        return configuration
    }

    /// 씬을 쓰지 않는 경로로 들어오는 경우까지 대비.
    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { await FamilyShareService.shared.acceptShare(cloudKitShareMetadata) }
    }
}

/// 초대 링크를 눌러 앱이 열렸을 때 공유를 수락한다.
/// (화면 구성은 SwiftUI가 그대로 담당 — 여기서는 수락만 처리)
final class ShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { await FamilyShareService.shared.acceptShare(cloudKitShareMetadata) }
    }
}
