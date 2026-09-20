import SwiftUI

struct ChangesView: View {
    @Bindable var model: WorktreeModel

    var body: some View {
        // HSplitView 只按内容的固有高度撑开，不会自己吃掉父容器给的全部空间。
        // 不显式声明撑满的话，整个详情区会缩成中间一条、上下留出大片空白，
        // 而文件列表被挤到几乎没有高度、内容直接被裁掉。
        GeometryReader { geometry in
            let defaultListWidth = max(260, geometry.size.width * 0.3)
            HSplitView {
                VStack(spacing: 0) {
                    fileList
                    Divider()
                    CommitBox(model: model)
                }
                .frame(
                    minWidth: defaultListWidth,
                    idealWidth: defaultListWidth,
                    maxWidth: max(defaultListWidth, geometry.size.width * 0.45),
                    maxHeight: .infinity
                )

                DiffPane(model: model)
                    .frame(
                        minWidth: 380,
                        idealWidth: geometry.size.width * 0.7,
                        maxHeight: .infinity
                    )
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 文件列表

    private var fileList: some View {
        VStack(spacing: 0) {
            listHeader

            if model.status.changes.isEmpty {
                ContentUnavailableView {
                    Label("工作区干净", systemImage: "checkmark.seal")
                } description: {
                    Text("没有未提交的改动。")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: selectedChange) {
                    if !conflictedChanges.isEmpty {
                        Section {
                            ForEach(conflictedChanges.map { ChangeRowKey(change: $0, side: .worktree) }) { key in
                                ConflictRow(change: key.change, model: model)
                                    .tag(ChangeSelection(path: key.change.path, side: .worktree))
                            }
                        } header: {
                            conflictHeader
                        }
                    }

                    if !stagedChanges.isEmpty {
                        Section {
                            ForEach(stagedChanges.map { ChangeRowKey(change: $0, side: .staged) }) { key in
                                ChangeRow(change: key.change, isStaged: true, model: model)
                                    .tag(ChangeSelection(path: key.change.path, side: .staged))
                            }
                        } header: {
                            SectionHeader(
                                title: "已暂存",
                                count: stagedChanges.count,
                                actionLabel: "全部取消",
                                action: { Task { await model.unstageAll() } }
                            )
                        }
                    }

                    if !unstagedChanges.isEmpty {
                        Section {
                            ForEach(unstagedChanges.map { ChangeRowKey(change: $0, side: .worktree) }) { key in
                                ChangeRow(change: key.change, isStaged: false, model: model)
                                    .tag(ChangeSelection(path: key.change.path, side: .worktree))
                            }
                        } header: {
                            SectionHeader(
                                title: "未暂存",
                                count: unstagedChanges.count,
                                actionLabel: "全部暂存",
                                action: { Task { await model.stageAll() } }
                            )
                        }
                    }
                }
                .listStyle(.inset)
                // 列表要吃掉「表头」和「提交框」之外的全部高度。
                // 少了这句，List 只按内容的固有高度显示，改动一多就被裁成一条。
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("改动")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if model.status.hasConflicts {
                Label("\(model.status.conflictCount) 个冲突", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
            }

            Spacer()

            if model.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// 冲突文件单独一区，放在最上面：它们挡着提交和「继续」，是此刻唯一要做的事。
    private var conflictedChanges: [FileChange] {
        model.status.conflictedChanges
    }

    /// 冲突区的表头。「全部采用一侧」是一口气把所有文件定下来的操作，先确认。
    private var conflictHeader: some View {
        HStack(spacing: 6) {
            Text("冲突")
                .foregroundStyle(.red)
            Text("\(conflictedChanges.count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            Menu("全部采用…") {
                Button("当前更改") { Task { await confirmResolveAll(taking: .ours) } }
                Button("传入的更改") { Task { await confirmResolveAll(taking: .theirs) } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 10))
            .disabled(model.activity != nil)
        }
    }

    @MainActor
    private func confirmResolveAll(taking side: GitClient.ConflictSide) async {
        let context = model.conflictContext ?? .unknown
        let source = side == .ours ? context.oursLabel : context.theirsLabel
        let alert = NSAlert()
        alert.messageText = "所有 \(conflictedChanges.count) 个冲突文件都\(side.actionLabel)？"
        alert.informativeText = "每个文件都会整个换成 \(source) 的版本（那一侧删掉的文件会被删除），然后标记为已解决。已经手工改过的内容会被覆盖。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: side.actionLabel)
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await model.resolveAllConflicts(taking: side)
    }

    /// 「已暂存」区里显示所有有暂存内容的文件；部分暂存的文件会同时出现在两个区里，
    /// 那是刻意的 —— 它确实两边都有内容，藏起任何一边都会让人误判。
    /// 冲突文件例外：它们已经有专属区域，再出现在这里会和冲突区同 id 双高亮。
    private var stagedChanges: [FileChange] {
        model.status.changes.filter { $0.isStaged && !$0.isConflicted }
    }

    private var unstagedChanges: [FileChange] {
        model.status.changes.filter { $0.unstaged != nil && !$0.isConflicted }
    }

    /// 列表行的身份。不能直接用 FileChange（id = 路径）：部分暂存的文件
    /// 会同时出现在「已暂存」「未暂存」两区，两行同 id 会让底层的 NSTableView
    /// 行标识冲突 —— 点一行、两行一起亮，看起来就像两个区是同一个东西。
    /// 把所在侧拼进 id，两行就是两个独立条目（也确实是两个版本）。
    private struct ChangeRowKey: Identifiable {
        let change: FileChange
        let side: WorktreeModel.DiffSide

        var id: String { "\(side.rawValue)|\(change.path)" }
    }

    /// 同一个文件可能同时出现在「已暂存」和「未暂存」两区，路径本身不足以表示选择。
    /// 把所在侧一起放进 tag，点击哪一行就读取哪一侧的 diff。
    private struct ChangeSelection: Hashable {
        var path: String
        var side: WorktreeModel.DiffSide
    }

    private var selectedChange: Binding<ChangeSelection?> {
        Binding(
            get: {
                model.selectedPath.map { ChangeSelection(path: $0, side: model.diffSide) }
            },
            set: { selection in
                guard let selection else {
                    model.selectedPath = nil
                    return
                }
                // 先切侧、再切路径。两个属性都会触发加载，但后一次会取消前一次，
                // 最终只保留带正确 path + side 的查询。
                model.diffSide = selection.side
                model.selectedPath = selection.path
            }
        )
    }
}

// MARK: - 分区标题

private struct SectionHeader: View {
    let title: String
    let count: Int
    let actionLabel: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            Button(actionLabel, action: action)
                .buttonStyle(.borderless)
                .font(.system(size: 10))
        }
    }
}

// MARK: - 单个文件行

private struct ChangeRow: View {
    let change: FileChange
    let isStaged: Bool
    let model: WorktreeModel

    private var kind: ChangeKind {
        (isStaged ? change.staged : change.unstaged) ?? change.primaryKind
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(kind.badge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 14, height: 14)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 0) {
                Text(change.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if change.directory != "." {
                    Text(change.directory)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            if change.isPartiallyStaged {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("部分暂存：这个文件在暂存区和工作区都有改动")
            }

            Button {
                Task {
                    if isStaged { await model.unstage(change) } else { await model.stage(change) }
                }
            } label: {
                Image(systemName: isStaged ? "minus" : "plus")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help(isStaged ? "取消暂存" : "暂存")
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button(isStaged ? "取消暂存" : "暂存") {
                Task {
                    if isStaged { await model.unstage(change) } else { await model.stage(change) }
                }
            }
            Button("打开文件") {
                SystemActions.openFile(in: model.path, path: change.path)
            }
            Button("在 Finder 显示") {
                SystemActions.revealInFinder(model.path.appendingPathComponent(change.path))
            }
            Button("复制路径") { SystemActions.copyToPasteboard(change.path) }

            if !isStaged {
                Divider()
                Button("丢弃改动…", role: .destructive) {
                    Task { await confirmDiscard() }
                }
            }
        }
    }

    private var tint: Color {
        switch kind {
        case .added, .untracked: .green
        case .deleted: .red
        case .modified, .typeChanged: .orange
        case .renamed, .copied: .blue
        case .unmerged: .red
        }
    }

    /// 丢弃是不可撤销的（git 没有回收站），所以一定要二次确认。
    @MainActor
    private func confirmDiscard() async {
        let alert = NSAlert()
        alert.messageText = "丢弃「\(change.displayName)」的改动？"
        alert.informativeText = "这个操作无法撤销，文件会恢复到上次提交的状态。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "丢弃")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await model.discard(change)
    }
}

// MARK: - 冲突文件行

private struct ConflictRow: View {
    let change: FileChange
    let model: WorktreeModel

    var body: some View {
        HStack(spacing: 7) {
            Text(ChangeKind.unmerged.badge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.red)
                .frame(width: 14, height: 14)
                .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 0) {
                Text(change.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    Text(change.conflict?.label ?? "冲突")
                        .foregroundStyle(.red)
                    if change.directory != "." {
                        Text("·")
                        Text(change.directory)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            Button {
                Task { await confirmMarkResolved() }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("标记为已解决：把工作区里现在的内容当作结果")
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button("采用当前更改") { Task { await model.resolveConflict(change, taking: .ours) } }
            Button("采用传入的更改") { Task { await model.resolveConflict(change, taking: .theirs) } }
            Button("标记为已解决") { Task { await confirmMarkResolved() } }
            Divider()
            Button("打开文件") {
                SystemActions.openFile(in: model.path, path: change.path)
            }
            Button("在 Finder 显示") {
                SystemActions.revealInFinder(model.path.appendingPathComponent(change.path))
            }
            Button("复制路径") { SystemActions.copyToPasteboard(change.path) }
            if change.conflict?.hasTextualMarkers == true {
                Divider()
                Button("恢复冲突标记…") { Task { await confirmRestore() } }
            }
        }
    }

    /// 带着 `<<<<<<<` 提交出去是冲突解决里最常见的事故，标记前先数一遍。
    @MainActor
    private func confirmMarkResolved() async {
        let remaining = model.unresolvedMarkerCount(in: change)
        if remaining > 0 {
            let alert = NSAlert()
            alert.messageText = "文件里还有 \(remaining) 处冲突标记"
            alert.informativeText = "「\(change.displayName)」里仍然有 <<<<<<< 这样的标记。现在标记为已解决，这些标记会原样进入提交。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "仍然标记为已解决")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        await model.markConflictResolved(change)
    }

    @MainActor
    private func confirmRestore() async {
        let alert = NSAlert()
        alert.messageText = "恢复「\(change.displayName)」的冲突标记？"
        alert.informativeText = "文件会回到 git 刚合并完的样子，在这个文件里做的所有选择和手工修改都会丢失。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await model.restoreConflictMarkers(change)
    }
}

// MARK: - 提交框

private struct CommitBox: View {
    @Bindable var model: WorktreeModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.commitMessage)
                .disabled(model.isGeneratingCommitMessage)
                .font(.system(size: 12, design: .default))
                .scrollContentBackground(.hidden)
                .frame(height: 74)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topLeading) {
                    if model.commitMessage.isEmpty,
                       !isFocused,
                       !model.isGeneratingCommitMessage {
                        Text("提交信息…")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    aiCommitControl
                        .padding(7)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 0.5)
                }
                .focused($isFocused)

            if !model.isAICommitEnabled {
                HStack(spacing: 5) {
                    Text("AI 生成功能已关闭。")
                        .foregroundStyle(.secondary)
                    SettingsLink { Text("打开设置…") }
                        .buttonStyle(.link)
                }
                .font(.system(size: 10.5))
            }

            if let note = model.generatedDiffNotice {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }

            if model.canRetryCommitMessageGeneration {
                Button("重试") { confirmAndGenerate() }
                    .buttonStyle(.link)
                    .font(.system(size: 10.5))
            }

            HStack(spacing: 8) {
                Toggle("修补上一个提交", isOn: $model.amendLastCommit)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("git commit --amend：把这次改动并进上一个提交，而不是新建一个")
                    .disabled(model.commits.isEmpty)

                Spacer()

                Button {
                    Task { await model.commit() }
                } label: {
                    if model.status.stagedCount > 0 {
                        Text("提交 \(model.status.stagedCount) 项")
                    } else {
                        Text("提交")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!model.canCommit)
                .keyboardShortcut(.return, modifiers: .command)
                .help("⌘↩")
            }

            if model.status.hasConflicts {
                Label("先把上面「冲突」区的文件都标记为已解决，才能提交", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            } else if model.status.stagedCount == 0 && !model.amendLastCommit {
                Text("暂存一些改动才能提交")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var aiCommitControl: some View {
        if model.isGeneratingCommitMessage {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Button("取消") { model.cancelCommitMessageGeneration() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .help("取消生成")
        } else {
            Button { confirmAndGenerate() } label: {
                Image(systemName: model.hasGeneratedCommitMessage ? "arrow.clockwise" : "sparkles")
                    .font(.system(size: 11))
                    .padding(4)
            }
            .buttonStyle(.borderless)
            .background(.regularMaterial, in: Circle())
            .disabled(!model.isAICommitEnabled || model.status.stagedCount == 0)
            .help(aiCommitHelp)
        }
    }

    private var aiCommitHelp: String {
        if !model.isAICommitEnabled {
            return "AI 生成功能已关闭，请在 Grove 设置中开启。"
        }
        if model.status.stagedCount == 0 { return "先暂存一些改动。" }
        return model.hasGeneratedCommitMessage ? "重新生成提交信息" : "用 AI 生成提交信息"
    }

    @MainActor
    private func confirmAndGenerate() {
        if !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 这里选择覆盖前确认：提交框表达的是一份最终草稿，追加多个候选会模糊提交边界。
            let alert = NSAlert()
            alert.messageText = "替换已有的提交信息？"
            alert.informativeText = "AI 生成的草稿会替换输入框里的现有内容。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "替换并生成")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        isFocused = false
        model.startCommitMessageGeneration()
    }

}
