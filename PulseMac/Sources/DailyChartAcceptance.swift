#if DEBUG
import AppKit
import SwiftUI
import PulseCore

/// Public market data only; saved credentials stay inside the signed app.
@MainActor
enum DailyChartAcceptance {
    static func run(provider: FuyaoProvider) async -> Bool {
        let symbol = SymbolID(market: .sz, code: "001309")
        let tencent = TencentProvider()
        do {
            let raw = try await tencent.candles(for: symbol, period: .day, count: 100)
            let alternate = try await tencent.candles(for: symbol, period: .day, count: 100, adjustment: .forward)
            let forward: [Candle]
            do {
                forward = try await provider.candles(for: symbol, period: .day, count: 100, adjustment: .forward)
                print("PULSE_DAILY_CONTRACT fuyao forward fetched rows=\(forward.count)")
            } catch {
                print("PULSE_DAILY_CONTRACT fuyao unavailable \(String(describing: error)); verifying adjusted fallback")
                forward = alternate
            }
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = Market.sz.timeZone
            func close(_ bars: [Candle], _ day: String) -> Double? { bars.first { formatter.string(from: $0.time) == day }?.close }
            guard let old = close(raw, "2026-10-12"), let adjusted = close(forward, "2026-10-12"),
                  let backup = close(alternate, "2026-10-12"),
                  abs(old - 321.43) < 0.01, abs(adjusted - (old - 1.5) / 1.4) < 0.02,
                  abs(adjusted - backup) < 0.02,
                  let current = raw.last, let last = forward.last,
                  current.time == last.time, abs(current.close - last.close) < 0.01 else {
                print("PULSE_DAILY_CONTRACT failed historical basis check"); return false
            }
            print("PULSE_DAILY_CONTRACT day ok actual=\(old) forward=\(adjusted) tencent=\(backup) latest=\(last.close) rows=\(forward.count)")
            for period in [CandlePeriod.week, .month] {
                let bars = try await tencent.candles(for: symbol, period: period, count: 100, adjustment: .forward)
                guard !bars.isEmpty, bars.allSatisfy({ $0.low > 0 && $0.high >= $0.low }),
                      let recent = bars.last, abs(recent.close - last.close) < 0.02 else {
                    print("PULSE_DAILY_CONTRACT failed \(period.rawValue)"); return false
                }
                print("PULSE_DAILY_CONTRACT \(period.rawValue) ok rows=\(bars.count) latest=\(bars.last!.close)")
            }
            let quote = try await tencent.quotes(for: [symbol])
            let state = AppState()
            let defaults = UserDefaults(suiteName: MainWindowDemo.userDefaultsSuite)!
            state.sharedWatchlist.add(.init(symbol: symbol, name: "德明利", type: .equity))
            state.market.apply(quotes: quote)
            state.market.cache(candles: raw, for: .init(symbol: symbol, period: .day))
            state.market.cache(candles: forward, for: .init(symbol: symbol, period: .day, adjustment: .forward))
            for adjustment in CandleAdjustment.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    try await render(DetailView(symbol: symbol, route: .constant(.detail(symbol)), initialPeriod: .day, initialAdjustment: adjustment)
                        .environment(state).defaultAppStorage(defaults), name: "popover-\(adjustment.rawValue)-\(scheme == .dark ? "dark" : "light")", width: 340, height: 670, scheme: scheme)
                }
            }
            try await render(MainInstrumentView(symbol: symbol, initialPeriod: .day).environment(state).defaultAppStorage(defaults),
                name: "main-forward", width: 900, height: 850, scheme: .light)
            print("PULSE_DAILY_CONTRACT ok renders=5")
            return true
        } catch {
            print("PULSE_DAILY_CONTRACT failed \(String(describing: error))")
            return false
        }
    }

    private static func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme) async throws {
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
        for _ in 0..<8 { hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded(); try await Task.sleep(for: .milliseconds(100)) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        print("PULSE_DAILY_RENDER \(name) \(png.base64EncodedString())")
    }
}
#endif
