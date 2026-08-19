//
//  FamilyShareView.swift
//  CalendarSnap
//
//  가족 초대 화면 — 초대 링크 만들기·보내기, 참여자 확인, 공유 중단.
//  실제 동기화는 FamilyShareService가 담당한다.
//

import CloudKit
import SwiftUI
import UIKit

struct FamilyShareView: View {
    @ObservedObject private var service = FamilyShareService.shared

    @State private var share: CKShare?
    @State private var showShareSheet = false
    @State private var participants: [ShareParticipantInfo] = []
    @State private var showStopConfirm = false
    @State private var accountStatus: CKAccountStatus = .available

    var body: some View {
        List {
            switch service.state.role {
            case .none:
                introSection
                inviteSection
            case .owner:
                ownerSection
                inviteSection
                stopSection
            case .participant:
                participantSection
                stopSection
            }

            if service.state.isSharing {
                syncSection
            }
        }
        .navigationTitle("가족 공유")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            accountStatus = await service.accountStatus()
            await refreshShare()
            await service.syncIfNeeded()
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            Task {
                await refreshShare()
                await service.sync()
            }
        }) {
            if let share {
                CloudSharingSheet(share: share, container: service.cloudContainer) { error in
                    service.errorMessage = "초대 링크를 보내지 못했어요.\n\(error.localizedDescription)"
                } onStopSharing: {
                    Task { await service.stopSharing() }
                }
                .ignoresSafeArea()
            }
        }
        .confirmationDialog(stopTitle, isPresented: $showStopConfirm, titleVisibility: .visible) {
            Button(stopTitle, role: .destructive) {
                Task {
                    await service.stopSharing()
                    await refreshShare()
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(service.state.role == .owner
                 ? "초대한 가족이 더 이상 일정을 볼 수 없게 됩니다. 지금까지의 일정은 양쪽 기기에 그대로 남아요."
                 : "이 가족의 일정을 더 이상 받지 않습니다. 지금까지 받은 일정은 그대로 남아요.")
        }
        .alert("알림", isPresented: .constant(service.infoMessage != nil)) {
            Button("확인") { service.infoMessage = nil }
        } message: {
            Text(service.infoMessage ?? "")
        }
        .alert("오류", isPresented: .constant(service.errorMessage != nil)) {
            Button("확인") { service.errorMessage = nil }
        } message: {
            Text(service.errorMessage ?? "")
        }
    }

    // MARK: - 섹션

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("배우자·조부모와 함께 보기", systemImage: "person.2.fill")
                    .font(.headline)
                Text("초대 링크를 카카오톡·메시지로 보내면, 상대가 아이일정 앱에서 열어 바로 참여할 수 있어요. 이후에는 어느 쪽에서 일정을 추가하거나 고쳐도 양쪽에 자동으로 반영됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var inviteSection: some View {
        Section {
            Button {
                Task {
                    if let prepared = await service.startSharing() {
                        share = prepared
                        showShareSheet = true
                    }
                }
            } label: {
                HStack {
                    Label(service.state.role == .owner ? "초대 링크 보내기 · 참여자 관리" : "가족 초대하기",
                          systemImage: "person.crop.circle.badge.plus")
                    Spacer()
                    if service.isBusy { ProgressView() }
                }
            }
            .disabled(service.isBusy || accountStatus != .available)
        } footer: {
            if accountStatus != .available {
                Text("iCloud에 로그인해야 가족 공유를 쓸 수 있어요. 설정 앱 > Apple 계정에서 로그인해주세요.")
                    .foregroundStyle(.orange)
            } else {
                Text("초대받은 사람도 일정을 추가·수정할 수 있어요. 아이 프로필 사진은 공유되지 않습니다.")
            }
        }
    }

    private var ownerSection: some View {
        Section {
            if participants.isEmpty {
                Label("아직 참여한 사람이 없어요", systemImage: "person.badge.clock")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(participants) { participant in
                    HStack {
                        Label(participant.name, systemImage: "person.crop.circle")
                        Spacer()
                        Text(participant.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("함께 보는 사람")
        } footer: {
            Text("참여자를 빼거나 권한을 바꾸려면 아래 ‘참여자 관리’를 눌러주세요.")
        }
    }

    private var participantSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(ownerTitle, systemImage: "person.2.fill")
                    .font(.headline)
                Text("이 가족의 일정을 함께 보고 있어요. 내가 추가하거나 고친 일정도 상대에게 그대로 전달됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("참여 중")
        }
    }

    private var syncSection: some View {
        Section {
            Button {
                Task { await service.sync() }
            } label: {
                HStack {
                    Label("지금 동기화", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if service.isBusy { ProgressView() }
                }
            }
            .disabled(service.isBusy)
        } footer: {
            Text(lastSyncedText)
        }
    }

    private var stopSection: some View {
        Section {
            Button(stopTitle, role: .destructive) { showStopConfirm = true }
                .disabled(service.isBusy)
        }
    }

    // MARK: - 표시 문구

    private var stopTitle: String {
        service.state.role == .owner ? "공유 중단" : "공유 나가기"
    }

    private var ownerTitle: String {
        let name = service.state.ownerDisplayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "가족의 일정과 연결됨" : "\(name)님과 함께 보는 중"
    }

    private var lastSyncedText: String {
        guard let date = service.state.lastSyncedAt else {
            return "아직 동기화한 적이 없어요."
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 a h:mm"
        return "마지막 동기화 \(formatter.string(from: date)) · 앱을 열 때와 일정을 바꿀 때 자동으로 맞춰져요."
    }

    // MARK: - 공유 정보 새로고침

    private func refreshShare() async {
        guard service.state.isSharing else {
            share = nil
            participants = []
            return
        }
        let current = await service.currentShare()
        share = current
        participants = (current?.participants ?? [])
            .filter { $0.role != .owner }
            .map(ShareParticipantInfo.init)
    }
}

// MARK: - 참여자 표시 모델

struct ShareParticipantInfo: Identifiable {
    let id: String
    let name: String
    let status: String

    init(_ participant: CKShare.Participant) {
        id = participant.userIdentity.userRecordID?.recordName
            ?? participant.userIdentity.lookupInfo?.emailAddress
            ?? UUID().uuidString
        let resolved = FamilyShareService.displayName(for: participant.userIdentity)
        name = resolved.isEmpty ? "초대한 가족" : resolved
        switch participant.acceptanceStatus {
        case .accepted:  status = participant.permission == .readOnly ? "보기 전용" : "함께 편집"
        case .pending:   status = "수락 대기 중"
        case .removed:   status = "제외됨"
        default:         status = ""
        }
    }
}

// MARK: - iOS 기본 공유 시트 (초대 링크 발송·참여자 관리)

struct CloudSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    var onError: (Error) -> Void = { _ in }
    var onStopSharing: () -> Void = {}

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        // 초대받은 사람도 일정을 고칠 수 있어야 하므로 비공개 + 읽기/쓰기만 허용
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let parent: CloudSharingSheet

        init(_ parent: CloudSharingSheet) { self.parent = parent }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "아이일정 함께 보기"
        }

        func cloudSharingController(_ csc: UICloudSharingController,
                                    failedToSaveShareWithError error: Error) {
            parent.onError(error)
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {}

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            parent.onStopSharing()
        }
    }
}
