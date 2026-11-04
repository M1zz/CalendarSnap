//
//  ScanNoticeIntent.swift
//  CalendarSnap
//
//  "아이일정으로 알림장 찍어줘" — 카메라를 바로 연다.
//  단축어 앱에서 사진을 넘기면(예: 사진 공유 → 단축어) 그 사진에서 바로 일정을 뽑는다.
//  저장한 일정은 Spotlight 에 색인해 Siri 가 찾게 한다. 누르면 달력이 그 날로 간다.
//  색인(IndexedEntity)은 iOS 18 부터라 그 부분만 나눠 둔다.
//

import AppIntents
import CoreSpotlight
import UIKit

@MainActor @Observable
final class ScanRouter {
    static let shared = ScanRouter()
    /// 늘어날 때마다 첫 화면이 카메라를 연다.
    var cameraRequest = 0
    /// 단축어가 넘긴 사진. 첫 화면이 읽어 들이고 비운다.
    var images: [UIImage] = []
    /// 열어 달라는 일정의 날. 달력이 그 날로 가고 비운다.
    var eventDay: Date?
}

struct ScanNoticeIntent: AppIntent {
    static let title = LocalizedStringResource("알림장 스캔", comment: "Siri: scan a daycare notice to extract events")
    static let description = IntentDescription(
        LocalizedStringResource("알림장 사진에서 일정을 뽑습니다. 사진을 넘기지 않으면 카메라를 엽니다.", comment: "Siri: scan notice description")
    )
    static let openAppWhenRun = true

    /// 그림이 아닌 파일은 읽지 못해 걸러진다 (iOS 17 은 형식 제한을 걸 수 없다).
    @Parameter(title: LocalizedStringResource("사진", comment: "Siri: photos parameter"),
               description: LocalizedStringResource("일정을 뽑을 알림장 사진. 비워 두면 카메라를 엽니다.", comment: "Siri: photos parameter description"))
    var photos: [IntentFile]?

    @MainActor
    func perform() async throws -> some IntentResult {
        let images = (photos ?? []).compactMap { UIImage(data: $0.data) }
        if images.isEmpty {
            ScanRouter.shared.cameraRequest &+= 1
        } else {
            ScanRouter.shared.images = images
        }
        return .result()
    }
}

// MARK: - 저장한 일정

struct EventEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("일정", comment: "Siri/Spotlight: one saved event")
    )
    static let defaultQuery = EventQuery()

    let id: UUID
    let title: String
    let date: Date
    let isAllDay: Bool
    let childName: String
    let notes: String

    init(_ event: ScannedEvent) {
        id = event.id
        title = event.title
        date = event.date
        isAllDay = event.isAllDay
        childName = event.childName
        notes = event.notes
    }

    /// 날짜(종일이 아니면 시각까지) · 아이 이름.
    var subtitle: String {
        let when = date.formatted(date: .abbreviated, time: isAllDay ? .omitted : .shortened)
        return childName.isEmpty ? when : "\(when) · \(childName)"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    static func all() -> [EventEntity] { EventStore.load().map(EventEntity.init) }
}

@available(iOS 18.0, *)
extension EventEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.textContent = [childName, notes].filter { !$0.isEmpty }.joined(separator: "\n")
        return set
    }
}

struct EventQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [EventEntity] {
        let wanted = Set(identifiers)
        return EventEntity.all().filter { wanted.contains($0.id) }
    }

    /// 제목 · 아이 이름 · 준비물 메모에서 찾는다(대소문자 · 악센트 무시).
    func entities(matching string: String) async throws -> [EventEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        func matches(_ s: String) -> Bool { s.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return EventEntity.all().filter { matches($0.title) || matches($0.childName) || matches($0.notes) }
    }

    /// 다가오는 일정부터.
    func suggestedEntities() async throws -> [EventEntity] {
        EventStore.upcoming(limit: 20).map(EventEntity.init)
    }
}

/// 일정을 연다. Spotlight · Siri 결과를 누르면 여기로 온다.
struct OpenEventIntent: OpenIntent {
    static let title = LocalizedStringResource("일정 열기", comment: "Siri/Spotlight: open a saved event")
    static let description = IntentDescription(
        LocalizedStringResource("저장한 일정을 달력에서 그 날로 엽니다.", comment: "Siri: open event description")
    )

    @Parameter(title: LocalizedStringResource("일정", comment: "Siri: event parameter"),
               description: LocalizedStringResource("열어 볼 저장한 일정", comment: "Siri: event parameter description"))
    var target: EventEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        ScanRouter.shared.eventDay = target.date
        return .result()
    }
}

enum EventIndex {
    /// 앱을 열 때 · 뒤로 보낼 때 부른다. 지운 일정이 남지 않게 비우고 다시 싣는다.
    static func reindex() async {
        guard #available(iOS 18.0, *) else { return }
        let index = CSSearchableIndex.default()
        try? await index.deleteAppEntities(ofType: EventEntity.self)
        try? await index.indexAppEntities(EventEntity.all())
    }
}

// MARK: - Siri 문구

struct CalendarSnapShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanNoticeIntent(),
            phrases: [
                "Scan a notice with \(.applicationName)",
                "Add events from a photo with \(.applicationName)"
            ],
            shortTitle: "Scan a Notice",
            systemImageName: "camera.viewfinder"
        )
    }
}
