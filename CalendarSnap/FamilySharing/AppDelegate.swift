import CloudKit
import UIKit

/// SwiftUI 라이프사이클에서 CloudKit 공유 초대 수락을 받기 위한 델리게이트.
/// (userDidAcceptCloudKitShareWith는 씬 델리게이트로만 전달됨)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // CKSyncEngine이 원격 변경 푸시를 받을 수 있도록 등록 (사용자에게 권한 팝업 없음)
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// 앱 실행 중 초대 링크 수락.
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in
            FamilySyncManager.shared.accept(cloudKitShareMetadata)
        }
    }

    /// 앱이 꺼진 상태에서 초대 링크로 실행된 경우.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { @MainActor in
                FamilySyncManager.shared.accept(metadata)
            }
        }
    }
}
