import SwiftUI

/// 아이 프로필 원형 아바타.
/// 사진이 있으면 사진, 없으면 이름 첫 글자 + 아이 색. name이 nil이면 "전체(통합)" 아바타.
struct ChildAvatarView: View {
    let name: String?
    let children: [String]
    var size: CGFloat = 44
    var isSelected = false

    var body: some View {
        avatar
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .inset(by: -3)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
            }
            .opacity(isSelected ? 1 : 0.7)
            .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    @ViewBuilder
    private var avatar: some View {
        if let name, let uiImage = ChildAvatarStore.image(for: name) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else if let name, let initial = name.first {
            Circle()
                .fill(ScannedEvent.color(for: name, children: children).gradient)
                .overlay {
                    Text(String(initial))
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                }
        } else {
            Circle()
                .fill(Color(.systemGray3).gradient)
                .overlay {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: size * 0.36))
                        .foregroundStyle(.white)
                }
        }
    }
}

/// 아바타 + 이름 라벨 버튼 (달력 필터·스캔 아이 선택에 공용).
struct ChildAvatarButton: View {
    let name: String?
    let label: String
    let children: [String]
    let isSelected: Bool
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ChildAvatarView(name: name, children: children, size: size, isSelected: isSelected)
                Text(label)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
