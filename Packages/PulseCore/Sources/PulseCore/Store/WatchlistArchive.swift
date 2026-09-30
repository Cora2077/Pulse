import Foundation

/// A portable, hand-writable snapshot of watchlists and their positions.
///
/// The on-disk `pulse.watchlists.v2` blob is an implementation detail: it stores
/// UUIDs, provider watermarks, and a derived legacy lot cache that only make sense
/// inside one installation. This archive is the user-facing shape instead — lists
/// are identified by name, instruments by market and code — so it survives a
/// reinstall, moves between Macs, and can be typed by hand to bulk-add symbols.
///
/// Everything except `market` and `code` is optional. An entry as small as
/// `{"market": "us", "code": "NVDA"}` imports correctly; the display name is then
/// filled in by the first quote refresh, the same path that upgrades watchlists
/// written by older Pulse versions.
public struct WatchlistArchive: Codable, Sendable, Equatable {
    public static let formatIdentifier = "pulse.watchlist"
    public static let currentVersion = 2
    private static let unixReferenceOffset: TimeInterval = 978_307_200

    public var format: String
    public var version: Int
    public var exportedAt: Date?
    public var app: String?
    public var lists: [List]

    public struct List: Codable, Sendable, Equatable {
        public var name: String
        public var entries: [Entry]

        public init(name: String, entries: [Entry]) {
            self.name = name
            self.entries = entries
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        /// Kept as written rather than as a `Market`. A typo in one entry should
        /// cost the user that row, not the whole import, so the market is resolved
        /// per entry and reported instead of failing the decode.
        public var market: String
        public var code: String
        public var name: String?
        public var type: InstrumentType?
        public var pinned: Bool?
        public var transactions: [PositionTransaction]?
        /// The user's own reason for holding the instrument, carried through an
        /// export so the reasoning survives a reinstall with the position.
        public var thesis: String?
        /// What the user intends to do at which price. Optional and absent
        /// unless there is one, so a hand-written archive stays as short as the
        /// `{"market": "us", "code": "NVDA"}` example promises.
        public var plans: [TradePlan]?
        /// Saved chart annotations. Optional so version 1 archives remain
        /// readable and minimal hand-written entries stay concise.
        public var drawings: [ChartDrawing]?

        public init(
            market: String,
            code: String,
            name: String? = nil,
            type: InstrumentType? = nil,
            pinned: Bool? = nil,
            transactions: [PositionTransaction]? = nil,
            thesis: String? = nil,
            plans: [TradePlan]? = nil,
            drawings: [ChartDrawing]? = nil
        ) {
            self.market = market
            self.code = code
            self.name = name
            self.type = type
            self.pinned = pinned
            self.transactions = transactions
            self.thesis = thesis
            self.plans = plans
            self.drawings = drawings
        }

        public init(
            market: Market,
            code: String,
            name: String? = nil,
            type: InstrumentType? = nil,
            pinned: Bool? = nil,
            transactions: [PositionTransaction]? = nil,
            thesis: String? = nil,
            plans: [TradePlan]? = nil,
            drawings: [ChartDrawing]? = nil
        ) {
            self.init(
                market: market.rawValue,
                code: code,
                name: name,
                type: type,
                pinned: pinned,
                transactions: transactions,
                thesis: thesis,
                plans: plans,
                drawings: drawings
            )
        }

        /// What Pulse makes of this entry. Reading it is how the import preview can
        /// show the user the instrument they are actually about to add, rather than
        /// echoing back the text they pasted.
        public enum Resolution: Sendable, Equatable {
            case resolved(SymbolID)
            case unknownMarket
            case missingCode
        }

        public var resolution: Resolution {
            let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawMarket = market.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let market = Market(rawValue: rawMarket) else { return .unknownMarket }
            guard !trimmedCode.isEmpty else { return .missingCode }
            // `SymbolID` owns crypto-pair parsing, index resolution, and per-market
            // code normalization, so a hand-typed `700`, `btc/usdt`, or `SPX` all
            // land on the value search would have produced.
            return .resolved(SymbolID(market: market, code: trimmedCode))
        }

        public var symbolID: SymbolID? {
            guard case .resolved(let symbol) = resolution else { return nil }
            return symbol
        }
    }

    public init(
        exportedAt: Date? = nil,
        app: String? = nil,
        lists: [List]
    ) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.app = app
        self.lists = lists
    }

    // MARK: - Serialization

    public enum DecodingFailure: Error, Equatable {
        case notJSON
        case wrongFormat(String)
        case unsupportedVersion(Int)
        case noLists
        case invalidTransactionFee(UUID)
        case duplicateChartDrawingID(UUID)
        case invalidChartDrawing(UUID)
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Version 2 keeps human-readable UTC ISO-8601 dates while including
        // enough fractional digits to round-trip Date's Double representation.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            guard date.timeIntervalSince1970.isFinite else {
                throw EncodingError.invalidValue(
                    date,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Archive dates must be finite."
                    )
                )
            }
            var container = encoder.singleValueContainer()
            try container.encode(archiveDateString(date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = archiveDate(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 date with an optional fractional second."
                )
            }
            return date
        }
        return decoder
    }

    private static func archiveDateString(_ date: Date) -> String {
        let unixSeconds = date.timeIntervalSince1970
        var wholeSeconds = floor(unixSeconds)
        var fraction = date.timeIntervalSinceReferenceDate - (wholeSeconds - unixReferenceOffset)
        if fraction < 0 {
            wholeSeconds -= 1
            fraction += 1
        } else if fraction >= 1 {
            wholeSeconds += 1
            fraction -= 1
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let whole = formatter.string(from: Date(timeIntervalSince1970: wholeSeconds))
        let fractionalDigits = String(
            format: "%.17f",
            locale: Locale(identifier: "en_US_POSIX"),
            fraction
        )
        let digits = String(fractionalDigits.dropFirst(2))
        return whole.hasSuffix("Z")
            ? String(whole.dropLast()) + "." + digits + "Z"
            : whole
    }

    private static func archiveDate(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Whole-second legacy archives use the standard ISO-8601 parser.
        guard let decimal = value.firstIndex(of: ".") else {
            return formatter.date(from: value)
        }

        // Foundation formatters differ on whether they accept fractional
        // seconds. Strip the fraction for the calendar portion and restore it
        // arithmetically so both old whole-second and new precise archives work.
        let suffixStart = value.index(after: decimal)
        let fractionalAndZone = value[suffixStart...]
        let digits = fractionalAndZone.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let zoneStart = fractionalAndZone.index(suffixStart, offsetBy: digits.count)
        let zone = String(fractionalAndZone[zoneStart...])
        let wholeValue = String(value[..<decimal]) + zone
        formatter.formatOptions = [.withInternetDateTime]
        guard let whole = formatter.date(from: wholeValue) else { return nil }
        guard let fraction = Double("0." + digits) else { return nil }
        return Date(timeIntervalSinceReferenceDate: whole.timeIntervalSinceReferenceDate + fraction)
    }

    public func encoded() throws -> String {
        let data = try Self.encoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses an archive, rejecting anything that is merely valid JSON. Import is
    /// additive and hard to notice when it silently does nothing, so every reason
    /// a payload cannot be applied is reported rather than swallowed.
    public static func decoded(from text: String) throws -> WatchlistArchive {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw DecodingFailure.notJSON
        }
        let archive: WatchlistArchive
        do {
            archive = try decoder().decode(WatchlistArchive.self, from: data)
        } catch let failure as DecodingFailure {
            throw failure
        } catch {
            throw DecodingFailure.notJSON
        }
        guard archive.format == formatIdentifier else {
            throw DecodingFailure.wrongFormat(archive.format)
        }
        guard (1...currentVersion).contains(archive.version) else {
            throw DecodingFailure.unsupportedVersion(archive.version)
        }
        guard !archive.lists.isEmpty else { throw DecodingFailure.noLists }
        for transaction in archive.lists.flatMap(\.entries).flatMap({ $0.transactions ?? [] }) {
            guard transaction.hasValidFee else {
                throw DecodingFailure.invalidTransactionFee(transaction.id)
            }
        }
        for drawing in archive.lists.flatMap(\.entries).flatMap({ $0.drawings ?? [] }) {
            guard drawing.isValid else { throw DecodingFailure.invalidChartDrawing(drawing.id) }
        }
        for entry in archive.lists.flatMap(\.entries) {
            var ids = Set<UUID>()
            for drawing in entry.drawings ?? [] where !ids.insert(drawing.id).inserted {
                throw DecodingFailure.duplicateChartDrawingID(drawing.id)
            }
        }
        return archive
    }

    /// A minimal, valid archive to hand someone who is writing one by hand. Offering
    /// this to the clipboard teaches the format far better than describing it does.
    public static func example() -> WatchlistArchive {
        WatchlistArchive(lists: [
            .init(name: PulseLocalization.localizedString("data.example.list.stocks"), entries: [
                .init(market: .us, code: "NVDA"),
                .init(market: .hk, code: "700"),
                .init(market: .sh, code: "688018")
            ]),
            .init(name: PulseLocalization.localizedString("data.example.list.crypto"), entries: [
                .init(market: .crypto, code: "BTC/USDT")
            ])
        ])
    }

    // MARK: - Import plan

    /// What an import would do, entry by entry, before anything is written.
    ///
    /// A code that cannot be verified against a provider offline still resolves to
    /// *something*, so the plan shows the instrument Pulse understood rather than a
    /// bare success flag: a wrong market or a mistyped pair is obvious when the
    /// interpretation is on screen next to the text that produced it.
    public struct ImportPlan: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            case add(SymbolID)
            case alreadyInList(SymbolID)
            case restorePosition(SymbolID)
            case skipped(Entry.Resolution)
        }

        public struct Item: Sendable, Equatable, Identifiable {
            public let id: Int
            public let entry: Entry
            public let outcome: Outcome

            public var symbol: SymbolID? {
                switch outcome {
                case .add(let symbol), .alreadyInList(let symbol), .restorePosition(let symbol):
                    symbol
                case .skipped:
                    nil
                }
            }
        }

        public struct ListPlan: Sendable, Equatable, Identifiable {
            public let id: Int
            public let name: String
            public let isNew: Bool
            public let items: [Item]
        }

        public var lists: [ListPlan]
        /// Number of saved drawing identities or versions that importing would
        /// add or change across existing and new instruments.
        public var drawingCount: Int

        public init(lists: [ListPlan], drawingCount: Int = 0) {
            self.lists = lists
            self.drawingCount = drawingCount
        }

        public var allItems: [Item] { lists.flatMap(\.items) }
        public var newListCount: Int { lists.filter(\.isNew).count }
        public var addCount: Int { allItems.filter { if case .add = $0.outcome { true } else { false } }.count }
        public var skippedCount: Int {
            allItems.filter { if case .skipped = $0.outcome { true } else { false } }.count
        }
        public var restoreCount: Int {
            allItems.filter { if case .restorePosition = $0.outcome { true } else { false } }.count
        }
        public var changesAnything: Bool {
            newListCount > 0 || addCount > 0 || restoreCount > 0 || drawingCount > 0
        }
    }
}
