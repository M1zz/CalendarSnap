import SwiftUI

/// 일정 직접 추가 화면. 아이 선택 → 제목 → 일시 → 준비물 순.
struct AddEventView: View {
    let children: [String]
    let onSave: (ScannedEvent) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var childName: String
    @State private var date: Date
    @State private var isAllDay = true
    @State private var notes = ""

    init(children: [String], initialDate: Date, initialChild: String,
         onSave: @escaping (ScannedEvent) -> Void) {
        self.children = children
        self.onSave = onSave
        // 시간 지정으로 바꿀 때 자연스러운 기본값 (오전 9시)
        let base = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: initialDate) ?? initialDate
        _date = State(initialValue: base)
        _childName = State(initialValue: initialChild)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !children.isEmpty {
                    Section("누구의 일정인가요?") {
                        HStack(spacing: 18) {
                            ForEach(children, id: \.self) { name in
                                ChildAvatarButton(name: name, label: name,
                                                  children: children,
                                                  isSelected: childName == name,
                                                  size: 48) {
                                    withAnimation { childName = name }
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("일정") {
                    TextField("제목 (예: 소풍, 준비물의 날)", text: $title)
                    Toggle("종일", isOn: $isAllDay)
                    DatePicker("일시", selection: $date,
                               displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                }

                Section("준비물·메모") {
                    TextField("예: 도시락, 물통 지참", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            .navigationTitle("일정 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") {
                        onSave(ScannedEvent(title: title.trimmingCharacters(in: .whitespaces),
                                            date: date,
                                            isAllDay: isAllDay,
                                            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                                            childName: childName,
                                            rawText: "직접 추가"))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

#Preview {
    AddEventView(children: ["지호", "서연"], initialDate: .now, initialChild: "지호") { _ in }
}
