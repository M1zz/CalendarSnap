import Foundation

/// 가족 공유 동기화 상태.
/// CKSyncEngine 상태 직렬화 + 레코드 시스템 필드 캐시 + 마지막 동기화 스냅샷을 담습니다.
/// (스냅샷은 "전체 배열 저장" 방식의 로컬 스토어를 레코드 단위 변경으로 diff하는 기준)
struct SyncState: Codable {
    enum Role: String, Codable {
        case none          // 공유 안 함 (동기화 꺼짐)
        case owner         // 내 private DB의 FamilyZone을 공유하는 쪽
        case participant   // 다른 사람의 FamilyZone에 참여한 쪽
    }

    var role: Role = .none
    /// 참여자일 때 소유자 존의 ownerName (존 ID 복원용).
    var zoneOwnerName: String?
    var privateEngineState: Data?
    var sharedEngineState: Data?
    /// recordName → encodeSystemFields로 아카이브한 CKRecord (기존 레코드 재저장에 필요).
    var recordSystemFields: [String: Data] = [:]
    /// 이벤트 UUID 문자열 → 내용 지문. 저장 훅에서 변경 감지에 사용.
    var syncedEventFingerprints: [String: String] = [:]
    /// 아이 이름 → 내용 지문.
    var syncedChildFingerprints: [String: String] = [:]

    var isActive: Bool { role != .none }
}

/// SyncState를 App Group 컨테이너의 JSON 파일로 저장/로드.
/// (위젯이 읽는 UserDefaults 키와 분리해 위젯 갱신에 영향을 주지 않음)
enum SyncStateStore {
    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("family-sync-state.json")
    }

    static func load() -> SyncState {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else { return SyncState() }
        return state
    }

    static func save(_ state: SyncState) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func reset() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
