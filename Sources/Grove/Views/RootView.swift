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
        case newTag(WorktreeModel, CommitSummary)
        case addRemoteServer
        case editRemoteServer(RemoteServer)
        case addRemoteProject(RemoteServer)

        var id: String {
            switch self {
            case .newWorktree(let repository): "new-\(repository.id.identityKey)"
            case .createRemoteRepository(let repository): "remote-\(repository.id.identityKey)"
            case .createPullRequest(let worktree): "pr-\(worktree.identityKey)"
            case .removeWorktree(let repository, let worktree): "remove-\(RepoID(location: repository.location, root: worktree.path).identityKey)"
            case .cleanupBranches(let repository): "cleanup-\(repository.id.identityKey)"
            case .rebase(let worktree): "rebase-\(worktree.identityKey)"
            case .newTag(let worktree, let commit): "tag-\(worktree.identityKey)-\(commit.oid)"
            case .addRemoteServer: "add-remote-server"
            case .editRemoteServer(let server): "edit-remote-server-\(server.id)"
            case .addRemoteProject(let server): "add-remote-project-\(server.id)"
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
                        // 淡出中的旧视图不能再把自己唤回来，也不能挡住下面的文件列表。
                        .allowsHitTesting(showsHoverSidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))
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
                        if isHovering { presentHoverSidebar() }
                    }
                }
            }
        }
    }

    private func updateHoverSidebar(_ isHovering: Bool) {
        sidebarDismissTask?.cancel()
        guard showsHoverSidebar, !isHovering else { return }

        sidebarDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                showsHoverSidebar = false
            }
        }
    }

    private func presentHoverSidebar() {
        sidebarDismissTask?.cancel()
        guard !showsHoverSidebar else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            showsHoverSidebar = true
        }
    }

    private func dismissHoverSidebar() {
        sidebarDismissTask?.cancel()
        guard showsHoverSidebar else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            showsHoverSidebar = false
        }
    }

    // MARK: - 详情区

    @ViewBuilder
    private var detail: some View {
        if !model.toolsReady {
            ProgressView("正在准备…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.allRepositories.isEmpty {
            EmptyRepositoryView(connectServer: { sheet = .addRemoteServer })
        } else {
            switch model.selection {
            case .worktree:
                if let worktree = model.selectedWorktreeModel {
                    WorktreeDetailView(model: worktree, sheet: $sheet)
                        // 机器或路径变了就重建页面状态，避免同路径工作树串用滚动位置和编辑草稿。
                        .id(worktree.identityKey)
                } else {
                    placeholder
                }
            case .repositoryHome:
                if let repository = model.selectedRepository {
                    ProjectHomeView(repository: repository)
                        .id(repository.origin)
                        .id(repository.id)
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

        ToolbarItem(placement: .navigation) {
            Button {
                sheet = .addRemoteServer
            } label: {
                // 只留图标：中文长标签会把侧栏顶部的工具区挤得没有下脚处，
                // 用途写进悬停提示。符号用 externaldrive.badge.plus —— 与
                // 「打开仓库」的 folder.badge.plus 对仗，+ 号暗示「添加」。
                // 注意别用 server.rack.badge.plus：不存在这个符号，渲染成空白。
                Label("连接远程服务器", systemImage: "externaldrive.badge.plus")
                    .labelStyle(.iconOnly)
            }
            .help("通过 SSH 管理远程服务器上的项目（添加 / 编辑服务器）")
        }

        ToolbarItemGroup {
            if let repository = model.selectedRepository {
                if !repository.hasOrigin {
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
                    Label("Fetch", systemImage: "arrow.down.circle")
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
        case .worktree(let repository, let path): "wt:\(repository.identityKey):\(path.path)"
        case .repositoryHome(let repository): "home:\(repository.identityKey)"
        case nil: "none"
        }
    }

    private func refreshSelection() async {
        switch model.selection {
        case .worktree:
            await model.selectedWorktreeModel?.refresh()
        case .repositoryHome:
            // 主页里的分栏自己带加载和轮询（CI 每 10–30 秒自刷）；
            // 这里补拉一次 PR 列表，供概览卡片和拉取请求分栏用。
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
            case .newTag(let worktree, let commit):
                NewTagSheet(model: worktree, commit: commit)
            case .addRemoteServer:
                RemoteServerSheet()
            case .editRemoteServer(let server):
                RemoteServerSheet(server: server)
            case .addRemoteProject(let server):
                AddRemoteProjectSheet(server: server)
            }
        }
    }
}

// MARK: - 空状态

struct EmptyRepositoryView: View {
    @Environment(AppModel.self) private var model
    var connectServer: () -> Void = {}

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

            Button {
                connectServer()
            } label: {
                Label("连接远程服务器…", systemImage: "server.rack")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)

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
                if let context = failure.context {
                    Text(context)
                        .font(.caption.weight(.medium))
                        .textSelection(.enabled)
                }
                Text(failure.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let technicalDetail = failure.technicalDetail, !technicalDetail.isEmpty {
                    DisclosureGroup("技术详情", isExpanded: $showsTechnicalDetails) {
                        ScrollView {
                            Text(technicalDetail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollIndicators(.visible)
                        .frame(height: 160)
                        .padding(.top, 3)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button {
                let technical = failure.technicalDetail.map { "\n\n技术详情：\n\($0)" } ?? ""
                let context = failure.context.map { "\n\($0)" } ?? ""
                SystemActions.copyToPasteboard("\(failure.title)\(context)\n\(failure.detail)\(technical)")
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
