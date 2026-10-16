#if DEBUG
import AppKit
import SwiftUI
import PulseCore

/// Native before/after renders for the question "US tickers should show Chinese
/// names by default".
///
///     ./FFF --main-window-demo --us-name-preview-selftest
///
/// Draws the two production name surfaces — the popover list and the main-window
/// sidebar — over the instruments in the user's own 美股 group, captured twice
/// from the *same* view and the *same* quotes: once with the English names the
/// watchlist stores today, and once after a Chinese name is offered through
/// `WatchlistStore.upgradeDisplayName`. The only difference between the two
/// images is therefore the name the store accepted, which is exactly the
/// question under review.
///
/// The render reports how many rows changed and, when an offer is refused,
/// prints the priority comparison that refused it. That is the point of the
/// exercise: with today's provider ranking the offer *is* refused for US rows,
/// so a preview that only drew pretty Chinese names would be lying.
///
/// Instrument list, prices and intraday closes come from
/// `us-name-preview-fixture.json` (public market data, written by the fetch
/// script; kept outside the repository). A missing fixture fails the render
/// rather than substituting invented names.
///
/// Requires `--main-window-demo`, so it runs in an isolated, wiped defaults
/// suite with every provider disabled: no network, no credentials, no sync, and
/// no access to the user's real watchlist.
@MainActor
enum UsNamePreviewSelfTest {

    private static let groupName = "美股"
    private static let directoryName = "us-names"
    private static let popoverWidth: CGFloat = 340
    private static let sidebarWidth: CGFloat = 281
    private static let height: CGFloat = 650
    /// Stand-in provider rank for the editorial glossary. Higher than any real
    /// provider so a supplemented row cannot be mistaken for a sourced one.
    private static let glossaryPriority = 9_999

    // MARK: - Fixture

    private struct Fixture: Decodable {
        struct Row: Decodable {
            let code: String
            let english: String
            let tencentChinese: String?
            let curated: String?
            let price: Double
            let previousClose: Double
            let sparkline: [Double]
        }
        let sessionStart: TimeInterval
        let intervalSeconds: TimeInterval
        let rows: [Row]
    }

    /// The candidate a source offers for one row.
    private struct Offer {
        var name: String
        var providerID: String
        var localeIdentifier: String
        var isCurated: Bool
    }

    private static func fixtureURL() -> URL {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/app.pulse.mac.dev/Data/tmp")
        let candidates = [
            container.appendingPathComponent("us-name-preview-fixture.json"),
            URL(fileURLWithPath: "build/name-cn/rows.json"),
            FileManager.default.temporaryDirectory.appendingPathComponent("us-name-preview-fixture.json"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    private static func loadFixture() -> Fixture? {
        let url = fixtureURL()
        guard let data = try? Data(contentsOf: url) else {
            print("PULSE_US_NAME_PREVIEW failed error=fixture-missing \(url.path)")
            return nil
        }
        do {
            let fixture = try JSONDecoder().decode(Fixture.self, from: data)
            guard !fixture.rows.isEmpty else {
                print("PULSE_US_NAME_PREVIEW failed error=fixture-empty")
                return nil
            }
            print("US_NAME_PREVIEW_FIXTURE \(url.path) rows=\(fixture.rows.count)")
            return fixture
        } catch {
            print("PULSE_US_NAME_PREVIEW failed error=fixture-decode \(error)")
            return nil
        }
    }

    // MARK: - Run

    static func run() -> Bool {
        guard CommandLine.arguments.contains("--main-window-demo") else {
            print("PULSE_US_NAME_PREVIEW failed error=requires---main-window-demo")
            return false
        }
        guard let fixture = loadFixture() else { return false }

        let state = AppState()
        let store = state.watchlist
        guard let groupID = seedGroup(fixture: fixture, store: store, state: state) else {
            print("PULSE_US_NAME_PREVIEW failed error=could-not-seed-group")
            return false
        }
        // Both surfaces list from the shared facade, not from the financial
        // store, so the group under review must be the shared selection — every
        // other physical group is emptied first, or its rows would be drawn too.
        state.sharedWatchlist.selectGroup(groupID)

        // Baseline: the store must really hold the English name for every row,
        // otherwise the "before" image would be mislabelled.
        for row in fixture.rows {
            let symbol = SymbolID(market: .us, code: row.code)
            guard let item = store.item(for: symbol) else {
                print("PULSE_US_NAME_PREVIEW failed error=missing-item \(row.code)")
                return false
            }
            guard item.displayName == row.english else {
                print("PULSE_US_NAME_PREVIEW failed error=baseline-name \(row.code) "
                    + "stored='\(item.displayName)' expected='\(row.english)'")
                return false
            }
        }

        let offers = offers(for: fixture.rows, state: state)

        let directory = URL(fileURLWithPath: "build/artifacts/\(directoryName)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("PULSE_US_NAME_PREVIEW failed error=output-directory \(error)")
            return false
        }

        let defaults = UserDefaults(suiteName: MainWindowDemo.userDefaultsSuite) ?? .standard

        // BEFORE: exactly what the app shows today.
        do {
            try render(name: "popover-before", width: popoverWidth, scheme: .dark,
                       state: state, defaults: defaults, directory: directory)
            try render(name: "sidebar-before", width: sidebarWidth, scheme: .dark,
                       state: state, defaults: defaults, directory: directory)
        } catch {
            print("PULSE_US_NAME_PREVIEW failed error=render-before \(error)")
            return false
        }

        // The whole list in one image, so every instrument can be checked at once
        // rather than only the rows that fit a popover-height window. This is
        // rendered here, before any name is offered, so it really is the "before"
        // state; the matching "after" is drawn lower down.
        let fullNames = fixture.rows.map { ($0.code, $0.english) }
        let tall = tallHeight(rowCount: fixture.rows.count)
        do {
            try render(name: "list-before-full", width: popoverWidth, height: tall, scheme: .dark,
                       state: state, defaults: defaults, directory: directory)
        } catch {
            print("PULSE_US_NAME_PREVIEW failed error=render-full-before \(error)")
            return false
        }

        // OFFER: write each Chinese name through the store's own watermark path,
        // with the priority the composite actually assigns that provider today.
        //
        // The pass is run twice so the two things the user must judge stay
        // separate. The first pass is the shipping design: only names a wired
        // source really returned. The second adds the hand-written supplement,
        // which is not part of that design and is only here to show what the
        // four remaining English rows would look like with one.
        func offerNames(includingCurated: Bool) -> (accepted: Int, refused: Int, curated: Int, refusal: String?) {
            var accepted = 0, refused = 0, curated = 0
            var refusal: String?
            for row in fixture.rows {
                guard let offer = offers[row.code], includingCurated || !offer.isCurated else { continue }
                let symbol = SymbolID(market: .us, code: row.code)
                let current = store.item(for: symbol)?.displayNameSource
                let priority = state.provider.namePriority(for: offer.providerID, market: .us)
                    ?? Self.glossaryPriority
                let source = DisplayNameSource(
                    providerID: offer.providerID,
                    priority: priority,
                    localeIdentifier: offer.localeIdentifier
                )
                let didUpgrade = store.upgradeDisplayName(
                    for: symbol,
                    to: offer.name,
                    source: source,
                    allowSameProviderRefresh: true
                )
                if didUpgrade {
                    accepted += 1
                    if offer.isCurated { curated += 1 }
                } else {
                    refused += 1
                    if refusal == nil {
                        refusal = "\(row.code): stored "
                            + "\(current.map { "\($0.providerID)(p\($0.priority), \($0.localeIdentifier))" } ?? "none")"
                            + " vs offered \(offer.providerID)(p\(priority), \(offer.localeIdentifier))"
                    }
                }
            }
            return (accepted, refused, curated, refusal)
        }

        let shipped = offerNames(includingCurated: false)

        // AFTER: the same views, same quotes, whatever names the store took.
        do {
            try render(name: "popover-after", width: popoverWidth, scheme: .dark,
                       state: state, defaults: defaults, directory: directory)
            try render(name: "sidebar-after", width: sidebarWidth, scheme: .dark,
                       state: state, defaults: defaults, directory: directory)
            try render(name: "popover-after-light", width: popoverWidth, scheme: .light,
                       state: state, defaults: defaults, directory: directory)
        } catch {
            print("PULSE_US_NAME_PREVIEW failed error=render-after \(error)")
            return false
        }

        // The whole list in one image, so every instrument can be checked at once
        // rather than only the rows that fit a popover-height window. The window
        // is made tall enough for all of them; the view itself is unchanged.
        do {
            try render(name: "list-after-full", width: popoverWidth, height: tall, scheme: .dark,
                       state: state, defaults: defaults, directory: directory)
        } catch {
            print("PULSE_US_NAME_PREVIEW failed error=render-full \(error)")
            return false
        }
        for (code, expected) in fullNames {
            let actual = store.item(for: SymbolID(market: .us, code: code))?.displayName
            print("US_NAME_PREVIEW_ROW \(code) '\(expected)' -> '\(actual ?? "<none>")'")
        }

        let supplemented = offerNames(includingCurated: true)
        do {
            try render(name: "popover-after-supplemented", width: popoverWidth, scheme: .dark,
                       state: state, defaults: defaults, directory: directory)
        } catch {
            print("PULSE_US_NAME_PREVIEW failed error=render-supplemented \(error)")
            return false
        }

        let finalNames = fixture.rows.compactMap {
            store.item(for: SymbolID(market: .us, code: $0.code))?.displayName
        }
        let chinese = finalNames.filter(hasCJK).count
        print("US_NAME_PREVIEW_RESULT symbols=\(fixture.rows.count) "
            + "shippedOffered=\(shipped.accepted + shipped.refused) shippedAccepted=\(shipped.accepted) "
            + "shippedRefused=\(shipped.refused) "
            + "curatedAccepted=\(supplemented.curated) "
            + "chineseNames=\(chinese) englishNames=\(finalNames.count - chinese)")
        if let refusal = shipped.refusal {
            print("US_NAME_PREVIEW_REFUSAL \(refusal)")
        }
        print("PULSE_US_NAME_PREVIEW ok dir=\(directory.path) rendered=popover-before,sidebar-before,"
            + "popover-after,sidebar-after,popover-after-light,popover-after-supplemented")
        return true
    }

    // MARK: - Seeding

    /// Builds the group under review, reproduces the provenance the user's real
    /// rows carry, and applies each quote and intraday series.
    ///
    /// The seeded name is written through `SymbolInfo.displayNameSource` with
    /// the same `yahoo` / priority 1 / `en` watermark the live watchlist stores.
    /// That matters: `upgradeDisplayName` replaces a name only when the offer
    /// outranks what is already there, so a preview seeded without a watermark
    /// would accept any candidate and show a result the app cannot deliver.
    private static func seedGroup(fixture: Fixture, store: WatchlistStore, state: AppState) -> UUID? {
        // Start from the demo's own group so no second tag is invented, then drop
        // everything already in it: the fixture decides the contents.
        MainWindowDemo.seed(state: state)
        guard let groupID = store.selectedGroup?.id else { return nil }
        // Name the tag as the user's list is named, so the render shows the same
        // tab label the question refers to.
        _ = store.renameGroup(groupID, to: groupName)
        for symbol in store.selectedGroup?.symbols ?? [] {
            store.setMembership(symbol, in: groupID, included: false)
        }
        // Any other tag would contribute rows to the same shared list.
        for group in store.groups where group.id != groupID {
            for symbol in group.symbols {
                store.setMembership(symbol, in: group.id, included: false)
            }
        }

        let yahoo = DisplayNameSource(providerID: "yahoo", priority: 1, localeIdentifier: "en")
        for row in fixture.rows {
            let symbol = SymbolID(market: .us, code: row.code)
            store.add(SymbolInfo(symbol: symbol, name: row.english, type: .equity,
                                 displayNameSource: yahoo), to: groupID)
        }
        // `add` inserts at the top of the unpinned block, so the stored order is
        // reversed. Restore the fixture order.
        store.reorder(fixture.rows.map { SymbolID(market: .us, code: $0.code) })

        let start = Date(timeIntervalSince1970: fixture.sessionStart)
        let interval = fixture.intervalSeconds
        var quotes: [Quote] = []
        for row in fixture.rows {
            let symbol = SymbolID(market: .us, code: row.code)
            let closes = row.sparkline
            quotes.append(Quote(
                symbol: symbol,
                name: row.english,
                price: row.price,
                previousClose: row.previousClose,
                open: closes.first ?? row.price,
                high: closes.max() ?? row.price,
                low: closes.min() ?? row.price,
                currencyCode: "USD",
                sourceID: "yahoo",
                sourceName: "Yahoo Finance",
                timestamp: start.addingTimeInterval(interval * Double(max(closes.count - 1, 0))),
                marketState: .closed
            ))
            let candles = closes.enumerated().map { offset, close in
                Candle(time: start.addingTimeInterval(interval * Double(offset)),
                       open: close, high: close, low: close, close: close)
            }
            state.market.cache(candles: candles, for: CandleCacheKey(symbol: symbol, period: .minute1))
            state.market.apply(sparkline: candles, for: symbol)
        }
        state.market.apply(quotes: quotes)
        return groupID
    }

    // MARK: - Offers

    /// Same test the provider applies before it will call a name Chinese, so the
    /// preview cannot show a row the shipping path would refuse to upgrade.
    private static func hasCJK(_ text: String) -> Bool {
        SecurityName.isChineseName(text)
    }

    /// What each wired source offers per instrument. Tencent is the only
    /// registered source that returns Chinese for US names, and the hand-written
    /// supplement is kept separate so it can never be mistaken for a live result.
    ///
    /// A glossary name carries `glossaryPriority`, which no provider holds, so a
    /// supplemented row is visibly stamped as editorial rather than attributed to
    /// a source that never said it. The shipping design does not include the
    /// glossary at all — see the second offer pass in `run()`.
    private static func offers(for rows: [Fixture.Row], state: AppState) -> [String: Offer] {
        var result: [String: Offer] = [:]
        for row in rows {
            if let chinese = row.tencentChinese, hasCJK(chinese) {
                result[row.code] = Offer(name: chinese, providerID: "tencent",
                                         localeIdentifier: "zh-Hans", isCurated: false)
            } else if let curated = row.curated, hasCJK(curated) {
                result[row.code] = Offer(name: curated, providerID: "glossary",
                                         localeIdentifier: "zh-Hans", isCurated: true)
            }
        }
        return result
    }

    // MARK: - Render

    /// Height that fits every row of the list, so the full picture can be
    /// reviewed in one image. Roughly one row per 62pt plus the chrome.
    private static func tallHeight(rowCount: Int) -> CGFloat {
        200 + CGFloat(rowCount) * 62
    }

    private static func render(name: String, width: CGFloat,
                               height: CGFloat? = nil, scheme: ColorScheme,
                               state: AppState, defaults: UserDefaults,
                               directory: URL) throws {
        let resolvedHeight = height ?? Self.height
        let view: AnyView = name.hasPrefix("sidebar")
            ? AnyView(MainWatchlistSidebar(selectedSymbol: .constant(nil), currentPage: nil,
                                           onShowPage: { _ in })
                .environment(state)
                .defaultAppStorage(defaults))
            : AnyView(WatchlistView(route: .constant(.list), searchSession: .constant(SearchSession()))
                .environment(state)
                .defaultAppStorage(defaults))
        let framed = view
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.colorScheme, scheme)
            .frame(width: width, height: resolvedHeight)
        try renderOffscreen(view: framed, width: width, height: resolvedHeight,
                            to: directory.appendingPathComponent("\(name).png"), scheme: scheme)
    }

    /// Local copy of the canonical offscreen harness. It is duplicated rather
    /// than shared because `TacticalBoardSelfTest`'s helper is private to that
    /// type and its blank-region guard assumes a pool board.
    private static func renderOffscreen<V: View>(view: V, width: CGFloat, height: CGFloat,
                                                 to url: URL, scheme: ColorScheme) throws {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = frame

        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance
        window.backgroundColor = scheme == .dark ? .black : .white
        window.contentView = hosting
        // Parked beyond any real display; `orderBack` runs the layout pass the
        // lazy list needs without ever coming forward.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw ShareImageError.renderingFailed
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ShareImageError.encodingFailed
        }
        if CommandLine.arguments.contains("--export-render-base64") {
            print("PULSE_RENDER_BASE64 \(url.lastPathComponent) \(data.base64EncodedString())")
            fflush(stdout)
        } else {
            try data.write(to: url)
        }
        print("US_NAME_PREVIEW_RENDER \(url.lastPathComponent) "
            + "\(rep.pixelsWide)x\(rep.pixelsHigh) bytes=\(data.count)")
        fflush(stdout)
    }
}
#endif
