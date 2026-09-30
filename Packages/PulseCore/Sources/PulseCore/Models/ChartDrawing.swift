import Foundation

/// A point in chart data coordinates. Times and prices are persisted directly;
/// screen coordinates are always derived by the chart that displays the anchor.
public struct ChartAnchor: Codable, Sendable, Hashable {
    public var time: Date
    public var price: Double

    public init(time: Date, price: Double) {
        self.time = time
        self.price = price
    }

    public var isValid: Bool {
        time.timeIntervalSince1970.isFinite && price.isFinite && price > 0
    }
}

/// Persisted geometry for a user drawing. A horizontal line is instrument-wide
/// and deliberately has no synthetic time anchor.
public enum ChartDrawingGeometry: Codable, Sendable, Hashable {
    case horizontal(price: Double)
    case trend(start: ChartAnchor, end: ChartAnchor)

    public var isValid: Bool {
        switch self {
        case .horizontal(let price):
            price.isFinite && price > 0
        case .trend(let start, let end):
            start.isValid && end.isValid
        }
    }
}

/// Period visibility for a chart drawing.
public enum ChartDrawingScope: Codable, Sendable, Hashable {
    case all
    case candles(period: CandlePeriod)
    case intraday(day: Date)

    public var isValid: Bool {
        switch self {
        case .all, .candles:
            true
        case .intraday(let day):
            day.timeIntervalSince1970.isFinite
        }
    }
}

public enum ChartDrawingColor: String, Codable, Sendable, CaseIterable, Hashable {
    case blue
    case orange
    case purple
    case gray
}

public struct ChartDrawingStyle: Codable, Sendable, Hashable {
    public var color: ChartDrawingColor
    public var lineWidth: Double

    public init(color: ChartDrawingColor = .blue, lineWidth: Double = 1.5) {
        self.color = color
        self.lineWidth = lineWidth
    }

    public var isValid: Bool {
        lineWidth.isFinite && lineWidth > 0
    }
}

/// A saved annotation belonging to one watchlist instrument.
public struct ChartDrawing: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var geometry: ChartDrawingGeometry
    public var scope: ChartDrawingScope
    public var style: ChartDrawingStyle
    public var note: String?
    public var isLocked: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Deletion is represented as data so an offline peer cannot restore an old
    /// copy of the drawing. Undo creates a new drawing identity.
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        geometry: ChartDrawingGeometry,
        scope: ChartDrawingScope = .all,
        style: ChartDrawingStyle = .init(),
        note: String? = nil,
        isLocked: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.geometry = geometry
        self.scope = scope
        self.style = style
        self.note = note
        self.isLocked = isLocked
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }

    public var isValid: Bool {
        let hasCompatibleScope: Bool
        switch (geometry, scope) {
        case (.horizontal(_), .all):
            hasCompatibleScope = true
        case (.trend(let start, let end), .candles(_)),
             (.trend(let start, let end), .intraday(_)):
            hasCompatibleScope = start.time != end.time || start.price != end.price
        default:
            hasCompatibleScope = false
        }
        return geometry.isValid
            && scope.isValid
            && style.isValid
            && hasCompatibleScope
            && createdAt.timeIntervalSince1970.isFinite
            && updatedAt.timeIntervalSince1970.isFinite
            && (deletedAt?.timeIntervalSince1970.isFinite ?? true)
    }

    /// Canonical persisted order, independent of dictionary/hash iteration.
    public static func ordered(_ drawings: [ChartDrawing]) -> [ChartDrawing] {
        drawings.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

/// Result of comparing two data-space anchors. `pointCount` counts distinct
/// actual sample timestamps in the inclusive interval, not calendar days or
/// an estimate based on elapsed time.
public struct ChartMeasurement: Sendable, Hashable {
    public let priceChange: Double
    public let priceChangePercent: Double
    public let elapsedSeconds: TimeInterval
    public let pointCount: Int

    public init?(start: ChartAnchor, end: ChartAnchor, sampleTimes: [Date]) {
        guard start.isValid, end.isValid else { return nil }
        let change = end.price - start.price
        let percent = change / start.price * 100
        let elapsed = abs(end.time.timeIntervalSince(start.time))
        guard change.isFinite, percent.isFinite, elapsed.isFinite else { return nil }

        let lower = min(start.time, end.time)
        let upper = max(start.time, end.time)
        let points = Set(sampleTimes.filter {
            $0.timeIntervalSince1970.isFinite && $0 >= lower && $0 <= upper
        })

        self.priceChange = change
        self.priceChangePercent = percent
        self.elapsedSeconds = elapsed
        self.pointCount = points.count
    }
}

/// Shared deterministic collection rules for local normalization, archive
/// import, and three-way snapshot convergence. Absence carries no deletion
/// meaning; only a tombstone can remove a drawing.
enum ChartDrawingMerge {
    static func merge(
        base: [ChartDrawing],
        local: [ChartDrawing],
        remote: [ChartDrawing]
    ) -> [ChartDrawing] {
        let b = map(base)
        let l = map(local)
        let r = map(remote)
        let ids = Set(b.keys).union(l.keys).union(r.keys)
        let merged = ids.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> ChartDrawing? in
            let baseDrawing = b[id]
            let localDrawing = l[id]
            let remoteDrawing = r[id]

            // A tombstone is permanent for this UUID. Its presence beats a
            // concurrent edit regardless of clock skew or which peer has it.
            let tombstones = [baseDrawing, localDrawing, remoteDrawing].compactMap { drawing in
                drawing?.isDeleted == true ? drawing : nil
            }
            if !tombstones.isEmpty {
                return tombstones.dropFirst().reduce(tombstones[0]) { current, next in
                    canonicalNewer(Optional(current), Optional(next))!
                }
            }

            if localDrawing == remoteDrawing { return localDrawing ?? baseDrawing }
            if localDrawing == baseDrawing { return remoteDrawing ?? baseDrawing }
            if remoteDrawing == baseDrawing { return localDrawing ?? baseDrawing }
            return canonicalNewer(localDrawing, remoteDrawing)
        }
        return ChartDrawing.ordered(merged)
    }

    /// Canonicalizes malformed duplicate IDs without making array order decide
    /// which peer's version survives.
    static func collapsed(_ drawings: [ChartDrawing]) -> [ChartDrawing] {
        merge(base: [], local: drawings, remote: [])
    }

    static func changedCount(local: [ChartDrawing], incoming: [ChartDrawing]) -> Int {
        let localByID = map(local)
        return merge(base: [], local: local, remote: incoming)
            .filter { localByID[$0.id] != $0 }
            .count
    }

    private static func map(_ drawings: [ChartDrawing]) -> [UUID: ChartDrawing] {
        var result: [UUID: ChartDrawing] = [:]
        for drawing in drawings where drawing.isValid {
            if let existing = result[drawing.id] {
                result[drawing.id] = canonicalNewer(Optional(existing), Optional(drawing))
            } else {
                result[drawing.id] = drawing
            }
        }
        return result
    }

    private static func canonicalNewer(_ lhs: ChartDrawing?, _ rhs: ChartDrawing?) -> ChartDrawing? {
        switch (lhs, rhs) {
        case (nil, let rhs): return rhs
        case (let lhs, nil): return lhs
        case (let lhs?, let rhs?):
            if lhs.isDeleted != rhs.isDeleted { return lhs.isDeleted ? lhs : rhs }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt ? lhs : rhs }
            return encoded(lhs).lexicographicallyPrecedes(encoded(rhs)) ? rhs : lhs
        }
    }

    private static func encoded(_ drawing: ChartDrawing) -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(drawing)).map(Array.init) ?? []
    }
}
