import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: ActiveSheet?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showsHoverSidebar = false
    @State private var sidebarDismissTask: Task<Void, Never>?
    @State private var dismissedFallbackID: UUID?

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
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(sheet: $sheet)
                .navigationSplitViewColumnWidth(min: 250, ideal: GroveStyle.sidebarWidth, max: 290)
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .overlay(alignment: .leading) { hoverSidebar }
        .overlay(alignment: .bottom) { notificationFallback }
        .sheet(item: $sheet)
        .sheet(item: $model.presentedFailure) { failure in
            ScrollView {
                FailureBanner(failure: failure) { model.presentedFailure = nil }
                    .padding(20)
            }
            .frame(width: 600)
            .frame(minHeight: 180, maxHeight: 500)
        }
        .task(id: refreshTrigger) { await refreshSelection() }
        .onChange(of: sidebarVisibility) { _, visibility in
            guard visibility != .detailOnly else { return }
            dismissHoverSidebar()
        }
    }

    // MARK: - 通知兜底

    /// 系统通知不可用时短暂提示；提示消失后仍可从工具栏查看完整错误。
    @ViewBuilder
    private var notificationFallback: some View {
        if let failure = model.notificationFallbackFailure, dismissedFallbackID != failure.id {
            HStack(spacing: 12) {
                Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                    .lineLimit(2)
                Button("查看详情") { model.presentedFailure = failure }
            }
            .font(.callout)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(16)
            .task(id: failure.id) {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                dismissedFallbackID = failure.id
            }
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
                        .frame(width: GroveStyle.sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: GroveStyle.largeRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: GroveStyle.largeRadius, style: .continuous)
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
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                showsHoverSidebar = false
            }
        }
    }

    private func presentHoverSidebar() {
        sidebarDismissTask?.cancel()
        guard !showsHoverSidebar else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            showsHoverSidebar = true
        }
    }

    private func dismissHoverSidebar() {
        sidebarDismissTask?.cancel()
        guard showsHoverSidebar else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            showsHoverSidebar = false
        }
    }

    // MARK: - 详情区

    @ViewBuilder
    private var detail: some View {
        if !model.toolsReady {
            ProgressView("正在准备…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                DailyView().retainedPage(model.navigation.page == .daily)
                WorkspaceView().retainedPage(model.navigation.page == .workspace)
                if model.allRepositories.isEmpty {
                    EmptyRepositoryView(connectServer: { sheet = .addRemoteServer })
                        .retainedPage(model.navigation.page == .repositories)
                }
                ForEach(model.navigation.visited, id: \.self) { selection in
                    let active = model.navigation.page == .repositories && model.selection == selection
                    Group {
                        switch selection {
                        case .worktree(let id, let path):
                            if let repository = model.repository(matching: id), let worktree = repository.worktreeModel(for: path) {
                                WorktreeDetailView(model: worktree, sheet: $sheet)
                            }
                        case .repositoryHome(let id):
                            if let repository = model.repository(matching: id) {
                                ProjectHomeView(repository: repository).id(repository.origin)
                            }
                        }
                    }
                    .environment(\.repositoryPageActive, active)
                    .retainedPage(active)
                }
                if model.selection == nil && !model.allRepositories.isEmpty {
                    placeholder.retainedPage(model.navigation.page == .repositories)
                }
            }
        }
    }

    private var placeholder: some View {
        GroveEmptyState(title: "选择一个工作树", systemImage: "tree",
                        description: "从左侧挑一个工作树查看它的改动和 PR。")
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            if let failure = model.notificationFallbackFailure {
                Button { model.presentedFailure = failure } label: {
                    Label("查看最近错误", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .labelStyle(.iconOnly)
                .help("查看最近错误：\(failure.title)")
            }
        }

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
                // 工具栏项统一「图标 + 文字」，不单独留裸图标。符号用
                // server.rack：与侧栏「远程环境」一致；externaldrive.badge.plus
                // 留给「创建远程仓库」，两个按钮不同图标。
                // 注意别用 server.rack.badge.plus：不存在这个符号，渲染成空白。
                Label("连接远程服务器", systemImage: "server.rack")
            }
            .help("通过 SSH 管理远程服务器上的项目（添加 / 编辑服务器）")
        }

        // .automatic 在 macOS 上会跟着导航项挤到左缘，右侧留一大片空白；
        // 显式用 .primaryAction 把操作按钮推到工具栏右端。
        ToolbarItemGroup(placement: .primaryAction) {
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

    // MARK: - 选中项变化时刷新

    /// 选中项的稳定标识。`.task(id:)` 靠它判断要不要重跑。
    private var refreshTrigger: String {
        guard model.navigation.page == .repositories else { return model.navigation.page.rawValue }
        return switch model.selection {
        case .worktree(let repository, let path): "wt:\(repository.identityKey):\(path.path)"
        case .repositoryHome(let repository): "home:\(repository.identityKey)"
        case nil: "none"
        }
    }

    private func refreshSelection() async {
        guard model.navigation.page == .repositories else { return }
        switch model.selection {
        case .worktree:
            await model.selectedWorktreeModel?.refresh()
        case .repositoryHome:
            // 主页里的分栏自己带加载和轮询（CI 每 10–30 秒自刷）；
            // 这里补拉一次 PR 列表，供概览卡片和拉取请求分栏用。
            await model.selectedRepository?.refreshPullRequests(ifNeeded: true)
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
        GroveEmptyState(title: "Grove", systemImage: "tree",
                        description: "用工作树并行开发，顺手处理 PR") {
            VStack(spacing: GroveStyle.Space.md) {
                HStack(spacing: GroveStyle.Space.sm) {
                    Button {
                        Task { await FolderPicker.openRepository(into: model) }
                    } label: {
                        Label("打开仓库…", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { connectServer() } label: {
                        Label("连接远程服务器…", systemImage: "server.rack")
                    }
                }
                if let message = model.availability(of: .github).message {
                    Label(message, systemImage: "info.circle")
                        .font(GroveStyle.metadata)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 380)
                }
            }
        }
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

/// 保持视图身份与布局，切页时保留局部状态和滚动位置。
extension View {
    func retainedPage(_ active: Bool) -> some View {
        modifier(RetainedPageModifier(active: active))
    }
}

private struct RetainedPageModifier: ViewModifier {
    let active: Bool
    @Namespace private var focusScope
    @Environment(\.resetFocus) private var resetFocus
    @Environment(\.isEnabled) private var parentEnabled

    func body(content: Content) -> some View {
        // 隐藏页面仍会注册快捷键；必须禁用操作，并仅释放本页的输入焦点。
        content
            .focusScope(focusScope)
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .disabled(!active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
            .onChange(of: active) { _, active in
                if !active && parentEnabled { resetFocus(in: focusScope) }
            }
    }
}
