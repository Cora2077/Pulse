// Design-only native render. No application target, credentials, or live data.
// Korean quotes re-cut onto a China-standard-time axis. Numbers are illustrative.
import Foundation
import SwiftUI
import AppKit

private let red    = Color(red: 0.91, green: 0.26, blue: 0.29)
private let violet = Color(red: 0.52, green: 0.34, blue: 0.88)
private let ink    = Color(red: 0.10, green: 0.15, blue: 0.22)
private let muted  = Color(red: 0.47, green: 0.52, blue: 0.59)
private let amber  = Color(red: 0.88, green: 0.60, blue: 0.14)
private let hair   = Color(red: 0.80, green: 0.83, blue: 0.87)

// MARK: - Clock

/// Every x position below is one wall-clock instant read in China standard time,
/// so a point placed on the Korean line means the same moment as the point
/// directly above or below it on the Chinese line.
private enum Clock {
    static let axisStart = 8 * 60       // 08:00 CST = 09:00 KST
    static let axisEnd   = 15 * 60      // 15:00 CST = 16:00 KST
    static var span: Double { Double(axisEnd - axisStart) }

    static func fraction(_ minute: Double) -> Double {
        (minute - Double(axisStart)) / span
    }
    static func fraction(hour: Int, _ minute: Int) -> Double {
        fraction(Double(hour * 60 + minute))
    }

    static let krOpen        = 8 * 60        // 09:00 KST
    static let cnOpen        = 9 * 60 + 30
    static let cnMorningEnd  = 11 * 60 + 30
    static let cnAfternoonAt = 13 * 60
    static let krClose       = 14 * 60 + 30  // 15:30 KST
    static let cnClose       = 15 * 60

    /// A-share trading minute (0…240, lunch folded out) → CST clock minute.
    static func cnClockMinute(_ tradingMinute: Double) -> Double {
        tradingMinute <= 120
            ? Double(cnOpen) + tradingMinute
            : Double(cnAfternoonAt) + (tradingMinute - 120)
    }

    /// Korean minute (0…390 from 09:00 KST) → CST clock minute.
    static func krClockMinute(_ koreanMinute: Double) -> Double {
        Double(krOpen) + koreanMinute
    }
}

// MARK: - Illustrative series

private let cnPreviousClose = 3717.56 / 1.0027
private let krPreviousClose = 5727.37 / 1.0312

/// Percent against previous close, shaped so the two lines tell a story:
/// Korea runs ahead through the morning, keeps climbing while Shanghai is at
/// lunch, then gives some back into the Shanghai afternoon.
private func cnPercent(_ tradingMinute: Double) -> Double {
    let u = tradingMinute / 240
    return 0.0027 * u
        + 0.0016 * sin(u * 11.0)
        + 0.0011 * sin(u * 27.0 + 1.1)
        + 0.0007 * sin(u * 61.0 + 0.4)
}

private func krPercent(_ koreanMinute: Double) -> Double {
    let u = koreanMinute / 390
    return 0.0312 * u
        + 0.0042 * sin(u * 8.0 + 0.4)
        - 0.0030 * sin(u * 21.0 + 0.2)
        + 0.0014 * sin(u * 53.0)
}

private let nowCST = 13 * 60 + 12          // 13:12 Beijing / 14:12 Seoul
private let nowCNTrading = 120.0 + 12.0
private let nowKRMinute = Double(nowCST - Clock.krOpen)

// MARK: - Chart

private struct Series: Identifiable {
    let id = UUID()
    let fraction: Double   // 0…1 across the plot width
    let percent: Double
}

private func cnSeries() -> [Series] {
    stride(from: 0.0, through: 240.0, by: 3).map { t in
        Series(fraction: Clock.fraction(Clock.cnClockMinute(t)), percent: cnPercent(t))
    }
}

private func krSeries() -> [Series] {
    stride(from: 0.0, through: 390.0, by: 3).map { m in
        Series(fraction: Clock.fraction(Clock.krClockMinute(m)), percent: krPercent(m))
    }
}

private let yLow: Double = -0.009
private let yHigh: Double = 0.040

private func yPosition(_ percent: Double, top: CGFloat, bottom: CGFloat) -> CGFloat {
    let t = (percent - yLow) / (yHigh - yLow)
    return bottom - CGFloat(min(max(t, 0), 1)) * (bottom - top)
}

private func path(_ points: [Series], top: CGFloat, bottom: CGFloat) -> Path {
    var p = Path()
    for (index, point) in points.enumerated() {
        let x = CGFloat(point.fraction) * 370   // replaced by caller width below
        let y = yPosition(point.percent, top: top, bottom: bottom)
        if index == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    return p
}

// MARK: - Main panel

private struct MainPanel: View {
    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 14
            let bottom: CGFloat = size.height - 9
            func x(_ fraction: Double) -> CGFloat { CGFloat(fraction) * size.width }

            // Zone washes: who owns each stretch of the wall clock.
            let zones: [(Double, Double, Color, String, UnitPoint)] = [
                (Clock.fraction(hour: 8, 0), Clock.fraction(hour: 9, 30),
                 violet.opacity(0.10), "韩 09:00–09:30", .topLeading),
                (Clock.fraction(hour: 11, 30), Clock.fraction(hour: 13, 0),
                 amber.opacity(0.14), "午休 · 韩国仍交易", .top),
                (Clock.fraction(hour: 14, 30), Clock.fraction(hour: 15, 0),
                 Color.gray.opacity(0.12), "韩已收盘", .topTrailing),
            ]
            for zone in zones {
                let rect = CGRect(x: x(zone.0), y: 0, width: x(zone.1) - x(zone.0), height: size.height)
                context.fill(Path(rect), with: .color(zone.2))
                let label = context.resolve(Text(zone.3).font(.system(size: 6.5, weight: .medium)))
                switch zone.4 {
                case .topLeading:  context.draw(label, at: CGPoint(x: rect.minX + 3, y: 3), anchor: .topLeading)
                case .topTrailing: context.draw(label, at: CGPoint(x: rect.maxX - 3, y: 3), anchor: .topTrailing)
                default:           context.draw(label, at: CGPoint(x: rect.midX, y: 3), anchor: .top)
                }
            }

            // Previous close, shared by both series because both are drawn in percent.
            var zero = Path()
            let zeroY = yPosition(0, top: top, bottom: bottom)
            zero.move(to: CGPoint(x: 0, y: zeroY))
            zero.addLine(to: CGPoint(x: size.width, y: zeroY))
            context.stroke(zero, with: .color(hair), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            // Session boundaries.
            for (minute, color) in [(Clock.cnOpen, red), (Clock.cnMorningEnd, amber),
                                    (Clock.cnAfternoonAt, amber), (Clock.krClose, violet)] {
                var rule = Path()
                rule.move(to: CGPoint(x: x(Clock.fraction(Double(minute))), y: top - 4))
                rule.addLine(to: CGPoint(x: x(Clock.fraction(Double(minute))), y: size.height))
                context.stroke(rule, with: .color(color.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            }

            // China: solid inside each session, faint across the lunch band. Both
            // series stop at "now" — an intraday chart never draws the future.
            let nowFraction = Clock.fraction(Double(nowCST))
            let cn = cnSeries().filter { $0.fraction <= nowFraction }
            let morning = cn.filter { $0.fraction <= Clock.fraction(Double(Clock.cnMorningEnd)) }
            let afternoon = cn.filter { $0.fraction >= Clock.fraction(Double(Clock.cnAfternoonAt)) }
            context.stroke(path(in: morning, width: size.width, top: top, bottom: bottom),
                           with: .color(red), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            context.stroke(path(in: afternoon, width: size.width, top: top, bottom: bottom),
                           with: .color(red), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            var bridge = Path()
            if let lastMorning = morning.last, let firstAfternoon = afternoon.first {
                bridge.move(to: CGPoint(x: x(lastMorning.fraction), y: yPosition(lastMorning.percent, top: top, bottom: bottom)))
                bridge.addLine(to: CGPoint(x: x(firstAfternoon.fraction), y: yPosition(firstAfternoon.percent, top: top, bottom: bottom)))
            }
            context.stroke(bridge, with: .color(red.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))

            // Korea: one continuous line, straight through Shanghai's lunch.
            context.stroke(path(in: krSeries().filter { $0.fraction <= nowFraction },
                                width: size.width, top: top, bottom: bottom),
                           with: .color(violet), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))

            // Now marker: one vertical instant, both lines.
            let nowX = x(nowFraction)
            var nowRule = Path()
            nowRule.move(to: CGPoint(x: nowX, y: top - 5))
            nowRule.addLine(to: CGPoint(x: nowX, y: size.height))
            context.stroke(nowRule, with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: 0.7))

            for (percent, color) in [(cnPercent(nowCNTrading), red), (krPercent(nowKRMinute), violet)] {
                let dot = CGRect(x: nowX - 2, y: yPosition(percent, top: top, bottom: bottom) - 2, width: 4, height: 4)
                context.fill(Path(ellipseIn: dot), with: .color(color))
            }
        }
        .frame(height: 102)
        .clipped()
    }
}

private func path(in points: [Series], width: CGFloat, top: CGFloat, bottom: CGFloat) -> Path {
    var p = Path()
    for (index, point) in points.enumerated() {
        let x = CGFloat(point.fraction) * width
        let y = yPosition(point.percent, top: top, bottom: bottom)
        if index == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    return p
}

// MARK: - Axis

private struct AxisRow: View {
    var body: some View {
        Canvas { context, size in
            let marks: [(Double, String, CGFloat)] = [
                (Clock.fraction(hour: 8, 0), "09:00", 0),
                (Clock.fraction(hour: 9, 30), "09:30", 0),
                (Clock.fraction(hour: 11, 30), "11:30", 0),
                (Clock.fraction(hour: 13, 0), "13:00", 0),
                (Clock.fraction(hour: 14, 30), "15:30", 7),
                (Clock.fraction(hour: 15, 0), "15:00", 0),
            ]
            for mark in marks {
                let x = CGFloat(mark.0) * size.width
                let text = context.resolve(
                    Text(mark.1).font(.system(size: 7, design: .monospaced)).foregroundStyle(muted)
                )
                // Edge-clamped so the first and last tick never leave the card; the
                // 15:30/15:00 pair is stacked so the two cannot collide.
                let clamped = min(max(x, 11), size.width - 11)
                context.draw(text, at: CGPoint(x: clamped, y: mark.2), anchor: .top)
            }
        }
        .frame(height: 14)
    }
}

// MARK: - Bottom comparison

private struct MiniNow: View {
    var body: some View {
        Canvas { context, size in
            let cnLane: CGFloat = 11
            let krLane: CGFloat = 26

            // Today: each series keeps its own axis, so the same instant lands
            // at two different x positions.
            let cnNow = CGFloat(nowCNTrading / 240) * size.width
            let krNow = CGFloat(nowKRMinute / 390) * size.width

            func drawLine(_ percent: (Double) -> Double, domain: ClosedRange<Double>,
                          steps: Int, lane: CGFloat, color: Color, nowX: CGFloat) {
                var p = Path()
                for i in 0...steps {
                    let u = Double(i) / Double(steps)
                    let value = percent(u * (domain.upperBound - domain.lowerBound) + domain.lowerBound)
                    let y = lane - 5 - CGFloat((value - yLow) / (yHigh - yLow)) * 10
                    let x = CGFloat(u) * size.width
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                var rule = Path()
                rule.move(to: CGPoint(x: nowX, y: lane - 10))
                rule.addLine(to: CGPoint(x: nowX, y: lane + 3))
                context.stroke(rule, with: .color(ink.opacity(0.5)), style: StrokeStyle(lineWidth: 0.6, dash: [1.5, 2]))
            }

            drawLine(cnPercent, domain: 0...240, steps: 40, lane: cnLane, color: red, nowX: cnNow)
            drawLine(krPercent, domain: 0...390, steps: 40, lane: krLane, color: violet, nowX: krNow)

            let label = Text("现在 13:12").font(.system(size: 6.5)).foregroundStyle(muted)
            context.draw(label, at: CGPoint(x: size.width, y: 0), anchor: .topTrailing)
        }
        .frame(height: 34)
    }
}

private struct MiniAligned: View {
    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 4
            let bottom: CGFloat = size.height - 3

            func draw(_ percent: (Double) -> Double, domain: ClosedRange<Double>,
                      clock: (Double) -> Double, color: Color) {
                var p = Path()
                for i in 0...60 {
                    let u = Double(i) / 60
                    let minute = u * (domain.upperBound - domain.lowerBound) + domain.lowerBound
                    let value = percent(minute)
                    let x = CGFloat(Clock.fraction(clock(minute))) * size.width
                    let y = yPosition(value, top: top, bottom: bottom)
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            }

            draw(cnPercent, domain: 0...240, clock: Clock.cnClockMinute, color: red)
            draw(krPercent, domain: 0...390, clock: Clock.krClockMinute, color: violet)

            // The lunch band Korea trades through.
            let band = CGRect(
                x: CGFloat(Clock.fraction(Double(Clock.cnMorningEnd))) * size.width,
                y: 0,
                width: CGFloat(Clock.fraction(Double(Clock.cnAfternoonAt)) - Clock.fraction(Double(Clock.cnMorningEnd))) * size.width,
                height: size.height
            )
            context.fill(Path(band), with: .color(amber.opacity(0.16)))

            let nowX = CGFloat(Clock.fraction(Double(nowCST))) * size.width
            var rule = Path()
            rule.move(to: CGPoint(x: nowX, y: 0))
            rule.addLine(to: CGPoint(x: nowX, y: size.height))
            context.stroke(rule, with: .color(ink.opacity(0.5)), style: StrokeStyle(lineWidth: 0.6))
        }
        .frame(height: 34)
    }
}

private struct MiniCard: View {
    let title: String
    let note: String
    let content: AnyView

    init(title: String, note: String, @ViewBuilder content: () -> some View) {
        self.title = title
        self.note = note
        self.content = AnyView(content())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(ink)
                Spacer(minLength: 0)
                Text(note).font(.system(size: 6.5)).foregroundStyle(muted)
            }
            content
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.975, green: 0.98, blue: 0.99), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(hair.opacity(0.7), lineWidth: 0.5))
    }
}

// MARK: - Card

private struct PreviewCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("韩国行情 · 按中国时段分割").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                    HStack(spacing: 7) {
                        Label { Text("上证指数 3717.56  +0.27%").font(.system(size: 7.5, weight: .medium)) } icon: {
                            Circle().fill(red).frame(width: 5, height: 5)
                        }
                        Label { Text("韩国综合 5727.37  +3.12%").font(.system(size: 7.5, weight: .medium)) } icon: {
                            Circle().fill(violet).frame(width: 5, height: 5)
                        }
                    }.foregroundStyle(ink.opacity(0.75))
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("13:12").font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(ink)
                    Text("北京 · 首尔 14:12").font(.system(size: 7)).foregroundStyle(muted)
                }
            }
            .padding(.bottom, 5)

            MainPanel()
            AxisRow()
                .padding(.top, 2)
                .padding(.bottom, 6)

            HStack(alignment: .top, spacing: 7) {
                MiniCard(title: "现状", note: "两条各自的轴") { MiniNow() }
                MiniCard(title: "本方案", note: "一条北京时间轴") { MiniAligned() }
            }
        }
        .padding(11)
        .frame(width: 370, height: 230, alignment: .topLeading)
        .background(.white)
    }
}

@main struct RenderKoreaChinaSplit {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
            ?? "/Users/cora/Projects/Pulse/docs/design/korea-china-split-preview.png")
        let renderer = ImageRenderer(content: PreviewCard().environment(\.colorScheme, .light))
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
