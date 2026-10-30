import SwiftUI
import PhotosUI
import LeeoKit

/// 챙긴 일정이 이만큼 쌓였을 때 응원을 부탁한다. 큰 것부터.
enum CalendarSnapTipMoments {
    static let events = [200, 100, 30]

    static func reached(events total: Int) -> [LeeoTipMoment] {
        events.filter { total >= $0 }.map { threshold in
            LeeoTipMoment(id: "events.\(threshold)",
                          message: String(localized: "지금까지 아이 일정 \(total)개를 챙겼어요",
                                          comment: "Tip ask card: number of child schedule entries saved in the app"))
        }
    }
}

struct ContentView: View {
    @State private var pickedItems: [PhotosPickerItem] = []
    /// 이번 스캔 세션에서 올린 사진들 (페이지 스와이프로 확인)
    @State private var scannedImages: [UIImage] = []
    @State private var showPhotoViewer = false
    @State private var photoViewerIndex = 0
    /// 저장된 일정 (달력 탭·위젯·공유의 원본)
    @State private var savedEvents: [ScannedEvent] = EventStore.load()
    /// 이번에 추가한 사진에서 추출된 일정 원본 (반 필터 적용 전)
    @State private var scannedAll: [ScannedEvent] = []
    /// 스캔 탭에 표시되는 일정 (아이 반에 맞게 필터됨 — 저장하면 비워짐)
    @State private var scanned: [ScannedEvent] = []
    @State private var settings: ReminderSettings = ReminderSettingsStore.load()
    @State private var isProcessing = false
    @State private var showCamera = false
    @State private var showPasteText = false
    @State private var showSettings = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var savedBanner = false
    // 이미 저장된 일정이 있으면 달력 탭으로 시작
    @State private var selectedTab = EventStore.load().isEmpty ? 0 : 1
    // 이번 스캔이 어느 아이의 달력인지
    @State private var selectedChild = ""
    // 다른 아이일정 사용자에게 받은 데이터 가져오기 결과
    @State private var importMessage: String?
    // 일정 직접 추가
    @State private var showAddEvent = false
    @State private var addEventDate = Date()
    // 아이 미등록 상태에서 저장 시 이름을 물어보는 팝업
    @State private var showAskChild = false
    @State private var newChildName = ""
    // 자동 아이 추정으로 인한 선택 변경 시, 전체 재배정을 건너뛰기 위한 플래그
    @State private var suppressRestamp = false
    // 가족 공유 상태 (참여/종료 안내 메시지 표시용)
    @ObservedObject private var syncManager = FamilySyncManager.shared
    // 저장된 일정 중 다른 반 전용으로 보이는 것 정리 제안
    @State private var otherClassEvents: [ScannedEvent] = []
    @State private var otherClassNames: Set<String> = []
    @State private var showClassCleanup = false
    // 아이폰 듀오: 펴면 달력 탭이 오른쪽(세로면 위) 판으로 옮겨 간다 (LeeoKit Fold)
    @Environment(\.foldLayout) private var fold
    /// 펼치면서 달력 탭을 스캔 탭으로 돌렸다. 접으면 달력 탭으로 돌아간다.
    @State private var foldMovedCalendar = false

    var body: some View {
        TabView(selection: $selectedTab) {
            // 펴면 왼쪽(세로면 아래) 스캔 | 오른쪽(위) 달력 — 찍고 저장한 일정이 바로 옆 달력에 선다.
            // 접혀 있거나 보통 아이폰이면 스캔만 그린다(지금 화면 그대로). 두 쪽이 다 보이니 탭바는 숨긴다.
            FoldSplitView {
                scanTab
            } result: {
                calendarTab
                    .environment(\.foldLayout, .single)
            }
            .toolbar(fold.isUnfolded ? .hidden : .automatic, for: .tabBar)
            .tabItem { Label("스캔", systemImage: "camera.viewfinder") }
            .tag(0)

            calendarTab
                .tabItem { Label("달력", systemImage: "calendar") }
                .tag(1)
        }
        // 펼친 화면에는 달력 탭이 따로 서지 않는다 — 달력은 오른쪽 판에 있다.
        .onChange(of: fold.isUnfolded, initial: true) { _, _ in foldRedirectTab() }
        .onChange(of: selectedTab) { _, _ in foldRedirectTab() }
        #if DEBUG
        .onAppear { applyScreenshotDemo() }
        #endif
        // 다른 사용자가 보낸 .aischedule 파일을 열면 일정을 채워줌
        .onOpenURL { url in
            handleIncomingFile(url)
        }
        // 가족 공유로 받은 원격 변경을 화면·알림·캘린더에 반영
        .onReceive(NotificationCenter.default.publisher(for: .familyDataDidChange)) { _ in
            applyFamilyDataChange()
        }
        // 공유 참여/종료 등 일정 공유 안내
        .alert("일정 공유", isPresented: .constant(syncManager.infoMessage != nil)) {
            Button("확인") { syncManager.infoMessage = nil }
        } message: {
            Text(syncManager.infoMessage ?? "")
        }
        // 앱 시작 시 이미 저장돼 있는 다른 반 일정을 발견하면 정리 제안
        .onAppear {
            offerOtherClassCleanup()
        }
        .confirmationDialog("다른 반 일정 정리", isPresented: $showClassCleanup, titleVisibility: .visible) {
            Button("일정 \(otherClassEvents.count)개 삭제", role: .destructive) {
                removeOtherClassEvents()
            }
            Button("남겨두기", role: .cancel) {
                otherClassEvents = []
                otherClassNames = []
            }
        } message: {
            Text("등록된 아이의 반이 아닌 \(otherClassSummary) 일정 \(otherClassEvents.count)개가 저장돼 있어요. 삭제할까요?")
        }
        // 설정 시트와 오류 알림은 어느 탭에서든 열리도록 탭 공통 레벨에 부착
        .sheet(isPresented: $showSettings, onDismiss: {
            settings.childNames = settings.childNames
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            ReminderSettingsStore.save(settings)
            adoptOrphanEventsIfPossible()
            refreshScanned()   // 반이 바뀌었을 수 있으니 필터 재적용
            offerOtherClassCleanup()   // 반 입력/변경 시 기존 저장분도 정리 제안
        }) {
            SettingsView(settings: $settings,
                         childEventCount: { name in
                             savedEvents.filter { $0.childName == name }.count
                         },
                         onDeleteChild: { name in
                             deleteChild(name)
                         })
        }
        .alert("오류", isPresented: .constant(errorMessage != nil)) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("가져오기 완료", isPresented: .constant(importMessage != nil)) {
            Button("확인") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
        // 올린 사진 크게 보기 (스와이프 + 핀치 줌)
        .fullScreenCover(isPresented: $showPhotoViewer) {
            PhotoViewerView(images: scannedImages, index: photoViewerIndex)
                .foldConfined()
        }
        .sheet(isPresented: $showAddEvent) {
            AddEventView(children: registeredChildren,
                         initialDate: addEventDate,
                         initialChild: selectedChild.isEmpty ? (registeredChildren.first ?? "") : selectedChild) { newEvent in
                addManualEvent(newEvent)
            }
        }
        // 아이가 등록돼 있지 않으면 저장 전에 누구의 일정인지 물어봄
        .alert("누구의 일정인가요?", isPresented: $showAskChild) {
            TextField("아이 이름 (예: 지호)", text: $newChildName)
            Button("저장") {
                let name = newChildName.trimmingCharacters(in: .whitespaces)
                newChildName = ""
                guard !name.isEmpty else { return }
                settings.childNames.append(name)
                ReminderSettingsStore.save(settings)
                selectedChild = name
                Task { await addAllEvents() }
            }
            Button("취소", role: .cancel) { newChildName = "" }
        } message: {
            Text("아이를 등록하면 일정이 아이별로 관리되고 알림에도 이름이 함께 표시돼요.")
        }
    }

    /// 직접 추가한 일정은 즉시 저장 + 위젯 갱신 + (권한 있으면) 알림 예약.
    /// 새 아이 이름이 입력됐다면 아이도 함께 등록.
    private func addManualEvent(_ event: ScannedEvent) {
        let name = event.childName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !settings.childNames.contains(name) {
            settings.childNames.append(name)
            ReminderSettingsStore.save(settings)
        }
        if selectedChild.isEmpty { selectedChild = name }

        savedEvents = (savedEvents + [event]).sorted { $0.date < $1.date }
        EventStore.save(savedEvents)
        Task {
            if await NotificationManager.authorizationStatus() == .authorized {
                await NotificationManager.schedule(for: savedEvents, settings: settings)
            }
        }
    }

    /// 주인 없는(공통) 일정 복구: 등록된 아이가 정확히 1명이면 그 아이에게 자동 배정.
    /// (아이 없이 일정을 만들었다가 나중에 아이를 등록한 경우,
    ///  통합에는 보이는데 아이 필터에는 없는 모순을 방지)
    private func adoptOrphanEventsIfPossible() {
        let names = registeredChildren
        guard names.count == 1, savedEvents.contains(where: { $0.childName.isEmpty }) else { return }
        savedEvents = savedEvents.map { event in
            var e = event
            if e.childName.isEmpty { e.childName = names[0] }
            return e
        }
        EventStore.save(savedEvents)
    }

    // MARK: - 다른 반 일정 정리

    /// 저장된 일정 중 "OO반" 표기가 명시된, 등록된 아이들 반이 아닌 일정을 찾아 삭제를 제안.
    private func offerOtherClassCleanup() {
        let myClasses = registeredChildren.compactMap { settings.childClasses[$0] }
        guard !myClasses.isEmpty else { return }
        let found = EventParser.otherClassEvents(in: savedEvents, myClasses: myClasses)
        guard !found.events.isEmpty else { return }
        otherClassEvents = found.events
        otherClassNames = found.classes
        showClassCleanup = true
    }

    private var otherClassSummary: String {
        otherClassNames.sorted().prefix(3).map { String(localized: "\($0)반") }.joined(separator: "·")
    }

    private func removeOtherClassEvents() {
        let ids = Set(otherClassEvents.map(\.id))
        otherClassEvents = []
        otherClassNames = []
        guard !ids.isEmpty else { return }
        savedEvents.removeAll { ids.contains($0.id) }
        EventStore.save(savedEvents)
        Task {
            if await NotificationManager.authorizationStatus() == .authorized {
                await NotificationManager.schedule(for: savedEvents, settings: settings)
            }
        }
    }

    /// 가족 공유 원격 변경 반영: 로컬 스토어를 다시 읽고 알림·캘린더 미러링을 갱신.
    private func applyFamilyDataChange() {
        savedEvents = EventStore.load()
        settings = ReminderSettingsStore.load()
        refreshScanned()
        Task {
            if await NotificationManager.authorizationStatus() == .authorized {
                await NotificationManager.schedule(for: savedEvents, settings: settings)
            }
            if settings.mirrorToCalendar, await CalendarService.requestAccess() {
                _ = try? CalendarService.addEvents(savedEvents)   // 기존 중복 제외 로직 활용
            }
        }
    }

    /// 다른 아이일정 사용자가 공유한 데이터 파일 가져오기.
    private func handleIncomingFile(_ url: URL) {
        guard url.pathExtension.lowercased() == EventSharing.packageExtension else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let package = try EventSharing.importPackage(from: try Data(contentsOf: url))

            // 아이 목록 병합
            for name in package.children where !name.isEmpty && !settings.childNames.contains(name) {
                settings.childNames.append(name)
            }
            ReminderSettingsStore.save(settings)

            // 일정 병합 (중복 제외)
            let fresh = newEvents(package.events, excluding: savedEvents)
            savedEvents = (savedEvents + fresh).sorted { $0.date < $1.date }
            EventStore.save(savedEvents)

            selectedTab = 1
            let skipped = package.events.count - fresh.count
            importMessage = String(localized: "일정 \(fresh.count)개를 가져왔어요.")
                + (skipped > 0 ? String(localized: " (이미 있는 \(skipped)개 제외)") : "")

            // 알림 권한이 이미 있으면 가져온 일정까지 포함해 재예약
            Task {
                if await NotificationManager.authorizationStatus() == .authorized {
                    await NotificationManager.schedule(for: savedEvents, settings: settings)
                }
            }
        } catch {
            errorMessage = String(localized: "일정 데이터를 가져오지 못했습니다.\n아이일정 앱에서 내보낸 파일인지 확인해주세요.")
        }
    }

    // MARK: - 탭

    /// 펼친 화면에서 달력 탭으로 가려 하면(저장 뒤 이동 포함) 스캔 탭에 남기고, 접으면 달력 탭으로 돌려 놓는다.
    private func foldRedirectTab() {
        if fold.isUnfolded, selectedTab == 1 {
            foldMovedCalendar = true
            selectedTab = 0
        } else if !fold.isUnfolded, foldMovedCalendar {
            foldMovedCalendar = false
            selectedTab = 1
        }
    }

    private var scanTab: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                // 방금 일정을 저장한 자리. 쌓인 일정이 숫자로 보일 때만, 드물게 응원을 부탁한다.
                if savedBanner {
                    LeeoTipAskSlot<CalendarSnapSpec>(tipJar: CalendarSnapSpec.tipJar,
                                                     reached: CalendarSnapTipMoments.reached(events: savedEvents.count))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                childPickerSection
                imageSection
                eventsSection
            }
            #if DEBUG
            .task(id: scanned.isEmpty) {
                guard ScreenshotDemo.screen == "events", let first = scanned.first?.id else { return }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(first, anchor: .top)
            }
            #endif
            }
            // 스캔 후 저장을 놓치지 않도록 화면 하단에 항상 보이는 저장 바
            .safeAreaInset(edge: .bottom) {
                if !scanned.isEmpty || savedBanner {
                    saveBar
                }
            }
            .navigationTitle("아이일정")
            .toolbar { toolbarContent }
            .overlay { if isProcessing { processingOverlay } }
            .sheet(isPresented: $showCamera) {
                CameraPicker { captured in
                    scannedImages.append(captured)
                    Task { await runOCR(on: captured) }
                }
                .ignoresSafeArea()
            }
            // 어린이집 문자·카카오톡 메시지를 붙여넣어 일정으로 추출
            .sheet(isPresented: $showPasteText) {
                PasteTextView { text in
                    Task { await runParse(on: text) }
                }
            }
            // 위에서 아이를 바꾸면 추출된 일정 전체를 그 아이로 재배정하고 반 필터도 다시 적용
            .onChange(of: selectedChild) { _, newChild in
                // 자동 추정에 의한 변경은 해당 사진 분량만 배정되므로 전체 재배정 생략
                if suppressRestamp {
                    suppressRestamp = false
                    refreshScanned()
                    return
                }
                guard !newChild.isEmpty, !scannedAll.isEmpty else { return }
                scannedAll = scannedAll.map { event in
                    var e = event
                    e.childName = newChild
                    return e
                }
                refreshScanned()
            }
            // 목록에서의 편집(제목·시간·아이 등)을 원본에도 반영
            .onChange(of: scanned) { _, edited in
                for event in edited {
                    if let i = scannedAll.firstIndex(where: { $0.id == event.id }) {
                        scannedAll[i] = event
                    }
                }
            }
            .onChange(of: pickedItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    // 여러 장(통신문 I/II, 달력 등)을 한 번에 스캔해 일정 누적
                    var added = 0
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data) {
                            scannedImages.append(uiImage)
                            added += await runOCR(on: uiImage)
                        }
                    }
                    pickedItems = []
                    if added == 0 {
                        errorMessage = String(localized: "일정으로 인식할 텍스트를 찾지 못했습니다.\n글씨가 선명하게 나오도록 다시 찍어보세요.")
                    }
                }
            }
        }
    }

    private var calendarTab: some View {
        NavigationStack {
            MonthCalendarView(events: savedEvents, children: settings.childNames,
                              onAddEvent: { date in
                                  addEventDate = date
                                  showAddEvent = true
                              },
                              onDelete: { event in
                                  savedEvents.removeAll { $0.id == event.id }
                                  EventStore.save(savedEvents)
                              })
                .navigationTitle("달력")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel(Text("설정"))
                    }
                }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var imageSection: some View {
        if scannedImages.isEmpty {
            // 문자 붙여넣기로 추출된 일정만 있을 땐 안내 카드를 숨김
            if scanned.isEmpty {
                Section {
                    ContentUnavailableView(
                        "어린이집 알림장을 찍거나 문자를 붙여넣어 보세요",
                        systemImage: "calendar.badge.plus",
                        description: Text("한 달 일정을 자동으로 추출해\n캘린더에 한 번에 추가하고 알림을 보내드려요."))
                }
            }
        } else {
            Section {
                // 올린 사진들을 좌우 스와이프로 넘겨보고, 탭하면 크게 보기
                TabView(selection: $photoViewerIndex) {
                    ForEach(scannedImages.indices, id: \.self) { i in
                        Image(uiImage: scannedImages[i])
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.bottom, scannedImages.count > 1 ? 24 : 0)
                            .contentShape(Rectangle())
                            .onTapGesture { showPhotoViewer = true }
                            // VoiceOver·음성 명령에서도 사진을 열 수 있게 버튼으로 알린다
                            .accessibilityElement()
                            .accessibilityLabel(Text("사진 크게 보기"))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { showPhotoViewer = true }
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: scannedImages.count > 1 ? .always : .never))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .frame(height: 250)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(scannedImages.count > 1
                     ? String(localized: "사진 \(scannedImages.count)장 — 좌우로 넘겨보고, 탭하면 크게 볼 수 있어요.")
                     : String(localized: "사진을 탭하면 크게 볼 수 있어요."))
            }
        }
    }

    @ViewBuilder
    private var eventsSection: some View {
        if !scanned.isEmpty {
            Section {
                ForEach($scanned) { $event in
                    EventRow(event: $event, children: registeredChildren)
                }
                .onDelete { offsets in
                    let ids = offsets.map { scanned[$0].id }
                    scanned.remove(atOffsets: offsets)
                    scannedAll.removeAll { ids.contains($0.id) }
                }
            } header: {
                Text("이번 사진에서 추출된 일정 \(scanned.count)개")
            } footer: {
                Text("제목·시간·준비물을 확인하고, 동그라미를 눌러 아이를 바꾸거나 필요 없는 일정은 밀어서 삭제하세요. 저장하면 달력으로 이동합니다.")
            }

            reminderSummarySection
        }
        addEventSection
    }

    private var addEventSection: some View {
        Section {
            Button {
                addEventDate = Date()
                showAddEvent = true
            } label: {
                Label("일정 직접 추가", systemImage: "plus.circle.fill")
            }
        }
    }

    @ViewBuilder
    private var childPickerSection: some View {
        let names = registeredChildren
        if names.count >= 2 {
            Section("누구의 일정인가요?") {
                HStack(spacing: 18) {
                    ForEach(names, id: \.self) { name in
                        ChildAvatarButton(name: name, label: name,
                                          children: names,
                                          isSelected: selectedChild == name,
                                          size: 48) {
                            withAnimation { selectedChild = name }
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .onAppear {
                    if selectedChild.isEmpty { selectedChild = names[0] }
                }
            }
        }
    }

    private var registeredChildren: [String] {
        settings.childNames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var reminderSummarySection: some View {
        Section("알림 설정") {
            Button {
                showSettings = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if !registeredChildren.isEmpty {
                            Text(registeredChildren.joined(separator: " · "))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        Text(reminderSummaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .tint(.primary)
        }
    }

    /// 하단 고정 저장 바 — 스캔 결과를 저장해야 알림·달력에 반영된다는 것을 놓치지 않게.
    private var saveBar: some View {
        VStack(spacing: 6) {
            Button {
                if registeredChildren.isEmpty {
                    showAskChild = true   // 아이부터 물어보고 저장
                } else {
                    Task { await addAllEvents() }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: savedBanner ? "checkmark.circle.fill" : "calendar.badge.plus")
                    Text(savedBanner ? String(localized: "저장 완료! 달력·위젯에서 확인하세요")
                         : String(localized: "일정 \(scanned.count)개 저장 + 알림 받기"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(savedBanner ? .green : .accentColor)

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        // 저장 결과는 아래 작은 글로만 나오니 VoiceOver 에는 말로 알린다
        .onChange(of: resultMessage) { _, message in
            if let message, !message.isEmpty { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private var reminderSummaryText: String {
        let selected = ReminderOption.allCases.filter { settings.options.contains($0) }
        let times = selected.isEmpty ? String(localized: "알림 없음") : selected.map(\.title).joined(separator: ", ")
        let cal = settings.mirrorToCalendar ? String(localized: " · 캘린더에도 추가") : ""
        return times + cal
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel(Text("설정"))
            if !scanned.isEmpty {
                Button(role: .destructive) {
                    scannedAll = []
                    scanned = []
                    scannedImages = []
                    resultMessage = nil
                    savedBanner = false
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(Text("스캔 결과 지우기"))
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            // 문자·카카오톡 메시지 붙여넣기
            Button {
                showPasteText = true
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .accessibilityLabel(Text("문자로 일정 추가"))
            Button {
                showCamera = true
            } label: {
                Image(systemName: "camera")
            }
            .accessibilityLabel(Text("사진 찍기"))
            // 통신문·달력 여러 장을 한 번에 선택 가능
            PhotosPicker(selection: $pickedItems, maxSelectionCount: 10, matching: .images) {
                Image(systemName: "photo.on.rectangle")
            }
            .accessibilityLabel(Text("사진 선택"))
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("처리 중…")
                    .font(.callout)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Actions

    /// 사진 한 장을 OCR → 파싱해 현재 목록에 누적. 추가된 일정 수를 반환.
    @discardableResult
    private func runOCR(on image: UIImage) async -> Int {
        isProcessing = true
        savedBanner = false
        resultMessage = nil
        defer { isProcessing = false }
        do {
            let recognized = try await OCRService.recognizeLines(in: image)

            // 달력 격자 사진이면 셀 위치 기반 파싱, 아니면 줄 단위(통신문·안내문) 파싱으로 폴백
            var parsed = CalendarGridParser.parse(lines: recognized)
            if parsed.isEmpty {
                parsed = EventParser.parse(recognized: recognized)
            }
            return ingest(parsed)
        } catch {
            errorMessage = error.localizedDescription
            return 0
        }
    }

    /// 붙여넣은 문자·카카오톡 메시지를 파싱해 현재 목록에 누적. 추가된 일정 수를 반환.
    @discardableResult
    private func runParse(on text: String) async -> Int {
        isProcessing = true
        savedBanner = false
        resultMessage = nil
        defer { isProcessing = false }

        let parsed = EventParser.parseMessage(text)
        let added = ingest(parsed)
        if added == 0 {
            errorMessage = String(localized: "이 문자에서 날짜가 있는 일정을 찾지 못했습니다.\n날짜(예: 7월 12일)나 '내일·금요일' 같은 표현이 있는지 확인해주세요.")
        }
        return added
    }

    /// 파싱된 일정을 아이 자동추정·중복제거 후 이번 스캔 목록에 누적. 추가된 개수 반환.
    /// (사진 OCR·문자 붙여넣기 두 입력 경로가 공통으로 사용)
    @discardableResult
    private func ingest(_ parsed: [ScannedEvent]) -> Int {
        // 과거 일정 패턴(반 이름·고유 어휘)으로 어느 아이의 문서인지 자동 추정
        if registeredChildren.count >= 2,
           let guessed = EventParser.guessChild(for: parsed,
                                                history: savedEvents,
                                                children: registeredChildren,
                                                classes: settings.childClasses),
           guessed != selectedChild {
            suppressRestamp = true
            selectedChild = guessed
            resultMessage = String(localized: "일정 패턴을 보고 '\(guessed)'의 문서로 인식했어요. 아니라면 위에서 바꿔주세요.")
        }

        // 선택된 아이(미선택이면 첫 아이)로 표시 후 이번 스캔 목록에 누적
        // (이미 저장돼 있거나 이번 스캔에 있는 일정은 중복 제외)
        let assignChild = selectedChild.isEmpty ? (registeredChildren.first ?? "") : selectedChild
        let stamped = parsed.map { event -> ScannedEvent in
            var e = event
            if e.childName.isEmpty { e.childName = assignChild }
            return e
        }
        let fresh = newEvents(stamped, excluding: savedEvents + scannedAll)
        scannedAll = (scannedAll + fresh).sorted { $0.date < $1.date }
        refreshScanned()
        return fresh.count
    }

    /// 이번 스캔 결과를 저장소에 병합 + 알림 예약 + (옵션) 애플 캘린더 미러링.
    /// 저장이 끝나면 스캔 작업 공간(사진·추출 목록)은 비워짐.
    private func addAllEvents() async {
        guard !scanned.isEmpty else { return }
        isProcessing = true
        savedBanner = false
        defer { isProcessing = false }

        ReminderSettingsStore.save(settings)

        // 아이 미지정 일정은 현재 선택된 아이(미선택이면 첫 아이)로 표시
        let assignChild = selectedChild.isEmpty ? (registeredChildren.first ?? "") : selectedChild
        let stamped = scanned.map { event in
            var e = event
            if e.childName.isEmpty { e.childName = assignChild }
            return e
        }

        // 저장소에 병합 (중복 제외)
        let fresh = newEvents(stamped, excluding: savedEvents)
        savedEvents = (savedEvents + fresh).sorted { $0.date < $1.date }
        EventStore.save(savedEvents)   // 위젯 갱신

        // 스캔 작업 공간 비우기 — 저장된 일정은 달력 탭에서
        scannedAll = []
        scanned = []
        scannedImages = []

        var messages: [String] = []

        // 1) 로컬 알림 — 앱이 직접 알림을 담당
        if settings.options.isEmpty {
            messages.append(String(localized: "알림 시점이 꺼져 있어요"))
        } else {
            let granted = await NotificationManager.requestAuthorization()
            if granted {
                let n = await NotificationManager.schedule(for: savedEvents, settings: settings)
                messages.append(String(localized: "알림 \(n)개 예약"))
            } else {
                messages.append(String(localized: "알림 권한이 필요해요 (설정에서 허용)"))
            }
        }

        // 2) 애플 캘린더 미러링 (선택)
        if settings.mirrorToCalendar {
            let calGranted = await CalendarService.requestAccess()
            if calGranted {
                do {
                    let result = try CalendarService.addEvents(savedEvents)
                    var msg = String(localized: "캘린더 \(result.added)개 추가")
                    if result.skipped > 0 { msg += String(localized: " (중복 \(result.skipped)개 제외)") }
                    if result.removed > 0 { msg += String(localized: " · 쌓여 있던 중복 \(result.removed)개 정리") }
                    messages.append(msg)
                } catch {
                    messages.append(String(localized: "캘린더 추가 실패"))
                    errorMessage = error.localizedDescription
                }
            } else {
                messages.append(String(localized: "캘린더 권한이 필요해요"))
            }
        }

        resultMessage = messages.joined(separator: " · ")
        withAnimation { savedBanner = true }
    }

    /// `candidates` 중 `existing`이나 앞선 후보와 중복(`ScannedEvent.isDuplicate`)이 아닌 것만.
    private func newEvents(_ candidates: [ScannedEvent], excluding existing: [ScannedEvent]) -> [ScannedEvent] {
        var kept = existing
        var fresh: [ScannedEvent] = []
        for event in candidates where !kept.contains(where: { $0.isDuplicate(of: event) }) {
            kept.append(event)
            fresh.append(event)
        }
        return fresh
    }

    /// 아이 삭제 확정 시 연쇄 정리: 그 아이의 일정·프로필 사진 삭제 + 알림 재예약.
    private func deleteChild(_ name: String) {
        savedEvents.removeAll { $0.childName == name }
        EventStore.save(savedEvents)
        scannedAll.removeAll { $0.childName == name }
        scanned.removeAll { $0.childName == name }
        ChildAvatarStore.delete(for: name)
        if selectedChild == name {
            selectedChild = registeredChildren.first ?? ""
        }
        Task {
            if await NotificationManager.authorizationStatus() == .authorized {
                await NotificationManager.schedule(for: savedEvents, settings: settings)
            }
        }
    }

    #if DEBUG
    /// 스토어 스크린샷용 예시 화면 (실행 인자 -demoScreen)
    private func applyScreenshotDemo() {
        guard ScreenshotDemo.isOn else { return }
        switch ScreenshotDemo.screen {
        case "scan", "events":
            selectedTab = 0
            suppressRestamp = true
            selectedChild = registeredChildren.first ?? ""
            if let image = ScreenshotDemo.noticeImage() { scannedImages = [image] }
            scannedAll = ScreenshotDemo.scannedEvents()
            scanned = scannedAll
        case "settings":
            selectedTab = 1
            showSettings = true
        default:
            selectedTab = 1
        }
    }
    #endif

    /// 선택된 아이의 반에 맞게 추출 목록 필터 (다른 반 전용 견학 등 제외).
    /// 아이가 1명이라 선택 UI가 없는 경우에도 첫 아이의 반으로 필터.
    private func refreshScanned() {
        let effectiveChild = selectedChild.isEmpty
            ? (registeredChildren.first ?? "")
            : selectedChild
        let className = settings.className(for: effectiveChild)
        scanned = className.isEmpty
            ? scannedAll
            : EventParser.filterForClass(scannedAll, className: className)
    }
}

// MARK: - 일정 행

private struct EventRow: View {
    @Binding var event: ScannedEvent
    let children: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // 아이 변경 메뉴 (아바타 탭)
                if !children.isEmpty {
                    Menu {
                        Picker("아이", selection: $event.childName) {
                            ForEach(children, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            Text("공통").tag("")
                        }
                    } label: {
                        ChildAvatarView(name: event.childName.isEmpty ? nil : event.childName,
                                        children: children, size: 30, isSelected: false)
                    }
                    .accessibilityLabel(Text("아이"))
                    .accessibilityValue(event.childName.isEmpty ? Text("공통") : Text(verbatim: event.childName))
                }
                TextField("제목", text: $event.title)
                    .font(.headline)
            }

            Toggle(isOn: $event.isAllDay) {
                Text("종일")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .fixedSize()

            DatePicker(
                "일시",
                selection: $event.date,
                displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
                .font(.caption)

            TextField("준비물·메모 (예: 도시락 지참)", text: $event.notes, axis: .vertical)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1...3)

            if !event.rawText.isEmpty {
                Text(event.rawText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 문자 붙여넣기

/// 어린이집 문자·카카오톡 메시지를 붙여넣어 일정으로 추출하는 시트.
struct PasteTextView: View {
    var onExtract: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .font(.body)
                .padding(.horizontal, 12)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("여기에 어린이집 문자·카카오톡 메시지를 붙여넣으세요.\n예) 내일은 비가 예정된 만큼 장화, 우의, 우산에 이름을 적어 보내주세요.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
                .navigationTitle("문자로 일정 추가")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Label("취소", systemImage: "xmark") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            let captured = text
                            dismiss()
                            onExtract(captured)
                        } label: {
                            Label("일정 추출", systemImage: "text.viewfinder")
                        }
                        .fontWeight(.semibold)
                        .disabled(isEmpty)
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Button {
                            if let clip = UIPasteboard.general.string { text = clip }
                        } label: {
                            Label("클립보드에서 붙여넣기", systemImage: "doc.on.clipboard")
                        }
                        .disabled(!UIPasteboard.general.hasStrings)
                        Spacer()
                        Button("지우기") { text = "" }
                            .disabled(text.isEmpty)
                    }
                }
                .onAppear { focused = true }
        }
    }
}

// MARK: - 카메라 래퍼

struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

#Preview {
    ContentView()
}

#if DEBUG
// MARK: - 스토어 스크린샷용 예시 화면 (DEBUG 빌드 전용 · 출시 빌드에는 들어가지 않는다)
//
// 실행 인자: -demoLang <언어> -demoScreen scan|events|calendar|settings
// 가상의 두 아이 이름·반·일정을 그 언어로 채우고, 알림장 사진 대신 그 언어로 그린 안내문을 보여 준다.
enum ScreenshotDemo {
    static var language: String? { UserDefaults.standard.string(forKey: "demoLang") }
    static var screen: String? { UserDefaults.standard.string(forKey: "demoScreen") }
    static var isOn: Bool { language != nil && screen != nil }

    struct Content {
        var children: (String, String)
        var classes: (String, String)
        var nursery: String
        /// {M} = 그 언어의 달 이름(LLLL)
        var noticeTitle: String
        /// 안내문 네 줄: 11/5 종일 · 11/12 10시 · 11/18 종일 · 11/26 15시
        var notice: [String]
        var footnote: String
        var todayTitle: String
        var todayNotes: String
        var recurringTitle: String
        var others: [String]
    }

    static let contents: [String: Content] = [
        "ko": .init(children: ("지호", "서아"), classes: ("햇살", "무지개"), nursery: "해바라기 어린이집",
                    noticeTitle: "햇살반 {M} 행사 안내",
                    notice: ["가을 운동회 (도시락, 운동화)", "인형극 관람", "김장 체험 (앞치마 지참)", "생일잔치"],
                    footnote: "가정에서도 아이와 함께 일정을 확인해 주세요.",
                    todayTitle: "숲 체험", todayNotes: "편한 운동화, 물병", recurringTitle: "영어 특별활동",
                    others: ["도서관 가는 날", "수영", "건강검진", "현장학습", "음악 수업", "부모 상담"]),
        "en": .init(children: ("Liam", "Emma"), classes: ("Sunflowers", "Rainbows"), nursery: "Little Acorns Daycare",
                    noticeTitle: "Sunflower Class · {M} Events",
                    notice: ["Fall sports day (lunch, sneakers)", "Puppet show", "Cookie baking (bring an apron)", "Birthday party"],
                    footnote: "Please go over the schedule with your child at home.",
                    todayTitle: "Nature walk", todayNotes: "comfy sneakers, water bottle", recurringTitle: "Spanish club",
                    others: ["Library day", "Swimming", "Picture day", "Field trip", "Music class", "Parent meeting"]),
        "en-GB": .init(children: ("Oliver", "Amelia"), classes: ("Sunflowers", "Rainbows"), nursery: "Little Acorns Nursery",
                    noticeTitle: "Sunflower Class · {M} Events",
                    notice: ["Autumn sports day (packed lunch, trainers)", "Puppet show", "Biscuit baking (bring an apron)", "Birthday party"],
                    footnote: "Please go through the schedule with your child at home.",
                    todayTitle: "Forest school walk", todayNotes: "wellies, water bottle", recurringTitle: "French club",
                    others: ["Library day", "Swimming", "School photos", "Farm visit", "Music class", "Parents’ evening"]),
        "zh-Hans": .init(children: ("小宇", "朵朵"), classes: ("向日葵", "彩虹"), nursery: "阳光幼儿园",
                    noticeTitle: "向日葵班 {M}活动安排",
                    notice: ["秋季运动会（带午餐、运动鞋）", "观看木偶剧", "烘焙体验（带围裙）", "生日会"],
                    footnote: "请在家中和孩子一起确认日程。",
                    todayTitle: "森林探索", todayNotes: "舒适运动鞋、水壶", recurringTitle: "英语兴趣班",
                    others: ["图书日", "游泳课", "体检", "郊游", "音乐课", "家长会"]),
        "zh-Hant": .init(children: ("小宇", "朵朵"), classes: ("向日葵", "彩虹"), nursery: "陽光幼兒園",
                    noticeTitle: "向日葵班 {M}活動安排",
                    notice: ["秋季運動會（帶午餐、運動鞋）", "觀賞布偶劇", "烘焙體驗（帶圍裙）", "慶生會"],
                    footnote: "請在家中和孩子一起確認行程。",
                    todayTitle: "森林探索", todayNotes: "舒適運動鞋、水壺", recurringTitle: "英語才藝課",
                    others: ["圖書日", "游泳課", "健康檢查", "戶外教學", "音樂課", "親師座談會"]),
        "ja": .init(children: ("はると", "ゆい"), classes: ("ひまわり", "にじ"), nursery: "たんぽぽ保育園",
                    noticeTitle: "ひまわり組 {M}の行事予定",
                    notice: ["秋の運動会（お弁当・運動靴）", "人形劇鑑賞", "クッキー作り（エプロン持参）", "お誕生日会"],
                    footnote: "ご家庭でもお子さまと予定をご確認ください。",
                    todayTitle: "森のおさんぽ", todayNotes: "運動靴・水筒", recurringTitle: "英語あそび",
                    others: ["絵本の日", "プール", "健康診断", "遠足", "リトミック", "保護者会"]),
        "ru": .init(children: ("Миша", "Аня"), classes: ("Солнышко", "Радуга"), nursery: "Детский сад «Ромашка»",
                    noticeTitle: "Группа «Солнышко»: план на {M}",
                    notice: ["Осенний спортивный праздник (обед, кроссовки)", "Кукольный театр", "Печём печенье (взять фартук)", "День рождения"],
                    footnote: "Пожалуйста, обсудите расписание с ребёнком дома.",
                    todayTitle: "Прогулка в лесу", todayNotes: "удобная обувь, бутылка воды", recurringTitle: "Английский кружок",
                    others: ["День библиотеки", "Бассейн", "Медосмотр", "Экскурсия", "Музыкальное занятие", "Родительское собрание"]),
        "es": .init(children: ("Mateo", "Lucía"), classes: ("Girasoles", "Arcoíris"), nursery: "Escuela Infantil Los Pinos",
                    noticeTitle: "Clase Girasoles · Actividades de {M}",
                    notice: ["Fiesta deportiva de otoño (almuerzo, zapatillas)", "Teatro de títeres", "Taller de galletas (traer delantal)", "Fiesta de cumpleaños"],
                    footnote: "Repasad el calendario con vuestro peque en casa.",
                    todayTitle: "Paseo por el bosque", todayNotes: "zapatillas cómodas, botella de agua", recurringTitle: "Inglés extraescolar",
                    others: ["Día de la biblioteca", "Natación", "Revisión médica", "Excursión", "Música", "Reunión de familias"]),
        "de": .init(children: ("Paul", "Mia"), classes: ("Sonnenblumen", "Regenbogen"), nursery: "Kita Kleine Strolche",
                    noticeTitle: "Sonnenblumen-Gruppe · Termine im {M}",
                    notice: ["Herbstsportfest (Brotdose, Turnschuhe)", "Puppentheater", "Plätzchen backen (Schürze mitbringen)", "Geburtstagsfeier"],
                    footnote: "Bitte besprechen Sie die Termine zu Hause mit Ihrem Kind.",
                    todayTitle: "Waldtag", todayNotes: "feste Schuhe, Trinkflasche", recurringTitle: "Englisch-AG",
                    others: ["Büchereitag", "Schwimmen", "Vorsorgeuntersuchung", "Ausflug", "Musikstunde", "Elternabend"]),
        "fr": .init(children: ("Léo", "Jade"), classes: ("Tournesols", "Arc-en-ciel"), nursery: "Crèche Les Petits Loups",
                    noticeTitle: "Section des Tournesols · Programme de {M}",
                    notice: ["Fête du sport d’automne (pique-nique, baskets)", "Spectacle de marionnettes", "Atelier biscuits (apporter un tablier)", "Fête des anniversaires"],
                    footnote: "Merci de consulter le programme avec votre enfant à la maison.",
                    todayTitle: "Balade en forêt", todayNotes: "baskets confortables, gourde", recurringTitle: "Éveil à l’anglais",
                    others: ["Journée bibliothèque", "Piscine", "Visite médicale", "Sortie scolaire", "Éveil musical", "Réunion des parents"]),
        "it": .init(children: ("Leonardo", "Sofia"), classes: ("Girasoli", "Arcobaleno"), nursery: "Asilo Nido Il Girotondo",
                    noticeTitle: "Sezione Girasoli · Appuntamenti di {M}",
                    notice: ["Festa dello sport (pranzo al sacco, scarpe da ginnastica)", "Spettacolo di burattini", "Laboratorio di biscotti (portare il grembiule)", "Festa di compleanno"],
                    footnote: "Vi preghiamo di rivedere il calendario a casa con il vostro bambino.",
                    todayTitle: "Passeggiata nel bosco", todayNotes: "scarpe comode, borraccia", recurringTitle: "Inglese",
                    others: ["Giornata in biblioteca", "Piscina", "Visita pediatrica", "Gita", "Musica", "Colloqui con i genitori"]),
        "pt-BR": .init(children: ("Miguel", "Helena"), classes: ("Girassol", "Arco-íris"), nursery: "Escolinha Pequeno Príncipe",
                    noticeTitle: "Turma Girassol · Agenda de {M}",
                    notice: ["Gincana da primavera (lanche, tênis)", "Teatro de fantoches", "Oficina de biscoitos (levar avental)", "Festa de aniversário"],
                    footnote: "Confira a agenda com seu filho em casa.",
                    todayTitle: "Passeio no bosque", todayNotes: "tênis confortável, garrafinha de água", recurringTitle: "Aula de inglês",
                    others: ["Dia da biblioteca", "Natação", "Consulta médica", "Passeio escolar", "Musicalização", "Reunião de pais"]),
        "th": .init(children: ("ภูมิ", "มะปราง"), classes: ("ทานตะวัน", "สายรุ้ง"), nursery: "โรงเรียนอนุบาลบ้านรัก",
                    noticeTitle: "ห้องทานตะวัน · กิจกรรมเดือน{M}",
                    notice: ["กีฬาสีประจำปี (ข้าวกล่อง รองเท้าผ้าใบ)", "ชมละครหุ่น", "ทำคุกกี้ (นำผ้ากันเปื้อนมา)", "งานวันเกิด"],
                    footnote: "ผู้ปกครองโปรดทบทวนตารางกิจกรรมกับบุตรหลานที่บ้าน",
                    todayTitle: "เดินชมธรรมชาติ", todayNotes: "รองเท้าผ้าใบ ขวดน้ำ", recurringTitle: "ชมรมภาษาอังกฤษ",
                    others: ["วันห้องสมุด", "ว่ายน้ำ", "ตรวจสุขภาพ", "ทัศนศึกษา", "ดนตรี", "ประชุมผู้ปกครอง"]),
        "vi": .init(children: ("Bin", "Na"), classes: ("Hướng Dương", "Cầu Vồng"), nursery: "Trường Mầm non Hoa Sen",
                    noticeTitle: "Lớp Hướng Dương · Lịch hoạt động {M}",
                    notice: ["Hội thao mùa thu (cơm hộp, giày thể thao)", "Xem múa rối", "Làm bánh quy (mang tạp dề)", "Tiệc sinh nhật"],
                    footnote: "Phụ huynh vui lòng cùng bé xem lại lịch ở nhà.",
                    todayTitle: "Dạo chơi trong rừng", todayNotes: "giày thoải mái, bình nước", recurringTitle: "Câu lạc bộ tiếng Anh",
                    others: ["Ngày thư viện", "Bơi lội", "Khám sức khỏe", "Dã ngoại", "Âm nhạc", "Họp phụ huynh"]),
        "cs": .init(children: ("Jakub", "Ema"), classes: ("Slunečnice", "Duha"), nursery: "Mateřská škola Sluníčko",
                    noticeTitle: "Třída Slunečnice · Plán na {M}",
                    notice: ["Podzimní sportovní den (svačina, tenisky)", "Loutkové divadlo", "Pečení sušenek (s sebou zástěru)", "Oslava narozenin"],
                    footnote: "Projděte si prosím plán doma s dítětem.",
                    todayTitle: "Vycházka do lesa", todayNotes: "pohodlné boty, láhev s vodou", recurringTitle: "Angličtina",
                    others: ["Den v knihovně", "Plavání", "Prohlídka u lékaře", "Výlet", "Hudební výchova", "Třídní schůzka"]),
        "da": .init(children: ("William", "Ida"), classes: ("Solsikkerne", "Regnbuen"), nursery: "Børnehaven Mælkebøtten",
                    noticeTitle: "Solsikkestuen · Plan for {M}",
                    notice: ["Efterårets idrætsdag (madpakke, kondisko)", "Dukketeater", "Vi bager småkager (medbring forklæde)", "Fødselsdagsfest"],
                    footnote: "Gennemgå gerne planen med dit barn derhjemme.",
                    todayTitle: "Tur i skoven", todayNotes: "gode sko, drikkedunk", recurringTitle: "Engelsk",
                    others: ["Biblioteksdag", "Svømning", "Sundhedstjek", "Udflugt", "Musik", "Forældremøde"]),
        "el": .init(children: ("Γιώργος", "Μαρία"), classes: ("Ηλιοτρόπια", "Ουράνιο Τόξο"), nursery: "Παιδικός Σταθμός «Τα Χαμόγελα»",
                    noticeTitle: "Τμήμα Ηλιοτρόπια · Πρόγραμμα: {M}",
                    notice: ["Φθινοπωρινή γιορτή αθλητισμού (φαγητό, αθλητικά)", "Κουκλοθέατρο", "Φτιάχνουμε μπισκότα (φέρτε ποδιά)", "Πάρτι γενεθλίων"],
                    footnote: "Παρακαλούμε δείτε το πρόγραμμα μαζί με το παιδί σας στο σπίτι.",
                    todayTitle: "Βόλτα στο δάσος", todayNotes: "άνετα παπούτσια, μπουκάλι νερό", recurringTitle: "Αγγλικά",
                    others: ["Ημέρα βιβλιοθήκης", "Κολύμβηση", "Ιατρικός έλεγχος", "Εκδρομή", "Μουσική", "Συνάντηση γονέων"]),
        "fi": .init(children: ("Eino", "Aino"), classes: ("Auringonkukat", "Sateenkaaret"), nursery: "Päiväkoti Satakieli",
                    noticeTitle: "Auringonkukat · Tapahtumat: {M}",
                    notice: ["Syysliikuntapäivä (eväät, lenkkarit)", "Nukketeatteri", "Pipareiden leivonta (ota esiliina)", "Synttärijuhlat"],
                    footnote: "Käykää aikataulu läpi kotona yhdessä lapsen kanssa.",
                    todayTitle: "Metsäretki", todayNotes: "hyvät kengät, juomapullo", recurringTitle: "Englannin kerho",
                    others: ["Kirjastopäivä", "Uinti", "Terveystarkastus", "Retki", "Musiikkihetki", "Vanhempainilta"]),
        "id": .init(children: ("Raka", "Kirana"), classes: ("Matahari", "Pelangi"), nursery: "TK Ceria",
                    noticeTitle: "Kelas Matahari · Agenda {M}",
                    notice: ["Lomba olahraga (bekal, sepatu olahraga)", "Pertunjukan boneka", "Membuat kue (bawa celemek)", "Pesta ulang tahun"],
                    footnote: "Mohon tinjau jadwal ini bersama anak di rumah.",
                    todayTitle: "Jalan-jalan ke hutan", todayNotes: "sepatu nyaman, botol minum", recurringTitle: "Klub bahasa Inggris",
                    others: ["Hari perpustakaan", "Berenang", "Pemeriksaan kesehatan", "Karyawisata", "Kelas musik", "Pertemuan orang tua"]),
        "nb": .init(children: ("Jakob", "Nora"), classes: ("Solsikkene", "Regnbuen"), nursery: "Barnehagen Løvetann",
                    noticeTitle: "Solsikkene · Plan for {M}",
                    notice: ["Høstidrettsdag (matpakke, joggesko)", "Dukketeater", "Vi baker kjeks (ta med forkle)", "Bursdagsfeiring"],
                    footnote: "Gå gjerne gjennom planen sammen med barnet hjemme.",
                    todayTitle: "Tur i skogen", todayNotes: "gode sko, drikkeflaske", recurringTitle: "Engelsk",
                    others: ["Biblioteksdag", "Svømming", "Helsekontroll", "Utflukt", "Musikk", "Foreldremøte"]),
        "nl": .init(children: ("Daan", "Julia"), classes: ("Zonnebloemen", "Regenboog"), nursery: "Kinderopvang De Speeltuin",
                    noticeTitle: "Groep Zonnebloem · Planning {M}",
                    notice: ["Herfstsportdag (lunchpakket, gymschoenen)", "Poppenkast", "Koekjes bakken (schort meenemen)", "Verjaardagsfeest"],
                    footnote: "Neem de planning thuis samen met uw kind door.",
                    todayTitle: "Boswandeling", todayNotes: "stevige schoenen, drinkfles", recurringTitle: "Engelse les",
                    others: ["Bibliotheekdag", "Zwemmen", "Consultatiebureau", "Uitstapje", "Muziekles", "Ouderavond"]),
        "pl": .init(children: ("Antek", "Zosia"), classes: ("Słoneczniki", "Tęcza"), nursery: "Przedszkole Słoneczko",
                    noticeTitle: "Grupa Słoneczniki · Plan na {M}",
                    notice: ["Jesienny dzień sportu (drugie śniadanie, trampki)", "Teatrzyk kukiełkowy", "Pieczenie ciasteczek (fartuszek)", "Urodziny w grupie"],
                    footnote: "Prosimy przejrzeć plan razem z dzieckiem w domu.",
                    todayTitle: "Spacer do lasu", todayNotes: "wygodne buty, bidon", recurringTitle: "Zajęcia z angielskiego",
                    others: ["Dzień w bibliotece", "Basen", "Bilans zdrowia", "Wycieczka", "Rytmika", "Zebranie z rodzicami"]),
        "sv": .init(children: ("Elias", "Alice"), classes: ("Solrosen", "Regnbågen"), nursery: "Förskolan Smultronstället",
                    noticeTitle: "Avdelning Solrosen · Planering för {M}",
                    notice: ["Höstens idrottsdag (matsäck, gympaskor)", "Dockteater", "Vi bakar kakor (ta med förkläde)", "Kalas"],
                    footnote: "Gå gärna igenom planeringen med ditt barn hemma.",
                    todayTitle: "Skogsutflykt", todayNotes: "bra skor, vattenflaska", recurringTitle: "Engelska",
                    others: ["Biblioteksdag", "Simning", "Hälsokontroll", "Utflykt", "Musik", "Föräldramöte"]),
        "tr": .init(children: ("Ege", "Elif"), classes: ("Ayçiçeği", "Gökkuşağı"), nursery: "Neşeli Adımlar Anaokulu",
                    noticeTitle: "Ayçiçeği Sınıfı · {M} Etkinlikleri",
                    notice: ["Sonbahar spor şenliği (beslenme, spor ayakkabı)", "Kukla gösterisi", "Kurabiye atölyesi (önlük getirin)", "Doğum günü kutlaması"],
                    footnote: "Lütfen programı evde çocuğunuzla birlikte gözden geçirin.",
                    todayTitle: "Orman yürüyüşü", todayNotes: "rahat ayakkabı, su matarası", recurringTitle: "İngilizce kulübü",
                    others: ["Kütüphane günü", "Yüzme", "Sağlık taraması", "Gezi", "Müzik", "Veli toplantısı"]),
    ]

    static var content: Content? { language.flatMap { contents[$0] } }

    private static var cal: Calendar { .current }

    /// 다음 달 n일 (hour 가 있으면 그 시각)
    private static func nextMonth(_ day: Int, hour: Int? = nil) -> Date {
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let next = cal.date(byAdding: .month, value: 1, to: start)!
        var c = cal.dateComponents([.year, .month], from: next)
        c.day = day; c.hour = hour ?? 0
        return cal.date(from: c)!
    }

    private static func thisMonth(_ day: Int, hour: Int? = nil) -> Date {
        var c = cal.dateComponents([.year, .month], from: Date())
        c.day = day; c.hour = hour ?? 0
        return cal.date(from: c)!
    }

    /// 앱 실행 직후, 화면이 저장소를 읽기 전에 부른다.
    static func seedIfRequested() {
        guard isOn, let c = content else { return }
        var settings = ReminderSettings()
        settings.childNames = [c.children.0, c.children.1]
        settings.childClasses = [c.children.0: c.classes.0, c.children.1: c.classes.1]
        settings.mirrorToCalendar = false
        ReminderSettingsStore.save(settings)

        let today = cal.component(.day, from: Date())
        let lastDay = cal.range(of: .day, in: .month, for: Date())!.count
        var events: [ScannedEvent] = [
            ScannedEvent(title: c.todayTitle, date: thisMonth(today), isAllDay: true, notes: c.todayNotes,
                         childName: c.children.0, rawText: c.todayTitle),
            ScannedEvent(title: c.recurringTitle, date: thisMonth(today, hour: 11), childName: c.children.1,
                         isRecurring: true, rawText: c.recurringTitle),
        ]
        // 달 전체에 고르게 흩는다 (오늘 뺀 날)
        let days = [1, 2, 7, 9, 14, 15, 16, 21, 22, 27, 29, 30].filter { $0 != today && $0 <= lastDay }
        for (i, day) in days.enumerated() {
            let child = i % 2 == 0 ? c.children.0 : c.children.1
            let title = c.others[i % c.others.count]
            events.append(ScannedEvent(title: title, date: thisMonth(day), isAllDay: true,
                                       childName: child, rawText: title))
        }
        EventStore.save(events)
    }

    /// 스캔 탭에 띄울 안내문 일정
    static func scannedEvents() -> [ScannedEvent] {
        guard let c = content else { return [] }
        let specs: [(Int, Int?)] = [(5, nil), (12, 10), (18, nil), (26, 15)]
        return zip(c.notice, specs).map { title, spec in
            ScannedEvent(title: title, date: nextMonth(spec.0, hour: spec.1), isAllDay: spec.1 == nil,
                         childName: c.children.0, rawText: line(title, spec.0, spec.1))
        }
    }

    private static func line(_ title: String, _ day: Int, _ hour: Int?) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(hour == nil ? "MMMMd" : "MMMMdjmm")
        return "\(f.string(from: nextMonth(day, hour: hour))) \(title)"
    }

    /// 어린이집에서 받은 안내문 사진 대신, 그 언어로 쓴 안내문을 그린다.
    @MainActor static func noticeImage() -> UIImage? {
        guard let c = content else { return nil }
        let monthName: String = {
            let f = DateFormatter(); f.locale = .current; f.dateFormat = "LLLL"
            return f.string(from: nextMonth(1))
        }()
        let specs: [(Int, Int?)] = [(5, nil), (12, 10), (18, nil), (26, 15)]
        let lines = zip(c.notice, specs).map { line($0, $1.0, $1.1) }
        let view = ZStack {
            Color(red: 0.80, green: 0.77, blue: 0.71)
            VStack(alignment: .leading, spacing: 14) {
                Text(c.noticeTitle.replacingOccurrences(of: "{M}", with: monthName))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(red: 0.2, green: 0.4, blue: 0.2))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Text(c.nursery)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 14)
                ForEach(lines, id: \.self) { l in
                    Text(l).font(.system(size: 15)).foregroundStyle(.black.opacity(0.85))
                }
                Spacer().frame(height: 24)
                Text(c.footnote).font(.system(size: 11)).foregroundStyle(.black.opacity(0.55))
                Spacer()
            }
            .padding(28)
            .frame(width: 400, height: 560)
            .background(Color(red: 0.99, green: 0.98, blue: 0.95))
            .shadow(color: .black.opacity(0.25), radius: 8, x: 2, y: 4)
            .rotationEffect(.degrees(-1.2))
        }
        .frame(width: 520, height: 680)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return renderer.uiImage
    }
}
#endif
