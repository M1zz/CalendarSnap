import Foundation
import CoreGraphics

/// Vision OCR 관측 하나: 텍스트 + 정규화 바운딩 박스 (원점 좌하단, 0~1).
struct RecognizedLine {
    let text: String
    let box: CGRect
    var centerX: CGFloat { box.midX }
    var centerY: CGFloat { box.midY }
}

/// 달력 "격자" 사진 전용 파서.
///
/// 어린이집 월간 달력처럼 날짜 숫자와 일정 텍스트가 셀 안에 흩어져 있으면
/// 줄 단위 파싱(EventParser)으로는 날짜↔일정을 연결할 수 없습니다.
/// 이 파서는 OCR 바운딩 박스로 요일 헤더와 날짜 격자를 복원한 뒤
/// 각 텍스트를 해당 날짜 셀에 매칭합니다.
///
/// - "Sun Mon …" / "일 월 화 …" 요일 헤더로 7개 컬럼 위치 추정 (OCR 오타 허용: Son, Tho)
/// - 셀의 날짜 숫자(1~31)로 행 위치 추정, 스티커 등으로 가려진 날짜는 격자 산술로 복원
/// - 헤더 위 텍스트에서 월/년 추출 ("7월", "7 JULY 2026"), 1일의 요일 배치로 교차 검증
/// - "*월요일 3시: 꼬미꼬미 오감퍼포먼스" 형태는 매주 반복 특별활동으로 한 달 치 전개
enum CalendarGridParser {

    static func parse(lines: [RecognizedLine], referenceDate: Date = Date()) -> [ScannedEvent] {
        let calendar = Calendar.current
        guard let header = detectHeader(in: lines) else { return [] }
        let colSpacing = header.columnCenters[1] - header.columnCenters[0]

        // 1. 헤더 아래 관측을 날짜 숫자 / 일반 텍스트로 분리
        var dayNumbers: [(day: Int, col: Int, y: CGFloat)] = []
        var textLines: [RecognizedLine] = []
        for line in lines where line.centerY < header.y - 0.01 {
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let day = Int(t), (1...31).contains(day), line.box.width < colSpacing * 0.5,
               let col = nearestColumn(x: line.centerX, centers: header.columnCenters, maxDistance: colSpacing * 0.6) {
                dayNumbers.append((day, col, line.centerY))
            } else {
                textLines.append(line)
            }
        }
        guard dayNumbers.count >= 5 else { return [] }

        // 2. 날짜 숫자의 y 좌표로 행 복원
        let rowCenters = clusterRows(ys: dayNumbers.map(\.y))
        let rowSpacing = medianSpacing(of: rowCenters) ?? 0.12

        // 3. 격자 오프셋(1일이 놓인 컬럼) 최빈값 — 오인식된 숫자 방어
        //    첫 주 행이 통째로 안 읽히면(1일이 토요일인데 그림에 가려진 경우 등)
        //    행 인덱스가 한 주씩 밀려 offset이 음수로 나온다. 7의 배수만큼 밀린
        //    것이므로 날짜 산술(row*7 + col - offset + 1)은 그대로 성립한다.
        var offsetVotes: [Int: Int] = [:]
        for dn in dayNumbers {
            guard let row = rowIndex(forDayNumberY: dn.y, rowCenters: rowCenters, rowSpacing: rowSpacing) else { continue }
            offsetVotes[row * 7 + dn.col - (dn.day - 1), default: 0] += 1
        }
        guard let offset = offsetVotes.max(by: { $0.value < $1.value })?.key,
              (-28...6).contains(offset) else { return [] }

        // 4. 월/년 결정 (헤더 텍스트 + 1일 요일 배치 교차 검증)
        let firstWeekday = (header.startWeekday + offset % 7 + 7) % 7
        let (year, month) = resolveMonthYear(lines: lines, headerY: header.y,
                                             firstWeekday: firstWeekday,
                                             referenceDate: referenceDate, calendar: calendar)
        var firstOfMonth = DateComponents()
        firstOfMonth.year = year; firstOfMonth.month = month; firstOfMonth.day = 1
        guard let firstDate = calendar.date(from: firstOfMonth),
              let daysInMonth = calendar.range(of: .day, in: .month, for: firstDate)?.count
        else { return [] }

        // 5. 텍스트를 날짜 셀에 배정
        var cells: [Int: [RecognizedLine]] = [:]
        var unassigned: [RecognizedLine] = []
        for line in textLines {
            guard hasContent(line.text), !isNoise(line.text) else { continue }
            // 특별활동 시간표 범례는 격자 왼쪽에 붙어 있어 첫 주 셀로 빨려들어간다.
            // 셀 배정보다 먼저 걸러 매주 반복 일정으로 전개되게 한다.
            if firstMatch(in: line.text, pattern: recurringPattern) != nil {
                unassigned.append(line)
                continue
            }
            guard let col = nearestColumn(x: line.centerX, centers: header.columnCenters, maxDistance: colSpacing * 0.75)
            else { unassigned.append(line); continue }

            var row = rowIndex(forTextY: line.centerY, rowCenters: rowCenters, rowSpacing: rowSpacing)
            if row == nil, hangulCount(of: line.text) >= 2 {
                // 일정 누락 방지가 1순위: 한글 텍스트는 행 판정에 실패해도
                // 가장 가까운 행에 강제 배정 (영문 장식·잡음은 제외)
                row = nearestRowIndex(y: line.centerY, rowCenters: rowCenters)
            }
            guard let row else { unassigned.append(line); continue }

            let day = row * 7 + col - offset + 1
            if (1...daysInMonth).contains(day) {
                cells[day, default: []].append(line)
            } else {
                unassigned.append(line)
            }
        }

        // 6. 셀 → 일정
        var events: [ScannedEvent] = []
        for (day, cellLines) in cells {
            if let event = makeEvent(day: day, cellLines: cellLines,
                                     year: year, month: month, calendar: calendar) {
                events.append(event)
            }
        }

        // 7. 배정되지 않은 텍스트에서 매주 반복 특별활동 전개
        events += recurringEvents(from: unassigned, year: year, month: month,
                                  daysInMonth: daysInMonth, calendar: calendar)

        // 8. 중복 제거 + 정렬
        var seen = Set<String>()
        return events
            .filter { seen.insert("\($0.title)|\($0.date.timeIntervalSince1970)").inserted }
            .sorted { $0.date < $1.date }
    }

    // MARK: - 셀 → 일정

    private static func makeEvent(day: Int, cellLines: [RecognizedLine],
                                  year: Int, month: Int, calendar: Calendar) -> ScannedEvent? {
        // 위→아래, 왼→오른쪽 순으로 셀 안 텍스트 정리
        let ordered = cellLines.sorted {
            abs($0.centerY - $1.centerY) > 0.008 ? $0.centerY > $1.centerY : $0.centerX < $1.centerX
        }
        var texts = ordered.map { cleanCellText($0.text) }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return nil }

        // 시간 추출 (셀 안 어느 줄이든 처음 발견된 것)
        var hour: Int?
        var minute = 0
        for (i, t) in texts.enumerated() {
            if let (rest, h, m) = extractTime(from: t) {
                hour = h; minute = m
                texts[i] = rest
                break
            }
        }
        texts = texts.filter { !$0.isEmpty }
        let joined = texts.joined(separator: " ")
        guard !joined.isEmpty else { return nil }

        // 짧으면 전체가 제목, 길면 첫 줄(짧으면 두 줄)이 제목·나머지는 메모
        var title: String
        var notes = ""
        if joined.count <= 18 || texts.count == 1 {
            title = joined
        } else {
            let titleLineCount = (texts[0].count < 6 && texts.count > 1) ? 2 : 1
            title = texts.prefix(titleLineCount).joined(separator: " ")
            notes = texts.dropFirst(titleLineCount).joined(separator: " ")
        }

        var comp = DateComponents()
        comp.year = year; comp.month = month; comp.day = day
        comp.hour = hour ?? 0
        comp.minute = hour == nil ? 0 : minute
        guard let date = calendar.date(from: comp) else { return nil }

        return ScannedEvent(title: title, date: date, isAllDay: hour == nil, notes: notes,
                            rawText: "\(month)/\(day) " + ordered.map(\.text).joined(separator: " "))
    }

    // MARK: - 매주 반복 특별활동

    /// "*월요일 3시 : 꼬미꼬미 오감퍼포먼스", "목요일 3시30분 : 드림 유아체육"
    private static let recurringPattern =
        #"(월|화|수|목|금|토|일)\s*요일\s*[::]?\s*(\d{1,2})\s*시\s*(?:(\d{1,2})\s*분)?\s*[::]?\s*(.+)"#

    private static func recurringEvents(from unassigned: [RecognizedLine],
                                        year: Int, month: Int, daysInMonth: Int,
                                        calendar: Calendar) -> [ScannedEvent] {
        let koreanWeekdays = ["일", "월", "화", "수", "목", "금", "토"]
        var events: [ScannedEvent] = []
        for line in unassigned {
            guard let m = firstMatch(in: line.text, pattern: recurringPattern),
                  let weekdayStr = m[1],
                  let weekdayIndex = koreanWeekdays.firstIndex(of: weekdayStr),
                  let rawHour = Int(m[2] ?? "")
            else { continue }
            let title = (m[4] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let hour = adjustDaytime(rawHour)
            let minute = Int(m[3] ?? "") ?? 0

            for day in 1...daysInMonth {
                var comp = DateComponents()
                comp.year = year; comp.month = month; comp.day = day
                comp.hour = hour; comp.minute = minute
                guard let date = calendar.date(from: comp),
                      calendar.component(.weekday, from: date) - 1 == weekdayIndex else { continue }
                events.append(ScannedEvent(title: title, date: date, isAllDay: false,
                                           notes: "매주 \(weekdayStr)요일 특별활동",
                                           isRecurring: true,
                                           rawText: line.text))
            }
        }
        return events
    }

    // MARK: - 방향 선택용 점수

    /// 이 관측 묶음이 "달력 격자"로 얼마나 잘 읽혔는지 점수화 (0 = 달력 아님).
    ///
    /// 옆으로 찍힌 사진은 잘못된 방향에서도 글자 수는 꽤 나오지만
    /// 날짜 숫자가 거의 안 읽힌다. 줄 수 대신 이 점수로 방향을 고르면
    /// 회전된 달력 사진도 제대로 된 방향을 찾을 수 있다.
    static func calendarScore(lines: [RecognizedLine]) -> Int {
        var weekdayYs: [CGFloat] = []
        var dayNumbers = 0
        for line in lines {
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if weekdayIndex(of: t) != nil {
                weekdayYs.append(line.centerY)
            } else if let d = Int(t), (1...31).contains(d) {
                dayNumbers += 1
            }
        }
        // 요일 헤더는 한 줄에 나란히 있어야 인정 (본문 속 "월"·"토" 오검출 방어)
        let headerHits = weekdayYs.map { y in weekdayYs.filter { abs($0 - y) < 0.02 }.count }.max() ?? 0
        guard headerHits >= 4 else { return 0 }
        return headerHits * 10 + dayNumbers
    }

    /// 더 볼 것 없이 이 방향을 써도 되는 수준인지.
    /// (요일 헤더 5개 + 날짜 숫자 20개 수준. 똑바로 찍힌 달력은 대개 90점을 넘는다.)
    static func isConfidentCalendar(score: Int) -> Bool { score >= 70 }

    // MARK: - 요일 헤더

    private struct Header {
        let y: CGFloat                 // 헤더 행의 y 중심
        let columnCenters: [CGFloat]   // 물리적 컬럼 0~6의 x 중심
        let startWeekday: Int          // 컬럼 0의 요일 (0=일요일)
    }

    private static func detectHeader(in lines: [RecognizedLine]) -> Header? {
        var matches: [(weekday: Int, x: CGFloat, y: CGFloat)] = []
        for line in lines {
            if let w = weekdayIndex(of: line.text) {
                matches.append((w, line.centerX, line.centerY))
            }
        }
        guard matches.count >= 4 else { return nil }

        // 요일 헤더는 한 줄에 나란히 → 가장 큰 y 클러스터 선택
        var best: [(weekday: Int, x: CGFloat, y: CGFloat)] = []
        for m in matches {
            let cluster = matches.filter { abs($0.y - m.y) < 0.02 }
            if cluster.count > best.count { best = cluster }
        }
        var seenWeekday = Set<Int>()
        let unique = best.sorted { $0.x < $1.x }.filter { seenWeekday.insert($0.weekday).inserted }
        guard unique.count >= 4 else { return nil }

        // 시작 요일 추정: x 순서대로 요일이 (start + 컬럼) mod 7 로 증가해야 함
        for start in 0..<7 {
            let positions = unique.map { ($0.weekday - start + 7) % 7 }
            guard positions == positions.sorted(), Set(positions).count == positions.count,
                  positions.last! < 7 else { continue }

            // 최소제곱 직선 적합으로 7개 컬럼 중심 계산
            let n = CGFloat(positions.count)
            let sumP = CGFloat(positions.reduce(0, +))
            let sumX = unique.map(\.x).reduce(0, +)
            let sumPX = zip(positions, unique).map { CGFloat($0) * $1.x }.reduce(0, +)
            let sumPP = CGFloat(positions.map { $0 * $0 }.reduce(0, +))
            let denom = n * sumPP - sumP * sumP
            guard denom > 0 else { continue }
            let slope = (n * sumPX - sumP * sumX) / denom
            guard slope > 0.01 else { continue }
            let intercept = (sumX - slope * sumP) / n

            return Header(y: unique.map(\.y).reduce(0, +) / n,
                          columnCenters: (0..<7).map { intercept + slope * CGFloat($0) },
                          startWeekday: start)
        }
        return nil
    }

    /// "Sun"/"Son"/"Tho"/"일"/"월요일" 등에서 요일 인덱스(0=일) 추출. OCR 오타 허용.
    private static func weekdayIndex(of raw: String) -> Int? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let korean = ["일", "월", "화", "수", "목", "금", "토"]
        if let i = korean.firstIndex(where: { t == $0 || t == $0 + "요일" }) { return i }
        guard (2...5).contains(t.count), t.allSatisfy({ $0.isLetter }) else { return nil }
        let english: [(prefixes: [String], index: Int)] = [
            (["sun", "son"], 0), (["mon"], 1), (["tue", "tus"], 2), (["wed"], 3),
            (["thu", "tho"], 4), (["fri"], 5), (["sat"], 6),
        ]
        for (prefixes, i) in english where prefixes.contains(where: { t.hasPrefix($0) }) { return i }
        return nil
    }

    // MARK: - 월/년 결정

    private static func resolveMonthYear(lines: [RecognizedLine], headerY: CGFloat,
                                         firstWeekday: Int, referenceDate: Date,
                                         calendar: Calendar) -> (year: Int, month: Int) {
        var headerMonth: Int?
        var headerYear: Int?
        let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                          "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

        for line in lines where line.centerY > headerY {
            let text = line.text
            if headerYear == nil, let m = firstMatch(in: text, pattern: #"\b(20\d{2})\b"#) {
                headerYear = Int(m[1] ?? "")
            }
            if headerMonth == nil {
                if let m = firstMatch(in: text, pattern: #"(\d{1,2})\s*월"#),
                   let mo = Int(m[1] ?? ""), (1...12).contains(mo) {
                    headerMonth = mo
                } else if let m = firstMatch(in: text, pattern: #"\b(\d{1,2})\b\s*[A-Za-z]{3,}"#),
                          let mo = Int(m[1] ?? ""), (1...12).contains(mo) {
                    // "7 JULY" (OCR 오타 "7 JUI"도 허용)
                    headerMonth = mo
                } else {
                    let lower = text.lowercased()
                    if let hit = monthNames.first(where: { lower.contains($0.key) }) {
                        headerMonth = hit.value
                    }
                }
            }
        }

        let year = headerYear ?? calendar.component(.year, from: referenceDate)
        let wanted = headerMonth ?? calendar.component(.month, from: referenceDate)

        // 1일의 요일 배치와 맞는 달만 후보로 (헤더 오인식 교정)
        var candidates: [Int] = []
        for m in 1...12 {
            var comp = DateComponents()
            comp.year = year; comp.month = m; comp.day = 1
            if let d = calendar.date(from: comp),
               calendar.component(.weekday, from: d) - 1 == firstWeekday {
                candidates.append(m)
            }
        }
        if candidates.isEmpty || candidates.contains(wanted) { return (year, wanted) }
        let best = candidates.min { abs($0 - wanted) < abs($1 - wanted) } ?? wanted
        return (year, best)
    }

    // MARK: - 격자 기하

    private static func nearestColumn(x: CGFloat, centers: [CGFloat], maxDistance: CGFloat) -> Int? {
        guard let (i, d) = centers.enumerated().map({ ($0.offset, abs($0.element - x)) })
            .min(by: { $0.1 < $1.1 }) else { return nil }
        return d <= maxDistance ? i : nil
    }

    private static func clusterRows(ys: [CGFloat]) -> [CGFloat] {
        var clusters: [[CGFloat]] = []
        for y in ys.sorted(by: >) {
            if let last = clusters.last?.last, abs(last - y) < 0.05 {
                clusters[clusters.count - 1].append(y)
            } else {
                clusters.append([y])
            }
        }
        return clusters.map { $0.reduce(0, +) / CGFloat($0.count) }
    }

    private static func medianSpacing(of rowCenters: [CGFloat]) -> CGFloat? {
        guard rowCenters.count >= 2 else { return nil }
        let diffs = zip(rowCenters, rowCenters.dropFirst()).map { $0 - $1 }.sorted()
        return diffs[diffs.count / 2]
    }

    private static func rowIndex(forDayNumberY y: CGFloat, rowCenters: [CGFloat], rowSpacing: CGFloat) -> Int? {
        guard let (i, rc) = rowCenters.enumerated().min(by: { abs($0.element - y) < abs($1.element - y) })
        else { return nil }
        return abs(rc - y) <= rowSpacing * 0.45 ? i : nil
    }

    /// 셀 텍스트는 날짜 숫자보다 아래에 있으므로, 위 행이 우선권을 가짐.
    private static func rowIndex(forTextY y: CGFloat, rowCenters: [CGFloat], rowSpacing: CGFloat) -> Int? {
        for (i, rc) in rowCenters.enumerated() {   // rowCenters는 위(y 큰 쪽)부터 정렬됨
            if y <= rc + rowSpacing * 0.35, y > rc - rowSpacing * 0.92 { return i }
        }
        return nil
    }

    private static func nearestRowIndex(y: CGFloat, rowCenters: [CGFloat]) -> Int? {
        rowCenters.enumerated().min { abs($0.element - y) < abs($1.element - y) }?.offset
    }

    private static func hangulCount(of text: String) -> Int {
        text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
    }

    // MARK: - 텍스트 정리

    private static func hasContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// 일정이 될 수 없는 장식·표기 텍스트.
    /// 일정 누락 방지가 1순위이므로 확실한 것만 최소한으로 거른다.
    private static func isNoise(_ text: String) -> Bool {
        let t = cleanCellText(text)
        // "23/30", "24/31" 처럼 두 날짜를 한 칸에 표기한 것
        if firstMatch(in: t, pattern: #"^\d{1,2}\s*/\s*\d{1,2}$"#) != nil { return true }
        // 템플릿 워터마크 ("Designed by Pngtree")
        let lower = t.lowercased()
        if lower.contains("designed by") || lower.contains("pngtree") { return true }
        // 특별활동 시간표 범례의 제목 줄 (실제 일정은 recurringEvents가 만든다)
        if t.contains("특별활동") && t.contains("시간표") { return true }
        return false
    }

    private static func cleanCellText(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: ">‹<>»«|*・•,;· ").union(.whitespacesAndNewlines))
    }

    /// "오후 3시", "3시 30분", "14:00" 추출. 발견 시 (시간 제거된 텍스트, 시, 분) 반환.
    private static func extractTime(from text: String) -> (rest: String, hour: Int, minute: Int)? {
        if let m = firstMatch(in: text, pattern: #"(오전|오후)?\s*(\d{1,2})\s*:\s*(\d{2})"#),
           let h = Int(m[2] ?? ""), let min = Int(m[3] ?? ""), h <= 23, min <= 59 {
            return (removing(m.range, from: text), adjust(h, marker: m[1]), min)
        }
        if let m = firstMatch(in: text, pattern: #"(오전|오후)?\s*(\d{1,2})\s*시(?!간)(?:\s*(\d{1,2})\s*분)?"#),
           let h = Int(m[2] ?? ""), h <= 23 {
            return (removing(m.range, from: text), adjust(h, marker: m[1]), Int(m[3] ?? "") ?? 0)
        }
        return nil
    }

    private static func adjust(_ hour: Int, marker: String?) -> Int {
        if marker == "오후", hour < 12 { return hour + 12 }
        if marker == "오전" { return hour }
        return adjustDaytime(hour)
    }

    /// 오전/오후 표기가 없는 1~6시는 어린이집 활동 특성상 오후로 간주.
    private static func adjustDaytime(_ hour: Int) -> Int {
        (1...6).contains(hour) ? hour + 12 : hour
    }

    private static func removing(_ range: Range<String.Index>, from text: String) -> String {
        var t = text
        t.removeSubrange(range)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
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
