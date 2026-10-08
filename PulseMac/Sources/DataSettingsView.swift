import SwiftUI
import PulseCore

/// Settings → Data: sync a selected folder or move watchlists through the clipboard.
///
/// This lives on its own page rather than in the settings list. Import is a
/// multi-step review — paste, read what Pulse understood, then apply — and an
/// entry-by-entry preview inside a settings row would push everything else off
/// the screen every time someone looked at it.
///
/// The two actions name their destination ("to the clipboard", "from the
/// clipboard") because that is what a person has to know to use either one, and
/// the format is taught by a copyable example rather than described in prose.
struct DataSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.pulseHost) private var host
    @Binding var route: PopoverRoute

    private enum Phase: Equatable {
        case idle
        case previewing(ImportPreview)
        case imported(WatchlistArchive.ImportPlan)
        case failed(String)
        case exported(String)
    }

    /// A reviewed import, held together with what it was reviewed *against*.
    ///
    /// The plan is a reading of the store at one moment: which symbols are
    /// already present, which lists exist, what the account holds. Applying it
    /// later is only honest if both sides still match — the account must still
    /// be the one the archive was read in, and the source ledger must not have
    /// changed under it. Otherwise the plan would merge records the user never
    /// saw, or file an untagged archive into an account that was not the one on
    /// screen when they read the preview.
    private struct ImportPreview: Equatable {
        let archive: WatchlistArchive
        /// The account this preview was built in. Untagged archives are applied
        /// into whichever account is selected, so that choice has to be
        /// recorded rather than re-read at confirm time.
        let account: BrokerageAccountID
        /// The account's own ledger state when the plan was computed. A change
        /// here — another window, a sync, a classification — invalidates the
        /// plan's "already present" and "will add" readings.
        let sourceSnapshot: WatchlistSyncSnapshot
        let plan: WatchlistArchive.ImportPlan

        static func == (lhs: ImportPreview, rhs: ImportPreview) -> Bool {
            lhs.account == rhs.account && lhs.plan == rhs.plan
                && lhs.sourceSnapshot == rhs.sourceSnapshot
        }
    }

    @State private var phase: Phase = .idle
    @State private var showClassification = false
    /// An archive tagged with an account other than the current one. Import is
    /// held here until the user acknowledges it: a mismatch must never be
    /// resolved by silently writing the records into whichever account happens
    /// to be selected.
    @State private var foreignImport: WatchlistArchive.ImportPlan.RejectionReason?

    /// Import is its own two-step review — paste, read the plan, then apply — so
    /// the clipboard actions step aside while a plan is on screen. Sync is a
    /// standing setting and keeps its place either way.
    private var isReviewingImport: Bool {
        switch phase {
        case .previewing(_), .imported(_): true
        default: false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch phase {
                case .previewing(let preview):
                    planCard(preview.plan, archive: preview.archive, scopeAccount: preview.account)
                case .imported(let plan):
                    // The archive is already applied; the scope note would have
                    // nothing left to describe, so the result card omits it.
                    planCard(plan, archive: nil,
                             scopeAccount: appState.watchlist.activeBrokerageAccountID)
                default:
                    EmptyView()
                }
                BackupSettingsCard()
                if appState.watchlist.brokerageAccountsEnabled { accountCard }
                folderSyncCard
                if !isReviewingImport {
                    actionsCard
                    formatCard
                }
                message
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
            .softScrollEdgeEffect(for: .all)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .animation(.snappy(duration: 0.24), value: phase)
        .onChange(of: appState.watchlist.activeBrokerageAccountID) { _, _ in
            discardStalePreview()
        }
        .onChange(of: appState.watchlist.brokeragePortfolio(for: appState.watchlist.activeBrokerageAccountID).flatSnapshot) { _, _ in
            discardStalePreview()
        }
        .sheet(isPresented: $showClassification) {
            BrokerageAccountClassificationSheet { _ in }
        }
        .alert(
            PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
                ? "账号不匹配" : "Account mismatch",
            isPresented: foreignImportBinding
        ) {
            Button(PulseLocalization.localizedString("action.cancel"), role: .cancel) {
                foreignImport = nil
            }
        } message: {
            Text(foreignImportMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconButton(systemName: "chevron.left", help: PulseLocalization.localizedString("action.backHelp")) {
                route = .settings
            }
            Text(PulseLocalization.localizedString("settings.section.data"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, host == .pinnedWindow ? 2 : 8)
        .padding(.bottom, 8)
    }

    // MARK: - Action bar

    /// Cancel then confirm, right-aligned, small controls — the same action bar the
    /// trade and position pages use. A review step should not invent its own.
    @ViewBuilder
    private var actionBar: some View {
        switch phase {
        case .previewing(let preview):
            HStack {
                Spacer()
                Button(PulseLocalization.localizedString("action.cancel")) { phase = .idle }
                Button(PulseLocalization.localizedString("data.import.confirm")) {
                    confirmImport(preview)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !preview.plan.changesAnything
                        || preview.plan.rejectionReason != nil
                        || previewIsStale(preview)
                )
            }
            .controlSize(.small)
            .padding(12)
        case .imported:
            HStack {
                Spacer()
                Button(PulseLocalization.localizedString("action.done")) { phase = .idle }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(12)
        default:
            EmptyView()
        }
    }

    // MARK: - Idle

    private var actionsCard: some View {
        VStack(spacing: 0) {
            actionRow(
                title: "data.export",
                subtitle: "data.export.subtitle",
                systemName: "square.and.arrow.up"
            ) { exportToClipboard() }
            if appState.watchlist.brokerageAccountsEnabled {
                scopeNote(accountCopyData("导出当前账号", "Exports the current account"))
            }
            Divider().padding(.leading, 40)
            actionRow(
                title: "data.import",
                subtitle: "data.import.subtitle",
                systemName: "square.and.arrow.down"
            ) { previewClipboard() }
            if appState.watchlist.brokerageAccountsEnabled {
                scopeNote(accountCopyData("导入当前账号", "Imports into the current account"))
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func accountCopyData(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }

    /// Names the account the export/import above it acts on, and states the one
    /// thing that is easy to get wrong: backups and sync are not account-scoped,
    /// these two actions are.
    private func scopeNote(_ action: String) -> some View {
        let active = appState.watchlist.activeBrokerageAccountID
        return HStack(spacing: 5) {
            Circle().fill(AccountIdentity.dotColor(active)).frame(width: 6, height: 6)
            Text("\(action)：\(AccountIdentity.title(active)) · "
                 + accountCopyData("备份与同步包含全部账号",
                                   "backups and sync cover every account"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
    }

    /// Account scope and the way into classification.
    ///
    /// It lives on the Data page because that is where a user already goes to
    /// ask "which records does this app hold, and where do they live" — the
    /// export/import actions on this page act on one account, and the backups and
    /// sync below carry all of them.
    private var accountCard: some View {
        let active = appState.watchlist.activeBrokerageAccountID
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: AccountIdentity.symbolName(active))
                    .foregroundStyle(.secondary)
                Text(PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
                     ? "账号归属" : "Account classification")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Circle()
                    .fill(AccountIdentity.dotColor(active))
                    .frame(width: 6, height: 6)
                Text(AccountIdentity.title(active))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
                 ? "把历史数据从未归属分配到融资账号或萌萌账号。导出与导入只作用于当前账号；本地备份与同步包含全部账号。"
                 : "Move legacy records from 未归属 into 融资账号 or 萌萌账号. Export and import act on the current account only; local backups and sync carry every account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { showClassification = true } label: {
                Text(PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
                     ? "管理账户归属…" : "Manage classification…")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var folderSyncCard: some View {
        let sync = appState.folderSync
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "icloud")
                    .foregroundStyle(.secondary)
                Text(PulseLocalization.localizedString("sync.title"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if sync.isSyncing { ProgressView().controlSize(.small) }
            }

            Text(PulseLocalization.localizedString("sync.setup.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let folderPath = sync.selectedFolderPath {
                Text(folderPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Text(syncStatusText(sync))
                .font(.caption)
                .foregroundStyle(sync.lastError == nil
                    ? (sync.conflictSummaries.isEmpty ? Color.secondary : Color.orange)
                    : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            if let lastReadAt = sync.lastReadAt {
                Text(PulseLocalization.localizedString("sync.lastRead", formatted(lastReadAt)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let lastWriteAt = sync.lastWriteAt {
                Text(PulseLocalization.localizedString("sync.lastWrite", formatted(lastWriteAt)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error = sync.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
                    ? "先确认同步文件夹可访问、云端文件已下载，且其他 Mac 已更新 FFF；然后重试。若目录权限失效，可重新选择原文件夹。"
                    : "Check folder access, download cloud files, and update FFF on your other Macs, then retry. Reselect the same folder if its permission expired.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? "重试同步" : "Retry sync") {
                    sync.syncNow()
                }
                .disabled(!sync.isConfigured || sync.isSyncing)
            }

            ForEach(sync.conflictSummaries) { conflict in
                VStack(alignment: .leading, spacing: 5) {
                    Text(PulseLocalization.localizedString(
                        "sync.conflict.detail", conflict.count, String(conflict.id.prefix(8))
                    ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    ForEach(conflict.examples, id: \.self) { example in
                        Text(example)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(PulseLocalization.localizedString("sync.conflict.warning"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(PulseLocalization.localizedString("sync.conflict.keepLocal")) {
                            sync.resolveConflicts(peerID: conflict.id, choosingRemote: false)
                        }
                        .disabled(sync.isSyncing)
                        Button(PulseLocalization.localizedString("sync.conflict.useRemote")) {
                            sync.resolveConflicts(peerID: conflict.id, choosingRemote: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sync.isSyncing)
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            HStack {
                Button(PulseLocalization.localizedString(sync.isConfigured ? "sync.changeFolder" : "sync.choose.button")) {
                    sync.chooseFolder()
                }
                .buttonStyle(.borderedProminent)
                .disabled(sync.isSyncing)
                if sync.isConfigured {
                    Button(PulseLocalization.localizedString("sync.now")) { sync.syncNow() }
                        .disabled(sync.isSyncing)
                    Spacer(minLength: 0)
                    Button(PulseLocalization.localizedString("sync.disable")) { sync.disableSync() }
                        .disabled(sync.isSyncing)
                }
            }
            .controlSize(.small)

            Text(PulseLocalization.localizedString("sync.privacy"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func syncStatusText(_ sync: FolderSyncController) -> String {
        if sync.lastError != nil { return PulseLocalization.localizedString("sync.status.error") }
        if !sync.conflictSummaries.isEmpty {
            return PulseLocalization.localizedString("sync.status.conflicts", sync.conflictSummaries.count)
        }
        if sync.isSyncing { return PulseLocalization.localizedString("sync.status.syncing") }
        return PulseLocalization.localizedString(sync.isConfigured ? "sync.status.ready" : "sync.status.off")
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func actionRow(
        title: String,
        subtitle: String,
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PulseLocalization.localizedString(title))
                        .font(.system(size: 12, weight: .medium))
                    Text(PulseLocalization.localizedString(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    /// The format, shown rather than described: the shape people actually have to
    /// type, with the copyable example one tap away.
    private var formatCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PulseLocalization.localizedString("data.format.title"))
                .font(.system(size: 12, weight: .semibold))
            Text(Self.formatSketch)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(PulseLocalization.localizedString("data.format.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(PulseLocalization.localizedString("data.example")) { copyExample() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private static let formatSketch = """
    {
      "format": "pulse.watchlist", "version": 1,
      "lists": [
        { "name": "…", "entries": [
          { "market": "us", "code": "NVDA" }
        ] }
      ]
    }
    """

    // MARK: - Preview

    /// Every entry, grouped the way the archive groups them, showing the instrument
    /// Pulse resolved rather than the raw text. Seeing `SPX · S&P 500 Index`, or a row
    /// marked unreadable, is the only way to know an import is the one you meant.
    private func planCard(_ plan: WatchlistArchive.ImportPlan, archive: WatchlistArchive?,
                          scopeAccount: BrokerageAccountID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let archive { importScopeNote(archive, account: scopeAccount) }
            ForEach(plan.lists) { list in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(list.name)
                            .font(.system(size: 12, weight: .semibold))
                        if list.isNew {
                            Text(PulseLocalization.localizedString("data.import.newList"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(list.items) { item in
                        HStack(spacing: 6) {
                            Text(identity(of: item))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(item.symbol == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(PulseLocalization.localizedString(statusKey(for: item.outcome)))
                                .font(.caption)
                                .foregroundStyle(statusColor(for: item.outcome))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// Names the account the import will land in.
    ///
    /// A tagged archive whose account does not match is refused before it gets
    /// here. An untagged one — written by an older build, or hand-authored from
    /// the format example — carries no account, so it is stated plainly that it
    /// goes into whichever account is current rather than left ambiguous.
    private func importScopeNote(_ archive: WatchlistArchive, account: BrokerageAccountID) -> some View {
        let active = account
        let chinese = PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
        let text: String
        if !appState.watchlist.brokerageAccountsEnabled {
            text = ""
        } else if let tagged = archive.brokerageAccountID {
            text = chinese
                ? "导入到账号：\(AccountIdentity.title(tagged))"
                : "Importing into account: \(AccountIdentity.title(tagged))"
        } else {
            text = chinese
                ? "数据未标注账号，将导入当前账号：\(AccountIdentity.title(active))"
                : "Untagged data imports into the current account: \(AccountIdentity.title(active))"
        }
        return Group {
            if !text.isEmpty {
                HStack(spacing: 5) {
                    Circle().fill(AccountIdentity.dotColor(archive.brokerageAccountID ?? active))
                        .frame(width: 6, height: 6)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var message: some View {
        switch phase {
        case .failed(let text):
            note(text, color: .orange)
        case .exported(let text):
            note(text, color: .green)
        case .previewing(let preview):
            note(planSummary(for: preview.plan), color: preview.plan.skippedCount > 0 ? .orange : .secondary)
        case .imported(let plan):
            note(
                withDrawingSummary(
                    PulseLocalization.localizedString("data.import.done", plan.addCount, plan.newListCount),
                    plan: plan
                ),
                color: plan.changesAnything ? .green : .secondary
            )
        case .idle:
            EmptyView()
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func withDrawingSummary(_ text: String, plan: WatchlistArchive.ImportPlan) -> String {
        guard plan.drawingCount > 0 else { return text }
        return text + " " + PulseLocalization.localizedString("data.import.drawings", plan.drawingCount)
    }

    // MARK: - Actions

    private func exportToClipboard() {
        let archive = appState.watchlist.archive(app: appVersion)
        do {
            try ClipboardTextExporter.write(archive.encoded())
            let symbols = archive.lists.reduce(0) { $0 + $1.entries.count }
            phase = .exported(PulseLocalization.localizedString(
                "data.export.done", archive.lists.count, symbols
            ))
        } catch {
            phase = .failed(PulseLocalization.localizedString("share.text.copyFailed"))
        }
    }

    private func copyExample() {
        do {
            try ClipboardTextExporter.write(WatchlistArchive.example().encoded())
            phase = .exported(PulseLocalization.localizedString("data.example.done"))
        } catch {
            phase = .failed(PulseLocalization.localizedString("share.text.copyFailed"))
        }
    }

    private func previewClipboard() {
        guard let text = ClipboardTextReader.read() else {
            phase = .failed(PulseLocalization.localizedString("data.error.emptyClipboard"))
            return
        }
        do {
            let archive = try WatchlistArchive.decoded(from: text)
            // The core plan is the single authority on whether this archive may
            // be applied at all. It is computed once here and inspected before
            // anything reaches the screen; a refusal is reported with the two
            // account identities the plan captured, so the alert never has to
            // hold (or re-read) the archive itself.
            let plan = appState.watchlist.importPlan(for: archive)
            if let reason = plan.rejectionReason {
                foreignImport = reason
                return
            }
            phase = .previewing(ImportPreview(
                archive: archive,
                account: appState.watchlist.activeBrokerageAccountID,
                sourceSnapshot: appState.watchlist.brokeragePortfolio(for: appState.watchlist.activeBrokerageAccountID).flatSnapshot,
                plan: plan
            ))
        } catch let failure as WatchlistArchive.DecodingFailure {
            phase = .failed(message(for: failure))
        } catch {
            phase = .failed(PulseLocalization.localizedString("data.error.notArchive"))
        }
    }

    /// Whether the reviewed plan no longer describes what confirming would do.
    ///
    /// Both halves matter. A different account means an untagged archive would
    /// land somewhere the user never agreed to; a changed source ledger means
    /// the plan's "already present" and "will add" readings were taken from a
    /// store that has since moved. Either way the answer is a fresh preview,
    /// never a merge of data the user did not review.
    private func previewIsStale(_ preview: ImportPreview) -> Bool {
        preview.account != appState.watchlist.activeBrokerageAccountID
            || preview.sourceSnapshot != appState.watchlist.brokeragePortfolio(for: appState.watchlist.activeBrokerageAccountID).flatSnapshot
    }

    private func confirmImport(_ preview: ImportPreview) {
        guard !previewIsStale(preview) else {
            discardStalePreview()
            return
        }
        // `merge` returns the plan it actually applied. A refused plan must be
        // reported as such instead of being shown as a successful import whose
        // counts happen to be zero.
        let applied = appState.watchlist.merge(preview.archive)
        if let reason = applied.rejectionReason {
            foreignImport = reason
            return
        }
        phase = .imported(applied)
    }

    /// Drops a preview that no longer matches the store and says why, so the
    /// user can paste and review again instead of applying a plan that was
    /// computed against a different account or a different ledger.
    private func discardStalePreview() {
        guard case .previewing(let preview) = phase, previewIsStale(preview) else { return }
        phase = .failed(accountCopyData(
            "账号或数据已变化，之前的导入预览已失效。请重新导入以查看最新结果。",
            "The account or the data changed, so that import preview no longer applies. Import again to review the current result."
        ))
    }

    private var foreignImportBinding: Binding<Bool> {
        Binding(get: { foreignImport != nil }, set: { if !$0 { foreignImport = nil } })
    }

    /// Names both accounts and says what to do about it.
    ///
    /// With accounts switched off there is no account to switch to, so the only
    /// honest instruction is to turn the feature on and then choose the account
    /// the archive names. Either way the user makes the choice: nothing here
    /// enables the feature, selects an account, or retries on its own.
    private var foreignImportMessage: String {
        guard let reason = foreignImport else { return "" }
        switch reason {
        case .accountMismatch(let archiveAccountID, let destinationAccountID):
            let source = AccountIdentity.title(archiveAccountID)
            let destination = AccountIdentity.title(destinationAccountID)
            guard appState.watchlist.brokerageAccountsEnabled else {
                return accountCopyData(
                    "未导入任何内容。这份数据属于「\(source)」，当前账号是「\(destination)」。请先开启券商账号功能，选择「\(source)」账号后再重新导入。",
                    "Nothing was imported. This data belongs to \(source), but the current account is \(destination). Enable brokerage accounts, select \(source), then import again."
                )
            }
            return accountCopyData(
                "未导入任何内容。这份数据属于「\(source)」，当前账号是「\(destination)」。请先切换到「\(source)」账号再重新导入。",
                "Nothing was imported. This data belongs to \(source), but the current account is \(destination). Switch to \(source) and import again."
            )
        }
    }

    // MARK: - Copy

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return version.map { "\(AppBrand.displayName) \($0)" } ?? AppBrand.displayName
    }

    /// `US · NVDA` for a plain security, plus the resolved identity when Pulse read the
    /// code as something structured (an index alias, a crypto pair).
    private func identity(of item: WatchlistArchive.ImportPlan.Item) -> String {
        guard let symbol = item.symbol else {
            // An unreadable entry still echoes what was written, but a blank code
            // must not render as a dangling separator.
            let market = item.entry.market.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = item.entry.code.trimmingCharacters(in: .whitespacesAndNewlines)
            return [market, code].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let base = "\(symbol.market.displayName) · \(symbol.displayCode)"
        if let index = symbol.indexID {
            return "\(base) · \(index.displayName)"
        }
        if let name = item.entry.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, name != symbol.displayCode {
            return "\(base) · \(name)"
        }
        return base
    }

    private func statusKey(for outcome: WatchlistArchive.ImportPlan.Outcome) -> String {
        switch outcome {
        case .add: "data.import.status.add"
        case .alreadyInList: "data.import.status.present"
        case .restorePosition: "data.import.status.position"
        case .skipped(.unknownMarket): "data.import.status.unknownMarket"
        case .skipped(.missingCode): "data.import.status.missingCode"
        case .skipped: "data.import.status.unreadable"
        }
    }

    private func statusColor(for outcome: WatchlistArchive.ImportPlan.Outcome) -> Color {
        switch outcome {
        case .add, .restorePosition: .green
        case .alreadyInList: .secondary
        case .skipped: .orange
        }
    }

    private func planSummary(for plan: WatchlistArchive.ImportPlan) -> String {
        guard plan.skippedCount == 0 else {
            return withDrawingSummary(
                PulseLocalization.localizedString("data.import.someUnreadable", plan.skippedCount), plan: plan
            )
        }
        guard plan.changesAnything else {
            return PulseLocalization.localizedString("data.import.unchanged")
        }
        return withDrawingSummary(
            PulseLocalization.localizedString("data.import.willAdd", plan.addCount, plan.newListCount), plan: plan
        )
    }

    private func message(for failure: WatchlistArchive.DecodingFailure) -> String {
        switch failure {
        case .notJSON, .wrongFormat:
            PulseLocalization.localizedString("data.error.notArchive")
        case .unsupportedVersion:
            PulseLocalization.localizedString("data.error.newerVersion")
        case .noLists:
            PulseLocalization.localizedString("data.error.noLists")
        case .invalidTransactionFee:
            PulseLocalization.localizedString("data.error.invalidTransactionFee")
        case .invalidChartDrawing, .duplicateChartDrawingID:
            PulseLocalization.localizedString("data.error.invalidChartDrawing")
        case .invalidTradingProfile:
            PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
                ? "分类或防守价格无效，请检查导入文件。" : "Invalid classification or defense prices in the import."
        case .invalidInstrumentEvent, .duplicateInstrumentEventID:
            PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
                ? "事件日期、来源链接或事件标识无效，请检查导入文件。" : "Invalid event date, source URL, or event ID in the import."
        case .duplicateTradePlanID, .duplicateTradePlanConditionID, .duplicateTradePlanRevisionID,
             .invalidTradePlan, .invalidPlanExecution:
            PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
                ? "计划、条件、历史或成交关联无效，请检查导入文件。" : "Invalid plan, conditions, history, or linked fill in the import."
        case .invalidPositionAllocation:
            PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
                ? "仓位分账的数量、来源或历史记录无效，请检查导入文件。" : "Invalid position allocation quantity, source, or history in the import."
        }
    }
}
