import Foundation
import Observation
import PulseCore

/// 打新日历的缓存。
///
/// 六个查询（沪深/京市 × 三阶段）一次拉全再合并，因为它们共享同一个业务日期窗口；
/// 分开缓存只会让界面出现"沪深有、京市空"的错觉。6 小时刷新一次：
/// 打新日历一天变一次已算频繁。
@MainActor
@Observable
final class FuyaoIPOController {
    private(set) var calendar: FuyaoIPOCalendar?
    private(set) var loading = false
    private(set) var lastError: String?

    @ObservationIgnored private let provider: FuyaoProvider
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?

    static let ttl: TimeInterval = 6 * 60 * 60

    init(provider: FuyaoProvider, available: @escaping () -> Bool) {
        self.provider = provider
        self.available = available
    }

    func load(force: Bool = false) async {
        guard available() else { return }
        if !force, let calendar, Date.now.timeIntervalSince(calendar.fetchedAt) < Self.ttl { return }
        if let task { await task.value; return }
        loading = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loading = false; self.task = nil }
            do {
                let fresh = try await self.provider.ipoCalendar()
                self.calendar = fresh
                self.lastError = nil
            } catch is CancellationError {
                return
            } catch {
                // 保留上一次成功的日历：打新列表不会因一次失败而清空。
                self.lastError = FuyaoResearchController.message(error)
            }
        }
        self.task = task
        await task.value
    }

    func reset() {
        task?.cancel()
        task = nil
        calendar = nil
        lastError = nil
    }
}
