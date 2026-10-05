import PulseCore
import SwiftUI

struct BackupSettingsCard: View {
    @Environment(AppState.self) private var appState
    @State private var selectedID: String?
    @State private var selectedPreview: LocalBackupPreview?
    @State private var confirmingRestore = false
    @State private var restored = false

    private var controller: LocalBackupController { appState.localBackups }
    private var selectedBackup: LocalBackupRecord? { controller.backups.first { $0.id == selectedID } }
    private var isChinese: Bool { PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(.secondary)
                Text(copy("Local backups", "本地备份"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle(copy("Daily", "每日"), isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                ))
                .labelsHidden()
                .help(copy("Create one private backup each local calendar day", "每天按本地日期创建一份仅当前用户可访问的备份"))
                .accessibilityLabel(copy("Enable daily backups", "启用每日备份"))
                .disabled(!controller.isAvailable)
            }

            Text(copy(
                "Backups include all brokerage accounts, cash, budgets, sector limits, watchlists, retained history, transactions, plans, and drawings.",
                "备份包含全部证券账号、现金、仓位预算、板块上限，以及自选、历史交易、计划和图表标注。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(copy("Back up now", "立即备份")) { controller.createManualBackup() }
                    .disabled(!controller.isAvailable)
                if let date = controller.lastBackupAt {
                    Text(copy("Latest: \(formatted(date))", "最近备份：\(formatted(date))"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if controller.backups.isEmpty {
                Text(copy(
                    controller.isAvailable ? "No local backups yet." : "Unavailable in offline previews.",
                    controller.isAvailable ? "还没有本地备份。" : "离线预览中不可用。"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(controller.backups) { backup in
                        Button {
                            select(backup)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: backup.id == selectedID ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(.secondary)
                                Text(label(for: backup))
                                    .font(.caption)
                                Spacer()
                                Text(formatted(backup.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let selectedBackup, let selectedPreview {
                preview(selectedBackup, selectedPreview)
            }

            if let error = controller.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy(
                    "For backup failures, check free disk space and try Back up now. For restore failures, select the backup again and review a fresh preview; damaged or newer backups require another backup or an app update.",
                    "备份失败时，请检查磁盘剩余空间，再点“立即备份”。恢复失败时，请重新选择备份并核对预览；损坏的备份需换一份，较新版本的备份需先更新应用。"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(copy("Refresh backup list", "刷新备份列表")) { controller.refreshBackups() }
                    .disabled(!controller.isAvailable)
            } else if restored {
                Text(copy("Restore completed. A pre-restore backup was saved first.", "恢复完成，恢复前的完整备份已保存。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onAppear { controller.refreshBackups() }
    }

    private func preview(_ backup: LocalBackupRecord, _ preview: LocalBackupPreview) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(copy("Restore preview · \(label(for: backup))", "恢复预览 · \(label(for: backup))"))
                .font(.caption.weight(.semibold))
            Text(copy(
                "Groups \(preview.targetCounts.groups) · Symbols \(preview.targetCounts.symbols) · Retained history \(preview.targetCounts.retainedHistory)",
                "分组 \(preview.targetCounts.groups) · 标的 \(preview.targetCounts.symbols) · 留存历史 \(preview.targetCounts.retainedHistory)"
            ))
            Text(copy(
                "Transactions \(preview.targetCounts.transactions) · Plans \(preview.targetCounts.plans) · Drawings \(preview.targetCounts.drawings)",
                "交易记录 \(preview.targetCounts.transactions) · 计划 \(preview.targetCounts.plans) · 图表标注 \(preview.targetCounts.drawings)"
            ))
            Text(copy(
                "Entries: +\(preview.entryChanges.added) added · −\(preview.entryChanges.removed) removed · \(preview.entryChanges.changed) changed",
                "条目变化：新增 \(preview.entryChanges.added) · 移除 \(preview.entryChanges.removed) · 修改 \(preview.entryChanges.changed)"
            ))
                .foregroundStyle(.secondary)
            Text(copy("Restoring replaces the full saved state.", "恢复会完整替换当前保存的数据。"))
                .foregroundStyle(.secondary)
            if !preview.settingsChangedAccounts.isEmpty {
                Text("现金与预算将恢复：" + preview.settingsChangedAccounts.map(AccountIdentity.title).joined(separator: "、"))
                    .foregroundStyle(.orange)
            }
            if !preview.settingsPreservedAccounts.isEmpty {
                Text("旧备份不含这些账号的现金与预算，保留当前设置：" + preview.settingsPreservedAccounts.map(AccountIdentity.title).joined(separator: "、"))
                    .foregroundStyle(.orange)
            }
            if confirmingRestore {
                Text(copy(
                    "This replaces all current watchlists and retained history. When folder sync is configured, the restored state will sync to your other Macs. Provider credentials and local settings are preserved.",
                    "这会替换全部自选分组、标的和留存历史。配置文件夹同步后，恢复结果会同步到其他 Mac。行情账户凭证和本机设置会保留。"
                ))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(copy("Cancel", "取消")) { confirmingRestore = false }
                    Button(copy("Replace all watchlists", "覆盖恢复"), role: .destructive) { restoreSelected() }
                        .disabled(!controller.isAvailable)
                }
                .padding(.top, 2)
            } else {
                Button(copy("Restore…", "恢复…"), role: .destructive) { confirmingRestore = true }
                    .disabled(!controller.isAvailable)
                    .padding(.top, 2)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func label(for backup: LocalBackupRecord) -> String {
        switch backup.kind {
        case .daily: copy("Daily", "每日")
        case .manual: copy("Manual", "手动")
        case .preRestore: copy("Before restore", "恢复前")
        }
    }

    private func select(_ backup: LocalBackupRecord) {
        selectedID = backup.id
        confirmingRestore = false
        restored = false
        do {
            selectedPreview = try controller.preview(for: backup)
        } catch {
            selectedPreview = nil
        }
    }

    private func restoreSelected() {
        guard let backup = selectedBackup, let preview = selectedPreview else { return }
        restored = controller.restore(backup, afterReviewing: preview)
        if restored {
            selectedID = nil
            selectedPreview = nil
            confirmingRestore = false
        } else {
            // Keep the failure visible; choosing this backup again creates a fresh preview.
            selectedPreview = nil
            confirmingRestore = false
        }
    }

    private func copy(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            locale: PulseLocalization.currentLocale
        ))
    }
}
