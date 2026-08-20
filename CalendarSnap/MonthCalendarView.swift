import SwiftUI

/// 추출·저장된 일정을 월간 달력 그리드로 보여주는 화면.
/// 일정이 있는 날에는 점이 표시되고, 날짜를 누르면 아래에 그날 일정이 나옵니다.
struct MonthCalendarView: View {
    let events: [ScannedEvent]
    let children: [String]
    /// 선택한 날짜에 일정 직접 추가 (달력 탭 → "이 날 일정 추가")
    var onAddEvent: ((Date) -> Void)?
    /// 저장된 일정 삭제 (행을 밀어서)
    var onDelete: ((ScannedEvent) -> Void)?

    @State private var displayedMonth = Date()
    @State private var selectedDay: Date? = Calendar.current.startOfDay(for: Date())
    @State private var childFilter: String?          // nil = 통합(전체)
    @State private var typeFilter: TypeFilter = .all
    /// true면 선택한 주만 보이는 접힌 상태.
    /// 달력 탭의 본래 목적이 "오늘 무슨 일정이 있는지" 보는 것이라,
    /// 기본은 주간으로 접어 오늘 일정에 화면을 내준다. (핸들·스와이프로 월간 펼침)
    @State private var isWeekMode = true
    @State private var lastListOffset: CGFloat = 0

    private var calendar: Calendar { .current }
    private let koKR = Locale(identifier: "ko_KR")

    enum TypeFilter: String, CaseIterable, Identifiable {
        case all = "전체"
        case oneTime = "1회성"
        case recurring = "반복"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .all: return "list.bullet"
            case .oneTime: return "1.circle"
            case .recurring: return "repeat"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            monthHeader
                .padding(.horizontal)
                .padding(.vertical, 8)
            if registeredChildren.count >= 2 {
                childAvatarBar
                    .padding(.horizontal)
                    .padding(.bottom, 10)
            }
            weekdayHeader
            Group {
                if isWeekMode {
                    weekGrid
                } else {
                    monthGrid
                }
            }
            .padding(.horizontal, 8)
            // 달력 영역을 위로 쓸면 주간으로 접고, 아래로 쓸면 월간으로 펼침
            .gesture(
                DragGesture(minimumDistance: 15)
                    .onEnded { value in
                        if value.translation.height < -20 {
                            setWeekMode(true)
                        } else if value.translation.height > 20 {
                            setWeekMode(false)
                        }
                    }
            )
            collapseHandle
            Divider()
            eventList
        }
        .animation(.snappy(duration: 0.25), value: isWeekMode)
        // 앱 문구가 모두 한국어이므로 날짜 표기도 한국어로 고정
        .environment(\.locale, koKR)
        .toolbar {
            // 1회성/반복 필터는 우측 상단 메뉴로
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("일정 유형", selection: $typeFilter) {
                        ForEach(TypeFilter.allCases) { type in
                            Label(type.rawValue, systemImage: type.icon).tag(type)
                        }
                    }
                } label: {
                    Image(systemName: typeFilter == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
    }

    // MARK: - 아이 프로필 필터

    private var childAvatarBar: some View {
        HStack(spacing: 18) {
            ChildAvatarButton(name: nil, label: "전체",
                              children: registeredChildren,
                              isSelected: childFilter == nil) {
                withAnimation { childFilter = nil }
            }
            ForEach(registeredChildren, id: \.self) { name in
                ChildAvatarButton(name: name, label: name,
                                  children: registeredChildren,
                                  isSelected: childFilter == name) {
                    withAnimation { childFilter = name }
                }
            }
            Spacer()
        }
    }

    private var registeredChildren: [String] {
        children.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var filteredEvents: [ScannedEvent] {
        events.filter { event in
            if let childFilter, event.childName != childFilter { return false }
            switch typeFilter {
            case .all: return true
            case .oneTime: return !event.isRecurring
            case .recurring: return event.isRecurring
            }
        }
    }

    // MARK: - 데이터

    private var eventsByDay: [Date: [ScannedEvent]] {
        Dictionary(grouping: filteredEvents) { calendar.startOfDay(for: $0.date) }
    }

    /// 앞쪽 빈칸 포함 달력 셀 (nil = 빈칸)
    private var monthCells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth),
              let dayCount = calendar.range(of: .day, in: .month, for: interval.start)?.count
        else { return [] }
        let leading = calendar.component(.weekday, from: interval.start) - 1
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        return cells
    }

    private var selectedDayEvents: [ScannedEvent] {
        guard let selectedDay else { return [] }
        return (eventsByDay[calendar.startOfDay(for: selectedDay)] ?? [])
            .sorted { $0.date < $1.date }
    }

    private func nextEvent(after day: Date) -> ScannedEvent? {
        let dayEnd = calendar.startOfDay(for: day).addingTimeInterval(24 * 60 * 60)
        return filteredEvents.filter { $0.date >= dayEnd }.min { $0.date < $1.date }
    }

    // MARK: - 헤더

    private var monthHeader: some View {
        HStack {
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(displayedMonth, format: .dateTime.year().month(.wide).locale(koKR))
                .font(.headline)
            Spacer()
            Button("오늘") {
                displayedMonth = Date()
                selectedDay = calendar.startOfDay(for: Date())
            }
            .font(.subheadline)
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
        }
    }

    private func moveMonth(_ delta: Int) {
        if isWeekMode {
            // 주간 모드에서는 한 주씩 이동
            let anchor = selectedDay ?? displayedMonth
            if let next = calendar.date(byAdding: .weekOfYear, value: delta, to: anchor) {
                selectedDay = calendar.startOfDay(for: next)
                displayedMonth = next
            }
        } else if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = next
            selectedDay = nil
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) { i, name in
                Text(name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(i == 0 ? .red : i == 6 ? .blue : .secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - 접이식 (월간 ↔ 주간)

    private func setWeekMode(_ collapsed: Bool) {
        guard isWeekMode != collapsed else { return }
        withAnimation(.snappy(duration: 0.25)) { isWeekMode = collapsed }
    }

    /// 접힘/펼침 핸들 (탭으로도 전환 가능)
    private var collapseHandle: some View {
        Button {
            setWeekMode(!isWeekMode)
        } label: {
            Image(systemName: isWeekMode ? "chevron.compact.down" : "chevron.compact.up")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isWeekMode ? "월간 달력으로 펼치기" : "주간 달력으로 접기")
    }

    /// 선택한 날(없으면 오늘)이 속한 주.
    private var weekDays: [Date] {
        let anchor = selectedDay ?? displayedMonth
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchor) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private var weekGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
            ForEach(weekDays, id: \.self) { date in
                dayCell(date)
            }
        }
    }

    // MARK: - 그리드

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
            ForEach(Array(monthCells.enumerated()), id: \.offset) { _, date in
                if let date {
                    dayCell(date)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let day = calendar.component(.day, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let isToday = calendar.isDateInToday(date)
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        let dayEvents = eventsByDay[calendar.startOfDay(for: date)] ?? []

        return Button {
            selectedDay = date
        } label: {
            VStack(spacing: 3) {
                Text("\(day)")
                    .font(.callout.weight(isToday || isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white)
                                     : weekday == 1 ? AnyShapeStyle(.red)
                                     : weekday == 7 ? AnyShapeStyle(.blue)
                                     : AnyShapeStyle(.primary))
                    .frame(width: 32, height: 32)
                    .background {
                        if isSelected {
                            Circle().fill(.tint)
                        } else if isToday {
                            Circle().stroke(.tint, lineWidth: 1.5)
                        }
                    }
                HStack(spacing: 2) {
                    // 아이별 색으로 일정 점 표시 (통합 보기에서 구분)
                    ForEach(dayEvents.prefix(3)) { event in
                        Circle()
                            .fill(event.color(children: registeredChildren))
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 6)
            }
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 선택한 날 일정

    private var eventList: some View {
        List {
            // 스크롤 오프셋 마커: 목록을 위로 스크롤하면 달력을 주간으로 접음
            Color.clear
                .frame(height: 0)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ListScrollOffsetKey.self,
                                               value: geo.frame(in: .global).minY)
                    }
                )

            if let selectedDay {
                Section {
                    dayHeadline(selectedDay)
                        .listRowSeparator(.hidden)
                    if selectedDayEvents.isEmpty {
                        emptyDayRow(selectedDay)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(selectedDayEvents) { event in
                            eventRow(event)
                                .swipeActions(edge: .trailing) {
                                    if let onDelete {
                                        Button(role: .destructive) {
                                            onDelete(event)
                                        } label: {
                                            Label("삭제", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                }

                if onAddEvent != nil || !selectedDayEvents.isEmpty {
                    Section {
                        if let onAddEvent {
                            Button {
                                onAddEvent(selectedDay)
                            } label: {
                                Label("이 날 일정 추가", systemImage: "plus.circle.fill")
                            }
                        }
                        // 선택한 날 일정을 카카오톡 등으로 텍스트 공유
                        if !selectedDayEvents.isEmpty {
                            ShareLink(item: EventSharing.daySummary(for: selectedDayEvents, on: selectedDay)) {
                                Label("이 날 일정 공유하기", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }

                // 선택한 날에 일정이 없으면 다음 일정을 미리 보여줌
                if selectedDayEvents.isEmpty, let next = nextEvent(after: selectedDay) {
                    Section("다음 일정") {
                        HStack(alignment: .top, spacing: 12) {
                            Text(next.date, format: .dateTime.month().day().weekday().locale(koKR))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 64, alignment: .leading)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(next.title)
                                    .font(.subheadline.weight(.medium))
                                if !next.notes.isEmpty {
                                    Text(next.notes)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Text("날짜를 선택하면 일정이 표시됩니다")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)   // 마커 행이 공간을 차지하지 않도록
        .onPreferenceChange(ListScrollOffsetKey.self) { y in
            defer { lastListOffset = y }
            guard lastListOffset != 0 else { return }
            let delta = y - lastListOffset
            // 목록을 위로 스크롤(내용이 올라감) → 주간으로 접기
            if delta < -6, !isWeekMode {
                lastListOffset = 0   // 접히면서 생기는 레이아웃 변화 무시
                setWeekMode(true)
            }
        }
    }

    /// 선택한 날(기본 오늘)을 큼지막하게 알려주는 머리글.
    private func dayHeadline(_ day: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(dayLabel(day))
                .font(.largeTitle.bold())
                .foregroundStyle(calendar.isDateInToday(day) ? AnyShapeStyle(.tint)
                                                             : AnyShapeStyle(.primary))
            Text(day, format: .dateTime.month().day().weekday(.wide).locale(koKR))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if !selectedDayEvents.isEmpty {
                Text("\(selectedDayEvents.count)개")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    /// "오늘"·"내일"·"어제"는 그대로, 나머지는 요일로.
    private func dayLabel(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "오늘" }
        if calendar.isDateInTomorrow(day) { return "내일" }
        if calendar.isDateInYesterday(day) { return "어제" }
        return day.formatted(.dateTime.weekday(.wide).locale(koKR))
    }

    private func emptyDayRow(_ day: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(calendar.isDateInToday(day) ? "오늘은 챙길 일정이 없어요" : "이 날은 일정이 없어요")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func eventRow(_ event: ScannedEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(event.isAllDay ? "종일" : event.date.formatted(.dateTime.hour().minute().locale(koKR)))
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: 76, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if !event.childName.isEmpty {
                        Text(event.childName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(event.color(children: registeredChildren), in: Capsule())
                    }
                    Text(event.title)
                        .font(.title3.weight(.semibold))
                    if event.isRecurring {
                        Image(systemName: "repeat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !event.notes.isEmpty {
                    Text(event.notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// 일정 목록 스크롤 감지용 (위로 스크롤 시 달력 접기).
private struct ListScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    MonthCalendarView(events: [
        ScannedEvent(title: "현장체험 \"송도숲\"", date: .now, isAllDay: true,
                     notes: "자연 생태교육 동물체험", childName: "지호", rawText: ""),
        ScannedEvent(title: "생일파티", date: .now.addingTimeInterval(3600),
                     childName: "서연", rawText: ""),
    ], children: ["지호", "서연"])
}
