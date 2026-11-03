//
//  ScanNoticeIntent.swift
//  CalendarSnap
//
//  "아이일정으로 알림장 찍어줘" — 카메라를 바로 연다.
//  단축어 앱에서 사진을 넘기면(예: 사진 공유 → 단축어) 그 사진에서 바로 일정을 뽑는다.
//

import AppIntents
import UIKit

@MainActor @Observable
final class ScanRouter {
    static let shared = ScanRouter()
    /// 늘어날 때마다 첫 화면이 카메라를 연다.
    var cameraRequest = 0
    /// 단축어가 넘긴 사진. 첫 화면이 읽어 들이고 비운다.
    var images: [UIImage] = []
}

struct ScanNoticeIntent: AppIntent {
    static let title = LocalizedStringResource("알림장 스캔", comment: "Siri: scan a daycare notice to extract events")
    static let description = IntentDescription(
        LocalizedStringResource("알림장 사진에서 일정을 뽑습니다. 사진을 넘기지 않으면 카메라를 엽니다.", comment: "Siri: scan notice description")
    )
    static let openAppWhenRun = true

    /// 그림이 아닌 파일은 읽지 못해 걸러진다 (iOS 17 은 형식 제한을 걸 수 없다).
    @Parameter(title: LocalizedStringResource("사진", comment: "Siri: photos parameter"))
    var photos: [IntentFile]?

    @MainActor
    func perform() async throws -> some IntentResult {
        let images = (photos ?? []).compactMap { UIImage(data: $0.data) }
        if images.isEmpty {
            ScanRouter.shared.cameraRequest &+= 1
        } else {
            ScanRouter.shared.images = images
        }
        return .result()
    }
}

struct CalendarSnapShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanNoticeIntent(),
            phrases: [
                "Scan a notice with \(.applicationName)",
                "Add events from a photo with \(.applicationName)"
            ],
            shortTitle: "Scan a Notice",
            systemImageName: "camera.viewfinder"
        )
    }
}
