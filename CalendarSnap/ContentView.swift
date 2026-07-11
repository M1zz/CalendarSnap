import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var image: UIImage?
    /// 저장된 일정 (달력 탭·위젯·공유의 원본)
    @State private var savedEvents: [ScannedEvent] = EventStore.load()
    /// 이번에 추가한 사진에서 추출된 일정 원본 (반 필터 적용 전)
    @State private var scannedAll: [ScannedEvent] = []
    /// 스캔 탭에 표시되는 일정 (아이 반에 맞게 필터됨 — 저장하면 비워짐)
    @State private var scanned: [ScannedEvent] = []
    @State private var settings: ReminderSettings = ReminderSettingsStore.load()
    @State private var isProcessing = false
    @State private var showCamera = false
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

    var body: some View {
        TabView(selection: $selectedTab) {
            scanTab
                .tabItem { Label("스캔", systemImage: "camera.viewfinder") }
                .tag(0)

            calendarTab
                .tabItem { Label("달력", systemImage: "calendar") }
                .tag(1)
        }
        // 다른 사용자가 보낸 .aischedule 파일을 열면 일정을 채워줌
        .onOpenURL { url in
            handleIncomingFile(url)
        }
        // 설정 시트와 오류 알림은 어느 탭에서든 열리도록 탭 공통 레벨에 부착
        .sheet(isPresented: $showSettings, onDismiss: {
            settings.childNames = settings.childNames
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            ReminderSettingsStore.save(settings)
            adoptOrphanEventsIfPossible()
            refreshScanned()   // 반이 바뀌었을 수 있으니 필터 재적용
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
            let existingKeys = Set(savedEvents.map(dedupKey))
            let fresh = package.events.filter { !existingKeys.contains(dedupKey($0)) }
            savedEvents = (savedEvents + fresh).sorted { $0.date < $1.date }
            EventStore.save(savedEvents)

            selectedTab = 1
            let skipped = package.events.count - fresh.count
            importMessage = "일정 \(fresh.count)개를 가져왔어요."
                + (skipped > 0 ? " (이미 있는 \(skipped)개 제외)" : "")

            // 알림 권한이 이미 있으면 가져온 일정까지 포함해 재예약
            Task {
                if await NotificationManager.authorizationStatus() == .authorized {
                    await NotificationManager.schedule(for: savedEvents, settings: settings)
                }
            }
        } catch {
            errorMessage = "일정 데이터를 가져오지 못했습니다.\n아이일정 앱에서 내보낸 파일인지 확인해주세요."
        }
    }

    // MARK: - 탭

    private var scanTab: some View {
        NavigationStack {
            List {
                childPickerSection
                imageSection
                eventsSection
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
                    image = captured
                    Task { await runOCR(on: captured) }
                }
                .ignoresSafeArea()
            }
            // 위에서 아이를 바꾸면 추출된 일정 전체를 그 아이로 재배정하고 반 필터도 다시 적용
            .onChange(of: selectedChild) { _, newChild in
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
                            image = uiImage
                            added += await runOCR(on: uiImage)
                        }
                    }
                    pickedItems = []
                    if added == 0 {
                        errorMessage = "일정으로 인식할 텍스트를 찾지 못했습니다.\n글씨가 선명하게 나오도록 다시 찍어보세요."
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
                    ToolbarItem(placement: .topBarLeading) {
                        shareMenu
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        }
    }

    /// 배우자·가족에게 일정 공유: 아이일정 데이터 / 캘린더 파일(.ics) / 텍스트 요약.
    private var shareMenu: some View {
        Menu {
            ShareLink(item: ScheduleDataFile(events: savedEvents, children: settings.childNames),
                      preview: SharePreview("아이일정 데이터", image: Image(systemName: "square.and.arrow.down.on.square"))) {
                Label("아이일정 사용자에게 보내기", systemImage: "person.crop.circle.badge.plus")
            }
            ShareLink(item: EventICSFile(events: savedEvents),
                      preview: SharePreview("아이일정 캘린더", image: Image(systemName: "calendar"))) {
                Label("캘린더 파일로 공유 (.ics)", systemImage: "calendar.badge.plus")
            }
            ShareLink(item: EventSharing.textSummary(for: savedEvents)) {
                Label("텍스트로 공유", systemImage: "text.bubble")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(savedEvents.isEmpty)
    }

    // MARK: - Sections

    @ViewBuilder
    private var imageSection: some View {
        Section {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ContentUnavailableView(
                    "어린이집 알림장을 찍어보세요",
                    systemImage: "calendar.badge.plus",
                    description: Text("한 달 일정을 자동으로 추출해\n캘린더에 한 번에 추가하고 알림을 보내드려요."))
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
                    Text(savedBanner ? "저장 완료! 달력·위젯에서 확인하세요"
                         : "일정 \(scanned.count)개 저장 + 알림 받기")
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
    }

    private var reminderSummaryText: String {
        let selected = ReminderOption.allCases.filter { settings.options.contains($0) }
        let times = selected.isEmpty ? "알림 없음" : selected.map(\.title).joined(separator: ", ")
        let cal = settings.mirrorToCalendar ? " · 캘린더에도 추가" : ""
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
            if !scanned.isEmpty {
                Button(role: .destructive) {
                    scannedAll = []
                    scanned = []
                    image = nil
                    resultMessage = nil
                    savedBanner = false
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showCamera = true
            } label: {
                Image(systemName: "camera")
            }
            // 통신문·달력 여러 장을 한 번에 선택 가능
            PhotosPicker(selection: $pickedItems, maxSelectionCount: 10, matching: .images) {
                Image(systemName: "photo.on.rectangle")
            }
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

            // 선택된 아이(미선택이면 첫 아이)로 표시 후 이번 스캔 목록에 누적
            // (이미 저장돼 있거나 이번 스캔에 있는 일정은 중복 제외)
            let assignChild = selectedChild.isEmpty ? (registeredChildren.first ?? "") : selectedChild
            let stamped = parsed.map { event in
                var e = event
                if e.childName.isEmpty { e.childName = assignChild }
                return e
            }
            let existingKeys = Set((savedEvents + scannedAll).map(dedupKey))
            let fresh = stamped.filter { !existingKeys.contains(dedupKey($0)) }
            scannedAll = (scannedAll + fresh).sorted { $0.date < $1.date }
            refreshScanned()
            return fresh.count
        } catch {
            errorMessage = error.localizedDescription
            return 0
        }
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
        let existingKeys = Set(savedEvents.map(dedupKey))
        let fresh = stamped.filter { !existingKeys.contains(dedupKey($0)) }
        savedEvents = (savedEvents + fresh).sorted { $0.date < $1.date }
        EventStore.save(savedEvents)   // 위젯 갱신

        // 스캔 작업 공간 비우기 — 저장된 일정은 달력 탭에서
        scannedAll = []
        scanned = []
        image = nil

        var messages: [String] = []

        // 1) 로컬 알림 — 앱이 직접 알림을 담당
        if settings.options.isEmpty {
            messages.append("알림 시점이 꺼져 있어요")
        } else {
            let granted = await NotificationManager.requestAuthorization()
            if granted {
                let n = await NotificationManager.schedule(for: savedEvents, settings: settings)
                messages.append("알림 \(n)개 예약")
            } else {
                messages.append("알림 권한이 필요해요 (설정에서 허용)")
            }
        }

        // 2) 애플 캘린더 미러링 (선택)
        if settings.mirrorToCalendar {
            let calGranted = await CalendarService.requestAccess()
            if calGranted {
                do {
                    let result = try CalendarService.addEvents(savedEvents)
                    var msg = "캘린더 \(result.added)개 추가"
                    if result.skipped > 0 { msg += " (중복 \(result.skipped)개 제외)" }
                    messages.append(msg)
                } catch {
                    messages.append("캘린더 추가 실패")
                    errorMessage = error.localizedDescription
                }
            } else {
                messages.append("캘린더 권한이 필요해요")
            }
        }

        resultMessage = messages.joined(separator: " · ")
        withAnimation { savedBanner = true }
    }

    private func dedupKey(_ event: ScannedEvent) -> String {
        "\(event.title)|\(event.date.timeIntervalSince1970)|\(event.childName)"
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

    /// 선택된 아이의 반에 맞게 추출 목록 필터 (다른 반 전용 견학 등 제외).
    private func refreshScanned() {
        let className = settings.className(for: selectedChild)
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
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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
