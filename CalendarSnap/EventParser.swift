import Foundation

/// OCR 텍스트 라인에서 일정을 추출하는 줄 단위 파서.
/// 달력 격자가 아닌 문서(가정통신문·안내문·목록형 일정표)에 사용됩니다.
///
/// 지원 패턴
/// - "7월 12일 치과 예약", "12일 14:00 팀 미팅", "7/15 오후 3시 발표"
/// - "여름캠프 : 7월 16일(목)"                       — 제목이 날짜 앞에 오는 통신문 스타일
/// - "7월 10일(금)은 브레인아토밍 활동이 있는 날입니다."  — 요일 괄호·문장 어미 정리
/// - "7월 13일(월): 만5세 - 7월 14일(화): 만4세"       — 한 줄에 여러 날짜
/// - "방학기간 : 7월 27일(월) ~ 8월 7일(금)"           — 기간 → 시작일 이벤트 + 종료일 메모
/// - NSDataDetector가 잡는 일반 날짜 표현 (영문 포함)
enum EventParser {

    /// OCR 관측(바운딩 박스 포함)으로 파싱.
    /// - 같은 가로줄(행)의 관측을 하나로 합쳐 표(날짜|장소|반명) 구조를 지원
    /// - 안내문·전단지처럼 날짜 줄에 라벨("일정 :", "교육일시")만 있는 경우
    ///   가장 큰 글씨 헤딩을 문서 제목으로 찾아 일정 제목으로 사용
    static func parse(recognized: [RecognizedLine], referenceDate: Date = Date()) -> [ScannedEvent] {
        parse(lines: mergeRows(recognized),
              referenceDate: referenceDate,
              docTitle: documentTitle(in: recognized))
    }

    /// 세로 위치(midY)가 비슷한 관측을 왼쪽→오른쪽 순으로 한 줄로 병합.
    /// 견학 안내 표처럼 "7월 7일 | 경주안전체험관 | 무궁화, 목련"이
    /// 별개 관측으로 나뉘어도 하나의 논리 행이 됩니다.
    private static func mergeRows(_ lines: [RecognizedLine]) -> [String] {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let ref = rows.last?.first,
               abs(ref.box.midY - line.box.midY) < max(0.008, min(ref.box.height, line.box.height) * 0.6) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }
    }

    // MARK: - 반(클래스) 필터

    /// 다른 반 전용 일정 제외. 문서에서 "OO반" 형태로 언급된 반 이름들을 수집한 뒤,
    /// 반 언급이 있는 일정 중 내 아이 반이 없는 것만 제외합니다 (반 언급 없는 일정은 유지).
    static func filterForClass(_ events: [ScannedEvent], className: String) -> [ScannedEvent] {
        let mine = className.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "반", with: "")
        guard !mine.isEmpty else { return events }

        // 문서 전체에서 언급된 반 이름 수집 ("무궁화반", "튤립반" …)
        var classSet: Set<String> = [mine]
        for event in events {
            for m in allMatches(in: event.rawText + " " + event.title,
                                pattern: #"([가-힣]{2,4})\s*반"#) {
                if let name = m[1] { classSet.insert(name) }
            }
        }
        guard classSet.count > 1 else { return events }   // 반 정보가 없는 문서는 그대로

        return events.filter { event in
            // rawText는 한 줄에서 나온 여러 일정이 공유하므로, 이벤트 고유 텍스트로만 판정
            let text = "\(event.title) \(event.notes)"
            let mentioned = classSet.filter { text.contains($0) }
            return mentioned.isEmpty || mentioned.contains(mine)
        }
    }

    static func parse(lines: [String], referenceDate: Date = Date(),
                      docTitle: String? = nil) -> [ScannedEvent] {
        var events: [ScannedEvent] = []
        let calendar = Calendar.current
        let refComponents = calendar.dateComponents([.year, .month], from: referenceDate)

        // 문서의 "N월" 헤더를 찾아 기준 월로 사용
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
            // 식단표 열량 표기 등 명백한 잡음 제외
            guard !trimmed.contains("kcal") else { continue }

            let parsed = parseKorean(line: trimmed,
                                     year: contextYear,
                                     fallbackMonth: contextMonth,
                                     calendar: calendar)
            if !parsed.isEmpty {
                events += parsed
            } else if let event = parseWithDataDetector(line: trimmed) {
                events.append(event)
            }
        }

        // 단건 안내문(일정이 적은 문서)은 라벨뿐인 제목을 문서 헤딩으로 대체
        if let docTitle, !docTitle.isEmpty, events.count <= 3 {
            events = events.map { event in
                var e = event
                if e.title == "일정" {
                    e.title = docTitle
                } else if let m = firstMatch(in: e.title,
                                             pattern: #"^([고교]육|행사)?\s*(일시|일정|날짜)\s*[::]?\s*"#) {
                    var leftover = e.title
                    leftover.removeSubrange(m.range)
                    leftover = cleanTitle(leftover)
                    e.title = docTitle
                    if e.notes.isEmpty { e.notes = leftover }   // 남은 텍스트(장소 등)는 메모로
                }
                return e
            }
        }

        // 중복 제거 (같은 날짜 + 같은 제목)
        var seen = Set<String>()
        return events.filter { event in
            seen.insert("\(event.title)|\(event.date.timeIntervalSince1970)").inserted
        }.sorted { $0.date < $1.date }
    }

    /// 문서에서 가장 큰 글씨의 짧은 한글 줄을 제목 후보로 선택.
    private static func documentTitle(in lines: [RecognizedLine]) -> String? {
        lines
            .filter { line in
                let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let hangul = t.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
                guard hangul >= 2, (2...20).contains(t.count) else { return false }
                // 날짜·시간이 들어있는 줄과 통신문류 제목은 제외
                guard t.range(of: #"\d\s*[월일]|\d{1,2}\s*:\s*\d{2}"#, options: .regularExpression) == nil,
                      t.range(of: #"통신문|알림장|가정통신"#, options: .regularExpression) == nil
                else { return false }
                return true
            }
            .max { $0.box.height < $1.box.height }
            .map {
                $0.text.trimmingCharacters(in: CharacterSet(charactersIn: " \t[]《》〈〉“”\"'*※·•-"))
            }
    }

    // MARK: - 한국어 패턴 (한 줄 → 여러 일정 가능)

    private static func parseKorean(line: String, year: Int, fallbackMonth: Int,
                                    calendar: Calendar) -> [ScannedEvent] {
        // 1. 라인의 날짜 위치 전부 수집
        var dates: [(month: Int, day: Int, range: Range<String.Index>)] = []
        // "2026년 7월 8일" 처럼 연도가 붙으면 연도까지 날짜로 흡수 (제목에 남지 않도록)
        let monthDayMatches = allMatches(in: line, pattern: #"(?:20\d{2}\s*년?\s*)?(\d{1,2})\s*월\s*(\d{1,2})\s*일"#)
        if !monthDayMatches.isEmpty {
            for m in monthDayMatches {
                if let month = Int(m[1] ?? ""), let day = Int(m[2] ?? ""),
                   (1...12).contains(month), (1...31).contains(day) {
                    dates.append((month, day, m.range))
                }
            }
        } else if let m = firstMatch(in: line, pattern: #"\b(\d{1,2})\s*/\s*(\d{1,2})\b"#),
                  let month = Int(m[1] ?? ""), let day = Int(m[2] ?? ""),
                  (1...12).contains(month), (1...31).contains(day) {
            dates.append((month, day, m.range))
        } else if let m = firstMatch(in: line, pattern: #"(\d{1,2})\s*일(?![간양])"#),
                  let day = Int(m[1] ?? ""), (1...31).contains(day) {
            // "5일간" 같은 기간 표현 제외
            dates.append((fallbackMonth, day, m.range))
        }
        guard !dates.isEmpty else { return [] }

        // 2. 시간 추출 (라인에서 첫 번째 발견)
        var hour: Int?
        var minute = 0
        var timeRange: Range<String.Index>?
        if let m = firstMatch(in: line, pattern: #"(오전|오후|[AaPp][Mm])?\s*(\d{1,2})\s*:\s*(\d{2})"#),
           let h = Int(m[2] ?? ""), let min = Int(m[3] ?? ""), h <= 23, min <= 59 {
            hour = adjust(h, marker: m[1]); minute = min; timeRange = m.range
        } else if let m = firstMatch(in: line, pattern: #"(오전|오후)?\s*(\d{1,2})\s*시(?!간)(?:\s*(\d{1,2})\s*분)?"#),
                  let h = Int(m[2] ?? ""), h <= 23 {
            hour = adjust(h, marker: m[1]); minute = Int(m[3] ?? "") ?? 0; timeRange = m.range
        }

        // 3. 날짜별 뒷부분 텍스트(다음 날짜 전까지) 세그먼트 계산
        var segments: [String] = []
        for (i, d) in dates.enumerated() {
            let segEnd = i + 1 < dates.count ? dates[i + 1].range.lowerBound : line.endIndex
            segments.append(String(line[d.range.upperBound..<segEnd]))
        }
        let prefix = String(line[..<dates[0].range.lowerBound])

        // 4. 세그먼트 → 일정
        //    - 날짜 사이가 "~"뿐이면 기간: 시작일 이벤트 하나 + "…까지" 메모
        //    - "… · 개학식 : 8월 10일" 처럼 라벨이 날짜 앞에 오면 다음 이벤트 제목으로 넘김
        var events: [ScannedEvent] = []
        var pendingTitle: String?
        var i = 0
        while i < dates.count {
            let d = dates[i]
            var notes = ""
            var segment = segments[i]

            // 기간 병합: 이번 세그먼트가 "(월) ~" 처럼 이어짐 표시뿐이면 다음 날짜는 종료일
            if i + 1 < dates.count,
               segment.range(of: #"^[\s()월화수목금토일]*[~∼–—-]\s*$"#, options: .regularExpression) != nil {
                let end = dates[i + 1]
                notes = "\(end.month)월 \(end.day)일까지"
                segment = segments[i + 1]
                i += 1
            }

            // 세그먼트 끝의 "· 라벨 :"은 다음 날짜의 제목
            var nextLabel: String?
            if let m = firstMatch(in: segment, pattern: #"[·•,]\s*([^·•,::]{1,25}?)\s*[::]\s*$"#) {
                nextLabel = m[1]
                segment.removeSubrange(m.range)
            }

            var text = pendingTitle ?? ((events.isEmpty ? prefix + " " : "") + segment)
            if let timeRange {
                text = text.replacingOccurrences(of: String(line[timeRange]), with: " ")
            }

            var title = cleanTitle(text)
            if title.isEmpty { title = cleanTitle(segment) }
            if title.isEmpty { title = "일정" }

            var components = DateComponents()
            components.year = year
            components.month = d.month
            components.day = d.day
            components.hour = hour ?? 0
            components.minute = hour == nil ? 0 : minute
            if let date = calendar.date(from: components) {
                events.append(ScannedEvent(title: title, date: date,
                                           isAllDay: hour == nil, notes: notes,
                                           rawText: line))
            }

            pendingTitle = nextLabel
            i += 1
        }
        return events
    }

    /// 통신문 문장에서 일정 제목만 남기도록 정리.
    private static func cleanTitle(_ raw: String) -> String {
        var t = raw

        // 요일 괄호 제거: "(금)", "( 월 )"
        t = t.replacingOccurrences(of: #"\(\s*[월화수목금토일]\s*\)"#,
                                   with: " ", options: .regularExpression)

        // 남아 있는 시간 표기 제거 ("~ 오후 15:00" 등 — 시간은 이미 추출됨)
        t = t.replacingOccurrences(of: #"(오전|오후|[AaPp][Mm])?\s*\d{1,2}\s*:\s*\d{2}"#,
                                   with: " ", options: .regularExpression)

        // 문장 어미부터 끝까지 제거 (통신문 존댓말)
        let endings = [
            #"(활동|행사|교육|일정)?\s*(이|가)?\s*(있는|열리는|진행되는|하는)\s*날\s*입니다.*$"#,
            #"(으로|로)\s*지정되었으니.*$"#,
            #"(을|를)?\s*(진행|운영|실시)(합니다|됩니다|했습니다).*$"#,
            #"(이|가)\s*이루어집니다.*$"#,
            #"입니다.*$"#, #"바랍니다.*$"#, #"부탁드립니다.*$"#,
            #"주시기\s*바.*$"#, #"해주세요.*$"#, #"주세요.*$"#,
            #"됩니다.*$"#, #"합니다.*$"#,
        ]
        for pattern in endings {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        // 앞쪽 불릿·기호 제거 (조사 제거보다 먼저!)
        t = t.replacingOccurrences(of: #"^[\s\-–—·•※◦▶►*:：,.~∼]+"#,
                                   with: "", options: .regularExpression)

        // 날짜 바로 뒤에 붙는 조사 제거 ("…일(금)은 브레인아토밍" → "브레인아토밍")
        t = t.replacingOccurrences(of: #"^(에는|에도|부터|까지|은|는|이|가|을|를|에)\s+"#,
                                   with: "", options: .regularExpression)

        // 구분 기호·불릿 정리
        t = t.replacingOccurrences(of: #"[·•※◦▶►|]+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \t:：-–—~,.'‘’\"“”*"))

        // 끝에 남은 조사 제거
        t = t.replacingOccurrences(of: #"\s*(이|가|은|는|을|를|에|의)$"#,
                                   with: "", options: .regularExpression)

        // 공백 정리
        return t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 오전/오후 표기 없는 1~6시는 어린이집 활동 특성상 오후로 간주.
    private static func adjust(_ hour: Int, marker: String?) -> Int {
        let normalized = marker?.lowercased()
        if normalized == "오후" || normalized == "pm", hour < 12 { return hour + 12 }
        if normalized == "오전" || normalized == "am" { return hour }
        return (1...6).contains(hour) ? hour + 12 : hour
    }

    // MARK: - NSDataDetector (영문 등 일반 날짜)

    private static func parseWithDataDetector(line: String) -> ScannedEvent? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = detector.firstMatch(in: line, range: range),
              let date = match.date,
              let matchRange = Range(match.range, in: line)
        else { return nil }

        // "15:30" 처럼 시간뿐인 표현은 날짜가 아님 (시간표 행 오인 방지)
        let matchedText = String(line[matchRange]).trimmingCharacters(in: .whitespaces)
        guard matchedText.range(of: #"^[\d:.\s~\-]+$"#, options: .regularExpression) == nil else { return nil }

        var title = line
        title.removeSubrange(matchRange)
        title = cleanTitle(title)
        if title.isEmpty { title = "일정" }

        return ScannedEvent(title: title, date: date, rawText: line)
    }

    // MARK: - Regex helpers

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
        allMatches(in: text, pattern: pattern).first
    }

    private static func allMatches(in text: String, pattern: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { result in
            guard let fullRange = Range(result.range, in: text) else { return nil }
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
}
