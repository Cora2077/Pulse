import SwiftUI
import PulseCore
import PulseUI

extension TradePlanEntry.DisplayState {
    var sectionTitleKey: String {
        switch self {
        case .waiting: "plans.display.waiting"
        case .filled: "plans.display.filled"
        case .abandoned: "plans.display.abandoned"
        case .stopped: "plans.display.incompleteRecords"
        }
    }
}

/// Every number a plan surface prints, with its unit and its quote currency
/// spelled out.
///
/// The list used to print bare numbers beside a bare symbol code, which left a
/// reader to guess both the money and the thing being counted: `140.00 × 50`
/// says nothing about whether that is dollars or Hong Kong dollars, and a
/// crypto row's "50" is not 50 shares. Both answers are derived from the
/// instrument, and both are the same answer on every surface — the row, the
/// editor, the fill sheet, and the text export — because they all come through
/// here rather than each formatting its own.
///
/// Nothing here converts anything. A quote in USDT is printed as USDT; the
/// price precision still comes from `PriceFormatter` so a market's tick size is
/// unchanged.
enum PlanValueText {
    /// The dash every total uses when the value behind it is not a number.
    /// Printing `nan` or `inf` as if it were a price would be worse than
    /// printing nothing.
    static let unknown = "—"

    /// A price with the currency the quote is actually denominated in.
    ///
    /// `currencyCode` is what a live quote reported; when it is absent or
    /// unusable, the instrument's own currency stands in. Crypto is the case
    /// that matters: a pair's quote asset (USDT, USDC, BTC) is the money, and
    /// `Market.crypto.currencyCode` would have said USD — a different asset
    /// that only happens to trade nearby.
    static func price(_ value: Double, symbol: SymbolID, currencyCode: String? = nil) -> String {
        guard value.isFinite else { return unknown }
        let formatted = formattedPrice(value, market: symbol.market)
        guard let code = normalizedQuoteCurrency(currencyCode, symbol: symbol) else {
            // Nothing usable was reported and nothing usable is on the symbol.
            // For an instrument whose whole identity is a pair, saying nothing
            // would leave a bare number that reads as though it were home
            // currency; the annotation says out loud that Pulse does not know
            // which money this is, instead of inventing USD for it.
            return symbol.cryptoPair == nil
                ? formatted
                : "\(formatted) \(PulseLocalization.localizedString("plans.unit.unknownCurrency"))"
        }
        return "\(formatted) \(code)"
    }

    /// The price of a plan too small for its market's own price precision.
    ///
    /// A number that rounds to zero at the market's own precision is a lie about
    /// the position, so it is printed the way the quantity below is: with eight
    /// decimals, or in scientific notation when even those cannot show it. The
    /// caller still gets a bare number — an unknown currency is not an excuse to
    /// invent dollars.
    private static func formattedPrice(_ value: Double, market: Market) -> String {
        let formatted = PriceFormatter.price(value, market: market)
        // `allDigitsAreZero` is the real test, not a nil check: a formatter that
        // cannot show the value still returns the string "0" rather than
        // nothing, so falling back on `nil` alone would print the zero this
        // whole path exists to avoid.
        guard value != 0, allDigitsAreZero(formatted) else { return formatted }
        if let widened = formattedFraction(value, maximumFractionDigits: 8),
           !allDigitsAreZero(widened) {
            return widened
        }
        return scientific(value)
    }

    /// A quantity with the unit the instrument is counted in.
    ///
    /// The unit follows the caller's *resolved* instrument type. Guessing
    /// "shares" for something unknown would invent a claim about what the user
    /// holds, so an unknown type gets the neutral unit instead.
    static func quantity(
        _ value: Double,
        symbol: SymbolID,
        instrumentType: InstrumentType? = nil
    ) -> String {
        guard value.isFinite else { return unknown }
        return "\(formattedQuantity(value)) \(quantityUnit(symbol: symbol, instrumentType: instrumentType))"
    }

    /// Price and quantity as one cell: `1,234.50 USD × 0.005 BTC`.
    ///
    /// Half a pair is misleading — a price with no money, or a size with no
    /// unit — so the two travel together and share one dash when either side is
    /// not a real number.
    static func priceQuantity(
        price priceValue: Double,
        quantity quantityValue: Double,
        symbol: SymbolID,
        currencyCode: String? = nil,
        instrumentType: InstrumentType? = nil
    ) -> String {
        guard priceValue.isFinite, quantityValue.isFinite else { return unknown }
        return price(priceValue, symbol: symbol, currencyCode: currencyCode)
            + " × " + quantity(quantityValue, symbol: symbol, instrumentType: instrumentType)
    }

    /// The currency a price is printed in: the quote's own when it is usable,
    /// otherwise the instrument's. `nil` only when neither is a real code, in
    /// which case a bare number is more honest than an invented one.
    ///
    /// A crypto pair is deliberately *not* backed by its market's default: the
    /// only money a pair's price can be in is its own quote asset, so a pair
    /// whose quote asset does not survive sanitization has an unknown currency
    /// rather than a stand-in of USD. Every other market's currency is a
    /// property of the venue the symbol actually trades on, so it stands.
    static func normalizedQuoteCurrency(_ raw: String?, symbol: SymbolID) -> String? {
        if let code = sanitizedCode(raw) { return code }
        guard symbol.cryptoPair == nil else { return nil }
        return sanitizedCode(symbol.currencyCode)
    }

    /// The unit a quantity is counted in, localized.
    ///
    /// A crypto pair is the one case the symbol itself can answer, and the
    /// base asset is the whole point: 0.005 BTC is 0.005 BTC, not 0.005 of
    /// some generic unit, and USDT in the pair is money rather than the thing
    /// being counted. A pair whose base half is not a usable asset code — a
    /// provider payload, a punctuation-heavy string, an overlong blob — names
    /// no unit at all, so the neutral unit stands in rather than echoing the
    /// garbage back.
    static func quantityUnit(symbol: SymbolID, instrumentType: InstrumentType? = nil) -> String {
        if let pair = symbol.cryptoPair, let asset = sanitizedCode(pair.baseAsset) { return asset }
        switch instrumentType {
        case .equity: return PulseLocalization.localizedString("trade.unit.shares")
        case .etf, .fund: return PulseLocalization.localizedString("plans.unit.fund")
        default: return PulseLocalization.localizedString("plans.unit.generic")
        }
    }

    /// A finite quantity, printed so a real size is never shown as zero.
    ///
    /// `PriceFormatter.quantity` tops out at four decimals, which is right for
    /// a share count and wrong for a crypto size: 0.00000005 BTC is a real
    /// holding, and rounding it to "0" would claim the position is empty.
    /// Integral values keep the formatter's own integral output, everything
    /// else gets up to eight decimals — the app's widest legitimate size, and
    /// the same ceiling the text export uses — and a value too small for even
    /// that is printed in scientific notation rather than as a zero.
    static func formattedQuantity(_ value: Double) -> String {
        guard value.isFinite else { return unknown }
        if value == 0 || value.rounded() == value { return PriceFormatter.quantity(value) }
        if let exact = formattedFraction(value, maximumFractionDigits: 8),
           !allDigitsAreZero(exact) {
            return exact
        }
        return scientific(value)
    }

    /// A locale-correct decimal with a hard cap on fraction digits, or `nil`
    /// when the request cannot be satisfied.
    ///
    /// `NumberFormatter` rounds *and* reports its own failure: when the value
    /// is nonzero but every digit it could print is a zero, it returns a
    /// string like "0" rather than the lie, which is exactly the signal the
    /// callers above need to fall back instead of printing it.
    private static func formattedFraction(_ value: Double, maximumFractionDigits: Int) -> String? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.locale = .autoupdatingCurrent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.roundingMode = .halfUp
        // No scientific style, and never a currency symbol: this is a bare size
        // or a bare price, and both are read beside a unit the caller supplies.
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value))
    }

    /// Whether every digit in an already-formatted number is zero.
    private static func allDigitsAreZero(_ text: String) -> Bool {
        !text.contains { $0.isNumber && $0 != "0" }
    }

    /// A nonzero value too small for ordinary decimals: `5E-8`.
    ///
    /// The exponent is written the way the rest of the app writes machine
    /// numbers, and the mantissa carries enough digits to distinguish two
    /// nearby sizes rather than collapsing them onto one string.
    private static func scientific(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .scientific
        formatter.locale = .autoupdatingCurrent
        formatter.exponentSymbol = "E"
        formatter.positiveFormat = "0.####E0"
        formatter.negativeFormat = "-0.####E0"
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// A currency or asset code, or nothing.
    ///
    /// A quote's `currencyCode` is provider text and reaches a row as-is today,
    /// so it cannot be printed on trust. What qualifies is a short code of
    /// upper-case ASCII alphanumerics: `USD`, `HKD`, `USDT`, and the real
    /// assets that carry digits — `1INCH`, `1000SATS`, `USDC` — while spaces,
    /// punctuation, lowercase payload fragments, and anything overlong are
    /// dropped rather than echoed into a row. The length window is the one
    /// the crypto and currency universes actually occupy; a code outside it is
    /// not made up into a shorter one.
    private static func sanitizedCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...12).contains(trimmed.count),
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return trimmed.uppercased()
    }
}

extension TradePlanEntry {
    var displayStatusTitle: String {
        let key: String = switch displayState {
        case .waiting: "plans.display.waiting"
        case .filled: "plans.display.filled"
        case .abandoned: "plans.display.abandoned"
        case .stopped: filledQuantity > 0 ? "plans.display.incomplete" : "plans.display.unrecorded"
        }
        return PulseLocalization.localizedString(key)
    }

    var fillDateText: String? {
        lastFillDate?.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }

    /// What the linked fills actually paid, as a stored-string property.
    ///
    /// Source-compatible with every existing caller — `entry.actualFillText`
    /// still reads as an optional string — but no longer the whole story: the
    /// unit and the quote currency depend on an instrument type and a quote
    /// that a bare property cannot see, so the work moved to the method below
    /// and this only supplies the defaults.
    var actualFillText: String? {
        actualFillText(currencyCode: nil, instrumentType: nil)
    }

    /// The same fill, printed with an explicit unit and quote currency.
    ///
    /// `nil` when no fill was counted at all: an absent record is not the same
    /// as a zero, and the row that shows nothing is telling the truth.
    func actualFillText(currencyCode: String? = nil, instrumentType: InstrumentType? = nil) -> String? {
        guard let averageFillPrice, averageFillPrice.isFinite else { return nil }
        return PulseLocalization.localizedString("plans.display.actualFill",
            PlanValueText.price(averageFillPrice, symbol: symbol, currencyCode: currencyCode),
            PlanValueText.quantity(filledQuantity, symbol: symbol, instrumentType: instrumentType))
    }
}

struct PlanStatusBadge: View {
    let entry: TradePlanEntry

    private var tint: Color {
        switch entry.displayState {
        case .waiting: .secondary
        case .filled: .teal
        case .abandoned: .secondary
        case .stopped: .orange
        }
    }

    var body: some View {
        Text(entry.displayStatusTitle)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
            .fixedSize()
    }
}
