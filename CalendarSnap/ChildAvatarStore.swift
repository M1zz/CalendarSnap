import UIKit

/// 아이 프로필 사진을 App Group 컨테이너에 저장/로드.
enum ChildAvatarStore {
    /// 사진 변경/삭제 시 호출되는 동기화 훅 (가족 공유 업로드용).
    static var onChange: ((String) -> Void)?

    private static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("avatars", isDirectory: true)
    }

    static func image(for name: String) -> UIImage? {
        guard let url = fileURL(for: name), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// - Parameter notifySync: false면 동기화 훅을 건너뜀 (원격 변경 반영 시 에코 루프 방지).
    static func save(_ image: UIImage, for name: String, notifySync: Bool = true) {
        guard let dir = directory, let url = fileURL(for: name) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 표시용으로 작게 리사이즈 (긴 변 240pt)
        let side: CGFloat = 240
        let scale = min(1, max(side / image.size.width, side / image.size.height))
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        try? resized.jpegData(compressionQuality: 0.85)?.write(to: url)
        if notifySync { onChange?(name) }
    }

    static func delete(for name: String, notifySync: Bool = true) {
        guard let url = fileURL(for: name) else { return }
        try? FileManager.default.removeItem(at: url)
        if notifySync { onChange?(name) }
    }

    private static func fileURL(for name: String) -> URL? {
        let safe = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "_")
        guard !safe.isEmpty else { return nil }
        return directory?.appendingPathComponent("\(safe).jpg")
    }
}
