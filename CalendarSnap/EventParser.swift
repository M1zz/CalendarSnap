import Foundation

/// OCR로 뽑은 텍스트 라인에서 날짜/시간 + 일정 제목을 추출합니다.
///
/// 지원 패턴 예시
/// - "7월 12일 치과 예약"
/// - "12일 14:00 팀 미팅"
/// - "7/15 오후 3시 발표"
/// - NSDataDetector가 잡는 일반 날짜 표현 (영문 포함)
enum EventParser {

    static func parse(lines: [String], referenceDate: Date = Date()) -> [ScannedEvent] {
        var events: [ScannedEvent] = []
        let calendar = Calendar.current
        let refComponents = calendar.dateComponents([.year, .month], from: referenceDate)

        // 사진 속 달력의 "N월" 헤더를 찾아 기준 월로 사용
        var contextMonth = refComponents.month ?? 1
        var contextYear = refComponents.year ?? 2026
        for line in lines {
            if let m = firstMatch(in: line, pattern: #"(\d{1,2})\s*월"#),
               let month = Int(m[1] ?? ""), (1...12).contains(month) {
                contextMonth = month
                if let y = firstMatch(in: line, pattern: #"(20\d{2})"#), let year = Int(y[1] ?? "") {
                    contextYear = year
                }
                break
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { continue }

            if let event = parseKorean(line: trimmed,
                                       year: contextYear,
                                       fallbackMonth: contextMonth,
                                       calendar: calendar) {
                events.append(event)
            } else if let event = parseWithDataDetector(line: trimmed) {
                events.append(event)
            }
        }

        // 중복 제거 (같은 날짜 + 같은 제목)
        var seen = Set<String>()
        return events.filter { event in
            let key = "\(event.title)|\(event.date.timeIntervalSince1970)"
            return seen.insert(key).inserted
        }.sorted { $0.date < $1.date }
    }

    // MARK: - 한국어 패턴

    private static func parseKorean(line: String, year: Int, fallbackMonth: Int,
                                    calendar: Calendar) -> ScannedEvent? {
        var month = fallbackMonth
        var day: Int?
        var hour = 9, minute = 0   // 시간이 없으면 오전 9시 기본
        var consumedRanges: [Range<String.Index>] = []

        // "7월 12일" / "7/12" / "12일"
        if let m = firstMatch(in: line, pattern: #"(\d{1,2})\s*월\s*(\d{1,2})\s*일"#) {
            month = Int(m[1] ?? "") ?? month
            day = Int(m[2] ?? "")
            consumedRanges.append(m.range)
        } else if let m = firstMatch(in: line, pattern: #"\b(\d{1,2})\s*/\s*(\d{1,2})\b"#) {
            month = Int(m[1] ?? "") ?? month
            day = Int(m[2] ?? "")
            consumedRanges.append(m.range)
        } else if let m = firstMatch(in: line, pattern: #"(\d{1,2})\s*일"#) {
            day = Int(m[1] ?? "")
            consumedRanges.append(m.range)
        }

        guard let d = day, (1...31).contains(d), (1...12).contains(month) else { return nil }

        // "14:00" / "오후 3시" / "오전 10시 30분" / "3시"
        if let m = firstMatch(in: line, pattern: #"(\d{1,2}):(\d{2})"#) {
            hour = Int(m[1] ?? "") ?? hour
            minute = Int(m[2] ?? "") ?? 0
            consumedRanges.append(m.range)
        } else if let m = firstMatch(in: line, pattern: #"(오전|오후)?\s*(\d{1,2})\s*시\s*(\d{1,2})?\s*분?"#) {
            var h = Int(m[2] ?? "") ?? hour
            if m[1] == "오후", h < 12 { h += 12 }
            hour = h
            minute = Int(m[3] ?? "") ?? 0
            consumedRanges.append(m.range)
        }

        // 날짜/시간 부분을 지운 나머지를 제목으로
        var title = line
        for range in consumedRanges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            title.removeSubrange(range)
        }
        title = title
            .replacingOccurrences(of: #"[·•\-–—:,]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "일정" }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = d
        components.hour = hour
        components.minute = minute
        guard let date = calendar.date(from: components) else { return nil }

        return ScannedEvent(title: title, date: date, rawText: line)
    }

    // MARK: - NSDataDetector (영문 등 일반 날짜)

    private static func parseWithDataDetector(line: String) -> ScannedEvent? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = detector.firstMatch(in: line, range: range),
              let date = match.date,
              let matchRange = Range(match.range, in: line)
        else { return nil }

        var title = line
        title.removeSubrange(matchRange)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "일정" }

        return ScannedEvent(title: title, date: date, rawText: line)
    }

    // MARK: - Regex helper

    private struct Match {
        let range: Range<String.Index>
        private let groups: [String?]
        subscript(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
        init(range: Range<String.Index>, groups: [String?]) {
            self.range = range
            self.groups = groups
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, range: nsRange),
              let fullRange = Range(result.range, in: text) else { return nil }

        var groups: [String?] = []
        for i in 0..<result.numberOfRanges {
            if let r = Range(result.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append(nil)
            }
        }
        return Match(range: fullRange, groups: groups)
    }
}
