import WidgetKit
import SwiftUI

// MARK: - Timeline

struct ScheduleEntry: TimelineEntry {
    let date: Date
    let events: [ScannedEvent]
}

struct ScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry {
        ScheduleEntry(date: .now, events: Self.sampleEvents)
    }

    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        let events = context.isPreview ? Self.sampleEvents : EventStore.upcoming()
        completion(ScheduleEntry(date: .now, events: events))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        let events = EventStore.upcoming()
        let entry = ScheduleEntry(date: .now, events: events)

        // 다음 일정 시각 또는 30분 후 중 빠른 시점에 갱신
        let nextRefresh = min(
            events.first?.date ?? .now.addingTimeInterval(1800),
            .now.addingTimeInterval(1800))
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    static let sampleEvents: [ScannedEvent] = [
        ScannedEvent(title: "치과 예약", date: .now.addingTimeInterval(3600), rawText: ""),
        ScannedEvent(title: "팀 미팅", date: .now.addingTimeInterval(7200), rawText: ""),
        ScannedEvent(title: "발표 준비", date: .now.addingTimeInterval(86400), rawText: "")
    ]
}

// MARK: - Views

struct ScheduleWidgetEntryView: View {
    var entry: ScheduleEntry
    @Environment(\.widgetFamily) private var family

    /// 아이별 색상 구분용 (설정에 등록된 아이 순서 기준)
    private var children: [String] { ReminderSettingsStore.load().childNames }

    var body: some View {
        if entry.events.isEmpty {
            emptyView
        } else {
            switch family {
            case .systemSmall: smallView
            default: mediumView
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "camera.viewfinder")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("달력을 찍어\n일정을 등록하세요")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if let next = entry.events.first {
                Spacer(minLength: 2)
                if !next.childName.isEmpty {
                    Text(next.childName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(next.color(children: children))
                }
                Text(next.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(next.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(next.date, style: .relative)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(entry.events.prefix(3)) { event in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(event.childName.isEmpty ? AnyShapeStyle(.tint)
                              : AnyShapeStyle(event.color(children: children)))
                        .frame(width: 3, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if !event.childName.isEmpty {
                                Text(event.childName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(event.color(children: children))
                            }
                            Text(event.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                        Text(event.date, format: .dateTime.month().day().weekday().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(event.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar.badge.clock")
            Text("다가오는 일정")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tint)
    }
}

// MARK: - Widget

struct ScheduleWidget: Widget {
    let kind = "ScheduleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleProvider()) { entry in
            ScheduleWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("아이 일정")
        .description("어린이집 달력에서 추출한 다가오는 일정을 보여줍니다.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ScheduleWidgetBundle: WidgetBundle {
    var body: some Widget {
        ScheduleWidget()
    }
}

#Preview(as: .systemMedium) {
    ScheduleWidget()
} timeline: {
    ScheduleEntry(date: .now, events: ScheduleProvider.sampleEvents)
}
