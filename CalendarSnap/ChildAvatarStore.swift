import UIKit

/// 아이 프로필 사진을 App Group 컨테이너에 저장/로드.
enum ChildAvatarStore {
    private static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("avatars", isDirectory: true)
    }

    static func image(for name: String) -> UIImage? {
        guard let url = fileURL(for: name), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func save(_ image: UIImage, for name: String) {
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
    }

    static func delete(for name: String) {
        guard let url = fileURL(for: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileURL(for name: String) -> URL? {
        let safe = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "_")
        guard !safe.isEmpty else { return nil }
        return directory?.appendingPathComponent("\(safe).jpg")
    }
}
