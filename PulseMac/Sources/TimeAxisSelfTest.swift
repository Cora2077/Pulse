#if DEBUG
import AppKit
import SwiftUI
import PulseCore

@MainActor
enum TimeAxisSelfTest {
    static func run() -> Bool {
        guard CommandLine.arguments.contains("--main-window-demo") else { return false }
        let state = AppState()
        let defaults = UserDefaults(suiteName: MainWindowDemo.userDefaultsSuite)!
        defaults.set(WatchlistOrderMode.manual.rawValue, forKey: "pulse.watchlist.orderMode.v1")
        guard let group = state.sharedWatchlist.createGroup(named: "同轴验证") else { return false }
        let infos: [SymbolInfo] = [
            .init(symbol: .init(market: .sh, code: "600519"), name: "合成 A 股", type: .equity),
            .init(symbol: .init(market: .sz, code: "300750"), name: "合成深市", type: .equity),
            .init(symbol: .init(market: .kr, code: "005930"), name: "合成三星", type: .equity),
            .init(symbol: .init(market: .kr, code: "000660"), name: "合成海力士", type: .equity),
            .init(symbol: .init(market: .kr, code: "KOSPI"), name: "合成韩国指数", type: .index)]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = Market.sh.timeZone
        let day = calendar.startOfDay(for: .now)
        func at(_ hour: Int, _ minute: Int) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)! }
        for (index, info) in infos.enumerated() {
            state.sharedWatchlist.add(info, to: group)
            let isChina = info.symbol.market == .sh || info.symbol.market == .sz
            let times = stride(from: isChina ? 570 : 480, through: 870, by: 5).filter { !isChina || $0 <= 690 || $0 >= 780 }
            let base = Double(index + 1) * 100
            let bars: [Candle] = times.map { minute in
                let price = base + sin(Double(minute - 480) / 38) * 2 + Double(minute - 480) / 120
                return .init(time: at(minute / 60, minute % 60), open: price, high: price, low: price, close: price, volume: 100)
            }
            state.market.apply(sparkline: bars, for: info.symbol)
            state.market.apply(quotes: [.init(symbol: info.symbol, name: info.name, price: bars.last!.close,
                previousClose: base, timestamp: at(14, 30))])
        }
        state.sharedWatchlist.selectGroup(group)
        state.sharedWatchlist.setChinaAligned(true, for: group)
        do {
            for width in [340.0, 280.0] {
                for scheme in [ColorScheme.light, .dark] {
                    let view = WatchlistView(route: .constant(.list), searchSession: .constant(SearchSession()))
                        .environment(state).defaultAppStorage(defaults)
                    try render(view, name: "popover-\(Int(width))-\(scheme == .dark ? "dark" : "light")", width: width, height: 380, scheme: scheme)
                }
            }
            let sidebar = MainWatchlistSidebar(selectedSymbol: .constant(nil), currentPage: nil, onShowPage: { _ in })
                .environment(state).defaultAppStorage(defaults)
            try render(sidebar, name: "sidebar-aligned", width: 281, height: 960, scheme: .light)
            state.sharedWatchlist.setChinaAligned(false, for: group)
            try render(WatchlistView(route: .constant(.list), searchSession: .constant(SearchSession())).environment(state).defaultAppStorage(defaults),
                name: "popover-independent", width: 340, height: 380, scheme: .light)
            // Freeze all historical bars at 10:00, then move only the quote.
            // This exercises the actual WatchRow -> Canvas integration.
            for (index, info) in infos.enumerated() {
                let base = Double(index + 1) * 100
                let firstMinute = info.symbol.market == .kr ? 480 : 570
                let frozen = stride(from: firstMinute, through: 600, by: 2).map { minute -> Candle in
                    let price = base + sin(Double(minute - 480) / 20)
                    return .init(time: at(minute / 60, minute % 60), open: price, high: price, low: price, close: price, volume: 100)
                }
                state.market.apply(sparkline: frozen, for: info.symbol)
                state.market.apply(quotes: [.init(symbol: info.symbol, name: info.name, price: base + 0.5,
                    previousClose: base, sourceID: "synthetic-live", timestamp: at(10, 2))])
            }
            try render(WatchlistView(route: .constant(.list), searchSession: .constant(SearchSession())).environment(state).defaultAppStorage(defaults),
                name: "live-history-fixed-1000-quote-1002", width: 340, height: 380, scheme: .light)
            for (index, info) in infos.enumerated() {
                let base = Double(index + 1) * 100
                state.market.apply(quotes: [.init(symbol: info.symbol, name: info.name, price: base + 2,
                    previousClose: base, sourceID: "synthetic-live", timestamp: at(10, 8))])
            }
            try render(WatchlistView(route: .constant(.list), searchSession: .constant(SearchSession())).environment(state).defaultAppStorage(defaults),
                name: "live-history-fixed-1000-quote-1008", width: 340, height: 380, scheme: .light)
            print("PULSE_TIME_AXIS_SELFTEST ok renders=8")
            return true
        } catch { print("PULSE_TIME_AXIS_SELFTEST failed: \(error.localizedDescription)"); return false }
    }

    private static func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme) throws {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height)
            .environment(\.locale, Locale(identifier: "zh_CN")).environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance; window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<6 { hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded(); RunLoop.current.run(until: .now.addingTimeInterval(0.1)) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        print("PULSE_TIME_AXIS_RENDER \(name) \(png.base64EncodedString())")
    }
}
#endif
