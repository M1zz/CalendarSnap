import CloudKit
import SwiftUI

/// 설정 화면의 "일정 공유" 섹션.
/// 애플 가족 공유와 무관하게, 초대 링크를 받은 사람 누구나(배우자·조부모·돌봄 선생님 등)
/// iCloud 계정으로 수락하면 함께 볼 수 있습니다.
/// iCloud 상태·역할(소유자/참여자)에 따라 초대·참여자 관리·나가기 UI를 보여줍니다.
struct FamilySharingSection: View {
    /// sheet(item:)용 래퍼 (CKShare에 Identifiable을 소급 채택하지 않기 위함).
    private struct SharePresentation: Identifiable {
        let id = UUID()
        let share: CKShare
    }

    @ObservedObject private var syncManager = FamilySyncManager.shared
    @State private var shareToPresent: SharePresentation?
    @State private var isPreparingShare = false
    @State private var showStopConfirm = false
    @State private var showLeaveConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            content
        } header: {
            Text("일정 공유")
        } footer: {
            footerText
        }
        .sheet(item: $shareToPresent) { presentation in
            CloudSharingView(share: presentation.share,
                             container: CKContainer(identifier: FamilySyncManager.containerIdentifier),
                             onStopSharing: {
                                 Task { await syncManager.stopSharing() }
                             })
        }
        .confirmationDialog("일정 공유를 중지할까요?", isPresented: $showStopConfirm, titleVisibility: .visible) {
            Button("공유 중지", role: .destructive) {
                Task { await syncManager.stopSharing() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("초대받은 사람은 더 이상 일정을 볼 수 없어요. 내 데이터는 그대로 유지돼요.")
        }
        .confirmationDialog("일정 공유에서 나갈까요?", isPresented: $showLeaveConfirm, titleVisibility: .visible) {
            Button("공유 나가기", role: .destructive) {
                Task { await syncManager.leaveShare() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("나가도 지금까지의 일정은 이 기기에 남아요.")
        }
        .alert("일정 공유", isPresented: .constant(errorMessage != nil)) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            syncManager.refreshAccountStatus()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch syncManager.accountStatus {
        case nil:
            HStack {
                ProgressView()
                Text("iCloud 확인 중…")
                    .foregroundStyle(.secondary)
            }
        case .available:
            availableContent
        default:
            Label("iCloud 로그인이 필요해요", systemImage: "icloud.slash")
                .foregroundStyle(.secondary)
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    @ViewBuilder
    private var availableContent: some View {
        switch syncManager.role {
        case .none:
            Button {
                startSharing()
            } label: {
                if isPreparingShare {
                    HStack {
                        ProgressView()
                        Text("공유 준비 중…")
                    }
                } else {
                    Label("초대해서 함께 보기", systemImage: "person.crop.circle.badge.plus")
                }
            }
            .disabled(isPreparingShare)

        case .owner:
            ForEach(syncManager.participants, id: \.self) { participant in
                participantRow(participant)
            }
            Button {
                startSharing()   // 기존 공유 재사용 — 참여자 추가/관리 화면
            } label: {
                Label(syncManager.participants.isEmpty ? "초대해서 함께 보기" : "참여자 관리",
                      systemImage: "person.2")
            }
            .disabled(isPreparingShare)
            Button(role: .destructive) {
                showStopConfirm = true
            } label: {
                Label("공유 중지", systemImage: "xmark.circle")
            }

        case .participant:
            Label(participantStatusText, systemImage: "person.2.fill")
            Button(role: .destructive) {
                showLeaveConfirm = true
            } label: {
                Label("공유 나가기", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    private func participantRow(_ participant: CKShare.Participant) -> some View {
        HStack {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            Text(participantName(participant))
            Spacer()
            Text(participant.acceptanceStatus == .accepted ? "참여 중" : "수락 대기")
                .font(.caption)
                .foregroundStyle(participant.acceptanceStatus == .accepted ? .green : .secondary)
        }
    }

    private func participantName(_ participant: CKShare.Participant) -> String {
        let identity = participant.userIdentity
        if let components = identity.nameComponents,
           let formatted = PersonNameComponentsFormatter().string(for: components),
           !formatted.isEmpty {
            return formatted
        }
        return identity.lookupInfo?.emailAddress
            ?? identity.lookupInfo?.phoneNumber
            ?? "함께 보는 사람"
    }

    private var participantStatusText: String {
        if let ownerIdentity = syncManager.share?.owner.userIdentity,
           let components = ownerIdentity.nameComponents,
           let formatted = PersonNameComponentsFormatter().string(for: components),
           !formatted.isEmpty {
            return "\(formatted)님이 공유한 일정을 함께 보는 중"
        }
        return "공유된 일정을 함께 보는 중"
    }

    private var footerText: Text {
        switch syncManager.role {
        case .none:
            return Text("배우자·조부모·돌봄 선생님 등 원하는 사람을 초대해 모든 아이·일정을 실시간으로 함께 관리할 수 있어요. 애플 가족 공유와 무관하며, 초대 링크는 메시지·카카오톡으로 보낼 수 있어요.")
        case .owner:
            return Text("초대한 사람이 일정을 추가·수정하면 내 기기에도 바로 반영돼요.")
        case .participant:
            return Text("일정을 추가·수정하면 함께 보는 모두의 기기에 반영돼요.")
        }
    }

    private func startSharing() {
        isPreparingShare = true
        Task {
            defer { isPreparingShare = false }
            do {
                shareToPresent = SharePresentation(share: try await syncManager.createShare())
            } catch let error as FamilySharingError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = "공유를 시작하지 못했어요. 네트워크 상태를 확인한 뒤 다시 시도해주세요."
            }
        }
    }
}

