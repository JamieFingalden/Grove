import SwiftUI

struct WorktreeDetailView: View {
    @Bindable var model: WorktreeModel
    @Binding var sheet: RootView.ActiveSheet?
    @State private var tab: Tab = .changes

    enum Tab: String, CaseIterable, Identifiable {
        case changes, history

        var id: String { rawValue }
        var label: String {
            switch self {
            case .changes: "变更"
            case .history: "历史"
            }
        }
        var systemImage: String {
            switch self {
            case .changes: "pencil.and.list.clipboard"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorktreeHeader(model: model, sheet: $sheet)

            Divider()

            Picker("视图", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.label, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // 跟标题、内容一样左对齐。放在 VStack 里不管的话会居中，
            // 页面上其他东西全都靠左，只有它飘在中间，看着像没写完。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)

            Divider()

            switch tab {
            case .changes:
                ChangesView(model: model)
            case .history:
                HistoryView(model: model)
            }
        }
        // 撑满详情区。VStack 默认只占内容需要的高度，然后被父容器垂直居中，
        // 结果就是上下各留一大片空白。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }
}

// MARK: - 头部

private struct WorktreeHeader: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: WorktreeModel
    @Binding var sheet: RootView.ActiveSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(model.worktree.name)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if model.worktree.isPrimary {
                            Text("主工作树")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        if let operation = model.status.operation {
                            Label(operation.rawValue, systemImage: operation.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.15), in: Capsule())
                        }
                    }

                    branchLine
                }

                Spacer(minLength: 12)

                actions
            }

            if model.isRebasing { rebaseBanner }

            if let pullRequest = model.linkedPullRequest {
                PullRequestSummaryCard(pullRequest: pullRequest)
            }

            if let activity = model.activity {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(activity).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// 变基中途停下来时的出路条。
    ///
    /// 没有它的话，一遇冲突用户就被卡在半截状态里只能回终端 ——
    /// 那等于这个功能只做了一半。
    private var rebaseBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("变基进行中")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.status.hasConflicts
                     ? "有 \(model.status.conflictCount) 个文件冲突。改好之后暂存它们，再点「继续」。"
                     : "冲突已解决。点「继续」把剩下的提交接着重放。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("中止") { Task { await model.rebaseStep(.abort) } }
                .help("回到变基前的样子，什么都不改")
            Button("跳过") { Task { await model.rebaseStep(.skip) } }
                .help("丢掉当前这个提交，继续重放后面的")
            Button("继续") { Task { await model.rebaseStep(.cont) } }
                .buttonStyle(.borderedProminent)
                .disabled(model.status.hasConflicts)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).stroke(.orange.opacity(0.35), lineWidth: 1)
        }
    }

    private var branchLine: some View {
        HStack(spacing: 8) {
            Label(model.worktree.checkoutLabel, systemImage: "arrow.triangle.branch")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let upstream = model.status.upstream {
                Text("→ \(upstream)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if model.worktree.branch != nil {
                Text("未设上游")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if model.status.ahead > 0 {
                Badge(text: "\(model.status.ahead)", systemImage: "arrow.up", tint: .blue)
            }
            if model.status.behind > 0 {
                Badge(text: "\(model.status.behind)", systemImage: "arrow.down", tint: .purple)
            }

            Button {
                SystemActions.copyToPasteboard(model.path.path)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9.5))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help(model.path.path)
        }
    }

    /// 推送按钮。
    ///
    /// 只有一个远端时就是一个普通按钮 —— 多问一步「推到哪」纯属添乱。
    /// 有多个远端才变成分离式按钮：主区域按分支自己的上游推（跟终端里
    /// 敲 `git push` 一致），点箭头能展开选别的远端。
    /// 这在「内网 GitLab 做主、GitHub 做备份」这种仓库上是刚需。
    @ViewBuilder
    private var pushControl: some View {
        let repository = model.repository
        let remotes = repository?.remotes ?? []
        let isBusy = model.worktree.branch == nil || model.activity != nil

        if remotes.count > 1 {
            Menu {
                ForEach(remotes) { remote in
                    Button {
                        Task { await model.push(to: remote) }
                    } label: {
                        // 名字后面跟上目标地址：两个远端都叫得很像的时候
                        // （origin / upstream），只看名字根本分不清推去了哪。
                        Text(remote.name == model.upstreamRemoteName
                             ? "\(remote.name)（当前上游） — \(remote.summary)"
                             : "\(remote.name) — \(remote.summary)")
                    }
                }
            } label: {
                syncLabel(for: .push, title: "推送", systemImage: "arrow.up")
            } primaryAction: {
                Task { await model.push(to: model.defaultPushRemote) }
            }
            .menuStyle(.button)
            .tint(syncTint(for: .push))
            .fixedSize()
            .disabled(isBusy)
            .help(pushHelp(remotes: remotes))
        } else {
            Button {
                Task { await model.push() }
            } label: {
                syncLabel(for: .push, title: "推送", systemImage: "arrow.up")
            }
            .tint(syncTint(for: .push))
            .disabled(isBusy)
            .help(model.status.upstream == nil ? "推送并建立上游跟踪" : "git push")
        }
    }

    /// 变基按钮。跟拉取、推送并排 —— 这三个都是「跟远端对齐」的动作，
    /// 属于同一组，藏进菜单里等于让人猜它在哪。
    private var rebaseControl: some View {
        Button {
            sheet = .rebase(model)
        } label: {
            Label("变基", systemImage: "arrow.triangle.branch")
        }
        .disabled(model.worktree.branch == nil || model.isRebasing || model.activity != nil)
        .help(rebaseHelp)
    }

    private var rebaseHelp: String {
        if model.worktree.branch == nil { return "游离 HEAD 上没有分支可以变基" }
        if model.isRebasing { return "已经在变基中了，先处理上面那条横幅" }
        if let target = model.suggestedRebaseTarget {
            return "把当前分支重放到 \(target) 上（可以改目标）"
        }
        return "选一个分支，把当前分支重放到它上面"
    }

    /// 评审按钮。不可用时**保持在原位、禁用、把原因放进 tooltip**，
    /// 而不是整个消失 —— 消失了用户只会以为功能坏了。
    @ViewBuilder
    private var reviewControl: some View {
        switch model.pullRequestAction {
        case .view(let pullRequest):
            Button {
                SystemActions.openInBrowser(pullRequest.url)
            } label: {
                Label("查看 \(pullRequest.displayNumber)", systemImage: "arrow.up.forward.square")
            }
            .help(pullRequest.title)

        case .create(let term):
            Button {
                sheet = .createPullRequest(model)
            } label: {
                Label("提\(term)", systemImage: "arrow.triangle.pull")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.activity != nil)

        case .unavailable(let reason):
            Button {
            } label: {
                Label("提交评审", systemImage: "arrow.triangle.pull")
            }
            .disabled(true)
            .help(reason)
        }
    }

    private func pushHelp(remotes: [NamedRemote]) -> String {
        let target = model.defaultPushRemote?.name ?? "上游"
        let others = remotes.filter { $0.name != model.defaultPushRemote?.name }.map(\.name)
        var text = "推送到 \(target)"
        if model.status.upstream == nil { text += "（并建立上游跟踪）" }
        if !others.isEmpty { text += "；点箭头可选 \(others.joined(separator: "、"))" }
        return text
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.pull() }
            } label: {
                syncLabel(for: .pull, title: "拉取", systemImage: "arrow.down")
            }
            .tint(syncTint(for: .pull))
            .help("git pull --ff-only")
            .disabled(model.status.upstream == nil || model.activity != nil)

            rebaseControl

            pushControl

            reviewControl

            Menu {
                Button("在终端打开") { SystemActions.openInTerminal(model.path) }
                Button("在编辑器打开") { SystemActions.openInEditor(model.path) }
                Button("在 Finder 显示") { SystemActions.revealInFinder(model.path) }
                Divider()
                Button("刷新") { Task { await model.refresh() } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func syncLabel(
        for action: WorktreeModel.SyncFeedback.Action,
        title: String,
        systemImage: String
    ) -> some View {
        if let feedback = model.syncFeedback, feedback.action == action {
            switch feedback.phase {
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("\(title)中")
                }
            case .succeeded:
                Label("\(title)完成", systemImage: "checkmark")
            case .failed:
                Label("\(title)失败", systemImage: "exclamationmark.triangle.fill")
            }
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    private func syncTint(for action: WorktreeModel.SyncFeedback.Action) -> Color? {
        guard let feedback = model.syncFeedback, feedback.action == action else { return nil }
        switch feedback.phase {
        case .running: return nil
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}

// MARK: - PR 摘要卡片

struct PullRequestSummaryCard: View {
    let pullRequest: PullRequest

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: pullRequest.status.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(statusTint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(pullRequest.number)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(statusTint)
                    Text(pullRequest.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text("\(pullRequest.headRefName) → \(pullRequest.baseRefName)")
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let review = pullRequest.review.label,
                       let icon = pullRequest.review.systemImage {
                        Label(review, systemImage: icon)
                            .foregroundStyle(reviewTint)
                    }
                    if let checks = pullRequest.checks.label,
                       let icon = pullRequest.checks.systemImage {
                        Label(checks, systemImage: icon)
                            .foregroundStyle(checksTint)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                SystemActions.openInBrowser(pullRequest.url)
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("在浏览器打开")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(statusTint.opacity(0.25), lineWidth: 1)
        }
    }

    private var statusTint: Color {
        switch pullRequest.status {
        case .open: .green
        case .draft: .gray
        case .merged: .purple
        case .closed: .red
        }
    }

    private var reviewTint: Color {
        switch pullRequest.review {
        case .approved: .green
        case .changesRequested: .orange
        case .pending, .none: .secondary
        }
    }

    private var checksTint: Color {
        switch pullRequest.checks {
        case .passing: .green
        case .failing: .red
        case .running: .orange
        case .none: .secondary
        }
    }
}
