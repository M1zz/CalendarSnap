import CloudKit
import UIKit

/// 로컬 모델(ScannedEvent·아이 정보) ↔ CKRecord 변환.
/// 스키마 상수와 순수 변환 함수만 두고, 엔진 로직은 FamilySyncManager가 담당합니다.
enum RecordMapper {
    static let zoneName = "FamilyZone"

    enum EventKey {
        static let recordType = "Event"
        static let title = "title"
        static let date = "date"
        static let isAllDay = "isAllDay"
        static let notes = "notes"
        static let childName = "childName"
        static let isRecurring = "isRecurring"
        static let rawText = "rawText"
    }

    enum ChildKey {
        static let recordType = "Child"
        static let recordNamePrefix = "child:"
        static let name = "name"
        static let className = "className"
        static let sortIndex = "sortIndex"
        static let avatar = "avatar"
    }

    // MARK: - recordName 규칙

    static func recordID(for event: ScannedEvent, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: event.id.uuidString, zoneID: zoneID)
    }

    static func recordID(forChild name: String, zoneID: CKRecordZone.ID) -> CKRecord.ID? {
        guard let safe = sanitizedChildName(name) else { return nil }
        return CKRecord.ID(recordName: ChildKey.recordNamePrefix + safe, zoneID: zoneID)
    }

    /// ChildAvatarStore.fileURL과 동일한 규칙 (이름을 파일/레코드 키로 쓰기 위한 정리).
    static func sanitizedChildName(_ name: String) -> String? {
        let safe = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "_")
        return safe.isEmpty ? nil : safe
    }

    static func isEventRecordName(_ recordName: String) -> Bool {
        UUID(uuidString: recordName) != nil
    }

    static func isChildRecordName(_ recordName: String) -> Bool {
        recordName.hasPrefix(ChildKey.recordNamePrefix)
    }

    // MARK: - 지문 (변경 감지용 — 프로세스 간 안정적이어야 하므로 hashValue 금지)

    static func fingerprint(of event: ScannedEvent) -> String {
        [event.title,
         String(event.date.timeIntervalSince1970),
         String(event.isAllDay),
         event.notes,
         event.childName,
         String(event.isRecurring),
         event.rawText].joined(separator: "|")
    }

    static func childFingerprint(name: String, className: String, sortIndex: Int) -> String {
        [name, className, String(sortIndex)].joined(separator: "|")
    }

    // MARK: - 모델 → CKRecord

    static func record(for event: ScannedEvent, base: CKRecord?, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = base ?? CKRecord(recordType: EventKey.recordType,
                                      recordID: recordID(for: event, zoneID: zoneID))
        record[EventKey.title] = event.title
        record[EventKey.date] = event.date
        record[EventKey.isAllDay] = event.isAllDay ? 1 : 0
        record[EventKey.notes] = event.notes
        record[EventKey.childName] = event.childName
        record[EventKey.isRecurring] = event.isRecurring ? 1 : 0
        record[EventKey.rawText] = event.rawText
        return record
    }

    static func childRecord(name: String, className: String, sortIndex: Int,
                            base: CKRecord?, zoneID: CKRecordZone.ID) -> CKRecord? {
        guard let recordID = recordID(forChild: name, zoneID: zoneID) else { return nil }
        let record = base ?? CKRecord(recordType: ChildKey.recordType, recordID: recordID)
        record[ChildKey.name] = name
        record[ChildKey.className] = className
        record[ChildKey.sortIndex] = sortIndex

        // 아바타는 있으면 CKAsset으로 첨부 (임시 파일 경유), 없으면 제거
        if let image = ChildAvatarStore.image(for: name),
           let data = image.jpegData(compressionQuality: 0.85) {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("avatar-\(UUID().uuidString).jpg")
            if (try? data.write(to: tempURL)) != nil {
                record[ChildKey.avatar] = CKAsset(fileURL: tempURL)
            }
        } else {
            record[ChildKey.avatar] = nil
        }
        return record
    }

    // MARK: - CKRecord → 모델

    static func event(from record: CKRecord) -> ScannedEvent? {
        guard record.recordType == EventKey.recordType,
              let id = UUID(uuidString: record.recordID.recordName),
              let title = record[EventKey.title] as? String,
              let date = record[EventKey.date] as? Date
        else { return nil }
        var event = ScannedEvent(title: title, date: date,
                                 rawText: record[EventKey.rawText] as? String ?? "")
        event.id = id
        event.isAllDay = (record[EventKey.isAllDay] as? Int ?? 0) != 0
        event.notes = record[EventKey.notes] as? String ?? ""
        event.childName = record[EventKey.childName] as? String ?? ""
        event.isRecurring = (record[EventKey.isRecurring] as? Int ?? 0) != 0
        return event
    }

    struct RemoteChild {
        let name: String
        let className: String
        let sortIndex: Int
        let avatarData: Data?
    }

    static func child(from record: CKRecord) -> RemoteChild? {
        guard record.recordType == ChildKey.recordType,
              let name = record[ChildKey.name] as? String, !name.isEmpty
        else { return nil }
        var avatarData: Data?
        if let asset = record[ChildKey.avatar] as? CKAsset, let url = asset.fileURL {
            avatarData = try? Data(contentsOf: url)
        }
        return RemoteChild(name: name,
                           className: record[ChildKey.className] as? String ?? "",
                           sortIndex: record[ChildKey.sortIndex] as? Int ?? 0,
                           avatarData: avatarData)
    }
}
