import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var image: UIImage?
    @State private var events: [ScannedEvent] = EventStore.load()
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
    }

    /// 직접 추가한 일정은 즉시 저장 + 위젯 갱신 + (권한 있으면) 알림 예약.
    private func addManualEvent(_ event: ScannedEvent) {
        events = (events + [event]).sorted { $0.date < $1.date }
        EventStore.save(events)
        Task {
            if await NotificationManager.authorizationStatus() == .authorized {
                await NotificationManager.schedule(for: events, settings: settings)
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
            let existingKeys = Set(events.map(dedupKey))
            let fresh = package.events.filter { !existingKeys.contains(dedupKey($0)) }
            events = (events + fresh).sorted { $0.date < $1.date }
            EventStore.save(events)

            selectedTab = 1
            let skipped = package.events.count - fresh.count
            importMessage = "일정 \(fresh.count)개를 가져왔어요."
                + (skipped > 0 ? " (이미 있는 \(skipped)개 제외)" : "")

            // 알림 권한이 이미 있으면 가져온 일정까지 포함해 재예약
            Task {
                if await NotificationManager.authorizationStatus() == .authorized {
                    await NotificationManager.schedule(for: events, settings: settings)
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
            .navigationTitle("아이일정")
            .toolbar { toolbarContent }
            .overlay { if isProcessing { processingOverlay } }
            .alert("오류", isPresented: .constant(errorMessage != nil)) {
                Button("확인") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showSettings, onDismiss: { ReminderSettingsStore.save(settings) }) {
                SettingsView(settings: $settings)
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { captured in
                    image = captured
                    Task { await runOCR(on: captured) }
                }
                .ignoresSafeArea()
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
            MonthCalendarView(events: events, children: settings.childNames) { date in
                addEventDate = date
                showAddEvent = true
            }
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
            ShareLink(item: ScheduleDataFile(events: events, children: settings.childNames),
                      preview: SharePreview("아이일정 데이터", image: Image(systemName: "square.and.arrow.down.on.square"))) {
                Label("아이일정 사용자에게 보내기", systemImage: "person.crop.circle.badge.plus")
            }
            ShareLink(item: EventICSFile(events: events),
                      preview: SharePreview("아이일정 캘린더", image: Image(systemName: "calendar"))) {
                Label("캘린더 파일로 공유 (.ics)", systemImage: "calendar.badge.plus")
            }
            ShareLink(item: EventSharing.textSummary(for: events)) {
                Label("텍스트로 공유", systemImage: "text.bubble")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(events.isEmpty)
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
        if !events.isEmpty {
            Section {
                ForEach($events) { $event in
                    EventRow(event: $event, children: registeredChildren)
                }
                .onDelete { events.remove(atOffsets: $0) }
            } header: {
                Text("추출된 일정 \(events.count)개")
            } footer: {
                Text("제목·시간·준비물을 확인하고, 동그라미를 눌러 아이를 바꾸거나 필요 없는 일정은 밀어서 삭제하세요.")
            }

            reminderSummarySection
            actionSection
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

    private var actionSection: some View {
        Section {
            Button {
                Task { await addAllEvents() }
            } label: {
                Label(savedBanner ? "추가 완료!" : "일정 추가하고 알림 받기",
                      systemImage: savedBanner ? "checkmark.circle.fill" : "calendar.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets())
            .padding(.vertical, 4)

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
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
            if !events.isEmpty {
                Button(role: .destructive) {
                    events = []
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

            // 선택된 아이로 표시 후 기존 목록에 누적 (중복 제외)
            let stamped = parsed.map { event in
                var e = event
                if e.childName.isEmpty { e.childName = selectedChild }
                return e
            }
            let existingKeys = Set(events.map(dedupKey))
            let fresh = stamped.filter { !existingKeys.contains(dedupKey($0)) }
            events = (events + fresh).sorted { $0.date < $1.date }
            return fresh.count
        } catch {
            errorMessage = error.localizedDescription
            return 0
        }
    }

    /// 위젯 저장 + 로컬 알림 예약 + (옵션) 애플 캘린더 미러링을 한 번에 수행.
    private func addAllEvents() async {
        guard !events.isEmpty else { return }
        isProcessing = true
        savedBanner = false
        defer { isProcessing = false }

        ReminderSettingsStore.save(settings)

        // 아이 미지정 일정은 현재 선택된 아이로 표시
        if !selectedChild.isEmpty {
            events = events.map { event in
                var stamped = event
                if stamped.childName.isEmpty { stamped.childName = selectedChild }
                return stamped
            }
        }
        EventStore.save(events)   // 위젯 갱신

        var messages: [String] = []

        // 1) 로컬 알림 — 앱이 직접 알림을 담당
        if settings.options.isEmpty {
            messages.append("알림 시점이 꺼져 있어요")
        } else {
            let granted = await NotificationManager.requestAuthorization()
            if granted {
                let n = await NotificationManager.schedule(for: events, settings: settings)
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
                    let result = try CalendarService.addEvents(events)
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
