// Design-only native render. No application target, credentials, or live data.
// Preview of the 跟踪 section with a shared Beijing-time axis. Numbers are illustrative.
import Foundation
import SwiftUI
import AppKit

private let red     = Color(red: 0.91, green: 0.26, blue: 0.29)
private let violet  = Color(red: 0.52, green: 0.34, blue: 0.88)
private let ink     = Color(red: 0.10, green: 0.15, blue: 0.22)
private let muted   = Color(red: 0.47, green: 0.52, blue: 0.59)
private let amber   = Color(red: 0.86, green: 0.58, blue: 0.12)
private let hair    = Color(red: 0.78, green: 0.81, blue: 0.86)
private let card    = Color(red: 0.985, green: 0.99, blue: 1.0)
private let chipBg  = Color(red: 0.955, green: 0.965, blue: 0.98)

// MARK: - Clock

/// One wall-clock instant read in China standard time. Every x position in this
/// file is a fraction of the 08:00–15:00 CST window, so a point on any row means
/// the same moment as the point directly above or below it on any other row.
private enum Clock {
    static let start = 8 * 60
    static let end = 15 * 60
    static var span: Double { Double(end - start) }

    static func fraction(_ minute: Double) -> Double {
        (minute - Double(start)) / span
    }

    static let cnOpen = 9 * 60 + 30
    static let cnMorningEnd = 11 * 60 + 30
    static let cnAfternoonAt = 13 * 60
    static let krOpen = 8 * 60
    static let krClose = 14 * 60 + 30
    static let cnClose = 15 * 60
    static let now = 13 * 60 + 12
}

// MARK: - Illustrative series

private func cnPercent(_ tradingMinute: Double) -> Double {
    let u = tradingMinute / 240
    return 0.0034 * u + 0.0016 * sin(u * 11) + 0.0011 * sin(u * 27 + 1.1) + 0.0007 * sin(u * 61 + 0.4)
}

private func krPercent(_ koreanMinute: Double) -> Double {
    let u = koreanMinute / 390
    return 0.0312 * u + 0.0042 * sin(u * 8 + 0.4) - 0.0030 * sin(u * 21 + 0.2) + 0.0014 * sin(u * 53)
}

private func krIsOpen(_ koreanMinute: Double) -> Bool { koreanMinute <= 390 }

// MARK: - Row sparkline

private struct RowSparkline: View {
    let points: [(x: Double, percent: Double)]
    let tint: Color
    var height: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 2
            let bottom: CGFloat = size.height - 2

            func y(_ percent: Double) -> CGFloat {
                let t = (percent + 0.02) / 0.075
                return bottom - CGFloat(min(max(t, 0), 1)) * (bottom - top)
            }

            var line = Path()
            for (index, point) in points.enumerated() {
                let x = CGFloat(point.x) * size.width
                if index == 0 { line.move(to: CGPoint(x: x, y: y(point.percent))) }
                else { line.addLine(to: CGPoint(x: x, y: y(point.percent))) }
            }
            context.stroke(line, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))

            // Now dot: the same x on every row because the axis is shared.
            let nowX = CGFloat(Clock.fraction(Double(Clock.now))) * size.width
            if let nowPoint = points.last {
                let dot = CGRect(x: nowX - 2, y: y(nowPoint.percent) - 2, width: 4, height: 4)
                context.fill(Path(ellipseIn: dot), with: .color(tint))
            }
        }
        .frame(height: height)
    }
}

private func cnRowPoints() -> [(x: Double, percent: Double)] {
    stride(from: 0.0, through: 240.0, by: 4).compactMap { t in
        // The A-share line stops at "now": an intraday chart never draws the future.
        let minute = t <= 120 ? Double(Clock.cnOpen) + t : Double(Clock.cnAfternoonAt) + (t - 120)
        guard minute <= Double(Clock.now) else { return nil }
        return (Clock.fraction(minute), cnPercent(t))
    }
}

private func krRowPoints() -> [(x: Double, percent: Double)] {
    stride(from: 0.0, through: 390.0, by: 4).compactMap { m in
        let minute = Double(Clock.krOpen) + m
        guard minute <= Double(Clock.now) else { return nil }
        return (Clock.fraction(minute), krPercent(m))
    }
}

// MARK: - Shared axis strip

private struct AxisStrip: View {
    var body: some View {
        Canvas { context, size in
            let marks: [(Double, String)] = [
                (Clock.fraction(Double(Clock.krOpen)), "09:00"),
                (Clock.fraction(Double(Clock.cnOpen)), "09:30"),
                (Clock.fraction(Double(Clock.cnMorningEnd)), "11:30"),
                (Clock.fraction(Double(Clock.cnAfternoonAt)), "13:00"),
                (Clock.fraction(Double(Clock.krClose)), "15:30"),
                (Clock.fraction(Double(Clock.cnClose)), "15:00"),
            ]
            for mark in marks {
                let x = CGFloat(mark.0) * size.width
                let text = context.resolve(
                    Text(mark.1).font(.system(size: 7, design: .monospaced)).foregroundStyle(muted)
                )
                let clamped = min(max(x, 11), size.width - 11)
                context.draw(text, at: CGPoint(x: clamped, y: 0), anchor: .top)
            }
        }
        .frame(height: 14)
    }
}

// MARK: - Rows

private struct TrackRow: View {
    let name: String
    let market: String
    let code: String
    let price: String
    let change: String
    let tint: Color
    let points: [(x: Double, percent: Double)]

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(ink)
                HStack(spacing: 4) {
                    Text(market).font(.system(size: 6.5, weight: .medium)).foregroundStyle(muted)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(chipBg, in: RoundedRectangle(cornerRadius: 3))
                    Text(code).font(.system(size: 7, design: .monospaced)).foregroundStyle(muted)
                }
            }
            .frame(width: 74, alignment: .leading)

            RowSparkline(points: points, tint: tint)
                .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 3) {
                Text(price).font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(ink)
                Text(change).font(.system(size: 8, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: 62, alignment: .trailing)
        }
        .frame(height: 38)
    }
}

// MARK: - Section card

private struct TrackingSection: View {
    /// Height of the axis strip plus the four rows and their dividers. The lunch
    /// band uses the same number so it cannot outrun the data it explains.
    private var rowBlockHeight: CGFloat { 14 + 2 + 4 * 38 + 3 * 1 }
    /// Left inset of the sparkline column: the name column plus the row's own
    /// spacing. The band and every sparkline must agree on this or the band
    /// drifts away from the data it is meant to bracket.
    private let plotInset: CGFloat = 74 + 8
    /// Right inset: the price/change column plus its spacing.
    private let plotTrailing: CGFloat = 62 + 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group tabs
            HStack(spacing: 6) {
                ForEach(["持仓", "指数", "跟踪", "美股", "行业"], id: \.self) { name in
                    let selected = name == "跟踪"
                    Text(name)
                        .font(.system(size: 8.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color(red: 0.06, green: 0.45, blue: 0.96) : muted)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(selected
                            ? Color(red: 0.06, green: 0.45, blue: 0.96).opacity(0.12) : chipBg))
                }
                Spacer(minLength: 2)
                Image(systemName: "plus").font(.system(size: 9)).foregroundStyle(muted)
            }
            .padding(.bottom, 8)

            // The band and the axis live in one stack so the band's geometry is
            // measured against the plot column, not the whole card.
            VStack(alignment: .leading, spacing: 0) {
                AxisStrip()
                    .padding(.bottom, 2)
                    .background(alignment: .leading) {
                        // Tinted from the very top of the axis strip, so the strip
                        // itself sits inside the band rather than above it.
                        GeometryReader { geometry in
                            let plotWidth = geometry.size.width - plotInset - plotTrailing
                            let bandLeft = plotInset
                                + CGFloat(Clock.fraction(Double(Clock.cnMorningEnd))) * plotWidth
                            let bandWidth = CGFloat(Clock.fraction(Double(Clock.cnAfternoonAt))
                                                    - Clock.fraction(Double(Clock.cnMorningEnd))) * plotWidth
                            Rectangle()
                                .fill(amber.opacity(0.14))
                                .frame(width: bandWidth, height: geometry.size.height)
                                .offset(x: bandLeft)
                        }
                    }

                // The lunch band continues through the rows.
                TrackRow(name: "兆易创新", market: "A", code: "603986", price: "279.17", change: "+0.34%",
                         tint: red, points: cnRowPoints())
                    .background(alignment: .leading) { lunchBand }
                Divider().opacity(0.5)
                TrackRow(name: "三星电子", market: "韩", code: "005930", price: "215500", change: "+2.62%",
                         tint: violet, points: krRowPoints())
                    .background(alignment: .leading) { lunchBand }
                Divider().opacity(0.5)
                TrackRow(name: "韩国综合指数", market: "韩", code: "KOSPI", price: "5668.05", change: "+2.05%",
                         tint: violet, points: krRowPoints())
                    .background(alignment: .leading) { lunchBand }
                Divider().opacity(0.5)
                TrackRow(name: "SK海力士", market: "韩", code: "000660", price: "1272000", change: "+0.79%",
                         tint: violet, points: krRowPoints())
                    .background(alignment: .leading) { lunchBand }
            }
        }
        .padding(11)
        .frame(width: 376)
        .background(card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(hair.opacity(0.6), lineWidth: 0.5))
    }

    /// One row's slice of the lunch band, positioned in the plot column. Drawn
    /// per row so the band can never outrun the data it explains, and so the
    /// dividers between rows stay visible through it.
    private var lunchBand: some View {
        GeometryReader { geometry in
            let plotWidth = geometry.size.width - plotInset - plotTrailing
            let bandLeft = plotInset
                + CGFloat(Clock.fraction(Double(Clock.cnMorningEnd))) * plotWidth
            let bandWidth = CGFloat(Clock.fraction(Double(Clock.cnAfternoonAt))
                                    - Clock.fraction(Double(Clock.cnMorningEnd))) * plotWidth
            Rectangle()
                .fill(amber.opacity(0.14))
                .frame(width: bandWidth, height: geometry.size.height)
                .offset(x: bandLeft)
        }
    }
}

// MARK: - Comparison

private struct ComparisonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("同一条北京时间轴 · 同一时刻 = 同一个 x").font(.system(size: 9, weight: .semibold)).foregroundStyle(ink)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("改前").font(.system(size: 8, weight: .medium)).foregroundStyle(muted)
                    Text("韩国行按自己的 09:00–15:30 画，\n与 A 股行的同一时刻不在同一位置。")
                        .font(.system(size: 7.5)).foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hair.opacity(0.35)).frame(height: 30)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("改后").font(.system(size: 8, weight: .medium)).foregroundStyle(muted)
                    Text("韩国行 +1h 投影到北京轴，\n午休带里只有韩国线在走。")
                        .font(.system(size: 7.5)).foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(amber.opacity(0.16)).frame(height: 30)
                        .overlay(alignment: .leading) {
                            Text("午休").font(.system(size: 6.5)).foregroundStyle(amber).padding(.leading, 4)
                        }
                }
            }
        }
        .padding(11)
        .frame(width: 376)
        .background(chipBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Board

private struct Board: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackingSection()
            ComparisonCard()

            // What the band actually buys you, in the one number a trader reads
            // first: how much Korea moved while Shanghai was shut.
            VStack(alignment: .leading, spacing: 7) {
                Text("午休 90 分钟里发生了什么").font(.system(size: 9, weight: .semibold)).foregroundStyle(ink)
                HStack(spacing: 0) {
                    statBlock(label: "A 股", value: "休市", detail: "11:30–13:00 无成交", tint: muted)
                    Spacer(minLength: 8)
                    statBlock(label: "韩国综合", value: "+1.24%", detail: "午休期间独立走完", tint: violet)
                    Spacer(minLength: 8)
                    statBlock(label: "三星电子", value: "+0.86%", detail: "与 KOSPI 同步", tint: violet)
                }
                Text("改前这三列无法对照：韩国线自己的轴把午休那 90 分钟摊在了别的宽度上。")
                    .font(.system(size: 7.5)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(width: 376)
            .background(chipBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
        .frame(width: 416, height: 733, alignment: .topLeading)
        .background(Color(red: 0.93, green: 0.94, blue: 0.96))
    }

    private func statBlock(label: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 7.5)).foregroundStyle(muted)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(tint)
            Text(detail).font(.system(size: 6.5)).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@main struct RenderTrackingSplit {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
            ?? "/Users/cora/Projects/Pulse/docs/design/korea-china-split/korea-china-tracking-preview.png")
        let renderer = ImageRenderer(content: Board().environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.nsImage else { throw NSError(domain: "Render", code: 1) }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Render", code: 2)
        }
        try png.write(to: output)
        print("rendered \(image.size.width)x\(image.size.height) @2x -> \(output.path) (\(png.count) bytes)")
    }
}
