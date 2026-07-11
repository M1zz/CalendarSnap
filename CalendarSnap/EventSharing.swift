import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// 일정을 배우자·가족에게 공유하기 위한 내보내기.
/// - .ics 파일: 받은 사람이 열면 자기 캘린더에 바로 추가 가능 (아이폰/안드로이드/PC 공통)
/// - 텍스트 요약: 카카오톡 등 메신저용
enum EventSharing {

    // MARK: - ICS (캘린더 파일)

    static func icsString(for events: [ScannedEvent]) -> String {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//devkoan//아이일정//KO",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
        ]

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyyMMdd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "yyyyMMdd'T'HHmmss"

        for event in events.sorted(by: { $0.date < $1.date }) {
            let title = event.childName.isEmpty ? event.title : "[\(event.childName)] \(event.title)"
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(event.id.uuidString)@calendarsnap")
            lines.append("SUMMARY:\(escape(title))")
            if !event.notes.isEmpty {
                lines.append("DESCRIPTION:\(escape(event.notes))")
            }
            if event.isAllDay {
                let day = Calendar.current.startOfDay(for: event.date)
                let next = day.addingTimeInterval(24 * 60 * 60)
                lines.append("DTSTART;VALUE=DATE:\(dayFormatter.string(from: day))")
                lines.append("DTEND;VALUE=DATE:\(dayFormatter.string(from: next))")
            } else {
                lines.append("DTSTART:\(timeFormatter.string(from: event.date))")
                lines.append("DTEND:\(timeFormatter.string(from: event.date.addingTimeInterval(3600)))")
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - 텍스트 요약 (메신저용)

    static func textSummary(for events: [ScannedEvent]) -> String {
        guard !events.isEmpty else { return "공유할 일정이 없어요." }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "ko_KR")
        dayFormatter.dateFormat = "M/d(E)"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "ko_KR")
        timeFormatter.dateFormat = "a h:mm"

        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "ko_KR")
        monthFormatter.dateFormat = "M월"
        let sorted = events.sorted { $0.date < $1.date }
        let month = monthFormatter.string(from: sorted[0].date)

        var out = ["📅 \(month) 아이 일정"]
        let grouped = Dictionary(grouping: sorted) { Calendar.current.startOfDay(for: $0.date) }
        for day in grouped.keys.sorted() {
            for event in grouped[day]!.sorted(by: { $0.date < $1.date }) {
                var line = "· \(dayFormatter.string(from: day))"
                if !event.isAllDay { line += " \(timeFormatter.string(from: event.date))" }
                if !event.childName.isEmpty { line += " [\(event.childName)]" }
                line += " \(event.title)"
                if !event.notes.isEmpty { line += " (\(event.notes))" }
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }
}

/// ShareLink용: 공유 시점에 .ics 파일을 생성하는 Transferable.
struct EventICSFile: Transferable {
    let events: [ScannedEvent]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .icsType) { file in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("아이일정.ics")
            try EventSharing.icsString(for: file.events)
                .write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

extension UTType {
    static var icsType: UTType {
        UTType(filenameExtension: "ics") ?? .data
    }
}
