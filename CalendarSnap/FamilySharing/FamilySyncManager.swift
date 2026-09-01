import CloudKit
import Foundation
import UIKit

extension Notification.Name {
    /// 원격(가족) 변경이 로컬 스토어에 반영됐을 때 발행 — 화면·알림·캘린더 미러링 갱신용.
    static let familyDataDidChange = Notification.Name("familyDataDidChange")
}

/// CloudKit CKShare 기반 가족 공유 동기화 엔진.
///
/// - 소유자: private DB의 FamilyZone에 전체 데이터를 올리고 존 전체를 CKShare로 공유
/// - 참여자: shared DB를 통해 소유자의 FamilyZone을 읽고 씀 (읽기+쓰기 권한)
/// - 로컬 App Group 저장소가 계속 source of truth — 위젯·알림·캘린더 미러링은 로컬만 봄
@MainActor
final class FamilySyncManager: NSObject, ObservableObject {
    static let shared = FamilySyncManager()
    static let containerIdentifier = "iCloud.com.devkoan.calendarsnap"

    @Published private(set) var accountStatus: CKAccountStatus?
    @Published private(set) var role: SyncState.Role = .none
    @Published private(set) var share: CKShare?
    /// 사용자에게 보여줄 안내 (공유 참여/종료 등).
    @Published var infoMessage: String?

    private lazy var container = CKContainer(identifier: Self.containerIdentifier)
    private var state = SyncStateStore.load()
    private var privateEngine: CKSyncEngine?
    private var sharedEngine: CKSyncEngine?
    private var started = false
    /// 참여 직후 원격에서 실제로 받아온 레코드 수 (공유 존 노출 지연 재시도 판단용).
    private var appliedRemoteRecordCount = 0

    var isSharingActive: Bool { role != .none }

    /// 공유 수락 대기 중인 참여자 목록 표시용 (소유자 본인 제외).
    var participants: [CKShare.Participant] {
        share?.participants.filter { $0.role != .owner } ?? []
    }

    // MARK: - 시작/계정

    /// 앱 시작 시 호출. 이전에 공유를 켰던 경우에만 엔진을 기동합니다.
    func start() {
        guard !started else { return }
        started = true
        role = state.role
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAccountStatus() }
        }
        // 공유를 쓰지 않는 상태에서는 CloudKit을 건드리지 않음
        // (계정 상태는 설정 화면의 가족 공유 섹션이 열릴 때 조회)
        guard state.isActive else { return }
        refreshAccountStatus()
        startEngines()
        Task { await refreshShare() }
    }

    func refreshAccountStatus() {
        Task {
            let status = try? await container.accountStatus()
            accountStatus = status
        }
    }

    private func startEngines() {
        switch state.role {
        case .owner:
            _ = ownerEngine
        case .participant:
            _ = participantEngine
        case .none:
            break
        }
    }

    private var ownerEngine: CKSyncEngine {
        if let privateEngine { return privateEngine }
        let engine = makeEngine(database: container.privateCloudDatabase,
                                stateData: state.privateEngineState)
        privateEngine = engine
        return engine
    }

    private var participantEngine: CKSyncEngine {
        if let sharedEngine { return sharedEngine }
        let engine = makeEngine(database: container.sharedCloudDatabase,
                                stateData: state.sharedEngineState)
        sharedEngine = engine
        return engine
    }

    private func makeEngine(database: CKDatabase, stateData: Data?) -> CKSyncEngine {
        var serialization: CKSyncEngine.State.Serialization?
        if let stateData {
            serialization = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: stateData)
        }
        let configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: self)
        return CKSyncEngine(configuration)
    }

    /// 현재 역할에 맞는 활성 엔진.
    private var activeEngine: CKSyncEngine? {
        switch state.role {
        case .owner: return ownerEngine
        case .participant: return participantEngine
        case .none: return nil
        }
    }

    /// 현재 역할 기준 동기화 존 ID.
    private var zoneID: CKRecordZone.ID? {
        switch state.role {
        case .owner:
            return CKRecordZone.ID(zoneName: RecordMapper.zoneName)
        case .participant:
            guard let ownerName = state.zoneOwnerName else { return nil }
            return CKRecordZone.ID(zoneName: RecordMapper.zoneName, ownerName: ownerName)
        case .none:
            return nil
        }
    }

    private func saveState() {
        SyncStateStore.save(state)
    }

    // MARK: - 로컬 변경 업로드 (스토어 훅에서 호출)

    /// EventStore.save 훅: 전체 배열을 마지막 동기화 스냅샷과 diff해 레코드 단위 변경으로 변환.
    func enqueueEventsSnapshot(_ events: [ScannedEvent]) {
        guard state.isActive, let engine = activeEngine, let zoneID else { return }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        var seen = Set<String>()

        for event in events {
            let key = event.id.uuidString
            seen.insert(key)
            if state.syncedEventFingerprints[key] != RecordMapper.fingerprint(of: event) {
                pending.append(.saveRecord(RecordMapper.recordID(for: event, zoneID: zoneID)))
            }
        }
        for key in state.syncedEventFingerprints.keys where !seen.contains(key) {
            pending.append(.deleteRecord(CKRecord.ID(recordName: key, zoneID: zoneID)))
            state.syncedEventFingerprints[key] = nil
            state.recordSystemFields[key] = nil
        }
        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending)
        saveState()
    }

    /// ReminderSettingsStore.save 훅: 아이 목록·반 정보만 diff (알림 옵션 등은 기기별 설정).
    func enqueueChildrenSnapshot(_ settings: ReminderSettings) {
        guard state.isActive, let engine = activeEngine, let zoneID else { return }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        var seen = Set<String>()

        for (index, rawName) in settings.childNames.enumerated() {
            guard let name = RecordMapper.sanitizedChildName(rawName) else { continue }
            seen.insert(name)
            let fingerprint = RecordMapper.childFingerprint(
                name: name,
                className: settings.childClasses[rawName] ?? "",
                sortIndex: index)
            if state.syncedChildFingerprints[name] != fingerprint,
               let recordID = RecordMapper.recordID(forChild: name, zoneID: zoneID) {
                pending.append(.saveRecord(recordID))
            }
        }
        for name in state.syncedChildFingerprints.keys where !seen.contains(name) {
            if let recordID = RecordMapper.recordID(forChild: name, zoneID: zoneID) {
                pending.append(.deleteRecord(recordID))
            }
            state.syncedChildFingerprints[name] = nil
            state.recordSystemFields[RecordMapper.ChildKey.recordNamePrefix + name] = nil
        }
        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending)
        saveState()
    }

    /// ChildAvatarStore 훅: 프로필 사진 변경 → 해당 아이 레코드 재업로드.
    func enqueueAvatarChange(for name: String) {
        guard state.isActive, let engine = activeEngine, let zoneID,
              let recordID = RecordMapper.recordID(forChild: name, zoneID: zoneID),
              let safe = RecordMapper.sanitizedChildName(name),
              state.syncedChildFingerprints[safe] != nil   // 아직 동기화 안 된 아이면 children diff가 처리
        else { return }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    /// 포그라운드 진입 시 수동 fetch (시뮬레이터·푸시 누락 대비).
    func fetchChangesNow() {
        guard state.isActive, let engine = activeEngine else { return }
        Task {
            try? await engine.fetchChanges()
        }
    }

    // MARK: - 공유 시작 (소유자)

    /// "가족 초대하기": 존 생성 → 전체 데이터 업로드 예약 → 존 전체 CKShare 생성/반환.
    func createShare() async throws -> CKShare {
        if state.role == .participant {
            throw FamilySharingError.alreadyParticipant
        }
        let zoneID = CKRecordZone.ID(zoneName: RecordMapper.zoneName)

        // 존을 먼저 서버에 보장 (공유 레코드 저장 전 필수)
        _ = try await container.privateCloudDatabase.modifyRecordZones(
            saving: [CKRecordZone(zoneID: zoneID)], deleting: [])

        if state.role != .owner {
            state.role = .owner
            role = .owner
            saveState()
        }

        // 현재 로컬 데이터 전체를 업로드 대기열에 등록
        enqueueEventsSnapshot(EventStore.load())
        enqueueChildrenSnapshot(ReminderSettingsStore.load())
        try? await ownerEngine.sendChanges()

        // 기존 공유가 있으면 재사용 (존 전체 공유의 recordName은 고정)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let existing = try? await container.privateCloudDatabase.record(for: shareID) as? CKShare {
            // 예전 버전에서 "초대한 사람만"으로 만들어진 공유는 링크만 받은 사람이 수락할 수 없으므로
            // 링크 공유가 가능하도록 승격한다.
            let upgraded = (try? await ensureLinkShareable(existing)) ?? existing
            share = upgraded
            return upgraded
        }

        let newShare = CKShare(recordZoneID: zoneID)
        newShare[CKShare.SystemFieldKey.title] = "아이일정 함께 보기"
        // 카카오톡·메시지로 링크만 받아도 수락할 수 있어야 하므로 "링크가 있는 누구나"로 만든다.
        // (.none이면 UICloudSharingController가 "초대한 사람만"으로 시작해서, 링크를 그냥 전달받은
        //  상대방은 iCloud 웹에서 "초대가 필요합니다"로 막히고 앱으로 데이터가 넘어오지 않는다.)
        newShare.publicPermission = .readWrite
        let result = try await container.privateCloudDatabase.modifyRecords(
            saving: [newShare], deleting: [])
        if case .success(let saved) = result.saveResults[newShare.recordID] ?? .failure(CKError(.internalError)),
           let savedShare = saved as? CKShare {
            share = savedShare
            return savedShare
        }
        share = newShare
        return newShare
    }

    /// 공유 레코드가 "링크가 있는 누구나" 수락 가능한 상태인지 보장.
    private func ensureLinkShareable(_ existing: CKShare) async throws -> CKShare {
        guard existing.publicPermission == .none else { return existing }
        existing.publicPermission = .readWrite
        let result = try await container.privateCloudDatabase.modifyRecords(
            saving: [existing], deleting: [], savePolicy: .changedKeys)
        if case .success(let saved) = result.saveResults[existing.recordID] ?? .failure(CKError(.internalError)),
           let savedShare = saved as? CKShare {
            return savedShare
        }
        return existing
    }

    /// 공유 중지 (소유자): 공유 레코드만 삭제 — 데이터(존)는 유지되어 내 iCloud 백업으로 남음.
    func stopSharing() async {
        guard state.role == .owner, let share else { return }
        _ = try? await container.privateCloudDatabase.modifyRecords(
            saving: [], deleting: [share.recordID])
        self.share = nil
        infoMessage = "일정 공유를 중지했어요. 내 데이터는 그대로 유지돼요."
    }

    /// 공유 나가기 (참여자): shared DB에서 존 제거 → 참여 해제. 로컬 데이터는 유지.
    func leaveShare() async {
        guard state.role == .participant, let zoneID else { return }
        _ = try? await container.sharedCloudDatabase.modifyRecordZones(
            saving: [], deleting: [zoneID])
        detachFromShare(message: "일정 공유에서 나왔어요. 지금까지의 일정은 이 기기에 남아 있어요.")
    }

    /// 참여 상태 해제 (존 삭제 감지·나가기 공통). 로컬 데이터는 건드리지 않음.
    private func detachFromShare(message: String?) {
        sharedEngine = nil
        share = nil
        state = SyncState()
        role = .none
        SyncStateStore.reset()
        if let message { infoMessage = message }
    }

    /// 현재 존의 공유 레코드 로드 (참여자 목록 표시용).
    func refreshShare() async {
        guard let zoneID else { return }
        let database = state.role == .owner
            ? container.privateCloudDatabase
            : container.sharedCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        share = try? await database.record(for: shareID) as? CKShare
    }

    // MARK: - 공유 수락 (참여자)

    func accept(_ metadata: CKShare.Metadata) {
        guard metadata.containerIdentifier == Self.containerIdentifier else {
            infoMessage = "아이일정의 초대 링크가 아니에요."
            return
        }
        // 내가 만든 링크를 내가 누른 경우 — 조용히 무시하지 않고 이유를 알려준다.
        if metadata.participantRole == .owner {
            infoMessage = "내가 만든 초대 링크예요. 이 링크를 함께 볼 사람에게 보내주세요."
            return
        }
        // 이미 내 일정을 공유 중인 소유자는 다른 사람의 공유에 참여할 수 없다.
        if state.role == .owner {
            infoMessage = "이미 내 일정을 공유 중이에요. 설정 > 일정 공유에서 '공유 중지'를 한 뒤 초대 링크를 다시 눌러주세요."
            return
        }
        let shareZoneID = metadata.share.recordID.zoneID
        // 같은 공유에 이미 참여 중이면 재수락 대신 새로고침만.
        if state.role == .participant, state.zoneOwnerName == shareZoneID.ownerName {
            infoMessage = "이미 참여 중인 공유예요. 최신 일정을 가져올게요."
            fetchChangesNow()
            return
        }
        Task {
            do {
                _ = try await container.accept(metadata)
                state.role = .participant
                state.zoneOwnerName = shareZoneID.ownerName
                role = .participant
                saveState()

                let engine = participantEngine
                appliedRemoteRecordCount = 0
                try await engine.fetchChanges()

                // 수락 직후에는 공유 DB에 존이 아직 안 보일 수 있어 잠깐 재시도한다.
                var attempt = 0
                while appliedRemoteRecordCount == 0, attempt < 4 {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    try? await engine.fetchChanges()
                }

                // 원격에 없는 로컬 데이터(기존 사용자였던 경우)를 공유 존에 업로드
                enqueueEventsSnapshot(EventStore.load())
                enqueueChildrenSnapshot(ReminderSettingsStore.load())
                try? await engine.sendChanges()

                await refreshShare()
                if appliedRemoteRecordCount == 0 {
                    infoMessage = "공유에 참여했어요. 아직 받아온 일정이 없어요 — 잠시 후 앱을 다시 열면 반영돼요."
                } else {
                    let count = EventStore.load().count
                    infoMessage = "공유된 일정에 참여했어요. 일정 \(count)개를 함께 관리해요."
                }
            } catch {
                // 실패 원인을 그대로 보여줘야 iCloud 로그인·권한 문제를 구분할 수 있다.
                infoMessage = "공유 참여에 실패했어요. (\(error.localizedDescription))"
            }
        }
    }

    // MARK: - 원격 변경 반영

    /// 가져온 레코드 수정분을 로컬 스토어에 적용. (notifySync: false로 에코 루프 방지)
    private func applyRemoteModifications(_ records: [CKRecord]) {
        var events = EventStore.load()
        var settings = ReminderSettingsStore.load()
        var eventsChanged = false
        var settingsChanged = false

        for record in records {
            cacheSystemFields(of: record)
            appliedRemoteRecordCount += 1

            if let event = RecordMapper.event(from: record) {
                // 같은 내용의 다른 UUID 로컬 일정(파일 공유로 미리 받은 경우)은 원격 UUID로 통일
                let key = dedupKey(event)
                events.removeAll { $0.id != event.id && dedupKey($0) == key }
                if let index = events.firstIndex(where: { $0.id == event.id }) {
                    events[index] = event
                } else {
                    events.append(event)
                }
                state.syncedEventFingerprints[event.id.uuidString] = RecordMapper.fingerprint(of: event)
                eventsChanged = true

            } else if let child = RecordMapper.child(from: record) {
                if !settings.childNames.contains(child.name) {
                    settings.childNames.append(child.name)
                }
                if settings.childClasses[child.name] ?? "" != child.className {
                    settings.childClasses[child.name] = child.className
                }
                if let data = child.avatarData, let image = UIImage(data: data) {
                    ChildAvatarStore.save(image, for: child.name, notifySync: false)
                }
                if let safe = RecordMapper.sanitizedChildName(child.name) {
                    state.syncedChildFingerprints[safe] = RecordMapper.childFingerprint(
                        name: safe, className: child.className, sortIndex: child.sortIndex)
                }
                settingsChanged = true

            } else if let updatedShare = record as? CKShare {
                share = updatedShare
            }
        }

        finishApplying(events: events, eventsChanged: eventsChanged,
                       settings: settings, settingsChanged: settingsChanged)
    }

    private func applyRemoteDeletions(_ recordIDs: [CKRecord.ID]) {
        var events = EventStore.load()
        var settings = ReminderSettingsStore.load()
        var eventsChanged = false
        var settingsChanged = false

        for recordID in recordIDs {
            let name = recordID.recordName
            state.recordSystemFields[name] = nil

            if RecordMapper.isEventRecordName(name), let id = UUID(uuidString: name) {
                events.removeAll { $0.id == id }
                state.syncedEventFingerprints[name] = nil
                eventsChanged = true
            } else if RecordMapper.isChildRecordName(name) {
                let childName = String(name.dropFirst(RecordMapper.ChildKey.recordNamePrefix.count))
                settings.childNames.removeAll {
                    RecordMapper.sanitizedChildName($0) == childName
                }
                settings.childClasses[childName] = nil
                ChildAvatarStore.delete(for: childName, notifySync: false)
                state.syncedChildFingerprints[childName] = nil
                settingsChanged = true
            } else if name == CKRecordNameZoneWideShare {
                // 공유 레코드 삭제 = 소유자가 공유를 중지 (소유자 자신은 stopSharing에서 처리)
                if state.role == .participant {
                    detachFromShare(message: "일정 공유가 종료됐어요. 지금까지의 일정은 이 기기에 남아 있어요.")
                } else {
                    share = nil
                }
            }
        }

        finishApplying(events: events, eventsChanged: eventsChanged,
                       settings: settings, settingsChanged: settingsChanged)
    }

    private func finishApplying(events: [ScannedEvent], eventsChanged: Bool,
                                settings: ReminderSettings, settingsChanged: Bool) {
        guard eventsChanged || settingsChanged else {
            saveState()
            return
        }
        if eventsChanged {
            EventStore.save(events.sorted { $0.date < $1.date }, notifySync: false)
        }
        if settingsChanged {
            ReminderSettingsStore.save(settings, notifySync: false)
        }
        saveState()
        NotificationCenter.default.post(name: .familyDataDidChange, object: nil)
    }

    private func cacheSystemFields(of record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        state.recordSystemFields[record.recordID.recordName] = archiver.encodedData
    }

    private func cachedRecord(recordName: String) -> CKRecord? {
        Self.decodeRecord(state.recordSystemFields[recordName])
    }

    /// 아카이브된 시스템 필드에서 CKRecord 복원 (액터 무관 — 배치 클로저에서도 사용).
    nonisolated private static func decodeRecord(_ data: Data?) -> CKRecord? {
        guard let data, let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { return nil }
        return CKRecord(coder: unarchiver)
    }

    private func dedupKey(_ event: ScannedEvent) -> String {
        "\(event.title)|\(event.date.timeIntervalSince1970)|\(event.childName)"
    }
}

// MARK: - CKSyncEngineDelegate

extension FamilySyncManager: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            let data = try? JSONEncoder().encode(update.stateSerialization)
            if syncEngine === privateEngine {
                state.privateEngineState = data
            } else if syncEngine === sharedEngine {
                state.sharedEngineState = data
            } else if state.role == .participant {
                state.sharedEngineState = data
            } else {
                state.privateEngineState = data
            }
            saveState()

        case .accountChange(let change):
            switch change.changeType {
            case .signOut, .switchAccounts:
                // 계정이 사라지면 동기화 중단. 로컬 데이터는 유지.
                privateEngine = nil
                sharedEngine = nil
                if state.isActive {
                    detachFromShare(message: "iCloud 계정이 바뀌어 일정 공유가 중단됐어요.")
                }
            default:
                break
            }

        case .fetchedRecordZoneChanges(let changes):
            applyRemoteModifications(changes.modifications.map(\.record))
            applyRemoteDeletions(changes.deletions.map(\.recordID))

        case .fetchedDatabaseChanges(let changes):
            // 참여 중이던 존이 삭제됨 = 공유 종료 또는 내보내짐
            for deletion in changes.deletions where deletion.zoneID.zoneName == RecordMapper.zoneName {
                if state.role == .participant {
                    detachFromShare(message: "일정 공유가 종료됐어요. 지금까지의 일정은 이 기기에 남아 있어요.")
                }
            }

        case .sentRecordZoneChanges(let sent):
            for saved in sent.savedRecords {
                cacheSystemFields(of: saved)
                if let event = RecordMapper.event(from: saved) {
                    state.syncedEventFingerprints[event.id.uuidString] = RecordMapper.fingerprint(of: event)
                } else if let child = RecordMapper.child(from: saved),
                          let safe = RecordMapper.sanitizedChildName(child.name) {
                    state.syncedChildFingerprints[safe] = RecordMapper.childFingerprint(
                        name: safe, className: child.className, sortIndex: child.sortIndex)
                }
            }
            for failure in sent.failedRecordSaves {
                handleSaveFailure(failure, engine: syncEngine)
            }
            saveState()

        default:
            break
        }
    }

    private func handleSaveFailure(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
                                   engine: CKSyncEngine) {
        let recordID = failure.record.recordID
        switch failure.error.code {
        case .serverRecordChanged:
            // 충돌: 서버 레코드를 기반으로 내 변경을 다시 얹음 (내 쓰기가 최신 — last writer wins)
            if let serverRecord = failure.error.serverRecord {
                cacheSystemFields(of: serverRecord)
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
        case .zoneNotFound:
            // 존이 사라짐 — 참여자면 공유 종료 처리, 소유자면 존 재생성 후 재시도
            if state.role == .owner {
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: recordID.zoneID))])
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            } else if state.role == .participant {
                detachFromShare(message: "일정 공유가 종료됐어요. 지금까지의 일정은 이 기기에 남아 있어요.")
            }
        case .unknownItem:
            // 서버에서 이미 삭제된 레코드 갱신 시도 — 캐시를 비우고 새 레코드로 재저장
            state.recordSystemFields[recordID.recordName] = nil
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        default:
            break   // 네트워크·용량 등 일시 오류는 CKSyncEngine이 알아서 재시도
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        let events = EventStore.load()
        let settings = ReminderSettingsStore.load()
        let systemFields = state.recordSystemFields   // 클로저는 메인 액터 밖에서 실행될 수 있음

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            let name = recordID.recordName
            let base = Self.decodeRecord(systemFields[name])

            if RecordMapper.isEventRecordName(name), let id = UUID(uuidString: name) {
                guard let event = events.first(where: { $0.id == id }) else {
                    // 로컬에서 이미 사라진 일정 — 저장 대신 대기열에서 제거
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    return nil
                }
                return RecordMapper.record(for: event, base: base, zoneID: recordID.zoneID)
            }

            if RecordMapper.isChildRecordName(name) {
                let childName = String(name.dropFirst(RecordMapper.ChildKey.recordNamePrefix.count))
                guard let index = settings.childNames.firstIndex(where: {
                    RecordMapper.sanitizedChildName($0) == childName
                }) else {
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    return nil
                }
                let rawName = settings.childNames[index]
                return RecordMapper.childRecord(name: childName,
                                                className: settings.childClasses[rawName] ?? "",
                                                sortIndex: index,
                                                base: base,
                                                zoneID: recordID.zoneID)
            }

            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
    }
}

enum FamilySharingError: LocalizedError {
    case alreadyParticipant

    var errorDescription: String? {
        switch self {
        case .alreadyParticipant:
            return "이미 다른 사람이 공유한 일정에 참여 중이에요. 먼저 공유에서 나간 뒤 초대할 수 있어요."
        }
    }
}
