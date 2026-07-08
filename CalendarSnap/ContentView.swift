import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var pickedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var events: [ScannedEvent] = EventStore.load()
    @State private var isProcessing = false
    @State private var showCamera = false
    @State private var errorMessage: String?
    @State private var savedBanner = false

    var body: some View {
        NavigationStack {
            List {
                imageSection
                eventsSection
            }
            .navigationTitle("CalendarSnap")
            .toolbar { toolbarContent }
            .overlay { if isProcessing { processingOverlay } }
            .alert("오류", isPresented: .constant(errorMessage != nil)) {
                Button("확인") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { captured in
                    image = captured
                    Task { await runOCR(on: captured) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        image = uiImage
                        await runOCR(on: uiImage)
                    }
                }
            }
        }
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
                    "달력을 찍어보세요",
                    systemImage: "calendar.badge.plus",
                    description: Text("사진 속 일정을 자동으로 추출해\n위젯과 알림으로 보여드립니다."))
            }
        }
    }

    @ViewBuilder
    private var eventsSection: some View {
        if !events.isEmpty {
            Section("추출된 일정 \(events.count)개") {
                ForEach($events) { $event in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("제목", text: $event.title)
                            .font(.headline)
                        DatePicker("일시", selection: $event.date)
                            .font(.caption)
                        Text(event.rawText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { events.remove(atOffsets: $0) }
            }

            Section {
                Button {
                    Task { await saveAndNotify() }
                } label: {
                    Label(savedBanner ? "저장 완료! 위젯을 확인하세요" : "위젯에 저장 + 알림 등록",
                          systemImage: savedBanner ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 4)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showCamera = true
            } label: {
                Image(systemName: "camera")
            }
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Image(systemName: "photo.on.rectangle")
            }
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("일정 분석 중…")
                    .font(.callout)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Actions

    private func runOCR(on image: UIImage) async {
        isProcessing = true
        savedBanner = false
        defer { isProcessing = false }
        do {
            let lines = try await OCRService.recognizeText(in: image)
            let parsed = EventParser.parse(lines: lines)
            if parsed.isEmpty {
                errorMessage = "일정으로 인식할 텍스트를 찾지 못했습니다.\n달력 글씨가 선명하게 나오도록 다시 찍어보세요."
            } else {
                events = parsed
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveAndNotify() async {
        EventStore.save(events)
        let granted = await NotificationManager.requestAuthorization()
        if granted {
            await NotificationManager.schedule(for: events)
        }
        withAnimation { savedBanner = true }
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
