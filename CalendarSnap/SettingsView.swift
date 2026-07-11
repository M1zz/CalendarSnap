import SwiftUI
import PhotosUI

/// 아이 프로필(이름·사진) · 알림 시점 · 캘린더 미러링 설정 화면.
struct SettingsView: View {
    @Binding var settings: ReminderSettings
    @Environment(\.dismiss) private var dismiss
    @State private var avatarTargetIndex: Int?
    @State private var showAvatarPicker = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarRefresh = 0   // 사진 변경 후 아바타 다시 그리기용

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(settings.childNames.indices, id: \.self) { i in
                        HStack(spacing: 12) {
                            Button {
                                avatarTargetIndex = i
                                showAvatarPicker = true
                            } label: {
                                ChildAvatarView(name: settings.childNames[i],
                                                children: settings.childNames,
                                                size: 40, isSelected: false)
                                    .id(avatarRefresh)
                            }
                            .buttonStyle(.plain)
                            VStack(spacing: 2) {
                                TextField("이름 (예: 지호)", text: $settings.childNames[i])
                                    .textInputAutocapitalization(.never)
                                TextField("반 이름 (예: 무궁화)", text: classBinding(for: i))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textInputAutocapitalization(.never)
                            }
                        }
                    }
                    .onDelete { settings.childNames.remove(atOffsets: $0) }
                    Button {
                        settings.childNames.append("")
                    } label: {
                        Label("아이 추가", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("아이")
                } footer: {
                    Text("동그라미를 누르면 프로필 사진을 넣을 수 있어요. 반을 입력하면 통신문에서 다른 반 전용 일정(견학 등)을 자동으로 걸러줍니다. 새 학년에 반이 바뀌면 여기만 고쳐주세요.")
                }

                Section {
                    ForEach(ReminderOption.allCases) { option in
                        Toggle(isOn: binding(for: option)) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
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
            }
            .navigationTitle("알림 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
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

    private var calendarNamesDescription: String {
        let names = settings.childNames
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return "‘어린이집’" }
        return names.map { "‘\($0) 어린이집’" }.joined(separator: ", ")
    }

    /// i번째 아이의 반 이름 바인딩 (이름 키 기반 저장).
    private func classBinding(for index: Int) -> Binding<String> {
        Binding(
            get: {
                guard settings.childNames.indices.contains(index) else { return "" }
                return settings.childClasses[settings.childNames[index]] ?? ""
            },
            set: { newValue in
                guard settings.childNames.indices.contains(index) else { return }
                settings.childClasses[settings.childNames[index]] = newValue
            })
    }

    private func binding(for option: ReminderOption) -> Binding<Bool> {
        Binding(
            get: { settings.options.contains(option) },
            set: { isOn in
                if isOn { settings.options.insert(option) }
                else { settings.options.remove(option) }
            })
    }
}

#Preview {
    SettingsView(settings: .constant(.default))
}
