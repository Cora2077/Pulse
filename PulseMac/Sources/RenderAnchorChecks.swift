#if DEBUG
import AppKit
import Foundation

/// Content-level checks for renders the self-test harness writes.
///
/// The harness historically asserted only that a PNG was produced, which cannot
/// tell a chart with plan lines from an empty chart. These helpers decode the
/// written file and answer narrow, falsifiable questions about its pixels, so a
/// render that silently lost an overlay fails the run instead of being filed as
/// evidence. Debug-only, like the harness that calls them, and they only ever
/// read synthetic fixture renders from `build/artifacts/`.
enum RenderAnchorChecks {
    /// A pixel counts as saturated when its channels are far enough apart to be
    /// an accent color rather than gray text, grid lines, or a background wash.
    private static func isSaturated(_ color: NSColor, in colorSpace: NSColorSpace) -> Bool {
        guard let rgb = color.usingColorSpace(colorSpace) else { return false }
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        let chroma = max(r, g, b) - min(r, g, b)
        // Luminance below 0.95 keeps near-white antialiasing halos out; the wash
        // tints used behind plan capsules are far weaker than a 0.25 channel
        // spread, so they cannot counterfeit a dash either.
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return chroma > 0.25 && luminance < 0.95
    }

    private static func bitmap(at url: URL) -> NSBitmapImageRep? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    /// Number of scanlines containing at least `minRuns` separate horizontal
    /// runs of saturated pixels, each run at least 3px wide.
    ///
    /// A dashed plan line crosses a scanline as many short runs, while text or a
    /// solid border yields one or two. Rows are sampled every 2px: a 2x render
    /// draws a ~10px dash stroke over several rows, so every other row is ample
    /// to find the line without walking the whole bitmap.
    static func countSaturatedDashRows(_ url: URL, minRuns: Int) -> Int {
        guard let rep = bitmap(at: url), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return 0 }
        let colorSpace = rep.colorSpace
        let width = rep.pixelsWide
        var qualifyingRows = 0

        var row = 0
        while row < rep.pixelsHigh {
            var runs = 0
            var runLength = 0
            var col = 0
            while col < width {
                let saturated = rep.colorAt(x: col, y: row)
                    .map { isSaturated($0, in: colorSpace) } ?? false
                if saturated {
                    runLength += 1
                } else {
                    if runLength >= 3 { runs += 1 }
                    runLength = 0
                }
                col += 1
            }
            // A run reaching the right edge still counts.
            if runLength >= 3 { runs += 1 }
            if runs >= minRuns { qualifyingRows += 1 }
            row += 2
        }
        return qualifyingRows
    }

    /// Whether any saturated pixel sits in the right-hand gutter of the chart:
    /// the strip `gutterFraction` of the width wide at the right edge, from the
    /// top down to `bottomFraction` of the height.
    ///
    /// The price axis lives there and is drawn in neutral gray, so saturated ink
    /// appearing in that band means a plan capsule escaped the plot area.
    static func hasSaturatedColorInRightGutter(_ url: URL, gutterFraction: Double,
                                               bottomFraction: Double) -> Bool {
        guard let rep = bitmap(at: url), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return false }
        let colorSpace = rep.colorSpace
        let x0 = max(0, rep.pixelsWide - Int(Double(rep.pixelsWide) * gutterFraction))
        let y1 = min(rep.pixelsHigh, Int(Double(rep.pixelsHigh) * bottomFraction))
        guard x0 < rep.pixelsWide, y1 > 0 else { return false }

        var row = 0
        while row < y1 {
            var col = x0
            while col < rep.pixelsWide {
                if let color = rep.colorAt(x: col, y: row), isSaturated(color, in: colorSpace) {
                    return true
                }
                col += 1
            }
            row += 2
        }
        return false
    }
}
#endif
