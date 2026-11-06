import SwiftUI
import PhotosUI
import LeeoKit

/// 아이 프로필(이름·사진·반) · 알림 시점 · 캘린더 미러링 설정 화면.
struct SettingsView: View {
    @Binding var settings: ReminderSettings
    /// 해당 아이의 저장된 일정 수 (삭제 확인 문구용)
    var childEventCount: (String) -> Int = { _ in 0 }
    /// 아이 삭제 확정 시 호출 — 일정·프로필 사진 등 연쇄 삭제
    var onDeleteChild: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var avatarTargetIndex: Int?
    @State private var showAvatarPicker = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarRefresh = 0   // 사진 변경 후 아바타 다시 그리기용
    @State private var pendingDeleteIndex: Int?   // 삭제 확인 대기 중인 아이
    @State private var classEditIndex: Int?       // 반 입력 중인 아이
    @State private var classEditText = ""
    @State private var purchases = PurchaseManager.shared
    @ObservedObject private var syncManager = FamilySyncManager.shared
    @State private var paywall: PaywallRequest?
    @State private var showGraduation = false
    @State private var showManageSubscriptions = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(settings.childNames.indices, id: \.self) { i in
                        HStack(spacing: 12) {
                            Button {
                                guard unlocked(.childPhoto) else {
                                    paywall = PaywallRequest(highlight: .childPhoto)
                                    return
                                }
                                avatarTargetIndex = i
                                showAvatarPicker = true
                            } label: {
                                ChildAvatarView(name: settings.childNames[i],
                                                children: settings.childNames,
                                                size: 40, isSelected: false)
                                    .id(avatarRefresh)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("\(settings.childNames[i]) 프로필 사진"))
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("이름 (예: 지호)", text: $settings.childNames[i])
                                    .textInputAutocapitalization(.never)
                                classButton(for: i)
                            }
                        }
                    }
                    .onDelete { offsets in
                        // 바로 지우지 않고 확인부터 (일정도 함께 삭제되므로)
                        pendingDeleteIndex = offsets.first
                    }
                    Button {
                        if needsPlusForAnotherChild {
                            paywall = PaywallRequest(highlight: .moreChildren)
                        } else {
                            settings.childNames.append("")
                        }
                    } label: {
                        HStack {
                            Label("아이 추가", systemImage: "plus.circle.fill")
                            if needsPlusForAnotherChild {
                                Spacer()
                                PlanLockBadge(feature: .moreChildren)
                            }
                        }
                    }
                } header: {
                    Text("아이")
                } footer: {
                    Text("동그라미를 누르면 프로필 사진을 넣을 수 있어요. 반을 입력하면 통신문에서 다른 반 전용 일정(견학 등)을 자동으로 걸러줍니다. 새 학년에 반이 바뀌면 여기만 고쳐주세요.")
                }

                if !sharingBelowReminders {
                    familySharing
                }

                Section {
                    ForEach(ReminderOption.allCases) { option in
                        Toggle(isOn: binding(for: option)) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(option.title)
                                        // 켜려고 누르면 Plus 페이월이 뜬다.
                                        if let feature = PlanFeature.required(for: option), !unlocked(feature) {
                                            PlanLockBadge(feature: feature)
                                        }
                                    }
                                    if !option.appliesToAllDay {
                                        Text("시간이 지정된 일정에만 적용돼요")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: option.systemImage)
                            }
                        }

                    }
                } header: {
                    Text("알림 시점")
                } footer: {
                    Text("종일 일정(소풍·현장학습 등)은 ‘전날 저녁’과 ‘당일 아침’ 알림만 울립니다.")
                }

                Section {
                    Toggle(isOn: $settings.mirrorToCalendar) {
                        Label("애플 캘린더에도 추가", systemImage: "calendar")
                    }
                } footer: {
                    Text("켜면 \(calendarNamesDescription) 달력에 일정이 등록돼요. iOS 캘린더 앱에서 해당 달력을 ‘공유’하면 배우자·가족과 자동으로 동기화됩니다.")
                }

                if sharingBelowReminders {
                    familySharing
                }

                planSection

                Section {
                    // 피드백 보내기 + 리뷰 남기기 + 버전(7탭→개발자 모드→인박스). 전부 LeeoKit 제공.
                    LeeoSupportSection<CalendarSnapSpec>()
                    NavigationLink(LeeoRoadmapText.entry) { RoadmapScreen() }
                    LeeoShareAppLink<CalendarSnapSpec>()
                    LeeoTipJarLink<CalendarSnapSpec>(tipJar: CalendarSnapSpec.tipJar)
                } header: {
                    Text("지원")
                }
            }
            .navigationTitle("알림 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Label("완료", systemImage: "checkmark") }
                }
            }
            // 반 입력 팝업
            .alert(classAlertTitle, isPresented: .constant(classEditIndex != nil)) {
                TextField("반 이름 (예: 무궁화)", text: $classEditText)
                Button("저장") {
                    if let i = classEditIndex, settings.childNames.indices.contains(i) {
                        settings.childClasses[settings.childNames[i]] =
                            classEditText.trimmingCharacters(in: .whitespaces)
                    }
                    classEditIndex = nil
                    classEditText = ""
                }
                Button("취소", role: .cancel) {
                    classEditIndex = nil
                    classEditText = ""
                }
            } message: {
                Text("반을 입력하면 통신문에서 다른 반 전용 일정을 자동으로 걸러줘요.")
            }
            .confirmationDialog(deleteDialogTitle,
                                isPresented: .constant(pendingDeleteIndex != nil),
                                titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    confirmDeleteChild()
                }
                Button("취소", role: .cancel) { pendingDeleteIndex = nil }
            } message: {
                Text(deleteDialogMessage)
            }
            .sheet(item: $paywall) { request in
                PaywallView(highlight: request.highlight, headline: request.headline)
            }
            .sheet(isPresented: $showGraduation) {
                LeeoGraduationOfferView(graduate: purchases.product(PurchaseManager.graduateID)) {
                    await purchases.refresh()
                }
            }
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
            .photosPicker(isPresented: $showAvatarPicker, selection: $avatarItem, matching: .images)
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data),
                       let index = avatarTargetIndex,
                       settings.childNames.indices.contains(index) {
                        ChildAvatarStore.save(uiImage, for: settings.childNames[index])
                        avatarRefresh += 1
                    }
                    avatarItem = nil
                }
            }
        }
    }

    /// 스토어 스크린샷(-demoScreen settings)은 알림 시점이 주인공이라, 일정 공유 섹션을 그 아래로 내린다.
    private var sharingBelowReminders: Bool {
        #if DEBUG
        return ScreenshotDemo.isOn && ScreenshotDemo.screen == "settings"
        #else
        return false
        #endif
    }

    private var calendarNamesDescription: String {
        let names = settings.childNames
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return "‘\(CalendarService.calendarName(for: ""))’" }
        return names.map { "‘\(CalendarService.calendarName(for: $0))’" }.joined(separator: ", ")
    }

    // MARK: - 아이 삭제 확인

    private var pendingDeleteName: String {
        guard let i = pendingDeleteIndex, settings.childNames.indices.contains(i) else { return "" }
        return settings.childNames[i].trimmingCharacters(in: .whitespaces)
    }

    private var deleteDialogTitle: String {
        pendingDeleteName.isEmpty ? String(localized: "아이 삭제") : String(localized: "'\(pendingDeleteName)' 삭제")
    }

    private var deleteDialogMessage: String {
        let name = pendingDeleteName
        guard !name.isEmpty else { return String(localized: "이 아이를 삭제할까요?") }
        let count = childEventCount(name)
        return count > 0
            ? String(localized: "\(name)의 일정 \(count)개와 프로필 사진이 함께 삭제됩니다. 되돌릴 수 없어요.")
            : String(localized: "\(name)의 프로필이 삭제됩니다. 되돌릴 수 없어요.")
    }

    private func confirmDeleteChild() {
        defer { pendingDeleteIndex = nil }
        guard let i = pendingDeleteIndex, settings.childNames.indices.contains(i) else { return }
        let rawName = settings.childNames[i]
        let name = rawName.trimmingCharacters(in: .whitespaces)
        settings.childClasses[rawName] = nil
        settings.childNames.remove(at: i)
        if !name.isEmpty {
            onDeleteChild(name)   // 일정·프로필 사진 연쇄 삭제
        }
    }

    // MARK: - 반 입력

    /// 반이 없으면 "반을 추가해주세요" 버튼, 있으면 "OO반 ✏️" 표시.
    private func classButton(for index: Int) -> some View {
        let className = (settings.childNames.indices.contains(index)
                         ? settings.childClasses[settings.childNames[index]] ?? "" : "")
            .trimmingCharacters(in: .whitespaces)
        return Button {
            classEditIndex = index
            classEditText = className
        } label: {
            if className.isEmpty {
                Label("반을 추가해주세요", systemImage: "plus.circle")
                    .font(.caption)
                    .foregroundStyle(.tint)
            } else {
                HStack(spacing: 4) {
                    Text(className.hasSuffix("반") ? className : String(localized: "\(className)반"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.tint, in: Capsule())
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .accessibilityHint(Text("반 입력"))
            }
        }
        .buttonStyle(.plain)
    }

    private var classAlertTitle: String {
        guard let i = classEditIndex, settings.childNames.indices.contains(i),
              !settings.childNames[i].trimmingCharacters(in: .whitespaces).isEmpty
        else { return String(localized: "반 입력") }
        return String(localized: "\(settings.childNames[i])의 반")
    }

    /// 잠긴 알림 시점은 켜려고 할 때 페이월을 띄운다. 끄는 일은 언제나 된다.
    /// 칸이 내려가 잠긴 시점은 켜져 있어도 울리지 않으므로(→ NotificationManager) 꺼진 것으로 보인다.
    private func binding(for option: ReminderOption) -> Binding<Bool> {
        let feature = PlanFeature.required(for: option)
        return Binding(
            get: { settings.options.contains(option) && feature.map(unlocked) ?? true },
            set: { isOn in
                if isOn, let feature, !unlocked(feature) {
                    paywall = PaywallRequest(highlight: feature)
                } else if isOn {
                    settings.options.insert(option)
                } else {
                    settings.options.remove(option)
                }
            })
    }

    // MARK: - 요금제

    /// 이 기능을 지금 써도 되는가.
    /// 남이 공유한 가족 일정에 참여한 사람은 그 집 아이들을 그대로 다룬다 — 초대받은 사람은 무료다.
    private func unlocked(_ feature: PlanFeature) -> Bool {
        if purchases.allows(feature) { return true }
        return syncManager.role == .participant && (feature == .moreChildren || feature == .childPhoto)
    }

    /// 무료 한도(아이 1명)를 채웠는가. 이미 넣은 아이는 칸과 상관없이 그대로 보이고 지울 수 있다.
    private var needsPlusForAnotherChild: Bool {
        guard !unlocked(.moreChildren) else { return false }
        return settings.childNames.count >= Plan.freeChildLimit
    }

    /// 공유를 새로 만드는 주인만 Pro 를 확인한다. 이미 공유 중이거나 초대받은 사람은 그대로 쓴다.
    private var familySharing: some View {
        FamilySharingSection(canStartSharing: purchases.allows(.familySharing)) {
            paywall = PaywallRequest(highlight: .familySharing)
        }
    }

    private var planSection: some View {
        Section {
            if purchases.isKnown {
                LabeledContent("지금 쓰는 칸", value: purchases.tier.title)
            }
            if purchases.tier < .pro {
                Button {
                    paywall = PaywallRequest()
                } label: {
                    Label("요금제 보기", systemImage: "sparkles")
                }
            }
            if purchases.subscription != nil {
                Button {
                    showManageSubscriptions = true
                } label: {
                    Label("구독 관리", systemImage: "creditcard")
                }
                // 구독 중인 사람이 언제든 평생으로 옮겨 갈 길. 산 뒤 해지 화면으로 바로 안내한다.
                if purchases.product(PurchaseManager.graduateID) != nil, !purchases.ownsLifetime(.pro) {
                    Button {
                        showGraduation = true
                    } label: {
                        Label(LeeoLadderText.switchToLifetimeEntry, systemImage: "graduationcap")
                    }
                }
            }
            Button {
                Task { await purchases.restore() }
            } label: {
                Label("구매 복원", systemImage: "arrow.clockwise")
            }
            .disabled(purchases.isWorking)
        } header: {
            Text("요금제")
        } footer: {
            if purchases.isEarlyUser {
                Text("요금제가 생기기 전부터 쓰신 분이라 Pro가 그대로 열려 있어요.")
            } else if let message = purchases.failureMessage, purchases.tier == .free {
                Text(message)
            }
        }
    }
}

#Preview {
    SettingsView(settings: .constant(.default))
}
