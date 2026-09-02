import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: ActiveSheet?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showsHoverSidebar = false
    @State private var sidebarDismissTask: Task<Void, Never>?

    /// 用一个枚举驱动所有弹窗，而不是给每个 sheet 一个 Bool ——
    /// 多个 Bool 会出现「两个都为 true」的非法状态，SwiftUI 那时的表现是未定义的。
    enum ActiveSheet: Identifiable {
        case newWorktree(RepositoryModel)
        case createRemoteRepository(RepositoryModel)
        case createPullRequest(WorktreeModel)
        case removeWorktree(RepositoryModel, Worktree)
        case cleanupBranches(RepositoryModel)
        case rebase(WorktreeModel)

        var id: String {
            switch self {
            case .newWorktree(let repository): "new-\(repository.root.path)"
            case .createRemoteRepository(let repository): "remote-\(repository.root.path)"
            case .createPullRequest(let worktree): "pr-\(worktree.identity.path)"
            case .removeWorktree(_, let worktree): "remove-\(worktree.path.path)"
            case .cleanupBranches(let repository): "cleanup-\(repository.root.path)"
            case .rebase(let worktree): "rebase-\(worktree.identity.path)"
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(sheet: $sheet)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .overlay(alignment: .leading) { hoverSidebar }
        .overlay(alignment: .bottom) { failureBanner }
        .sheet(item: $sheet)
        .task(id: refreshTrigger) { await refreshSelection() }
        .onChange(of: sidebarVisibility) { _, visibility in
            guard visibility != .detailOnly else { return }
            dismissHoverSidebar()
        }
    }

    // MARK: - 临时侧栏

    /// 永久侧栏收起后，窗口左缘保留一条窄热点；悬停时用浮层展示，不挤压详情区。
    @ViewBuilder
    private var hoverSidebar: some View {
        if sidebarVisibility == .detailOnly {
            Group {
                if showsHoverSidebar {
                    ZStack(alignment: .leading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { dismissHoverSidebar() }

                    SidebarView(sheet: $sheet)
                        .frame(width: 272)
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.separator.opacity(0.7), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.22), radius: 20, x: 6, y: 3)
                        .padding(8)
                        .onHover(perform: updateHoverSidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    Button {
                        presentHoverSidebar()
                    } label: {
                        Color.clear
                            .frame(width: 8)
                            .frame(maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("临时显示边栏")
                    .onHover { isHovering in
                        if isHovering { updateHoverSidebar(true) }
                    }
                }
            }
        }
    }

    private func updateHoverSidebar(_ isHovering: Bool) {
        sidebarDismissTask?.cancel()
        if isHovering {
            presentHoverSidebar()
            return
        }

        sidebarDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                showsHoverSidebar = false
            }
        }
    }

    private func presentHoverSidebar() {
        sidebarDismissTask?.cancel()
        guard !showsHoverSidebar else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showsHoverSidebar = true
        }
    }

    private func dismissHoverSidebar() {
        sidebarDismissTask?.cancel()
        guard showsHoverSidebar else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            showsHoverSidebar = false
        }
    }

    // MARK: - 详情区

    @ViewBuilder
    private var detail: some View {
        if !model.toolsReady {
            ProgressView("正在准备…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.repositories.isEmpty {
            EmptyRepositoryView()
        } else {
            switch model.selection {
            case .worktree:
                if let worktree = model.selectedWorktreeModel {
                    WorktreeDetailView(model: worktree, sheet: $sheet)
                        // path 变了就当成换了个页面，重建视图内部状态（比如滚动位置、
                        // 展开的 hunk），否则会看到上一个工作树的残留。
                        .id(worktree.path)
                } else {
                    placeholder
                }
            case .pullRequests:
                if let repository = model.selectedRepository {
                    PullRequestListView(repository: repository)
                        .id(repository.root)
                } else {
                    placeholder
                }
            case nil:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "选择一个工作树",
            systemImage: "tree",
            description: Text("从左侧挑一个工作树查看它的改动和 PR。")
        )
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await FolderPicker.openRepository(into: model) }
            } label: {
                Label("打开仓库", systemImage: "folder.badge.plus")
            }
            .help("打开一个 git 仓库（⌘O）")
        }

        ToolbarItemGroup {
            if let repository = model.selectedRepository {
                if !repository.hasRemote {
                    Button {
                        sheet = .createRemoteRepository(repository)
                    } label: {
                        Label("创建远程仓库", systemImage: "externaldrive.badge.plus")
                    }
                    .help("在 GitHub 或 GitLab 创建仓库，添加 origin 并首次推送")
                }

                Button {
                    sheet = .newWorktree(repository)
                } label: {
                    Label("新建工作树", systemImage: "plus.rectangle.on.rectangle")
                }
                .help("在这个仓库里新建一个工作树")

                Button {
                    Task { await repository.fetch() }
                } label: {
                    Label("抓取", systemImage: "arrow.down.circle")
                }
                .help("git fetch --all --prune（⇧⌘F）")
                .disabled(!repository.hasRemote)

                Button {
                    Task {
                        await repository.refresh()
                        await model.selectedWorktreeModel?.refresh()
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("重新读取仓库状态（⌘R）")

                if repository.isRefreshing || repository.activity != nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 错误横幅

    @ViewBuilder
    private var failureBanner: some View {
        if !model.failures.isEmpty {
            VStack(spacing: 8) {
                ForEach(model.failures) { failure in
                    FailureBanner(failure: failure) { model.dismiss(failure) }
                }
            }
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.snappy, value: model.failures.count)
        }
    }

    // MARK: - 选中项变化时刷新

    /// 选中项的稳定标识。`.task(id:)` 靠它判断要不要重跑。
    private var refreshTrigger: String {
        switch model.selection {
        case .worktree(_, let path): "wt:\(path.path)"
        case .pullRequests(let root): "pr:\(root.path)"
        case nil: "none"
        }
    }

    private func refreshSelection() async {
        switch model.selection {
        case .worktree:
            await model.selectedWorktreeModel?.refresh()
        case .pullRequests:
            await model.selectedRepository?.refreshPullRequests()
        case nil:
            break
        }
    }
}

// MARK: - Sheet 路由

private extension View {
    /// 把 `ActiveSheet` 映射到具体的 sheet 视图。集中在一处，
    /// 避免在 RootView 主体里堆四个 `.sheet` 修饰器。
    func sheet(item: Binding<RootView.ActiveSheet?>) -> some View {
        sheet(item: item) { active in
            switch active {
            case .newWorktree(let repository):
                NewWorktreeSheet(repository: repository)
            case .createRemoteRepository(let repository):
                CreateRemoteRepositorySheet(repository: repository)
            case .createPullRequest(let worktree):
                CreatePullRequestSheet(model: worktree)
            case .removeWorktree(let repository, let worktree):
                RemoveWorktreeSheet(repository: repository, worktree: worktree)
            case .cleanupBranches(let repository):
                CleanupBranchesSheet(repository: repository)
            case .rebase(let worktree):
                RebaseSheet(model: worktree)
            }
        }
    }
}

// MARK: - 空状态

struct EmptyRepositoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tree")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("Grove")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("用工作树并行开发，顺手处理 PR")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await FolderPicker.openRepository(into: model) }
            } label: {
                Label("打开仓库…", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            if let message = model.availability(of: .github).message {
                Label(message, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .frame(maxWidth: 380)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct FailureBanner: View {
    let failure: GroveFailure
    let dismiss: () -> Void
    @State private var showsTechnicalDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(failure.title)
                    .font(.callout.weight(.semibold))
                Text(failure.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let technicalDetail = failure.technicalDetail, !technicalDetail.isEmpty {
                    DisclosureGroup("技术详情", isExpanded: $showsTechnicalDetails) {
                        Text(technicalDetail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            // 原始 stderr 只在用户主动展开时出现，并限制高度避免挤掉界面。
                            .lineLimit(8)
                            .textSelection(.enabled)
                            .padding(.top, 3)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button {
                let technical = failure.technicalDetail.map { "\n\n技术详情：\n\($0)" } ?? ""
                SystemActions.copyToPasteboard("\(failure.title)\n\(failure.detail)\(technical)")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制错误信息")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}
