import AppKit
import SwiftUI

struct PullRequestListView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var repository: RepositoryModel
    /// 进入时默认选中的编号。深链接（从别处跳到某个具体请求）和离屏渲染都要用它 ——
    /// 选中状态是视图内部的 @State，外面没有别的办法预置。
    var initialSelection: Int?
    @State private var selection: Int?
    @State private var searchText = ""
    @State private var mergeTarget: PullRequest?

    var body: some View {
        // 平台都认不出来时，整块换成「怎么接进来」的指引 ——
        // 这时候列表和详情都没有内容可显示，留着两栏只是浪费地方。
        if let setup = repository.forgeSetup {
            ForgeSetupView(repository: repository, setup: setup)
        } else {
            splitBody
        }
    }

    private var splitBody: some View {
        GeometryReader { geometry in
            // geometry 已经是扣掉左侧项目菜单后的内容区；列表默认 30%，详情默认 70%。
            let defaultListWidth = max(260, geometry.size.width * 0.3)
            HSplitView {
                list
                    .frame(
                        minWidth: defaultListWidth,
                        idealWidth: defaultListWidth,
                        maxWidth: geometry.size.width * 0.45,
                        maxHeight: .infinity
                    )

                detail
                    .frame(
                        minWidth: 380,
                        idealWidth: geometry.size.width * 0.7,
                        maxHeight: .infinity
                    )
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            selection = selection ?? initialSelection
            await repository.refreshPullRequests()
        }
        .sheet(item: $mergeTarget) { pullRequest in
            MergePullRequestSheet(repository: repository, pullRequest: pullRequest)
        }
    }

    // MARK: - 列表

    private var list: some View {
        VStack(spacing: 0) {
            header

            if let message = repository.pullRequestUnavailableReason {
                ContentUnavailableView {
                    Label("\(repository.reviewTerm)不可用", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            } else if repository.pullRequests.isEmpty {
                ContentUnavailableView {
                    Label(repository.isRefreshingPullRequests ? "正在加载…" : "没有开放的 PR",
                          systemImage: "arrow.triangle.pull")
                } description: {
                    Text(repository.slug.map { "仓库：\($0)" } ?? "")
                }
            } else {
                List {
                    ForEach(filtered) { pullRequest in
                        let isSelected = selection == pullRequest.number
                        Button {
                            selection = pullRequest.number
                        } label: {
                            PullRequestRow(
                                pullRequest: pullRequest,
                                worktree: worktree(for: pullRequest),
                                isSelected: isSelected,
                                isAIReviewing: appModel.isAIReviewing(
                                    for: repository.root,
                                    pullRequestNumber: pullRequest.number
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selectionBackground(isSelected))
                        .contextMenu { menu(for: pullRequest) }
                    }
                }
                .listStyle(.inset)
                .searchable(text: $searchText, placement: .sidebar, prompt: "搜索标题、分支、作者")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(repository.slug ?? repository.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if repository.isRefreshingPullRequests {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    Task { await repository.refreshPullRequests() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("重新加载 PR 列表")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var filtered: [PullRequest] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return repository.pullRequests }
        return repository.pullRequests.filter { pullRequest in
            pullRequest.title.lowercased().contains(query)
                || pullRequest.headRefName.lowercased().contains(query)
                || (pullRequest.author?.login.lowercased().contains(query) ?? false)
                || String(pullRequest.number).contains(query)
        }
    }

    /// 跟 Finder 侧栏一致：浅灰圆角底配强调色文字，不使用整块高饱和蓝色。
    private func selectionBackground(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isSelected
                  ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                  : .clear)
    }

    /// 这个 PR 的分支有没有已经检出成本地工作树。有的话就直接给「跳过去」的入口，
    /// 而不是让用户再建一个（git 也不会允许）。
    private func worktree(for pullRequest: PullRequest) -> Worktree? {
        let candidates = [pullRequest.headRefName, "pr-\(pullRequest.number)"]
        return repository.worktrees.first { worktree in
            guard let branch = worktree.branch else { return false }
            return candidates.contains(branch)
        }
    }

    // MARK: - 详情

    @ViewBuilder
    private var detail: some View {
        Group {
            if let selection, let pullRequest = repository.pullRequests.first(where: { $0.number == selection }) {
                PullRequestDetailView(
                    repository: repository,
                    pullRequest: pullRequest,
                    existingWorktree: worktree(for: pullRequest),
                    onMerge: { mergeTarget = pullRequest }
                )
                .id(pullRequest.number)
            } else {
                ContentUnavailableView {
                    Label("选择一个 PR", systemImage: "arrow.triangle.pull")
                } description: {
                    Text("查看检查状态，或者把它检出成一个工作树。")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for pullRequest: PullRequest) -> some View {
        if let worktree = worktree(for: pullRequest) {
            Button("跳到工作树「\(worktree.name)」") {
                appModel.selection = .worktree(repository: repository.root, worktree: worktree.path)
            }
        } else {
            Button("检出为新工作树") {
                Task { await checkout(pullRequest) }
            }
        }
        Button("在浏览器打开") { SystemActions.openInBrowser(pullRequest.url) }
        Divider()
        Button("复制链接") { SystemActions.copyToPasteboard(pullRequest.url) }
        Button("复制分支名") { SystemActions.copyToPasteboard(pullRequest.headRefName) }
    }

    private func checkout(_ pullRequest: PullRequest) async {
        guard let worktree = await repository.createWorktree(forPullRequest: pullRequest) else { return }
        appModel.selection = .worktree(repository: repository.root, worktree: worktree.path)
    }
}

// MARK: - PR 行

private struct PullRequestRow: View {
    let pullRequest: PullRequest
    let worktree: Worktree?
    let isSelected: Bool
    let isAIReviewing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: pullRequest.status.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.accentColor : statusTint)
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(pullRequest.displayNumber)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(
                            isSelected
                                ? Color.accentColor.opacity(0.75)
                                : Color(nsColor: .tertiaryLabelColor)
                        )
                    Text(pullRequest.title)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let author = pullRequest.author {
                        Text(author.displayName).lineLimit(1)
                    }
                    Text(pullRequest.headRefName)
                        .font(.system(size: 9.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(RelativeDate.format(pullRequest.listTimestamp))
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)

                HStack(spacing: 5) {
                    if isAIReviewing {
                        MiniBadge(text: "Review 中", systemImage: "sparkles", tint: .purple)
                    }
                    if let checks = pullRequest.checks.label, let icon = pullRequest.checks.systemImage {
                        MiniBadge(text: checks, systemImage: icon, tint: checksTint)
                    }
                    if let review = pullRequest.review.label, let icon = pullRequest.review.systemImage {
                        MiniBadge(text: review, systemImage: icon, tint: reviewTint)
                    }
                    if worktree != nil {
                        MiniBadge(text: "已检出", systemImage: "leaf.fill", tint: .teal)
                    }
                    if pullRequest.isCrossRepository {
                        MiniBadge(text: "fork", systemImage: "tuningfork", tint: .indigo)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var statusTint: Color {
        switch pullRequest.status {
        case .open: .green
        case .draft: .gray
        case .merged: .purple
        case .closed: .red
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

    private var reviewTint: Color {
        switch pullRequest.review {
        case .approved: .green
        case .changesRequested: .orange
        case .pending, .none: .secondary
        }
    }
}

struct MiniBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage).font(.system(size: 7.5, weight: .bold))
            Text(text).font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 3.5))
    }
}

// MARK: - PR 详情

private struct PullRequestDetailView: View {
    @Environment(AppModel.self) private var appModel
    let repository: RepositoryModel
    let pullRequest: PullRequest
    let existingWorktree: Worktree?
    let onMerge: () -> Void

    @State private var detailed: PullRequest?
    @State private var threads: [ReviewThread] = []
    @State private var diffFiles: [FileDiff] = []
    @State private var selectedDiffFileID: String?
    @State private var isLoadingThreads = false
    @State private var isLoadingDiff = false
    @State private var didFailDiff = false
    @State private var commentText = ""
    @State private var isWorking = false
    @State private var viewerHasApprovedOverride: Bool?
    @State private var aiReview: PullRequestAIReview?
    @State private var aiReviewIsStale = false
    @State private var aiReviewInstructions = ""
    @State private var aiReviewAreas = Set(PullRequestAIReview.Assessment.Area.allCases)
    @State private var showsAIReviewOptions = false

    /// 详情页要显示正文，而列表查询刻意没带 `body`（太大）。所以进来之后单独补一次。
    private var current: PullRequest { detailed ?? pullRequest }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleBlock
                actionBar
                if !current.labels.isEmpty { labelRow }
                statsRow
                if let checks = current.statusCheckRollup, !checks.isEmpty {
                    checksSection(checks)
                }
                bodySection
                codeSection
                if isReviewingAI || aiReview != nil { aiReviewSection }
                reviewSection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            aiReviewInstructions = appModel.aiReviewInstructions(for: repository.root)
            aiReviewAreas = appModel.aiReviewAreas(for: repository.root)
            restoreCachedAIReview()
            await loadDetail()
        }
        .onChange(of: appModel.aiReviewResultsRevision) { _, _ in
            restoreCachedAIReview(for: diffFiles.isEmpty ? nil : diffFiles)
        }
    }

    /// 详情页补齐列表没有的正文、代码 diff 和评论线程。三项并发加载，
    /// 不让体积最大的 diff 把标题和讨论也一起卡住。
    private func loadDetail() async {
        guard let forge = repository.forge else { return }
        isLoadingThreads = true
        isLoadingDiff = true

        async let loadedDetail = try? await forge.pullRequest(
            number: pullRequest.number,
            in: repository.root
        )
        async let loadedThreads = try? await forge.reviewThreads(
            number: pullRequest.number,
            in: repository.root
        )
        async let loadedDiff = try? await forge.pullRequestDiff(
            number: pullRequest.number,
            in: repository.root
        )

        // 完整详情不只补正文，还包含当前用户的审批状态。即使列表接口已经
        // 带了正文也必须加载，否则批准过的 MR 仍会错误显示「批准」。
        detailed = await loadedDetail

        threads = await loadedThreads ?? []
        isLoadingThreads = false

        if let files = await loadedDiff {
            diffFiles = files
            didFailDiff = false
            selectFirstDiffFileIfNeeded()
            restoreCachedAIReview(for: files)
        } else {
            diffFiles = []
            didFailDiff = true
        }
        isLoadingDiff = false
    }

    private func reloadThreads() async {
        guard let forge = repository.forge else { return }
        isLoadingThreads = true
        threads = (try? await forge.reviewThreads(number: pullRequest.number, in: repository.root)) ?? []
        isLoadingThreads = false
    }

    private func reloadDiff() async {
        guard let forge = repository.forge else { return }
        isLoadingDiff = true
        do {
            diffFiles = try await forge.pullRequestDiff(number: pullRequest.number, in: repository.root)
            didFailDiff = false
            selectFirstDiffFileIfNeeded()
            restoreCachedAIReview(for: diffFiles)
        } catch {
            diffFiles = []
            didFailDiff = true
        }
        isLoadingDiff = false
    }

    // MARK: - 评审

    @ViewBuilder
    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("讨论")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if isLoadingThreads { ProgressView().controlSize(.mini) }
                Spacer()
            }

            // 系统自动生成的记录（"assigned to @x"、"changed title"）数量很大
            // 且没有讨论价值，默认藏起来 —— 不然真正的评审意见会被淹掉。
            let visible = threads.filter { !$0.isSystemOnly }
            if visible.isEmpty && !isLoadingThreads {
                Text("还没有讨论。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(visible) { thread in
                    ReviewThreadView(thread: thread)
                }
            }

            commentComposer
        }
    }

    private var commentComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $commentText)
                .font(.system(size: 11.5))
                .scrollContentBackground(.hidden)
                .frame(height: 64)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topLeading) {
                    if commentText.isEmpty {
                        Text("写点什么…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 0.5) }

            HStack(spacing: 8) {
                Button("发表评论") { Task { await act(.comment) } }
                    .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)

                Button("要求修改") { Task { await act(.requestChanges) } }
                    .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                    .help(current.forge == .gitlab
                          ? "GitLab 没有独立的「要求修改」动作，会发一条带标记的评论"
                          : "提交一条 request changes 评审")

                Spacer()

                if viewerHasApprovedOverride ?? current.viewerHasApproved {
                    if current.forge == .gitlab {
                        Button {
                            Task { await act(.unapprove) }
                        } label: {
                            Label("撤销批准", systemImage: "checkmark.seal.fill")
                        }
                        .tint(.green)
                        .disabled(isWorking)
                    } else {
                        Label("已批准", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Button {
                        Task { await act(.approve) }
                    } label: {
                        Label("批准", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isWorking)
                }

                if isWorking { ProgressView().controlSize(.small) }
            }
        }
    }

    private enum ReviewAction { case comment, requestChanges, approve, unapprove }

    private func act(_ action: ReviewAction) async {
        guard let forge = repository.forge else { return }
        isWorking = true

        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch action {
            case .comment:
                try await forge.comment(number: current.number, body: text, in: repository.root)
            case .requestChanges:
                try await forge.requestChanges(number: current.number, body: text, in: repository.root)
            case .approve:
                try await forge.approve(number: current.number, in: repository.root)
                viewerHasApprovedOverride = true
                // 批准时顺手把写了的评论也发出去，不然那段字会被静默丢掉。
                if !text.isEmpty {
                    try await forge.comment(number: current.number, body: text, in: repository.root)
                }
            case .unapprove:
                try await forge.unapprove(number: current.number, in: repository.root)
                viewerHasApprovedOverride = false
            }
            switch action {
            case .unapprove:
                break
            case .comment, .requestChanges, .approve:
                commentText = ""
            }
        } catch {
            isWorking = false
            appModel.report(title: "操作失败", error: error)
            return
        }
        // 批准不会改变正文或讨论，本地 `didApprove` 已经足够立即收起按钮。
        // 只有真正新增了评论时才重载详情区。
        switch action {
        case .approve where !text.isEmpty:
            await reloadThreads()
        case .approve, .unapprove:
            break
        case .comment, .requestChanges:
            await reloadThreads()
        }
        isWorking = false

        // 列表刷新不该占着操作按钮的 loading。批准状态已经在本地立即更新，
        // 评论区也已单独重载；列表里的汇总角标慢半拍在后台补齐即可。
        Task { await repository.refreshPullRequests() }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label(current.status.label, systemImage: current.status.systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusTint, in: Capsule())

                Text(current.displayNumber)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                if current.isCrossRepository, let owner = current.headRepositoryOwner {
                    MiniBadge(text: "来自 \(owner.login) 的 fork", systemImage: "tuningfork", tint: .indigo)
                }
            }

            Text(current.title)
                .font(.system(size: 18, weight: .semibold))
                .textSelection(.enabled)

            HStack(spacing: 6) {
                if let author = current.author {
                    Text(author.displayName).fontWeight(.medium)
                }
                Text("想把")
                Text(current.headRefName)
                    .font(.system(size: 11, design: .monospaced))
                Text("合并进")
                Text(current.baseRefName)
                    .font(.system(size: 11, design: .monospaced))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if let existingWorktree {
                Button {
                    appModel.selection = .worktree(repository: repository.root, worktree: existingWorktree.path)
                } label: {
                    Label("跳到工作树", systemImage: "leaf.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task {
                        guard let worktree = await repository.createWorktree(forPullRequest: current) else { return }
                        appModel.selection = .worktree(repository: repository.root, worktree: worktree.path)
                    }
                } label: {
                    Label("检出为工作树", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .help("抓取这个 PR 的分支并创建一个新工作树，不影响你当前的工作")
                .disabled(repository.activity != nil)
            }

            Button {
                SystemActions.openInBrowser(current.url)
            } label: {
                Label("在浏览器打开", systemImage: "arrow.up.forward.square")
            }

            if isReviewingAI {
                Button {
                    cancelAIReview()
                } label: {
                    Label("取消 Review", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    startAIReview()
                } label: {
                    Label(aiReview == nil ? "AI Review" : "重新 Review", systemImage: "sparkles")
                }
                .disabled(!canStartAIReview)
                .help(aiReviewHelp)

                Button {
                    showsAIReviewOptions.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("设置本次 AI Review 的补充提示词")
                .popover(isPresented: $showsAIReviewOptions) {
                    aiReviewOptions
                }
            }

            if current.status == .open || current.status == .draft {
                Button {
                    onMerge()
                } label: {
                    Label("合并…", systemImage: "arrow.triangle.merge")
                }
                .disabled(current.status == .draft)
                .help(current.status == .draft ? "草稿状态的 PR 不能合并" : "gh pr merge")
            }

            Spacer()

            if let activity = repository.activity {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(activity).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canStartAIReview: Bool {
        appModel.isAIGenerationEnabled && !isLoadingDiff && !diffFiles.isEmpty
    }

    private var isReviewingAI: Bool {
        appModel.isAIReviewing(
            for: repository.root,
            pullRequestNumber: pullRequest.number
        )
    }

    private var aiReviewHelp: String {
        if !appModel.isAIGenerationEnabled {
            return "AI 生成功能已关闭，请先在 Grove 设置中开启。"
        }
        if isLoadingDiff { return "代码改动加载完成后才能 Review。" }
        if diffFiles.isEmpty { return "这个请求没有可供 Review 的代码改动。" }
        return "使用 \(appModel.aiReviewModel.name) 检查所选的 \(aiReviewAreas.count) 项合并风险"
    }

    private var aiReviewOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("审查范围")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("全选") {
                    aiReviewAreas = Set(PullRequestAIReview.Assessment.Area.allCases)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
            }
            Text("只会分析并输出勾选项；开始后会记作这个项目的默认选择。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(PullRequestAIReview.Assessment.Area.allCases, id: \.self) { area in
                    Toggle(isOn: reviewAreaBinding(area)) {
                        HStack(spacing: 8) {
                            Text(area.displayName)
                                .frame(width: 126, alignment: .leading)
                            Text(area.reviewDescription)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(aiReviewAreas.count == 1 && aiReviewAreas.contains(area))
                }
            }

            Divider()

            Text("本次 AI Review 提示词")
                .font(.system(size: 13, weight: .semibold))
            Text("当前内容来自项目默认提示词，可以针对这次改动临时修改。安全边界和 JSON 输出格式由 Grove 固定管理。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $aiReviewInstructions)
                .font(.system(size: 11.5))
                .scrollContentBackground(.hidden)
                .frame(height: 150)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 0.5) }

            HStack {
                Button("恢复项目默认") {
                    aiReviewInstructions = appModel.aiReviewInstructions(for: repository.root)
                }
                Button("恢复 Grove 默认") {
                    aiReviewInstructions = PullRequestReviewPromptBuilder.defaultInstructions
                }
                Button("保存为项目默认") {
                    appModel.setAIReviewInstructions(aiReviewInstructions, for: repository.root)
                }
                Spacer()
                Button("开始 Review") {
                    showsAIReviewOptions = false
                    startAIReview()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartAIReview)
            }
        }
        .padding(14)
        .frame(width: 520)
    }

    private func startAIReview() {
        guard canStartAIReview else { return }
        let request = current
        let files = diffFiles
        let model = appModel.aiReviewModel
        let instructions = aiReviewInstructions
        let selectedAreas = aiReviewAreas
        appModel.setAIReviewAreas(selectedAreas, for: repository.root)
        appModel.startAIReview(.init(
            pullRequest: request,
            files: files,
            customInstructions: instructions,
            selectedAreas: selectedAreas,
            model: model,
            repositoryRoot: repository.root
        ))
    }

    private func reviewAreaBinding(
        _ area: PullRequestAIReview.Assessment.Area
    ) -> Binding<Bool> {
        Binding(
            get: { aiReviewAreas.contains(area) },
            set: { selected in
                if selected {
                    aiReviewAreas.insert(area)
                } else if aiReviewAreas.count > 1 {
                    aiReviewAreas.remove(area)
                }
            }
        )
    }

    private func cancelAIReview() {
        appModel.cancelAIReview(
            for: repository.root,
            pullRequestNumber: pullRequest.number
        )
    }

    private func restoreCachedAIReview(for files: [FileDiff]? = nil) {
        guard let cached = appModel.cachedAIReview(
            for: repository.root,
            pullRequestNumber: pullRequest.number
        ) else {
            aiReview = nil
            aiReviewIsStale = false
            return
        }
        aiReview = cached.review
        aiReviewIsStale = files.map {
            cached.diffFingerprint != AIReviewCache.diffFingerprint($0)
        } ?? false
    }

    private var labelRow: some View {
        HStack(spacing: 5) {
            ForEach(current.labels) { label in
                Text(label.name)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color(hex: label.color)?.contrastingText ?? .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(hex: label.color) ?? .gray, in: Capsule())
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 14) {
            statItem("文件", "\(current.changedFiles)", "doc.text")
            // GitLab 的 MR 接口不返回增删行数。显示 "+0 −0" 会让人以为这个
            // 请求什么都没改，不如干脆不显示。
            if current.additions > 0 || current.deletions > 0 {
                statItem("新增", "+\(current.additions)", "plus", tint: .green)
                statItem("删除", "−\(current.deletions)", "minus", tint: .red)
            }
            if let mergeable = current.mergeable {
                statItem("可合并性", mergeableLabel(mergeable), "arrow.triangle.merge",
                         tint: mergeable == "CONFLICTING" ? .red : .secondary)
            }
        }
    }

    // MARK: - 代码评审

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("代码变更")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !diffFiles.isEmpty {
                    Text("\(diffFiles.count) 个文件")
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                if isLoadingDiff { ProgressView().controlSize(.mini) }
                Spacer()
                if didFailDiff {
                    Button("重试") { Task { await reloadDiff() } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5))
                }
            }

            Group {
                if isLoadingDiff {
                    ProgressView("正在加载代码改动…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if didFailDiff {
                    ContentUnavailableView {
                        Label("代码改动加载失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("可以重试，或者暂时在浏览器里查看。")
                    }
                } else if diffFiles.isEmpty {
                    ContentUnavailableView {
                        Label("没有代码改动", systemImage: "equal.circle")
                    } description: {
                        Text("这个请求可能只修改了提交记录，或者服务端没有返回 diff。")
                    }
                } else {
                    GeometryReader { geometry in
                        // 文件列表只占代码评审区域的 30%，把主要空间留给代码。
                        let defaultFileListWidth = max(180, geometry.size.width * 0.3)
                        HSplitView {
                            List(diffFiles, selection: $selectedDiffFileID) { file in
                                DiffFileRow(file: file)
                                    .tag(file.id)
                            }
                            .listStyle(.inset)
                            .frame(
                                minWidth: defaultFileListWidth,
                                idealWidth: defaultFileListWidth,
                                maxWidth: max(defaultFileListWidth, geometry.size.width * 0.45),
                                maxHeight: .infinity
                            )

                            if let file = selectedDiffFile {
                                DiffContentView(files: [file], showsFileHeaders: true)
                                    .frame(
                                        minWidth: 320,
                                        idealWidth: geometry.size.width * 0.7,
                                        maxHeight: .infinity
                                    )
                                    .layoutPriority(1)
                            }
                        }
                    }
                }
            }
            .frame(height: 520)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5) }
        }
    }

    @ViewBuilder
    private var aiReviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label("AI Review", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                if isReviewingAI {
                    ProgressView().controlSize(.mini)
                    Text("正在用 \(activeAIReviewModel.name) 检查代码…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else if let aiReview {
                    Spacer()
                    Label(verdictLabel(aiReview.verdict), systemImage: verdictIcon(aiReview.verdict))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(verdictTint(aiReview.verdict))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(verdictTint(aiReview.verdict).opacity(0.12), in: Capsule())
                }
            }

            if let aiReview {
                if aiReviewIsStale {
                    Label("PR 代码已更新，这份结果基于旧 diff；建议重新 Review。",
                          systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                }

                Text(aiReview.summary)
                    .font(.system(size: 11.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if aiReview.wasTruncated {
                    Label("改动过大，只审查了按文件截取的片段；结论已按信息不足处理。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }

                VStack(spacing: 7) {
                    ForEach(aiReview.assessments) { assessment in
                        aiReviewAssessment(assessment)
                    }
                }

                Text("AI Review 根据 PR diff 和仓库只读上下文判断合并风险，不能代替实际构建与测试。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(.separator, lineWidth: 0.5) }
    }

    private var activeAIReviewModel: AIGenerationModel {
        appModel.aiReviewingModel(
            for: repository.root,
            pullRequestNumber: pullRequest.number
        ) ?? appModel.aiReviewModel
    }

    private func aiReviewAssessment(_ assessment: PullRequestAIReview.Assessment) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: assessmentIcon(assessment.status))
                .foregroundStyle(assessmentTint(assessment.status))
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(assessmentLabel(assessment.area))
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(assessmentStatusLabel(assessment.status))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(assessmentTint(assessment.status))
                }
                Text(assessment.summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let evidence = assessment.evidence,
                   !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(evidence)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let file = assessment.file {
                    Button {
                        if let match = diffFiles.first(where: {
                            $0.newPath == file || $0.oldPath == file || $0.displayPath == file
                        }) {
                            selectedDiffFileID = match.id
                        }
                    } label: {
                        Text(file + (assessment.line.map { ":\($0)" } ?? ""))
                            .font(.system(size: 9.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.borderless)
                    .help("在代码变更中选择这个文件")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
    }

    private func verdictLabel(_ verdict: PullRequestAIReview.Verdict) -> String {
        switch verdict {
        case .ready:
            switch externalMergeState {
            case .conflict: "代码无明显问题，但存在冲突"
            case .failedChecks: "代码无明显问题，但检查失败"
            case .pendingChecks: "代码可合并，等待检查"
            case .clear: "可以合并"
            }
        case .needsChanges: "建议修改后合并"
        case .uncertain: "暂时无法判断"
        }
    }

    private func verdictIcon(_ verdict: PullRequestAIReview.Verdict) -> String {
        switch verdict {
        case .ready:
            switch externalMergeState {
            case .conflict, .failedChecks: "exclamationmark.octagon.fill"
            case .pendingChecks: "clock.fill"
            case .clear: "checkmark.seal.fill"
            }
        case .needsChanges: "exclamationmark.octagon.fill"
        case .uncertain: "questionmark.diamond.fill"
        }
    }

    private func verdictTint(_ verdict: PullRequestAIReview.Verdict) -> Color {
        switch verdict {
        case .ready:
            switch externalMergeState {
            case .conflict, .failedChecks: .red
            case .pendingChecks: .orange
            case .clear: .green
            }
        case .needsChanges: .red
        case .uncertain: .orange
        }
    }

    private enum ExternalMergeState {
        case conflict, failedChecks, pendingChecks, clear
    }

    private var externalMergeState: ExternalMergeState {
        if current.mergeable?.uppercased() == "CONFLICTING" { return .conflict }
        switch current.checks {
        case .failing: return .failedChecks
        case .running: return .pendingChecks
        case .passing, .none: return .clear
        }
    }

    private func assessmentLabel(_ area: PullRequestAIReview.Assessment.Area) -> String {
        area.displayName
    }

    private func assessmentStatusLabel(_ status: PullRequestAIReview.Assessment.Status) -> String {
        switch status {
        case .clear: "未发现风险"
        case .risk: "存在风险"
        case .unknown: "信息不足"
        }
    }

    private func assessmentIcon(_ status: PullRequestAIReview.Assessment.Status) -> String {
        switch status {
        case .clear: "checkmark.circle.fill"
        case .risk: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private func assessmentTint(_ status: PullRequestAIReview.Assessment.Status) -> Color {
        switch status {
        case .clear: .green
        case .risk: .red
        case .unknown: .orange
        }
    }

    private var selectedDiffFile: FileDiff? {
        diffFiles.first { $0.id == selectedDiffFileID } ?? diffFiles.first
    }

    private func selectFirstDiffFileIfNeeded() {
        guard !diffFiles.contains(where: { $0.id == selectedDiffFileID }) else { return }
        selectedDiffFileID = diffFiles.first?.id
    }

    private func statItem(_ title: String, _ value: String, _ icon: String, tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Label(value, systemImage: icon)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    private func mergeableLabel(_ value: String) -> String {
        switch value.uppercased() {
        case "MERGEABLE": "无冲突"
        case "CONFLICTING": "有冲突"
        // GitHub 是异步计算这个的，刚推完代码来看就是 UNKNOWN。
        // 显示「计算中」而不是「未知」，免得用户以为出错了。
        default: "计算中"
        }
    }

    @ViewBuilder
    private func checksSection(_ checks: [StatusCheck]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("检查")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(checks.prefix(40))) { check in
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: check.outcome))
                            .font(.system(size: 11))
                            .foregroundStyle(tint(for: check.outcome))
                            .frame(width: 14)

                        Text(check.displayName)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 8)

                        if let link = check.link {
                            Button {
                                SystemActions.openInBrowser(link.absoluteString)
                            } label: {
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.system(size: 9.5))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)

                    if check.id != checks.prefix(40).last?.id {
                        Divider().padding(.leading, 32)
                    }
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

            if checks.count > 40 {
                Text("还有 \(checks.count - 40) 项未显示，在浏览器里查看完整列表。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        if let body = current.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("描述")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                // PR 正文是 Markdown。这里不做完整渲染 —— SwiftUI 的 `Text(markdown:)`
                // 不支持标题、列表、代码块，硬套只会渲染得更乱。原样等宽展示反而更可读，
                // 需要好看的排版就点「在浏览器打开」。
                Text(body)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func icon(for outcome: StatusCheck.Outcome) -> String {
        switch outcome {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .skipped: "minus.circle"
        }
    }

    private func tint(for outcome: StatusCheck.Outcome) -> Color {
        switch outcome {
        case .success: .green
        case .failure: .red
        case .pending: .orange
        case .skipped: .secondary
        }
    }

    private var statusTint: Color {
        switch current.status {
        case .open: .green
        case .draft: .gray
        case .merged: .purple
        case .closed: .red
        }
    }
}

// MARK: - 颜色工具

extension Color {
    /// 从 GitHub 标签的六位十六进制色值构造颜色（不带 `#`）。
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// 在这个背景色上应该用黑字还是白字。
    ///
    /// GitHub 的标签颜色用户可以随便设，从 `f9d0c4` 到 `0e8a16` 都有。
    /// 固定用白字的话浅色标签会完全看不见，所以按感知亮度选。
    var contrastingText: Color {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return .black }
        // ITU-R BT.601 的亮度权重：人眼对绿色最敏感，对蓝色最不敏感。
        let luminance = 0.299 * components.redComponent
            + 0.587 * components.greenComponent
            + 0.114 * components.blueComponent
        return luminance > 0.6 ? .black : .white
    }
}

// MARK: - 评论线程

struct ReviewThreadView: View {
    let thread: ReviewThread

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let filePath = thread.filePath {
                HStack(spacing: 5) {
                    Image(systemName: "text.alignleft").font(.system(size: 9))
                    Text(filePath)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let line = thread.line {
                        Text("第 \(line) 行").font(.system(size: 9.5))
                    }
                    if thread.isResolved {
                        MiniBadge(text: "已解决", systemImage: "checkmark", tint: .green)
                    }
                }
                .foregroundStyle(.secondary)
            }

            ForEach(thread.notes.filter { !$0.isSystem }) { note in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(note.authorName)
                            .font(.system(size: 11, weight: .semibold))
                        if let date = note.createdAt {
                            Text(RelativeDate.format(date))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(note.body)
                        .font(.system(size: 11.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        // 行内评论跟整体评论视觉上要能区分 —— review 时最要紧的就是那些指着
        // 具体某一行说话的意见。
        .overlay(alignment: .leading) {
            if thread.isInline {
                Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 2)
            }
        }
    }
}

// MARK: - 接入指引

/// 认不出 origin 属于哪个平台时显示的指引。
///
/// 重点是**照着能做完**：命令拼好、可以一键复制、跑完点一下就重新检测。
/// 只说一句「不支持这个远端」等于把用户扔进 glab 的文档里自己找路。
struct ForgeSetupView: View {
    @Environment(AppModel.self) private var appModel
    let repository: RepositoryModel
    let setup: AppModel.ForgeSetup

    @State private var isDetecting = false
    @State private var copiedCommand: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("还没接入这个平台", systemImage: "link.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text(setup.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !setup.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(setup.steps) { step in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(step.text)
                                    .font(.system(size: 11.5, weight: .medium))

                                HStack(spacing: 8) {
                                    Text(step.command)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Button {
                                        SystemActions.copyToPasteboard(step.command)
                                        copiedCommand = step.command
                                    } label: {
                                        Image(systemName: copiedCommand == step.command
                                              ? "checkmark" : "doc.on.doc")
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.borderless)
                                    .help("复制命令")
                                }
                                .padding(9)
                                .background(Color(nsColor: .textBackgroundColor),
                                            in: RoundedRectangle(cornerRadius: 7))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 0.5)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            isDetecting = true
                            await appModel.redetectForges()
                            isDetecting = false
                        }
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDetecting)

                    if isDetecting { ProgressView().controlSize(.small) }

                    Text("在终端里跑完上面任一条之后点它，不用重启 Grove。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                Divider()

                // 明确说清楚「不可用的只是评审那一块」，免得用户以为整个仓库废了。
                Label("工作树、提交、diff、推送这些都不受影响 —— 它们只用 git，跟平台无关。",
                      systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
