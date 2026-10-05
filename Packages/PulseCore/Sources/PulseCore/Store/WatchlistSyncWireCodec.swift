import Foundation

/// Versioned JSON representation shared by devices syncing watchlist state.
/// Version 2 introduced numeric dates; version 3 adds drawing tombstones;
/// version 4 carries trade reviews; version 5 adds trading metadata;
/// version 6 adds position allocations and multi-day event end dates; version 7
/// adds a plan's intended position pool; version 8 adds a plan's conditions and
/// revision history, and the plan snapshot a transaction recorded its fill from;
/// version 9 adds a funding-source annotation on portions, transactions, plans,
/// and plan configurations; version 10 adds a plan condition's immutable event
/// reference and a transaction review's forward-looking checkpoint; version 11
/// adds a verification condition array on a position portion; version 12 adds
/// named brokerage accounts; version 13 adds per-account settings; version 14
/// adds a per-portion brokerage-account label.
/// Encoders keep older versions when the newer fields are absent.
public enum WatchlistSyncWireCodec {
    public static let formatIdentifier = "pulse.device-sync"
    public static let currentVersion = 14
    private static let reviewVersion = 4
    private static let tradingMetadataVersion = 5
    private static let allocationVersion = 6
    private static let planPoolVersion = 7
    private static let planWorkflowVersion = 8
    private static let fundingSourceVersion = 9
    private static let eventCheckpointVersion = 10
    private static let verificationVersion = 11
    private static let brokerageVersion = 12
    private static let accountSettingsVersion = 13
    /// The version a per-portion brokerage-account label requires. It is the
    /// newest field and so outranks the account and settings thresholds; keeping
    /// it a separate constant means raising `currentVersion` for the label does
    /// not move an untagged account-scoped payload off 12.
    private static let brokerageTagVersion = 14

    public struct File: Sendable, Equatable {
        public let format: String
        public let version: Int
        public let deviceID: String
        public let updatedAt: Date
        public let snapshot: WatchlistSyncSnapshot

        fileprivate init(
            format: String,
            version: Int,
            deviceID: String,
            updatedAt: Date,
            snapshot: WatchlistSyncSnapshot
        ) {
            self.format = format
            self.version = version
            self.deviceID = deviceID
            self.updatedAt = updatedAt
            self.snapshot = snapshot
        }
    }

    public enum CodecError: Error, Equatable {
        case invalidEnvelope
        case invalidBrokerageAccounts
        case unsupportedFormat
        case unsupportedVersion(Int)
        case unexpectedDeviceID
        case duplicateGroupID(UUID)
        case duplicateItemSymbol(SymbolID)
        case duplicateCostLotID(UUID)
        case duplicateTransactionID(UUID)
        case invalidTransactionFee(UUID)
        case duplicateTradePlanID(UUID)
        case duplicateChartDrawingID(UUID)
        case invalidChartDrawing(UUID)
        case invalidTradingProfile(SymbolID)
        case duplicateInstrumentEventID(UUID)
        case invalidInstrumentEvent(UUID)
        case invalidPositionAllocation(SymbolID)
        case duplicateTradePlanConditionID(UUID)
        case duplicateTradePlanRevisionID(UUID)
        case invalidTradePlan(UUID)
        case invalidPlanExecution(UUID)
    }

    private struct Header: Decodable {
        var format: String
        var version: Int
    }

    private struct Payload: Codable {
        var format: String
        var version: Int
        var deviceID: String
        var updatedAt: Date
        var snapshot: WatchlistSyncSnapshot
    }

    /// Older data stays on its previous version; position allocations and
    /// multi-day event end dates use v6, assigned plan pools use v7,
    /// conditions, revision history, or a fill's plan snapshot use v8, and any
    /// funding annotation uses v9.
    /// Codable's deferred Date strategy stores reference-date seconds as a
    /// JSON number with round-trippable floating-point precision.
    public static func encode(
        deviceID: String,
        updatedAt: Date = .now,
        snapshot: WatchlistSyncSnapshot
    ) throws -> Data {
        let allTransactions = snapshot.items.flatMap(\.transactions)
            + snapshot.retainedHistoryItems.flatMap(\.transactions)
        let allItems = snapshot.items + snapshot.retainedHistoryItems
        let hasAllocationOrEndDate = allItems.contains {
            $0.positionAllocation != nil || $0.events.contains { $0.endDate != nil }
        }
        let hasPlanPool = allItems.contains { item in
            item.plans.contains(where: { $0.positionPool != nil })
        }
        let hasPlanWorkflow = allItems.contains { item in
            item.plans.contains {
                !($0.conditions ?? []).isEmpty || !($0.history ?? []).isEmpty
            }
        } || allTransactions.contains { $0.planExecution != nil }
        // Every place a funding annotation can sit: the live portions and each
        // change's before/after snapshots, a transaction, a plan's intent, and
        // the configuration a revision or fill captured. A reader that stops at
        // the declared version would drop whichever one is left unscanned.
        let hasFundingSource = allItems.contains { item in
            item.positionAllocation?.hasFundingMetadata == true
                || item.plans.contains { $0.hasFundingMetadata }
        } || allTransactions.contains {
            $0.fundingSource != nil
                || $0.planExecution.map { $0.configuration.fundingSource != nil } == true
        }
        let hasNewTradingData = allItems.contains { $0.tradingProfile != nil || !$0.events.isEmpty }
            || allTransactions.contains { $0.review?.strategy != nil }
        let hasReview = allTransactions.contains { $0.review != nil }
        // An event reference or a review checkpoint is new at v10; either one
        // raises the declared version so an older reader cannot drop it.
        let hasEventOrCheckpoint = allItems.contains { item in
            item.plans.contains { $0.hasEventReferenceMetadata }
        } || allTransactions.contains { transaction in
            transaction.planExecution?.hasEventReferenceMetadata == true
                || transaction.review?.hasCheckpoint == true
        }
        // Verification is the newest field and outranks every other reason to
        // raise the version, so a payload mixing it with an event link declares
        // 11 rather than 10. An explicit empty condition array counts as
        // metadata, which is why the allocation is asked rather than inspected.
        let hasVerification = allItems.contains { $0.positionAllocation?.hasVerificationMetadata == true }
        // A per-portion brokerage-account label is newer than everything else,
        // including named accounts and their settings, so it is checked first.
        // Without that ordering an account-scoped snapshot carrying a label
        // would declare the settings version and let an older reader drop the
        // attribution.
        let hasBrokerageTag = snapshot.allAccountItems.contains { $0.positionAllocation?.hasBrokerageTagMetadata == true }
        let version = hasBrokerageTag ? brokerageTagVersion
            : snapshot.hasAccountSettings ? accountSettingsVersion
            : snapshot.brokerageAccounts != nil ? brokerageVersion
            : hasVerification ? verificationVersion
            : hasEventOrCheckpoint ? eventCheckpointVersion
            : hasFundingSource ? fundingSourceVersion
            : hasPlanWorkflow ? planWorkflowVersion
            : hasPlanPool ? planPoolVersion
            : hasAllocationOrEndDate ? allocationVersion
            : hasNewTradingData ? tradingMetadataVersion
            : hasReview ? reviewVersion
            : 3
        let file = File(
            format: formatIdentifier,
            version: version,
            deviceID: deviceID,
            updatedAt: updatedAt,
            snapshot: snapshot
        )
        try validate(file)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Payload(
            format: file.format,
            version: file.version,
            deviceID: file.deviceID,
            updatedAt: file.updatedAt,
            snapshot: file.snapshot
        ))
    }

    /// Decodes versions 1 through `currentVersion` and validates IDs before a
    /// decoded snapshot can reach merge code that assumes uniqueness.
    public static func decode(_ data: Data, expectedDeviceID: String? = nil) throws -> File {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw CodecError.invalidEnvelope
        }
        guard header.format == formatIdentifier else { throw CodecError.unsupportedFormat }
        guard (1...currentVersion).contains(header.version) else {
            throw CodecError.unsupportedVersion(header.version)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = header.version == 1 ? .iso8601 : .deferredToDate
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw CodecError.invalidEnvelope
        }
        guard payload.format == formatIdentifier, payload.version == header.version else {
            throw CodecError.invalidEnvelope
        }
        if let expectedDeviceID, payload.deviceID != expectedDeviceID {
            throw CodecError.unexpectedDeviceID
        }

        let file = File(
            format: payload.format,
            version: payload.version,
            deviceID: payload.deviceID,
            updatedAt: payload.updatedAt,
            snapshot: payload.snapshot
        )
        try validate(file)
        return file
    }

    private static func validate(_ file: File) throws {
        guard file.format == formatIdentifier else { throw CodecError.unsupportedFormat }
        guard (1...currentVersion).contains(file.version) else {
            throw CodecError.unsupportedVersion(file.version)
        }

        if file.snapshot.hasAccountSettings {
            guard file.version >= accountSettingsVersion else { throw CodecError.unsupportedVersion(accountSettingsVersion) }
            guard file.snapshot.accountSettings?.isValid ?? true,
                  (file.snapshot.brokerageAccounts ?? []).allSatisfy({ $0.settings?.isValid ?? true }) else {
                throw CodecError.invalidBrokerageAccounts
            }
        }

        if let accounts = file.snapshot.brokerageAccounts {
            guard file.version >= brokerageVersion else { throw CodecError.unsupportedVersion(brokerageVersion) }
            guard Set(accounts.map(\.accountID)).count == accounts.count,
                  accounts.allSatisfy({ $0.accountID != .unassigned }) else {
                throw CodecError.invalidBrokerageAccounts
            }
            for account in accounts {
                try validate(File(format: file.format, version: file.version, deviceID: file.deviceID,
                                  updatedAt: file.updatedAt, snapshot: account.flatSnapshot))
            }
            var ids = Set<UUID>()
            guard file.snapshot.allAccountItems.flatMap(\.transactions).allSatisfy({ ids.insert($0.id).inserted }) else {
                throw CodecError.invalidBrokerageAccounts
            }
        }
        let items = file.snapshot.items + file.snapshot.retainedHistoryItems
        let transactions = items.flatMap(\.transactions)
        // A per-portion brokerage-account label is the newest field. It is
        // checked before the account branches below and against the whole
        // snapshot, including the portions nested in named accounts, because a
        // payload claiming an older version while carrying a label — live or
        // only in an audit snapshot — must be rejected rather than downgraded to
        // one whose reader would drop it.
        if file.version < brokerageTagVersion,
           file.snapshot.allAccountItems.contains(where: {
               $0.positionAllocation?.hasBrokerageTagMetadata == true
           }) {
            throw CodecError.unsupportedVersion(brokerageTagVersion)
        }
        // A portion's verification array is the newest field; a payload claiming
        // an older version while carrying one is rejected, because the older
        // reader it claims compatibility with would drop the conditions.
        if file.version < verificationVersion,
           items.contains(where: { $0.positionAllocation?.hasVerificationMetadata == true }) {
            throw CodecError.unsupportedVersion(verificationVersion)
        }
        if file.version < eventCheckpointVersion,
           items.contains(where: { item in
               item.plans.contains { $0.hasEventReferenceMetadata }
           }) || transactions.contains(where: { transaction in
               transaction.planExecution?.hasEventReferenceMetadata == true
                   || transaction.review?.hasCheckpoint == true
           }) {
            throw CodecError.unsupportedVersion(eventCheckpointVersion)
        }
        if file.version < fundingSourceVersion,
           items.contains(where: { item in
               item.positionAllocation?.hasFundingMetadata == true
                   || item.plans.contains { $0.hasFundingMetadata }
           }) || transactions.contains(where: {
               $0.fundingSource != nil
                   || $0.planExecution.map { $0.configuration.fundingSource != nil } == true
           }) {
            throw CodecError.unsupportedVersion(fundingSourceVersion)
        }
        if file.version < planWorkflowVersion,
           items.contains(where: { item in
               item.plans.contains {
                   !($0.conditions ?? []).isEmpty || !($0.history ?? []).isEmpty
               }
           }) || transactions.contains(where: { $0.planExecution != nil }) {
            throw CodecError.unsupportedVersion(planWorkflowVersion)
        }
        if file.version < planPoolVersion,
           items.contains(where: { $0.plans.contains(where: { $0.positionPool != nil }) }) {
            throw CodecError.unsupportedVersion(planPoolVersion)
        }
        if file.version < allocationVersion,
           items.contains(where: { $0.positionAllocation != nil || $0.events.contains { $0.endDate != nil } }) {
            throw CodecError.unsupportedVersion(allocationVersion)
        }
        if file.version < tradingMetadataVersion,
           items.contains(where: { $0.tradingProfile != nil || !$0.events.isEmpty })
            || transactions.contains(where: { $0.review?.strategy != nil }) {
            throw CodecError.unsupportedVersion(tradingMetadataVersion)
        }
        if file.version < reviewVersion, transactions.contains(where: { $0.review != nil }) {
            throw CodecError.unsupportedVersion(reviewVersion)
        }

        var groupIDs = Set<UUID>()
        for group in file.snapshot.groups {
            guard groupIDs.insert(group.id).inserted else { throw CodecError.duplicateGroupID(group.id) }
        }

        var itemSymbols = Set<SymbolID>()
        for item in file.snapshot.items + file.snapshot.retainedHistoryItems {
            guard itemSymbols.insert(item.symbol).inserted else {
                throw CodecError.duplicateItemSymbol(item.symbol)
            }
            var lotIDs = Set<UUID>()
            for lot in item.lots {
                guard lotIDs.insert(lot.id).inserted else { throw CodecError.duplicateCostLotID(lot.id) }
            }
            var transactionIDs = Set<UUID>()
            for transaction in item.transactions {
                guard transaction.hasValidFee else { throw CodecError.invalidTransactionFee(transaction.id) }
                guard transactionIDs.insert(transaction.id).inserted else {
                    throw CodecError.duplicateTransactionID(transaction.id)
                }
                if let execution = transaction.planExecution,
                   !Self.isValidPlanExecution(execution) {
                    throw CodecError.invalidPlanExecution(transaction.id)
                }
            }
            // The plan merge keys by id, so a payload carrying one twice would
            // silently drop an edit instead of reporting the malformed file.
            var planIDs = Set<UUID>()
            for plan in item.plans {
                // Duplicate identity is reported ahead of payload validity so a
                // payload naming one id twice says so, rather than blaming the
                // plan's contents.
                guard planIDs.insert(plan.id).inserted else {
                    throw CodecError.duplicateTradePlanID(plan.id)
                }
                var conditionIDs = Set<UUID>()
                for condition in plan.conditions ?? [] where !conditionIDs.insert(condition.id).inserted {
                    throw CodecError.duplicateTradePlanConditionID(condition.id)
                }
                var revisionIDs = Set<UUID>()
                for revision in plan.history ?? [] where !revisionIDs.insert(revision.id).inserted {
                    throw CodecError.duplicateTradePlanRevisionID(revision.id)
                }
                guard plan.hasValidPayload, Self.hasConsistentPlanWorkflowMetadata(plan) else {
                    throw CodecError.invalidTradePlan(plan.id)
                }
            }
            var drawingIDs = Set<UUID>()
            for drawing in item.drawings {
                guard drawing.isValid else { throw CodecError.invalidChartDrawing(drawing.id) }
                guard drawingIDs.insert(drawing.id).inserted else {
                    throw CodecError.duplicateChartDrawingID(drawing.id)
                }
            }
            if let profile = item.tradingProfile, !profile.isValid {
                throw CodecError.invalidTradingProfile(item.symbol)
            }
            var eventIDs = Set<UUID>()
            for event in item.events {
                guard event.isValid else { throw CodecError.invalidInstrumentEvent(event.id) }
                guard eventIDs.insert(event.id).inserted else {
                    throw CodecError.duplicateInstrumentEventID(event.id)
                }
            }
            if let allocation = item.positionAllocation, !allocation.isValid {
                throw CodecError.invalidPositionAllocation(item.symbol)
            }
        }
    }

    /// Conditions must normalize cleanly and every revision must carry a
    /// configuration the ledger can replay, independent of `hasValidPayload`.
    private static func hasConsistentPlanWorkflowMetadata(_ plan: TradePlan) -> Bool {
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

    /// The immutable plan snapshot on a fill has to be readable on its own,
    /// including any event references its conditions carry.
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
}
