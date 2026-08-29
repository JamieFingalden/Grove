import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: RootView.ActiveSheet?

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            ForEach(model.repositories) { repository in
                Section {
                    ForEach(repository.worktrees) { worktree in
                        WorktreeRow(repository: repository, worktree: worktree)
                            .tag(AppModel.Selection.worktree(repository: repository.root, worktree: worktree.path))
                            .contextMenu {
                                worktreeMenu(repository: repository, worktree: worktree)
                            }
                    }

                    // 只要有远端就把入口留着。以前是 slug 拿到了才显示 ——
                    // 于是 GitLab 没登录、或者 gh 还没认出仓库时，整行直接消失，
                    // 用户根本不知道有这个功能，更不知道差哪一步。
                    if repository.hasRemote {
                        PullRequestsRow(repository: repository)
                            .tag(AppModel.Selection.pullRequests(repository: repository.root))
                    }
                } header: {
                    RepositoryHeader(repository: repository, sheet: $sheet)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.repositories.isEmpty && model.toolsReady {
                ContentUnavailableView {
                    Label("还没有仓库", systemImage: "folder")
                } description: {
                    Text("按 ⌘O 打开一个。")
                }
            }
        }
    }

    @ViewBuilder
    private func worktreeMenu(repository: RepositoryModel, worktree: Worktree) -> some View {
        Button("在终端打开") { SystemActions.openInTerminal(worktree.path) }
        Button("在编辑器打开") { SystemActions.openInEditor(worktree.path) }
        Button("在 Finder 显示") { SystemActions.revealInFinder(worktree.path) }
        Button("复制路径") { SystemActions.copyToPasteboard(worktree.path.path) }

        Divider()

        if worktree.isLocked {
            Button("解锁") {
                Task { await repository.setLock(false, on: worktree) }
            }
        } else if !worktree.isPrimary {
            Button("锁定") {
                Task { await repository.setLock(true, on: worktree) }
            }
        }

        // 主工作树就是仓库本体，删了等于删仓库。git 自己也拒绝，这里直接不给这个入口。
        if !worktree.isPrimary {
            Divider()
            Button("删除工作树…", role: .destructive) {
                sheet = .removeWorktree(repository, worktree)
            }
        }
    }
}

// MARK: - 仓库标题

private struct RepositoryHeader: View {
    @Environment(AppModel.self) private var model
    let repository: RepositoryModel
    @Binding var sheet: RootView.ActiveSheet?

    var body: some View {
        HStack(spacing: 6) {
            Text(repository.name)
                .lineLimit(1)
                .truncationMode(.middle)

            if repository.isRefreshing {
                ProgressView().controlSize(.mini)
            }

            Spacer(minLength: 4)

            Menu {
                Button("新建工作树…") { sheet = .newWorktree(repository) }
                Button("抓取远端") {
                    Task { await repository.fetch() }
                }
                .disabled(!repository.hasRemote)

                Divider()

                Button("清理失效工作树") {
                    Task { await repository.pruneWorktrees() }
                }
                .help("git worktree prune：清掉目录已被手工删除、但 git 还记着的工作树")

                Button("清理已合并分支…") { sheet = .cleanupBranches(repository) }
                    .disabled(repository.staleBranches.isEmpty)

                Divider()

                Button(repository.aiCommitEnabled ? "关闭 AI 生成功能" : "开启 AI 生成功能…") {
                    if repository.aiCommitEnabled {
                        repository.setAICommitEnabled(false)
                    } else {
                        Task { await confirmAICommitEnable() }
                    }
                }

                Divider()

                Button("在 Finder 显示") { SystemActions.revealInFinder(repository.root) }
                Button("复制路径") { SystemActions.copyToPasteboard(repository.root.path) }

                Divider()

                Button("从 Grove 移除", role: .destructive) {
                    model.closeRepository(repository)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @MainActor
    private func confirmAICommitEnable() async {
        let worktree = model.selectedRepository?.root == repository.root
            ? model.selectedWorktreeModel
            : repository.worktrees.first.flatMap { repository.worktreeModel(for: $0.path) }

        let byteCount: Int
        do {
            byteCount = try await worktree?.estimatedAICommitByteCount() ?? 0
        } catch {
            model.report(title: "读取 AI 提交信息上下文失败", error: error)
            return
        }

        guard AIEnableConfirmation.confirm(repository: repository, byteCount: byteCount) else { return }
        repository.setAICommitEnabled(true)
    }
}

// MARK: - 工作树行

private struct WorktreeRow: View {
    let repository: RepositoryModel
    let worktree: Worktree

    /// 这一行对应的详情模型。可能还没建（没被选中过），那就只显示静态信息。
    private var detail: WorktreeModel? {
        repository.worktreeModel(for: worktree.path)
    }

    private var pullRequest: PullRequest? {
        detail?.linkedPullRequest ?? repository.pullRequest(forBranch: worktree.branch)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(worktree.isPrimary ? Color.accentColor : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(worktree.name)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if worktree.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if worktree.isPrunable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("目录已不存在，可以清理掉")
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: worktree.isDetached ? "arrow.triangle.branch" : "arrow.triangle.branch")
                        .font(.system(size: 8.5))
                    Text(worktree.checkoutLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 2)

            trailingBadges
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if worktree.isBare { return "archivebox" }
        if worktree.isPrimary { return "house" }
        return "leaf"
    }

    @ViewBuilder
    private var trailingBadges: some View {
        HStack(spacing: 4) {
            if let status = detail?.status {
                if status.hasConflicts {
                    Badge(text: "\(status.conflictCount)", systemImage: "exclamationmark.triangle.fill", tint: .red)
                        .help("有冲突未解决")
                } else if !status.isClean {
                    Badge(text: "\(status.changes.count)", systemImage: "pencil", tint: .orange)
                        .help("\(status.changes.count) 个文件有改动")
                }

                if status.ahead > 0 {
                    Badge(text: "\(status.ahead)", systemImage: "arrow.up", tint: .blue)
                        .help("领先上游 \(status.ahead) 个提交")
                }
                if status.behind > 0 {
                    Badge(text: "\(status.behind)", systemImage: "arrow.down", tint: .purple)
                        .help("落后上游 \(status.behind) 个提交")
                }
            }

            if let pullRequest {
                PullRequestBadge(pullRequest: pullRequest)
            }
        }
    }
}

// MARK: - PR 入口行

private struct PullRequestsRow: View {
    let repository: RepositoryModel

    private var unavailableReason: String? { repository.pullRequestUnavailableReason }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            // 平台不同叫法不同：GitHub 是 Pull Request，GitLab 是合并请求。
            Text(repository.reviewTerm)

            Spacer(minLength: 4)

            if repository.isRefreshingPullRequests {
                ProgressView().controlSize(.mini)
            } else if unavailableReason != nil {
                // 用不了也要看得见，并且点进去能知道差哪一步。
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else if !repository.pullRequests.isEmpty {
                Text("\(repository.pullRequests.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(unavailableReason == nil ? 1 : 0.6)
        .help(unavailableReason ?? "查看这个仓库的\(repository.reviewTerm)")
    }
}

// MARK: - 小组件

struct Badge: View {
    let text: String
    let systemImage: String?
    let tint: Color

    init(text: String, systemImage: String? = nil, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 1.5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

struct PullRequestBadge: View {
    let pullRequest: PullRequest

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: pullRequest.status.systemImage)
                .font(.system(size: 8, weight: .bold))
            Text("#\(pullRequest.number)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.14), in: Capsule())
        .help(helpText)
    }

    private var tint: Color {
        switch pullRequest.status {
        case .open: pullRequest.checks.isFailing ? .red : .green
        case .draft: .gray
        case .merged: .purple
        case .closed: .red
        }
    }

    private var helpText: String {
        var parts = ["PR #\(pullRequest.number) · \(pullRequest.status.label)"]
        if let review = pullRequest.review.label { parts.append(review) }
        if let checks = pullRequest.checks.label { parts.append(checks) }
        return parts.joined(separator: " · ")
    }
}

extension PullRequest.CheckRollup {
    var isFailing: Bool {
        if case .failing = self { return true }
        return false
    }
}
