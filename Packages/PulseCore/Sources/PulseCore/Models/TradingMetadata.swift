import Foundation

public struct TradingProfile: Codable, Sendable, Hashable {
    public var sector: String?
    public var stopPrice: Double?
    public var targetPrice: Double?

    public init(sector: String? = nil, stopPrice: Double? = nil, targetPrice: Double? = nil) {
        self.sector = sector
        self.stopPrice = stopPrice
        self.targetPrice = targetPrice
    }

    var isValid: Bool {
        (stopPrice.map { $0.isFinite && $0 > 0 } ?? true)
            && (targetPrice.map { $0.isFinite && $0 > 0 } ?? true)
    }
}

public struct InstrumentEvent: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        case earnings
        case dividend
        case unlock
        case other
    }

    public var id: UUID
    public var kind: Kind
    public var date: Date
    /// Inclusive end date for a multi-day manual event. Nil is a single-day milestone.
    public var endDate: Date?
    public var title: String
    public var sourceURL: String?
    public var note: String?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        date: Date,
        title: String,
        endDate: Date? = nil,
        sourceURL: String? = nil,
        note: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.endDate = endDate
        self.title = title
        self.sourceURL = sourceURL
        self.note = note
        self.updatedAt = updatedAt
    }

    var isValid: Bool { normalized() != nil }

    func normalized() -> InstrumentEvent? {
        var result = self
        result.title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.note = result.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.note?.isEmpty == true { result.note = nil }
        result.sourceURL = result.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.sourceURL?.isEmpty == true { result.sourceURL = nil }
        guard !result.title.isEmpty,
              result.date.timeIntervalSince1970.isFinite,
              (result.endDate.map { $0.timeIntervalSince1970.isFinite && $0 >= result.date } ?? true),
              result.updatedAt.timeIntervalSince1970.isFinite,
              (result.sourceURL.map(Self.isValidSourceURL) ?? true) else { return nil }
        return result
    }

    static func isValidSourceURL(_ value: String) -> Bool {
        guard !value.contains(where: \.isWhitespace),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.url != nil else { return false }
        return components.port.map { (1...65_535).contains($0) } ?? true
    }

    static func ordered(_ events: [InstrumentEvent]) -> [InstrumentEvent] {
        events.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

enum InstrumentEventMerge {
    static func merge(
        base: [InstrumentEvent],
        local: [InstrumentEvent],
        remote: [InstrumentEvent]
    ) -> [InstrumentEvent] {
        let b = map(base)
        let l = map(local)
        let r = map(remote)
        return InstrumentEvent.ordered(Set(b.keys).union(l.keys).union(r.keys).compactMap { id in
            let baseEvent = b[id]
            let localEvent = l[id]
            let remoteEvent = r[id]
            if localEvent == remoteEvent { return localEvent }
            if localEvent == baseEvent { return remoteEvent }
            if remoteEvent == baseEvent { return localEvent }
            // A concurrent explicit deletion wins; two edits settle by timestamp.
            guard let localEvent, let remoteEvent else { return nil }
            if localEvent.updatedAt != remoteEvent.updatedAt {
                return localEvent.updatedAt > remoteEvent.updatedAt ? localEvent : remoteEvent
            }
            return encoded(localEvent).lexicographicallyPrecedes(encoded(remoteEvent))
                ? remoteEvent
                : localEvent
        })
    }

    static func collapsed(_ events: [InstrumentEvent]) -> [InstrumentEvent] {
        merge(base: [], local: events, remote: [])
    }

    private static func map(_ events: [InstrumentEvent]) -> [UUID: InstrumentEvent] {
        var result: [UUID: InstrumentEvent] = [:]
        for candidate in events {
            guard let event = candidate.normalized() else { continue }
            if let current = result[event.id] {
                if event.updatedAt > current.updatedAt
                    || (event.updatedAt == current.updatedAt
                        && encoded(current).lexicographicallyPrecedes(encoded(event))) {
                    result[event.id] = event
                }
            } else {
                result[event.id] = event
            }
        }
        return result
    }

    private static func encoded(_ event: InstrumentEvent) -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(event)).map(Array.init) ?? []
    }
}
