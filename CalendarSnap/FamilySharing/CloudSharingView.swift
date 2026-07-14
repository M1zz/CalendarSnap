import CloudKit
import SwiftUI
import UIKit

/// UICloudSharingController 래퍼 — 초대 링크 보내기·참여자 관리·공유 중지를
/// 시스템 표준(한국어 자동 지원) UI로 제공합니다.
///
/// 애플 가족 공유와 무관하게 원하는 사람 누구나 초대할 수 있도록,
/// "초대한 사람만"(.allowPrivate)과 "링크가 있는 누구나"(.allowPublic)를 모두 허용하고
/// 항상 읽기+쓰기(.allowReadWrite)로 공유합니다.
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    /// 시스템 UI에서 "공유 중지"를 눌렀을 때 호출.
    var onStopSharing: () -> Void = {}

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate, .allowPublic]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let parent: CloudSharingView
        init(_ parent: CloudSharingView) { self.parent = parent }

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
            parent.onStopSharing()
        }
    }
}
