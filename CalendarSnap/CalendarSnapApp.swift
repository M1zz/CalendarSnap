import SwiftUI
import LeeoKit

@main
struct CalendarSnapApp: App {
    // CloudKit 공유 초대 수락(userDidAcceptCloudKitShareWith)을 받기 위한 델리게이트
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 리뷰/만족도 프롬프트 타이밍용 실행 기록
        LeeoEngagement.shared.registerLaunch()

        // 로컬 저장 → 가족 공유 업로드 훅 연결 (위젯 프로세스에는 없음)
        EventStore.onSave = { events in
            Task { @MainActor in
                FamilySyncManager.shared.enqueueEventsSnapshot(events)
            }
        }
        ReminderSettingsStore.onSave = { settings in
            Task { @MainActor in
                FamilySyncManager.shared.enqueueChildrenSnapshot(settings)
            }
        }
        ChildAvatarStore.onChange = { name in
            Task { @MainActor in
                FamilySyncManager.shared.enqueueAvatarChange(for: name)
            }
        }
        Task { @MainActor in
            FamilySyncManager.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 사용량이 쌓이면 "즐겁게 쓰고 계신가요?" → 만족 시 리뷰 / 아쉬움 시 피드백
                .leeoSatisfactionCheck(CalendarSnapSpec.self)
        }
        .onChange(of: scenePhase) { _, phase in
            // 사일런트 푸시를 못 받는 경우(시뮬레이터 등) 대비 — 포그라운드 진입 시 수동 동기화
            if phase == .active {
                FamilySyncManager.shared.fetchChangesNow()
            }
        }
    }
}
