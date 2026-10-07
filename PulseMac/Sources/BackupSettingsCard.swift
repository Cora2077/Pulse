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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(.secondary)
                Text(PulseLocalization.localizedString("backup.title"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle(PulseLocalization.localizedString("backup.daily.toggle"), isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                ))
                .labelsHidden()
                .help(PulseLocalization.localizedString("backup.daily.help"))
                .accessibilityLabel(PulseLocalization.localizedString("backup.daily.accessibility"))
                .disabled(!controller.isAvailable)
            }

            Text(PulseLocalization.localizedString("backup.contents"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(PulseLocalization.localizedString("backup.now")) { controller.createManualBackup() }
                    .disabled(!controller.isAvailable)
                if let date = controller.lastBackupAt {
                    Text(PulseLocalization.localizedString("backup.latest", formatted(date)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if controller.backups.isEmpty {
                Text(PulseLocalization.localizedString(
                    controller.isAvailable ? "backup.empty.none" : "backup.empty.unavailable"
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
                Text(PulseLocalization.localizedString("backup.error.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(PulseLocalization.localizedString("backup.refresh")) { controller.refreshBackups() }
                    .disabled(!controller.isAvailable)
            } else if restored {
                Text(PulseLocalization.localizedString("backup.restored"))
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
            Text(PulseLocalization.localizedString("backup.preview.title", label(for: backup)))
                .font(.caption.weight(.semibold))
            Text(PulseLocalization.localizedString(
                "backup.preview.counts1",
                preview.targetCounts.groups,
                preview.targetCounts.symbols,
                preview.targetCounts.retainedHistory
            ))
            Text(PulseLocalization.localizedString(
                "backup.preview.counts2",
                preview.targetCounts.transactions,
                preview.targetCounts.plans,
                preview.targetCounts.drawings
            ))
            Text(PulseLocalization.localizedString(
                "backup.preview.changes",
                preview.entryChanges.added,
                preview.entryChanges.removed,
                preview.entryChanges.changed
            ))
                .foregroundStyle(.secondary)
            Text(PulseLocalization.localizedString("backup.preview.replaces"))
                .foregroundStyle(.secondary)
            if !preview.settingsChangedAccounts.isEmpty {
                Text(PulseLocalization.localizedString(
                    "backup.preview.cashRestored",
                    preview.settingsChangedAccounts.map(AccountIdentity.title).joined(separator: "、")
                ))
                    .foregroundStyle(.orange)
            }
            if !preview.settingsPreservedAccounts.isEmpty {
                Text(PulseLocalization.localizedString(
                    "backup.preview.cashPreserved",
                    preview.settingsPreservedAccounts.map(AccountIdentity.title).joined(separator: "、")
                ))
                    .foregroundStyle(.orange)
            }
            if confirmingRestore {
                Text(PulseLocalization.localizedString("backup.confirm.body"))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(PulseLocalization.localizedString("backup.confirm.cancel")) { confirmingRestore = false }
                    Button(PulseLocalization.localizedString("backup.confirm.replace"), role: .destructive) { restoreSelected() }
                        .disabled(!controller.isAvailable)
                }
                .padding(.top, 2)
            } else {
                Button(PulseLocalization.localizedString("backup.restore"), role: .destructive) { confirmingRestore = true }
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
        case .daily: PulseLocalization.localizedString("backup.kind.daily")
        case .manual: PulseLocalization.localizedString("backup.kind.manual")
        case .preRestore: PulseLocalization.localizedString("backup.kind.preRestore")
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

    private func formatted(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            locale: PulseLocalization.currentLocale
        ))
    }
}
