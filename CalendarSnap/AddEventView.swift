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
                if children.isEmpty {
                    // 아이가 아직 없으면 이름부터 물어보고 함께 등록
                    Section {
                        TextField("아이 이름 (예: 지호)", text: $childName)
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text("누구의 일정인가요?")
                    } footer: {
                        Text("아이를 등록하면 일정이 아이별로 관리되고 알림에도 이름이 표시돼요.")
                    }
                } else {
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
                                            childName: childName.trimmingCharacters(in: .whitespaces),
                                            rawText: "직접 추가"))
                        dismiss()
                    }
                    // 제목 필수 + 아이 미등록 상태면 아이 이름도 필수
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                              || (children.isEmpty && childName.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }
}

#Preview {
    AddEventView(children: ["지호", "서연"], initialDate: .now, initialChild: "지호") { _ in }
}
