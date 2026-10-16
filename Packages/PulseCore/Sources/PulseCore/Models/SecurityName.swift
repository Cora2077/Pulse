import Foundation

/// A localized canonical name returned by a provider's static reference-data API.
public struct SecurityName: Sendable, Hashable {
    public var symbol: SymbolID
    public var name: String
    public var localeIdentifier: String

    public init(symbol: SymbolID, name: String, localeIdentifier: String) {
        self.symbol = symbol
        self.name = name
        self.localeIdentifier = localeIdentifier
    }
}

/// A provider-ranked name ready to be compared with a watchlist's persisted
/// name watermark.
public struct SourcedSecurityName: Sendable, Hashable {
    public var symbol: SymbolID
    public var name: String
    public var source: DisplayNameSource

    public init(symbol: SymbolID, name: String, source: DisplayNameSource) {
        self.symbol = symbol
        self.name = name
        self.source = source
    }
}

/// Persisted provenance for a watchlist name. Lower priorities are preferred.
///
/// The numeric watermark intentionally survives temporary provider failure:
/// a lower-priority fallback may provide prices, but cannot rename the item.
public struct DisplayNameSource: Codable, Sendable, Hashable {
    public var providerID: String
    public var priority: Int
    public var localeIdentifier: String

    public init(providerID: String, priority: Int, localeIdentifier: String) {
        self.providerID = providerID
        self.priority = priority
        self.localeIdentifier = localeIdentifier
    }

    /// Whether `candidate` should replace `current` as a watchlist display name.
    ///
    /// Two keys, in order: a name in the interface language outranks a name in
    /// any other language, and among names in the same language the
    /// better-ranked provider wins. Locale leads because the interface ships one
    /// language: an English name for a US instrument is a worse label than the
    /// Chinese name the same market data already carries, even when the English
    /// name comes from a higher-ranked provider. Provider priority still decides
    /// between two names the user can read, so a credentialled source that names
    /// US instruments in Chinese keeps winning.
    ///
    /// This applies to every instrument type, funds included: a US ETF takes the
    /// Chinese name the Chinese-language media already use for it
    /// (`usSPY` → 标普500指数ETF-SPDR, `usSOXQ` → 费城半导体ETF-Invesco) rather than
    /// keeping its longer English listing name. The user chose that explicitly
    /// (2026-10-15) while reviewing this rule. Any instrument type is equally
    /// covered, so type-specific gates must not be introduced here.
    public func outranks(_ current: DisplayNameSource?) -> Bool {
        guard let current else { return true }
        let candidateRank = Self.localeRank(localeIdentifier)
        let currentRank = Self.localeRank(current.localeIdentifier)
        if candidateRank != currentRank { return candidateRank < currentRank }
        return priority < current.priority
    }

    /// 0 for the interface language, 1 for everything else. The whole identifier
    /// is compared as it is written, so "zh-Hans" matches exactly.
    private static func localeRank(_ localeIdentifier: String) -> Int {
        localeIdentifier == PulseLocalization.currentLanguageIdentifier ? 0 : 1
    }
}

public extension SecurityName {
    /// Whether `text` contains at least one Han-script character, i.e. whether a
    /// name is genuinely written in Chinese rather than being a Latin listing
    /// name. Sources that mostly answer in Chinese still return Latin names for
    /// part of the US board (`usIBM` → `IBM`, `usMETA` → `Meta Platforms`), and
    /// treating one of those as Chinese would record provenance the source never
    /// supplied — which, now that a locale match decides precedence, would also
    /// keep the real Chinese name from ever being adopted.
    static func isChineseName(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)        // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains(scalar.value) // Extension A
        }
    }
}
