import CloudKit
import UIKit

/// UICloudSharingController를 최상단 뷰 컨트롤러에서 직접 present.
///
/// SwiftUI `.sheet`로 감싸면, 이미 시트로 떠 있는 설정 화면 위에 겹쳐 present 하려다
/// "already presenting" 충돌로 초대 창이 즉시 사라집니다. UICloudSharingController는
/// 자신이 초대·관리 UI를 present 하는 컨트롤러이므로 UIKit 레벨에서 직접 표시합니다.
///
/// 애플 가족 공유와 무관하게 원하는 사람 누구나 초대할 수 있도록,
/// "초대한 사람만"(.allowPrivate)과 "링크가 있는 누구나"(.allowPublic)를 모두 허용하고
/// 항상 읽기+쓰기(.allowReadWrite)로 공유합니다.
enum CloudSharingPresenter {
    @MainActor
    static func present(share: CKShare,
                        container: CKContainer,
                        onStopSharing: @escaping () -> Void) {
        guard let presenter = topViewController() else { return }

        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate, .allowPublic]

        // 델리게이트를 컨트롤러 수명 동안 살려두기 (연관 객체로 강한 참조)
        let delegate = Delegate(onStopSharing: onStopSharing)
        controller.delegate = delegate
        objc_setAssociatedObject(controller, &Delegate.associationKey, delegate, .OBJC_ASSOCIATION_RETAIN)

        // iPad에서 팝오버 앵커 (iPhone에서는 무시됨)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                        y: presenter.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    /// 현재 화면에서 가장 위에 present 된 뷰 컨트롤러 (설정 시트 위에 올리기 위함).
    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController
                ?? scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    private final class Delegate: NSObject, UICloudSharingControllerDelegate {
        static var associationKey = 0
        let onStopSharing: () -> Void
        init(onStopSharing: @escaping () -> Void) { self.onStopSharing = onStopSharing }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "아이일정 함께 보기"
        }

        func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
            UIImage(named: "AppIcon")?.pngData()
        }

        func cloudSharingController(_ csc: UICloudSharingController,
                                    failedToSaveShareWithError error: Error) {
            Task { @MainActor in
                FamilySyncManager.shared.infoMessage = "공유 설정에 실패했어요. 네트워크 상태를 확인해주세요."
            }
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { @MainActor in
                await FamilySyncManager.shared.refreshShare()
            }
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onStopSharing()
        }
    }
}
