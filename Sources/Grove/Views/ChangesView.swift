import SwiftUI

struct ChangesView: View {
    @Bindable var model: WorktreeModel

    var body: some View {
        // HSplitView 只按内容的固有高度撑开，不会自己吃掉父容器给的全部空间。
        // 不显式声明撑满的话，整个详情区会缩成中间一条、上下留出大片空白，
        // 而文件列表被挤到几乎没有高度、内容直接被裁掉。
        HSplitView {
            VStack(spacing: 0) {
                fileList
                Divider()
                CommitBox(model: model)
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 460, maxHeight: .infinity)

            DiffPane(model: model)
                .frame(minWidth: 380, maxHeight: .infinity)
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
                List(selection: Binding(
                    get: { model.selectedPath },
                    set: { model.selectedPath = $0 }
                )) {
                    if !stagedChanges.isEmpty {
                        Section {
                            ForEach(stagedChanges) { change in
                                ChangeRow(change: change, isStaged: true, model: model)
                                    .tag(change.path)
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
                            ForEach(unstagedChanges) { change in
                                ChangeRow(change: change, isStaged: false, model: model)
                                    .tag(change.path)
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

    /// 「已暂存」区里显示所有有暂存内容的文件；部分暂存的文件会同时出现在两个区里，
    /// 那是刻意的 —— 它确实两边都有内容，藏起任何一边都会让人误判。
    private var stagedChanges: [FileChange] {
        model.status.changes.filter(\.isStaged)
    }

    private var unstagedChanges: [FileChange] {
        model.status.changes.filter { $0.unstaged != nil }
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

// MARK: - 提交框

private struct CommitBox: View {
    @Bindable var model: WorktreeModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.commitMessage)
                .font(.system(size: 12, design: .default))
                .scrollContentBackground(.hidden)
                .frame(height: 74)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topLeading) {
                    if model.commitMessage.isEmpty {
                        Text("提交信息…")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 12)
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

            if model.generatedFromTruncatedDiff {
                Label("diff 较大，只分析了一部分", systemImage: "exclamationmark.triangle")
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
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCommit)
                .keyboardShortcut(.return, modifiers: .command)
                .help("⌘↩")
            }

            if model.status.hasConflicts {
                Label("先解决冲突再提交", systemImage: "exclamationmark.triangle.fill")
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
        model.startCommitMessageGeneration()
    }

}
