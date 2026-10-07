import SwiftUI
import PulseCore

/// Calendar-day coordinates, including both ends of a manual range.
enum TradingEventTimelineLayout {
    static func span(event: InstrumentEvent, start: Date, dayCount: Int, calendar: Calendar) -> Range<Int>? {
        let first = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: event.date)).day ?? 0
        let last = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: event.endDate ?? event.date)).day ?? first
        guard dayCount > 0, last >= 0, first < dayCount, last >= first else { return nil }
        return max(0, first)..<min(dayCount, last + 1)
    }
}

struct TradingEventTimeline: View {
    private struct PlacedEvent: Identifiable {
        let entry: TradingEventEntry
        let span: Range<Int>
        let lane: Int
        let displayColumns: Int
        var id: String { entry.id }
    }

    let items: [WatchItem]
    let entries: [TradingEventEntry]
    let onSelect: (SymbolID) -> Void
    let onOpen: (TradingEventEntry) -> Void
    let onAdd: (SymbolID, Date) -> Void
    @State private var isMonth = true
    @State private var cursor = Date.now

    private var calendar: Calendar {
        var value = EastmoneyTradingEvents.dateCalendar
        value.firstWeekday = 2
        return value
    }
    private var start: Date {
        calendar.dateInterval(of: isMonth ? .month : .weekOfYear, for: cursor)?.start
            ?? calendar.startOfDay(for: cursor)
    }
    private var days: [Date] {
        let count = isMonth ? (calendar.range(of: .day, in: .month, for: cursor)?.count ?? 30) : 7
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    private var visibleCount: Int {
        entries.filter { TradingEventTimelineLayout.span(event: $0.event, start: start, dayCount: days.count, calendar: calendar) != nil }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            GeometryReader { geometry in
                let columnWidth = max(isMonth ? 24.0 : 90.0, (geometry.size.width - 196) / Double(max(1, days.count)))
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(items) { item in
                                timelineRow(item, columnWidth: columnWidth)
                            }
                        } header: {
                            dateHeader(columnWidth: columnWidth)
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
            HStack(spacing: 14) {
                Label(PulseLocalization.localizedString("timeline.legend.singleDay"), systemImage: "diamond.fill")
                Label(PulseLocalization.localizedString("timeline.legend.ranged"), systemImage: "rectangle.fill")
                Text(PulseLocalization.localizedString("timeline.legend.hint"))
                Spacer()
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .help(PulseLocalization.localizedString("timeline.previousHelp"))
                .accessibilityLabel(PulseLocalization.localizedString("timeline.previousLabel"))
            Button(PulseLocalization.localizedString("timeline.today")) { cursor = .now }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .help(PulseLocalization.localizedString("timeline.nextHelp"))
                .accessibilityLabel(PulseLocalization.localizedString("timeline.nextLabel"))
            Text(rangeTitle).font(.headline).monospacedDigit()
            Text(PulseLocalization.localizedString("timeline.eventCount", visibleCount)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker(PulseLocalization.localizedString("timeline.span.label"), selection: $isMonth) {
                Text(PulseLocalization.localizedString("timeline.span.week")).tag(false)
                Text(PulseLocalization.localizedString("timeline.span.month")).tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 100)
        }
        .controlSize(.small).padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func dateHeader(columnWidth: Double) -> some View {
        HStack(spacing: 0) {
            Text(PulseLocalization.localizedString("timeline.column.header"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 176, height: 54, alignment: .leading).padding(.leading, 20)
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 3) {
                        Text(day.formatted(dateStyle.day()))
                            .font(.system(size: 12, weight: isToday(day) ? .bold : .medium, design: .rounded))
                        if !isMonth {
                            Text(day.formatted(dateStyle.weekday(.abbreviated)))
                                .font(.system(size: 9))
                        }
                    }
                    .foregroundStyle(isToday(day) ? Color.accentColor : Color.secondary)
                    .frame(width: columnWidth, height: 54)
                    .background(isToday(day) ? Color.accentColor.opacity(0.1) : .clear)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func timelineRow(_ item: WatchItem, columnWidth: Double) -> some View {
        let placed = placeEvents(for: item.symbol, columnWidth: columnWidth)
        let height = Double(max(1, (placed.map(\.lane).max() ?? 0) + 1)) * 38 + 20
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Button { onSelect(item.symbol) } label: {
                    Text(item.resolvedDisplayName).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                }.buttonStyle(.plain)
                Text(item.symbol.displayCode).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(width: 156, height: height, alignment: .leading).padding(.horizontal, 20)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        Button { onAdd(item.symbol, day) } label: {
                            Rectangle().fill(isToday(day) ? Color.accentColor.opacity(0.055)
                                : calendar.isDateInWeekend(day) ? Color.secondary.opacity(0.04) : .clear)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(isToday(day) ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.1))
                                        .frame(width: isToday(day) ? 1.5 : 0.5)
                                }
                        }
                        .buttonStyle(.plain).frame(width: columnWidth, height: height)
                        .help(PulseLocalization.localizedString("timeline.day.addHelp", shortDate(day)))
                        .accessibilityLabel(PulseLocalization.localizedString(
                            "timeline.day.addLabel",
                            item.resolvedDisplayName,
                            shortDate(day)
                        ))
                    }
                }
                ForEach(placed) { event in
                    eventMark(event, width: Double(event.displayColumns) * columnWidth - 10)
                        .offset(x: Double(event.span.lowerBound) * columnWidth + 5, y: Double(event.lane) * 38 + 10)
                }
                if placed.isEmpty {
                    Text(PulseLocalization.localizedString("timeline.row.emptyHint")).font(.caption2).foregroundStyle(.tertiary)
                        .padding(.leading, 10).padding(.top, 20).allowsHitTesting(false)
                }
            }
            .frame(width: Double(days.count) * columnWidth, height: height)
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func eventMark(_ placed: PlacedEvent, width: Double) -> some View {
        let entry = placed.entry
        let ranged = entry.event.endDate.map { !calendar.isDate(entry.event.date, inSameDayAs: $0) } ?? false
        let color = eventColor(entry.event.kind)
        let dateRange = shortDate(entry.event.date)
            + (entry.event.endDate.map { " — " + shortDate($0) } ?? "")
        return Button { onOpen(entry) } label: {
            HStack(spacing: 5) {
                Image(systemName: ranged ? "rectangle.fill" : "diamond.fill").font(.system(size: 8))
                Text(entry.event.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if entry.isForecast { Text(PulseLocalization.localizedString("timeline.forecast")).font(.system(size: 8)).opacity(0.8) }
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8).frame(width: max(20, width), height: 28, alignment: .leading)
            .background(color.opacity(ranged ? 0.22 : 0.1), in: RoundedRectangle(cornerRadius: ranged ? 6 : 14))
            .overlay { RoundedRectangle(cornerRadius: ranged ? 6 : 14).stroke(color.opacity(0.4), lineWidth: 0.8) }
            .clipped()
        }
        .buttonStyle(.plain)
        // Event title, date range, and source are model data; only the two
        // labels around them are localized.
        .help(entry.isForecast
            ? PulseLocalization.localizedString("timeline.event.help.forecast", entry.event.title, dateRange, entry.sourceName)
            : PulseLocalization.localizedString("timeline.event.help", entry.event.title, dateRange, entry.sourceName))
        .accessibilityLabel(PulseLocalization.localizedString(
            "timeline.event.openLabel",
            entry.event.title,
            entry.sourceName
        ))
    }

    private func placeEvents(for symbol: SymbolID, columnWidth: Double) -> [PlacedEvent] {
        var laneEnds: [Int] = []
        var result: [PlacedEvent] = []
        for entry in entries where entry.symbol == symbol {
            guard let span = TradingEventTimelineLayout.span(event: entry.event, start: start, dayCount: days.count, calendar: calendar) else { continue }
            let ranged = entry.event.endDate.map { !calendar.isDate($0, inSameDayAs: entry.event.date) } ?? false
            // Reserve space for milestone labels so adjacent titles don't overlap.
            let columns = ranged ? span.count : min(days.count - span.lowerBound, max(1, Int(ceil(130 / columnWidth))))
            let end = span.lowerBound + columns
            let lane = laneEnds.firstIndex(where: { $0 <= span.lowerBound }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(end) } else { laneEnds[lane] = end }
            result.append(PlacedEvent(entry: entry, span: span, lane: lane, displayColumns: columns))
        }
        return result
    }

    private func eventColor(_ kind: InstrumentEvent.Kind) -> Color {
        switch kind {
        case .earnings: .purple
        case .dividend: .teal
        case .unlock: .orange
        case .other: .blue
        }
    }
    private var dateStyle: Date.FormatStyle { Date.FormatStyle(locale: .current, calendar: calendar, timeZone: calendar.timeZone) }
    private func isToday(_ day: Date) -> Bool { calendar.isDate(day, inSameDayAs: .now) }
    private func shortDate(_ date: Date) -> String { date.formatted(dateStyle.month().day()) }
    private var rangeTitle: String {
        isMonth ? start.formatted(dateStyle.year().month(.wide))
            : "\(shortDate(start)) — \(shortDate(days.last ?? start))"
    }
    private func shift(_ direction: Int) {
        cursor = calendar.date(byAdding: isMonth ? .month : .weekOfYear, value: direction, to: start) ?? cursor
    }
}
