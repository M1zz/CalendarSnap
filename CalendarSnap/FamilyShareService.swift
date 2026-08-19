//
//  FamilyShareService.swift
//  CalendarSnap
//
//  가족 초대 — 배우자·조부모를 초대하면 일정이 양쪽에서 계속 동기화된다.
//  서버 없이 CloudKit 공유(CKShare)만 사용하며, 초대받은 사람도 일정을 추가·수정할 수 있다.
//
//  ⚠️ 실제로 동작하려면 Apple 개발자 포털에서 `iCloud.com.devkoan.CalendarSnap`
//     컨테이너를 만들고 앱 타깃의 iCloud(CloudKit) capability에 추가해야 한다.
//     (엔타이틀먼트에는 이미 적어두었다. Info.plist의 CKSharingSupported도 필요.)
//
//  동기화 모델
//  - 소유자(초대한 사람): 개인 DB에 전용 존(FamilyZone)을 만들고 루트 레코드(Family)를 공유한다.
//  - 참가자(초대받은 사람): 공유 DB의 같은 존을 읽고 쓴다.
//  - 일정 레코드는 루트의 자식(parent)이라 공유 범위에 자동으로 포함된다.
//  - 충돌은 마지막 저장이 이기는(last-writer-wins) 단순 정책.
//

import CloudKit
import Foundation

// MARK: - 상태

enum FamilyShareError: Error {
    /// 공유 존의 루트 레코드를 찾을 수 없음 (소유자가 공유를 끊은 경우 등)
    case rootMissing
}

enum FamilyShareRole: String, Codable {
    case none, owner, participant
}

/// 가족 공유 상태 — App Group에 저장돼 앱을 껐다 켜도 유지된다.
struct FamilyShareState: Codable, Equatable {
    var role: FamilyShareRole = .none
    var zoneName = FamilyShareService.zoneName
    /// 참가자일 때는 소유자의 사용자 레코드 이름이 들어간다.
    var zoneOwnerName = CKCurrentUserDefaultName
    var shareRecordName = ""
    /// 참가자 화면에 "○○님과 함께 보는 중"으로 표시할 이름.
    var ownerDisplayName = ""
    /// 서버 변경 토큰 (아카이브된 CKServerChangeToken)
    var changeToken: Data?
    /// 서버에 마지막으로 올린 일정 지문 (일정 id → 지문). 바뀐 것만 올리기 위한 거울.
    var pushed: [String: String] = [:]
    var lastSyncedAt: Date?

    var isSharing: Bool { role != .none }

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
    }
}

enum FamilyShareStateStore {
    private static let key = "familyShareState"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroup.identifier)
    }

    static func load() -> FamilyShareState {
        guard let data = defaults?.data(forKey: key),
              let state = try? JSONDecoder().decode(FamilyShareState.self, from: data)
        else { return FamilyShareState() }
        return state
    }

    static func save(_ state: FamilyShareState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults?.set(data, forKey: key)
    }
}

// MARK: - 서비스

@MainActor
final class FamilyShareService: ObservableObject {
    static let shared = FamilyShareService()

    /// ⚠️ 본인 팀의 iCloud 컨테이너로 바꾸세요 (엔타이틀먼트와 동일해야 함).
    nonisolated static let containerIdentifier = "iCloud.com.devkoan.CalendarSnap"
    nonisolated static let zoneName = "FamilyZone"
    private static let rootRecordName = "family-root"
    private static let familyType = "Family"
    private static let eventType = "SharedEvent"
    private static let shareTitle = "아이일정 함께 보기"

    /// 원격 변경을 로컬에 반영했을 때 알림 — 화면이 다시 읽어가도록.
    static let didChangeNotification = Notification.Name("FamilyShareDidChange")

    @Published private(set) var state = FamilyShareStateStore.load()
    @Published private(set) var isBusy = false
    /// 사용자에게 보여줄 오류/안내 (화면에서 alert으로 소비)
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    private let container = CKContainer(identifier: FamilyShareService.containerIdentifier)
    private var syncTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// 초대 시트(UICloudSharingController)에 넘길 컨테이너.
    var cloudContainer: CKContainer { container }

    private var database: CKDatabase {
        state.role == .participant ? container.sharedCloudDatabase : container.privateCloudDatabase
    }

    private init() {
        // 앱에서 일정이 저장될 때마다(스캔 저장·직접 추가·삭제) 잠시 후 자동으로 올린다.
        NotificationCenter.default.addObserver(
            forName: EventStore.didSaveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.localDidChange() }
        }
    }

    // MARK: - 계정

    func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    // MARK: - 초대 (소유자)

    /// 전용 존·루트 레코드·CKShare를 준비한다. 초대 시트에 넘길 공유를 돌려준다.
    func startSharing() async -> CKShare? {
        guard state.role != .participant else {
            errorMessage = "이미 다른 가족의 공유에 참여하고 있어요. 먼저 ‘공유 나가기’를 한 뒤 초대해주세요."
            return nil
        }
        guard await ensureAccount() else { return nil }

        isBusy = true
        defer { isBusy = false }

        do {
            let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
            _ = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: [])

            let rootID = CKRecord.ID(recordName: Self.rootRecordName, zoneID: zoneID)
            let root = (try? await container.privateCloudDatabase.record(for: rootID))
                ?? CKRecord(recordType: Self.familyType, recordID: rootID)
            root["childNames"] = ReminderSettingsStore.load().childNames as CKRecordValue

            // 이미 공유 중이면 기존 공유를 그대로 재사용 (초대 링크 재발송·참가자 관리)
            if let reference = root.share,
               let existing = try? await container.privateCloudDatabase.record(for: reference.recordID) as? CKShare {
                markAsOwner(zoneID: zoneID, shareRecordName: existing.recordID.recordName)
                await sync()
                return existing
            }

            let share = CKShare(rootRecord: root)
            share[CKShare.SystemFieldKey.title] = Self.shareTitle as CKRecordValue
            share.publicPermission = .none

            let result = try await container.privateCloudDatabase.modifyRecords(
                saving: [root, share], deleting: [], savePolicy: .changedKeys, atomically: true)
            guard let saved = result.saveResults[share.recordID].flatMap({ try? $0.get() }) as? CKShare else {
                errorMessage = "초대 링크를 만들지 못했어요. 잠시 후 다시 시도해주세요."
                return nil
            }

            markAsOwner(zoneID: zoneID, shareRecordName: saved.recordID.recordName)
            await sync()   // 지금까지의 일정을 공유 존에 올린다
            return saved
        } catch {
            handle(error)
            return nil
        }
    }

    /// 참가자 관리·링크 재발송용으로 현재 공유를 가져온다.
    func currentShare() async -> CKShare? {
        guard state.isSharing, !state.shareRecordName.isEmpty else { return nil }
        let id = CKRecord.ID(recordName: state.shareRecordName, zoneID: state.zoneID)
        return try? await database.record(for: id) as? CKShare
    }

    private func markAsOwner(zoneID: CKRecordZone.ID, shareRecordName: String) {
        let wasSharing = state.role == .owner
        state.role = .owner
        state.zoneName = zoneID.zoneName
        state.zoneOwnerName = zoneID.ownerName
        state.shareRecordName = shareRecordName
        if !wasSharing {
            // 처음 공유를 시작하면 기존 일정을 전부 올린다.
            state.changeToken = nil
            state.pushed = [:]
        }
        persist()
    }

    // MARK: - 초대 수락 (참가자)

    func acceptShare(_ metadata: CKShare.Metadata) async {
        guard state.role != .owner else {
            errorMessage = "내가 만든 가족 공유가 이미 있어요. ‘공유 중단’ 후에 초대를 수락해주세요."
            return
        }
        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await container.accept(metadata)
            let zoneID = metadata.hierarchicalRootRecordID?.zoneID ?? metadata.share.recordID.zoneID

            state.role = .participant
            state.zoneName = zoneID.zoneName
            state.zoneOwnerName = zoneID.ownerName
            state.shareRecordName = metadata.share.recordID.recordName
            state.ownerDisplayName = Self.displayName(for: metadata.ownerIdentity)
            state.changeToken = nil
            state.pushed = [:]   // 내 일정도 공유 존에 함께 올린다
            persist()

            await sync()
            let who = state.ownerDisplayName.isEmpty ? "가족" : "\(state.ownerDisplayName)님"
            infoMessage = "\(who)의 일정과 연결됐어요. 이제 양쪽에서 함께 관리할 수 있어요."
        } catch {
            handle(error)
        }
    }

    // MARK: - 공유 중단

    /// 소유자는 공유를 끊고(참가자 전원 해제), 참가자는 공유에서 빠진다.
    /// 지금까지 합쳐진 일정은 양쪽 기기에 그대로 남는다.
    func stopSharing() async {
        isBusy = true
        defer { isBusy = false }

        if !state.shareRecordName.isEmpty {
            let shareID = CKRecord.ID(recordName: state.shareRecordName, zoneID: state.zoneID)
            _ = try? await database.deleteRecord(withID: shareID)
        }
        let wasOwner = state.role == .owner
        state = FamilyShareState()
        persist()
        infoMessage = wasOwner
            ? "가족 공유를 중단했어요. 지금까지의 일정은 그대로 남아 있어요."
            : "공유에서 나왔어요. 지금까지 받은 일정은 그대로 남아 있어요."
    }

    // MARK: - 동기화

    func syncIfNeeded() async {
        guard state.isSharing else { return }
        await sync()
    }

    /// 이미 동기화 중이면 그 작업이 끝나기를 기다린다 (중복 실행 방지).
    func sync() async {
        guard state.isSharing else { return }
        if let running = syncTask {
            await running.value
            return
        }
        let task = Task { await performSync() }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func performSync() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await pull()
            guard state.isSharing else { return }   // pull 도중 공유가 끊겼을 수 있음
            try await push()
            state.lastSyncedAt = Date()
            persist()
        } catch {
            handle(error)
        }
    }

    /// 로컬에서 일정이 바뀌면 잠깐 모았다가 한 번에 올린다.
    private func localDidChange() {
        guard state.isSharing, hasLocalChanges() else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            // 기다리는 사이 다른 경로(앱 활성화 등)로 이미 올라갔으면 건너뛴다
            guard self?.hasLocalChanges() == true else { return }
            await self?.sync()
        }
    }

    private func hasLocalChanges() -> Bool {
        let events = EventStore.load()
        if events.contains(where: { state.pushed[$0.id.uuidString] != fingerprint($0) }) { return true }
        let live = Set(events.map(\.id.uuidString))
        return state.pushed.keys.contains { !live.contains($0) }
    }

    // MARK: - 내려받기

    private func pull() async throws {
        do {
            try await pull(since: currentToken())
        } catch let error as CKError where error.code == .changeTokenExpired {
            // 토큰이 만료되면 처음부터 다시 받는다.
            state.changeToken = nil
            try await pull(since: nil)
        }
    }

    private func pull(since token: CKServerChangeToken?) async throws {
        var cursor = token
        var changed: [ScannedEvent] = []
        var deleted: Set<UUID> = []
        var remoteChildren: [String]?
        var moreComing = true

        while moreComing {
            let batch = try await database.recordZoneChanges(inZoneWith: state.zoneID, since: cursor)

            for result in batch.modificationResultsByID.values {
                guard let record = try? result.get().record else { continue }
                switch record.recordType {
                case Self.eventType:
                    if let event = Self.event(from: record) { changed.append(event) }
                case Self.familyType:
                    remoteChildren = record["childNames"] as? [String]
                default:
                    break
                }
            }
            for deletion in batch.deletions {
                if let id = UUID(uuidString: deletion.recordID.recordName) { deleted.insert(id) }
            }

            cursor = batch.changeToken
            moreComing = batch.moreComing
        }

        state.changeToken = Self.archive(cursor)
        apply(changed: changed, deleted: deleted, children: remoteChildren)
    }

    /// 원격 변경을 로컬 저장소에 병합. 거울(pushed)을 먼저 갱신해 되올리기를 막는다.
    private func apply(changed: [ScannedEvent], deleted: Set<UUID>, children: [String]?) {
        var mirror = state.pushed
        for event in changed { mirror[event.id.uuidString] = fingerprint(event) }
        for id in deleted { mirror[id.uuidString] = nil }
        state.pushed = mirror
        persist()

        if let children {
            var settings = ReminderSettingsStore.load()
            let fresh = children.filter { !$0.isEmpty && !settings.childNames.contains($0) }
            if !fresh.isEmpty {
                settings.childNames.append(contentsOf: fresh)
                ReminderSettingsStore.save(settings)
            }
        }

        guard !changed.isEmpty || !deleted.isEmpty else {
            if children != nil { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
            return
        }

        var local = EventStore.load()
        if !deleted.isEmpty { local.removeAll { deleted.contains($0.id) } }
        for event in changed {
            if let index = local.firstIndex(where: { $0.id == event.id }) {
                local[index] = event
            } else {
                local.append(event)
            }
        }
        EventStore.save(local.sorted { $0.date < $1.date })   // 위젯도 함께 갱신
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)

        // 받아온 일정까지 포함해 알림 재예약 (권한이 이미 있을 때만)
        Task {
            if await NotificationManager.authorizationStatus() == .authorized {
                await NotificationManager.schedule(for: EventStore.load(), settings: ReminderSettingsStore.load())
            }
        }
    }

    // MARK: - 올리기

    private func push() async throws {
        let zoneID = state.zoneID
        let events = EventStore.load()
        var mirror = state.pushed

        let changed = events.filter { mirror[$0.id.uuidString] != fingerprint($0) }
        let live = Set(events.map(\.id.uuidString))
        let removed = mirror.keys.filter { !live.contains($0) }

        // 아이 목록은 양쪽 합집합으로 맞춘다 (한쪽이 지워버리지 않도록)
        let root = try await rootRecord()
        let remoteChildren = root["childNames"] as? [String] ?? []
        let localChildren = ReminderSettingsStore.load().childNames
        let mergedChildren = remoteChildren + localChildren.filter { !$0.isEmpty && !remoteChildren.contains($0) }

        var toSave: [CKRecord] = []
        if mergedChildren != remoteChildren {
            root["childNames"] = mergedChildren as CKRecordValue
            toSave.append(root)
        }
        guard !changed.isEmpty || !removed.isEmpty || !toSave.isEmpty else { return }

        // 서버의 기존 레코드를 먼저 받아 변경 태그를 유지 (불필요한 충돌 방지)
        var existing: [CKRecord.ID: CKRecord] = [:]
        let ids = changed.map { CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID) }
        for chunk in ids.chunked(into: 200) {
            for (id, result) in try await database.records(for: chunk) {
                if let record = try? result.get() { existing[id] = record }
            }
        }

        var eventsByRecordName: [String: ScannedEvent] = [:]
        for event in changed {
            let id = CKRecord.ID(recordName: event.id.uuidString, zoneID: zoneID)
            eventsByRecordName[id.recordName] = event
            let record = existing[id] ?? CKRecord(recordType: Self.eventType, recordID: id)
            toSave.append(Self.apply(event, to: record, rootID: root.recordID))
        }

        for chunk in toSave.chunked(into: 300) {
            let saved = try await saveRecords(chunk, rootID: root.recordID, events: eventsByRecordName)
            for name in saved {
                if let event = eventsByRecordName[name] { mirror[name] = fingerprint(event) }
            }
        }

        let toDelete = removed.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        for chunk in toDelete.chunked(into: 300) {
            let result = try await database.modifyRecords(saving: [], deleting: chunk, atomically: false)
            for (id, outcome) in result.deleteResults {
                // 이미 서버에 없는 것도 정리 대상으로 본다
                if (try? outcome.get()) != nil || Self.isMissing(outcome) { mirror[id.recordName] = nil }
            }
        }

        state.pushed = mirror
        persist()
    }

    /// 저장하고, 서버가 더 최신이라 거절한 레코드는 서버본 위에 다시 얹어 한 번 더 시도한다.
    /// - Returns: 실제로 저장된 레코드 이름들.
    private func saveRecords(_ records: [CKRecord],
                             rootID: CKRecord.ID,
                             events: [String: ScannedEvent]) async throws -> Set<String> {
        var savedNames: Set<String> = []
        var retry: [CKRecord] = []

        let result = try await database.modifyRecords(
            saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
        for (id, outcome) in result.saveResults {
            switch outcome {
            case .success:
                savedNames.insert(id.recordName)
            case .failure(let error):
                guard let ckError = error as? CKError, ckError.code == .serverRecordChanged,
                      let serverRecord = ckError.serverRecord else { continue }
                if let event = events[id.recordName] {
                    retry.append(Self.apply(event, to: serverRecord, rootID: rootID))
                } else if id.recordName == rootID.recordName,
                          let mine = records.first(where: { $0.recordID == id })?["childNames"] as? [String] {
                    // 그 사이 상대가 아이를 추가했을 수 있으니 다시 합집합으로
                    let theirs = serverRecord["childNames"] as? [String] ?? []
                    serverRecord["childNames"] = (theirs + mine.filter { !theirs.contains($0) }) as CKRecordValue
                    retry.append(serverRecord)
                }
            }
        }

        guard !retry.isEmpty else { return savedNames }
        let second = try await database.modifyRecords(
            saving: retry, deleting: [], savePolicy: .allKeys, atomically: false)
        for (id, outcome) in second.saveResults where (try? outcome.get()) != nil {
            savedNames.insert(id.recordName)
        }
        return savedNames
    }

    private func rootRecord() async throws -> CKRecord {
        let id = CKRecord.ID(recordName: Self.rootRecordName, zoneID: state.zoneID)
        if let existing = try? await database.record(for: id) { return existing }
        // 소유자인데 루트가 사라진 경우에만 새로 만든다 (참가자는 소유자의 루트를 쓴다).
        guard state.role == .owner else { throw FamilyShareError.rootMissing }
        return CKRecord(recordType: Self.familyType, recordID: id)
    }

    // MARK: - 레코드 ↔ 모델

    private static func apply(_ event: ScannedEvent, to record: CKRecord, rootID: CKRecord.ID) -> CKRecord {
        record["title"] = event.title as CKRecordValue
        record["date"] = event.date as CKRecordValue
        record["isAllDay"] = (event.isAllDay ? 1 : 0) as CKRecordValue
        record["notes"] = event.notes as CKRecordValue
        record["childName"] = event.childName as CKRecordValue
        record["isRecurring"] = (event.isRecurring ? 1 : 0) as CKRecordValue
        record["rawText"] = event.rawText as CKRecordValue
        // 루트의 자식이어야 공유 범위에 포함된다.
        record.parent = CKRecord.Reference(recordID: rootID, action: .none)
        return record
    }

    private static func event(from record: CKRecord) -> ScannedEvent? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let title = record["title"] as? String,
              let date = record["date"] as? Date
        else { return nil }
        return ScannedEvent(
            id: id,
            title: title,
            date: date,
            isAllDay: (record["isAllDay"] as? Int ?? 0) == 1,
            notes: record["notes"] as? String ?? "",
            childName: record["childName"] as? String ?? "",
            isRecurring: (record["isRecurring"] as? Int ?? 0) == 1,
            rawText: record["rawText"] as? String ?? "")
    }

    private func fingerprint(_ event: ScannedEvent) -> String {
        [event.title,
         String(Int(event.date.timeIntervalSince1970)),
         event.isAllDay ? "1" : "0",
         event.notes,
         event.childName,
         event.isRecurring ? "1" : "0"].joined(separator: "|")
    }

    nonisolated static func displayName(for identity: CKUserIdentity) -> String {
        if let components = identity.nameComponents {
            let name = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
            if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        }
        return identity.lookupInfo?.emailAddress
            ?? identity.lookupInfo?.phoneNumber
            ?? ""
    }

    // MARK: - 잡일

    private func persist() {
        FamilyShareStateStore.save(state)
    }

    private func currentToken() -> CKServerChangeToken? {
        guard let data = state.changeToken else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private static func archive(_ token: CKServerChangeToken?) -> Data? {
        guard let token else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func isMissing(_ outcome: Result<Void, any Error>) -> Bool {
        if case .failure(let error) = outcome, let ckError = error as? CKError {
            return ckError.code == .unknownItem
        }
        return false
    }

    private func ensureAccount() async -> Bool {
        switch await accountStatus() {
        case .available:
            return true
        case .noAccount:
            errorMessage = "iCloud에 로그인해야 가족과 일정을 공유할 수 있어요.\n설정 앱 > Apple 계정에서 로그인해주세요."
        case .restricted:
            errorMessage = "이 기기에서는 iCloud 사용이 제한돼 있어요."
        default:
            errorMessage = "iCloud 상태를 확인하지 못했어요. 잠시 후 다시 시도해주세요."
        }
        return false
    }

    private func handle(_ error: Error) {
        guard let ckError = error as? CKError else {
            errorMessage = "동기화에 실패했어요. 잠시 후 다시 시도해주세요."
            return
        }
        switch ckError.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            break   // 일시적 — 다음 동기화 때 자동으로 다시 시도
        case .notAuthenticated:
            errorMessage = "iCloud에 로그인해야 가족 공유를 쓸 수 있어요."
        case .quotaExceeded:
            errorMessage = "iCloud 저장 공간이 부족해 일정을 올리지 못했어요."
        case .zoneNotFound, .userDeletedZone:
            // 소유자가 공유를 끊었거나 존이 사라짐 — 로컬 일정은 유지하고 공유만 해제
            let wasParticipant = state.role == .participant
            state = FamilyShareState()
            persist()
            infoMessage = wasParticipant
                ? "가족 공유가 종료됐어요. 지금까지 받은 일정은 그대로 남아 있어요."
                : "공유 정보가 초기화됐어요. 다시 초대해주세요."
        default:
            errorMessage = "동기화에 실패했어요. 잠시 후 다시 시도해주세요."
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
