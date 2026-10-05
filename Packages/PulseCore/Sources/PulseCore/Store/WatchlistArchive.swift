import Foundation

/// A portable, hand-writable snapshot of watchlists and their positions.
///
/// The on-disk `pulse.watchlists.v2` blob is an implementation detail: it stores
/// UUIDs, provider watermarks, and a derived legacy lot cache that only make sense
/// inside one installation. This archive is the user-facing shape instead — lists
/// are identified by name, instruments by market and code — so it survives a
/// reinstall, moves between Macs, and can be typed by hand to bulk-add symbols.
///
/// Version 3 carries trade reviews; version 4 adds trading profiles and events;
/// version 5 adds position allocations and multi-day event end dates; version 6
/// adds a plan's intended position pool; version 7 adds a plan's conditions and
/// revision history, and the plan snapshot a transaction recorded its fill from;
/// version 8 adds a funding-source annotation on portions, transactions, plans,
/// and plan configurations; version 9 adds a plan condition's immutable event
/// reference and a transaction review's forward-looking checkpoint; version 10
/// adds a verification condition array on a position portion, which is the
/// condition list a block of actually-held shares is judged against; version 11
/// scopes the archive to one brokerage account; version 12 adds a
/// per-portion brokerage-account label.
/// Exports use the oldest version that describes their data. Everything except `market` and
/// `code` is optional. An entry as small as `{"market": "us", "code": "NVDA"}`
/// imports correctly; the display name is then filled in by the first quote
/// refresh, the same path that upgrades watchlists written by older versions.
public struct WatchlistArchive: Codable, Sendable, Equatable {
    public static let formatIdentifier = "pulse.watchlist"
    /// Newest archive schema. Older data keeps its existing version.
    public static let currentVersion = 12
    private static let reviewVersion = 3
    private static let tradingMetadataVersion = 4
    private static let allocationVersion = 5
    private static let planPoolVersion = 6
    private static let planWorkflowVersion = 7
    private static let fundingSourceVersion = 8
    private static let eventCheckpointVersion = 9
    private static let verificationVersion = 10
    /// The version an archive scoped to a brokerage account declares. Raising
    /// `currentVersion` for a per-portion account label must not drag an
    /// untagged account-scoped archive up with it, so the two thresholds are
    /// separate constants.
    static let brokerageAccountVersion = 11
    /// The version a per-portion brokerage-account label requires. This is the
    /// newest field, so it outranks every other reason to raise the version.
    static let brokerageTagVersion = 12
    private static let unixReferenceOffset: TimeInterval = 978_307_200

    public var format: String
    public var version: Int
    public var exportedAt: Date?
    public var app: String?
    public var lists: [List]
    /// An archive is scoped to one account; old untagged imports use the explicit current account.
    public var brokerageAccountID: BrokerageAccountID?

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
        public var tradingProfile: TradingProfile?
        public var events: [InstrumentEvent]?
        public var positionAllocation: PositionAllocation?

        public init(
            market: String,
            code: String,
            name: String? = nil,
            type: InstrumentType? = nil,
            pinned: Bool? = nil,
            transactions: [PositionTransaction]? = nil,
            thesis: String? = nil,
            plans: [TradePlan]? = nil,
            drawings: [ChartDrawing]? = nil,
            tradingProfile: TradingProfile? = nil,
            events: [InstrumentEvent]? = nil,
            positionAllocation: PositionAllocation? = nil
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
            self.tradingProfile = tradingProfile
            self.events = events
            self.positionAllocation = positionAllocation
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
            drawings: [ChartDrawing]? = nil,
            tradingProfile: TradingProfile? = nil,
            events: [InstrumentEvent]? = nil,
            positionAllocation: PositionAllocation? = nil
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
                drawings: drawings,
                tradingProfile: tradingProfile,
                events: events,
                positionAllocation: positionAllocation
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
        lists: [List],
        brokerageAccountID: BrokerageAccountID? = nil
    ) {
        format = Self.formatIdentifier
        let entries = lists.flatMap(\.entries)
        let transactions = entries.flatMap { $0.transactions ?? [] }
        let hasAllocationOrEndDate = entries.contains {
            $0.positionAllocation != nil || ($0.events ?? []).contains { $0.endDate != nil }
        }
        let hasPlanPool = entries.contains { entry in
            entry.plans?.contains(where: { $0.positionPool != nil }) == true
        }
        let hasPlanWorkflow = entries.contains { entry in
            entry.plans?.contains {
                !($0.conditions ?? []).isEmpty || !($0.history ?? []).isEmpty
            } == true
        } || transactions.contains { $0.planExecution != nil }
        // Funding lives in four places: the live portion list (and each change's
        // before/after snapshots), the transactions a buy created a portion
        // from, the plan's intent, and every configuration a plan or fill kept.
        // All four are scanned because omitting any one would let that copy be
        // silently dropped by a reader that stops at the declared version.
        let hasFundingSource = entries.contains { entry in
            entry.positionAllocation?.hasFundingMetadata == true
                || entry.plans?.contains { $0.hasFundingMetadata } == true
        } || transactions.contains {
            $0.fundingSource != nil
                || $0.planExecution.map { $0.configuration.fundingSource != nil } == true
        }
        let hasTradingData = entries.contains { $0.tradingProfile != nil || !($0.events ?? []).isEmpty }
            || transactions.contains { $0.review?.strategy != nil }
        let hasReview = transactions.contains { $0.review != nil }
        // An event link lives on a plan's own conditions or in the conditions a
        // revision's configuration captured; a checkpoint lives on a review.
        // Either one is enough to claim the newest version, because a reader
        // that stops at the declared version would drop it.
        let hasEventOrCheckpoint = entries.contains { entry in
            entry.plans?.contains { $0.hasEventReferenceMetadata } == true
        } || transactions.contains {
            $0.planExecution?.hasEventReferenceMetadata == true || $0.review?.hasCheckpoint == true
        }
        // Verification is the newest field, so it outranks every other reason to
        // raise the version; a payload that mixed it with an event link would
        // otherwise declare 9 and let the link be dropped. An explicit empty
        // condition array counts, which is why this asks the allocation rather
        // than inspecting the arrays itself.
        let hasVerification = entries.contains { $0.positionAllocation?.hasVerificationMetadata == true }
        // A per-portion brokerage-account label outranks all of the above. It is
        // asked through the allocation so a label that only survives in a
        // change's before/after snapshots still counts: a payload that dropped
        // the change log's copy would lose the attribution the user recorded.
        let hasBrokerageTag = entries.contains { $0.positionAllocation?.hasBrokerageTagMetadata == true }
        version = hasBrokerageTag ? Self.brokerageTagVersion
            : brokerageAccountID != nil ? Self.brokerageAccountVersion
            : hasVerification ? Self.verificationVersion
            : hasEventOrCheckpoint ? Self.eventCheckpointVersion
            : hasFundingSource ? Self.fundingSourceVersion
            : hasPlanWorkflow ? Self.planWorkflowVersion
            : hasPlanPool ? Self.planPoolVersion
            : hasAllocationOrEndDate ? Self.allocationVersion
            : hasTradingData ? Self.tradingMetadataVersion
            : hasReview ? Self.reviewVersion
            : 2
        self.exportedAt = exportedAt
        self.app = app
        self.lists = lists
        self.brokerageAccountID = brokerageAccountID
    }

    // MARK: - Serialization

    public enum DecodingFailure: Error, Equatable {
        case notJSON
        case wrongFormat(String)
        case unsupportedVersion(Int)
        case noLists
        case invalidTransactionFee(UUID)
        case invalidTradingProfile(String)
        case duplicateInstrumentEventID(UUID)
        case invalidInstrumentEvent(UUID)
        case invalidPositionAllocation(String)
        case duplicateChartDrawingID(UUID)
        case invalidChartDrawing(UUID)
        case duplicateTradePlanID(UUID)
        case duplicateTradePlanConditionID(UUID)
        case duplicateTradePlanRevisionID(UUID)
        case invalidTradePlan(UUID)
        case invalidPlanExecution(UUID)
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
        if archive.brokerageAccountID != nil, archive.version < brokerageAccountVersion {
            throw DecodingFailure.unsupportedVersion(brokerageAccountVersion)
        }
        let entries = archive.lists.flatMap(\.entries)
        let transactions = entries.flatMap { $0.transactions ?? [] }
        // A per-portion brokerage-account label is the newest field, and it can
        // sit in the live portion list or only in a change's before/after
        // snapshots. A payload claiming an older version while carrying either
        // is rejected rather than silently downgraded, because the reader it
        // claims compatibility with would drop the attribution.
        if archive.version < brokerageTagVersion,
           entries.contains(where: { $0.positionAllocation?.hasBrokerageTagMetadata == true }) {
            throw DecodingFailure.unsupportedVersion(brokerageTagVersion)
        }
        // Verification lives in the one place a reader that stops at the
        // declared version cannot see: a portion inside the allocation. A
        // payload claiming 9 or older while carrying it is rejected rather than
        // silently downgraded to an allocation the reader would drop the
        // conditions from.
        if archive.version < verificationVersion,
           entries.contains(where: { $0.positionAllocation?.hasVerificationMetadata == true }) {
            throw DecodingFailure.unsupportedVersion(verificationVersion)
        }
        // An event link or a review checkpoint is invisible to a reader that
        // stops at the declared version, so a payload that claims an older one
        // while carrying either is rejected rather than silently downgraded.
        if archive.version < eventCheckpointVersion,
           entries.contains(where: { entry in
               entry.plans?.contains { $0.hasEventReferenceMetadata } == true
           }) || transactions.contains(where: { transaction in
               transaction.planExecution?.hasEventReferenceMetadata == true
                   || transaction.review?.hasCheckpoint == true
           }) {
            throw DecodingFailure.unsupportedVersion(eventCheckpointVersion)
        }
        if archive.version < fundingSourceVersion,
           entries.contains(where: { entry in
               entry.positionAllocation?.hasFundingMetadata == true
                   || entry.plans?.contains { $0.hasFundingMetadata } == true
           }) || transactions.contains(where: {
               $0.fundingSource != nil
                   || $0.planExecution.map { $0.configuration.fundingSource != nil } == true
           }) {
            throw DecodingFailure.unsupportedVersion(fundingSourceVersion)
        }
        if archive.version < planWorkflowVersion,
           entries.contains(where: { entry in
               entry.plans?.contains {
                   !($0.conditions ?? []).isEmpty || !($0.history ?? []).isEmpty
               } == true
           }) || transactions.contains(where: { $0.planExecution != nil }) {
            throw DecodingFailure.unsupportedVersion(planWorkflowVersion)
        }
        if archive.version < planPoolVersion,
           entries.contains(where: { $0.plans?.contains(where: { $0.positionPool != nil }) == true }) {
            throw DecodingFailure.unsupportedVersion(planPoolVersion)
        }
        if archive.version < allocationVersion,
           entries.contains(where: { $0.positionAllocation != nil || ($0.events ?? []).contains { $0.endDate != nil } }) {
            throw DecodingFailure.unsupportedVersion(allocationVersion)
        }
        if archive.version < tradingMetadataVersion,
           entries.contains(where: { $0.tradingProfile != nil || !($0.events ?? []).isEmpty })
            || transactions.contains(where: { $0.review?.strategy != nil }) {
            throw DecodingFailure.unsupportedVersion(tradingMetadataVersion)
        }
        if archive.version < reviewVersion, transactions.contains(where: { $0.review != nil }) {
            throw DecodingFailure.unsupportedVersion(reviewVersion)
        }
        guard !archive.lists.isEmpty else { throw DecodingFailure.noLists }
        for transaction in archive.lists.flatMap(\.entries).flatMap({ $0.transactions ?? [] }) {
            guard transaction.hasValidFee else {
                throw DecodingFailure.invalidTransactionFee(transaction.id)
            }
            if let execution = transaction.planExecution,
               !Self.isValidPlanExecution(execution) {
                throw DecodingFailure.invalidPlanExecution(transaction.id)
            }
        }
        for drawing in archive.lists.flatMap(\.entries).flatMap({ $0.drawings ?? [] }) {
            guard drawing.isValid else { throw DecodingFailure.invalidChartDrawing(drawing.id) }
        }
        for entry in archive.lists.flatMap(\.entries) {
            if let profile = entry.tradingProfile, !profile.isValid {
                throw DecodingFailure.invalidTradingProfile(entry.code)
            }
            var eventIDs = Set<UUID>()
            for event in entry.events ?? [] {
                guard event.isValid else { throw DecodingFailure.invalidInstrumentEvent(event.id) }
                guard eventIDs.insert(event.id).inserted else {
                    throw DecodingFailure.duplicateInstrumentEventID(event.id)
                }
            }
            if let allocation = entry.positionAllocation, !allocation.isValid {
                throw DecodingFailure.invalidPositionAllocation(entry.code)
            }
            var ids = Set<UUID>()
            for drawing in entry.drawings ?? [] where !ids.insert(drawing.id).inserted {
                throw DecodingFailure.duplicateChartDrawingID(drawing.id)
            }
            var planIDs = Set<UUID>()
            for plan in entry.plans ?? [] {
                // Duplicate identity is reported ahead of payload validity so a
                // file that names one id twice says so, rather than blaming the
                // plan's contents.
                guard planIDs.insert(plan.id).inserted else {
                    throw DecodingFailure.duplicateTradePlanID(plan.id)
                }
                var conditionIDs = Set<UUID>()
                for condition in plan.conditions ?? [] where !conditionIDs.insert(condition.id).inserted {
                    throw DecodingFailure.duplicateTradePlanConditionID(condition.id)
                }
                var revisionIDs = Set<UUID>()
                for revision in plan.history ?? [] where !revisionIDs.insert(revision.id).inserted {
                    throw DecodingFailure.duplicateTradePlanRevisionID(revision.id)
                }
                guard plan.hasValidPayload, Self.hasUniquePlanWorkflowMetadata(plan) else {
                    throw DecodingFailure.invalidTradePlan(plan.id)
                }
            }
        }
        return archive
    }

    /// Whether the workflow metadata a plan carries is self-consistent on its
    /// own, without leaning on `hasValidPayload`: conditions must normalize
    /// cleanly (which includes any linked event reference) and history revisions
    /// must carry a usable configuration.
    private static func hasUniquePlanWorkflowMetadata(_ plan: TradePlan) -> Bool {
        var conditionIDs = Set<UUID>()
        for condition in plan.conditions ?? [] {
            guard condition.normalized() == condition, conditionIDs.insert(condition.id).inserted else {
                return false
            }
        }
        var revisionIDs = Set<UUID>()
        for revision in plan.history ?? [] {
            let configuration = revision.configuration
            guard revision.date.timeIntervalSince1970.isFinite,
                  revisionIDs.insert(revision.id).inserted,
                  configuration.price.isFinite, configuration.price > 0,
                  configuration.quantity.isFinite, configuration.quantity > 0,
                  configuration.createdAt.timeIntervalSince1970.isFinite,
                  (configuration.note.map { $0.count <= 4_000 } ?? true) else { return false }
            var nestedIDs = Set<UUID>()
            for condition in configuration.conditions ?? [] where
                condition.normalized() != condition || !nestedIDs.insert(condition.id).inserted {
                return false
            }
        }
        return true
    }

    /// A transaction's plan snapshot is immutable context: it has to point at a
    /// plan and carry a configuration the ledger can still read back, including
    /// any event references its conditions hold.
    private static func isValidPlanExecution(_ execution: TradePlanExecution) -> Bool {
        let configuration = execution.configuration
        guard configuration.price.isFinite, configuration.price > 0,
              configuration.quantity.isFinite, configuration.quantity > 0,
              configuration.createdAt.timeIntervalSince1970.isFinite,
              (configuration.note.map { $0.count <= 4_000 } ?? true) else { return false }
        var conditionIDs = Set<UUID>()
        for condition in configuration.conditions ?? [] where
            condition.normalized() != condition || !conditionIDs.insert(condition.id).inserted {
            return false
        }
        return true
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
        public var metadataCount: Int

        public init(lists: [ListPlan], drawingCount: Int = 0, metadataCount: Int = 0) {
            self.lists = lists
            self.drawingCount = drawingCount
            self.metadataCount = metadataCount
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
            newListCount > 0 || addCount > 0 || restoreCount > 0 || drawingCount > 0 || metadataCount > 0
        }
    }
}
