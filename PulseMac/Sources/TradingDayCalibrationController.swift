import Foundation
import Observation
import PulseCore
import PulseUI
import SwiftUI

/// 交易日历校准的本地副本。
///
/// 一天最多拉一次，持久化到本机；失败不覆盖已有成功副本。它**只提供查询**，
/// 不改任何历史成交日期，也不用于推断未来休市——上游端点本身只覆盖过去一年。
@MainActor
@Observable
final class TradingDayCalibrationController {
    private(set) var verified: VerifiedTradingDays?
    private(set) var lastError: String?
    private(set) var loading = false

    @ObservationIgnored private let provider: FuyaoProvider
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?

    /// 一天一次足够：交易日历一年才变一次。
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    private static let storageKey = "pulse.fuyao.tradingDays.v1"

    init(provider: FuyaoProvider, available: @escaping () -> Bool, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.available = available
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(VerifiedTradingDays.self, from: data) {
            verified = stored
        }
    }

    var state: TradingDayCalibration {
        if let verified {
            return lastError.map { .stale(verified, error: $0) } ?? .calibrated(verified)
        }
        return .notCalibrated
    }

    /// 查询某天是否交易日。无覆盖返回 nil——不是"休市"。
    func isTradingDay(_ day: CalendarDay) -> Bool? { verified?.isTradingDay(day) }

    /// 该日之前最近的交易日。无覆盖返回 nil。
    func previousTradingDay(before day: CalendarDay) -> CalendarDay? {
        verified?.previousTradingDay(before: day)
    }

    /// 与本地表的差异。无副本时返回 nil（无从比较）。
    func discrepancies(with market: Market) -> VerifiedTradingDays.Discrepancy? {
        verified?.discrepancies(with: market)
    }

    func loadIfNeeded(force: Bool = false) async {
        guard available() else { return }
        if !force, let verified,
           Date.now.timeIntervalSince(verified.fetchedAt) < Self.refreshInterval { return }
        if let task { await task.value; return }
        loading = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.loading = false
                self.task = nil
            }
            do {
                let fresh = try await self.provider.verifiedTradingDays()
                self.verified = fresh
                self.lastError = nil
                if let data = try? JSONEncoder().encode(fresh) {
                    self.defaults.set(data, forKey: Self.storageKey)
                }
            } catch is CancellationError {
                return
            } catch {
                // 保留已有副本，只记错误：日历不会因为一次失败而失效。
                self.lastError = FuyaoResearchController.message(error)
            }
        }
        self.task = task
        await task.value
    }

    func reset() {
        task?.cancel()
        task = nil
        verified = nil
        lastError = nil
        defaults.removeObject(forKey: Self.storageKey)
    }
}

/// 交易日历状态的展示层。只依赖值，便于原生渲染检查。
struct TradingDayCalibrationCard: View {
    var calibration: TradingDayCalibration = .notCalibrated
    var loading = false
    var discrepancy: VerifiedTradingDays.Discrepancy?
    var enabled = true
    var onRefresh: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("交易日历").font(.system(size: 12, weight: .medium))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("校准", action: onRefresh)
                    .controlSize(.small)
                    .disabled(loading || !enabled)
            }
            switch calibration {
            case .notCalibrated:
                text("尚未校准，交易日判断使用本机表（沪深仅核验到 2026 年）。", .secondary)
            case .calibrated(let verified):
                text(Self.summary(verified), .secondary)
                discrepancyLine
            case .stale(let verified, let error):
                text(Self.summary(verified), .secondary)
                text("上次刷新失败：\(error)；仍使用 \(ResearchFormat.fullTime(verified.fetchedAt)) 的副本。", .orange)
                discrepancyLine
            }
            text("只覆盖最近一年，不含未来休市安排；只用于提示差异，不会修改历史成交日期。", .tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var discrepancyLine: some View {
        if let discrepancy {
            if discrepancy.isEmpty {
                text("沪深本地表与该区间一致。", .green)
            } else {
                text("沪深本地表与该区间有 \(discrepancy.total) 天差异（本地多算 \(discrepancy.localOnly.count) 天、少算 \(discrepancy.upstreamOnly.count) 天）。仅提示，不改历史记录。", .orange)
            }
        }
    }

    private func text(_ content: String, _ tone: some ShapeStyle) -> some View {
        Text(content)
            .font(.caption2).foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func summary(_ verified: VerifiedTradingDays) -> String {
        let lower = verified.coverage.lowerBound
        let upper = verified.coverage.upperBound
        let range = String(format: "%04d-%02d-%02d – %04d-%02d-%02d",
                           lower.year, lower.month, lower.day, upper.year, upper.month, upper.day)
        return "已校准 \(verified.days.count) 个交易日（\(range)），获取于 \(ResearchFormat.fullTime(verified.fetchedAt))。"
    }
}
