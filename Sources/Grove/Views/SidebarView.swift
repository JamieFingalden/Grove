import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: RootView.ActiveSheet?

    var body: some View {
        @Bindable var model = model

        List {
            // 以项目为单位：同一项目的本地副本和远程副本合并成一个条目，
            // 工作树行上用位置标记区分（本机 / 服务器名）。
            ForEach(model.projects) { project in
                ProjectSection(project: project, sheet: $sheet)
            }

            // 底部的服务器管理区：项目在上面按 origin 合并了，
            // 服务器的增删改和连接状态留在这里。
            if model.remoteServers.isEmpty {
                Button {
                    sheet = .addRemoteServer
                } label: {
                    Label("连接远程服务器…", systemImage: "server.rack")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 与工作树行同一缩进（18），不要自成一派。
                        .padding(.leading, 18)
                        .frame(minHeight: SidebarMetrics.rowHeight, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 侧栏 List 的行不套 listRowBackground 时，点按会闪系统默认的
                // 整行高亮 —— 这行不是可选中项，给个透明背景压掉。
                .listRowBackground(Color.clear)
            } else {
                ForEach(model.remoteServers) { server in
                    RemoteServerRow(server: server, sheet: $sheet)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.allRepositories.isEmpty && model.toolsReady {
                ContentUnavailableView {
                    Label("还没有仓库", systemImage: "folder")
                } description: {
                    Text("按 ⌘O 打开一个，或连接远程服务器。")
                }
            }
        }
    }

    /// Finder 侧栏式选中态：系统自适应的浅灰底，不用大块强调色淹没文字和角标。
    private func selectionBackground(_ isSelected: Bool) -> some View {
        sidebarSelectionBackground(isSelected)
    }
}

/// Finder 侧栏式选中态的通用实现（供仓库区块里的各行共用）。
func sidebarSelectionBackground(_ isSelected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(isSelected
              ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
              : .clear)
}

/// 侧边栏行的统一高度：仓库行、工作树行、折叠三角都用它，节奏才一致。
enum SidebarMetrics {
    static let rowHeight: CGFloat = 32
}

// MARK: - 项目区块

/// 侧边栏里一个项目的整块：主页入口置顶，本地和各服务器的**全部**工作树
/// 缩进在它下面、可收起展开 —— 同名分支靠位置标记区分在哪台机器上。
/// 层级语义：项目 → 项目主页（仓库级）→ 工作树（检出级）。
private struct ProjectSection: View {
    @Environment(AppModel.self) private var model
    let project: AppModel.ProjectGroup
    @Binding var sheet: RootView.ActiveSheet?

    @State private var worktreesExpanded = true

    // 不包 Section：侧边栏 List 底层是 NSOutlineView，Section 是它的父节点，
    // 动画移除子行时两者行数对不上会直接闪退（_validateParentRowEntry）。
    // 现在没有 Section 头了，拆平成纯行列表，从结构上消除这个父节点。
    @ViewBuilder
    var body: some View {
        @Bindable var model = model

        // homeRepository 按构造不可能为 nil（组里至少有一个仓库），防御一下。
        if let home = project.homeRepository {
            // 仓库行 = 主页入口 + 工作树的折叠开关（三角长在仓库行上，
            // Finder/Xcode 的形态）。主页入口指向本地副本（PR / CI 只在本地可用）。
            let homeSelection = AppModel.Selection.repositoryHome(repository: home.id)
            let homeIsSelected = model.selection == homeSelection
            let worktreeCount = project.mergedWorktrees.count

            HStack(spacing: 6) {
                Button {
                    // 动画安全的前提是拆平结构（无 Section 父节点）——已用无头脚本验证：
                    // 折叠/展开/快速连点都不再触发 NSOutlineView 断言。
                    withAnimation(.snappy(duration: 0.2)) {
                        worktreesExpanded.toggle()
                    }
                } label: {
                    Image(systemName: worktreesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(worktreesExpanded ? "收起工作树" : "展开工作树（\(worktreeCount) 个）")

                Button {
                    model.selection = homeSelection
                } label: {
                    RepositoryHomeRow(
                        repository: home,
                        isSelected: homeIsSelected,
                        sheet: $sheet
                    )
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(sidebarSelectionBackground(homeIsSelected))
            .contextMenu {
                newWorktreeMenu
                if let local = project.local {
                    Button("在 Finder 显示") { SystemActions.revealInFinder(local.root) }
                }
            }

            if worktreesExpanded {
                // 组内按路径去重后的工作树（同一仓库的多个打开条目只出一遍）；
                // 本地条目的在前 —— 本地是响应最快的主场。
                ForEach(project.mergedWorktrees, id: \.worktree.id) { entry in
                    let repository = entry.repository
                    let worktree = entry.worktree
                    let marker = locationMarker(for: repository)
                    let selection = AppModel.Selection.worktree(
                        repository: repository.id,
                        worktree: worktree.path
                    )
                    let isSelected = model.selection == selection

                    Button {
                        model.selection = selection
                    } label: {
                        WorktreeRow(
                            repository: repository,
                            worktree: worktree,
                            isSelected: isSelected,
                            marker: marker
                        )
                    }
                    .buttonStyle(.plain)
                    // 缩进到仓库行图标正下方：三角(12) + 间距(6)。
                    .padding(.leading, 18)
                    .listRowBackground(sidebarSelectionBackground(isSelected))
                    .contextMenu {
                        worktreeMenu(repository: repository, worktree: worktree)
                    }
                }
            }
        }
    }

    /// 位置标记：远程副本标服务器名；本地副本只在「混合项目」里标「本机」——
    /// 纯本地项目里那是默认态，标了反而吵。
    private func locationMarker(for repository: RepositoryModel) -> LocationMarker? {
        if repository.isRemote, let server = repository.server {
            return .server(server)
        }
        return project.isMixed ? .local : nil
    }

    /// 跨多台机器的项目，新建工作树要选在哪边建。
    @ViewBuilder
    private var newWorktreeMenu: some View {
        if project.repositories.count > 1 {
            Menu("新建工作树…") {
                ForEach(project.repositories) { repository in
                    Button(locationName(of: repository)) {
                        sheet = .newWorktree(repository)
                    }
                }
            }
        } else if let only = project.homeRepository {
            Button("新建工作树…") { sheet = .newWorktree(only) }
        }
    }

    private func locationName(of repository: RepositoryModel) -> String {
        repository.server?.displayName ?? "本机"
    }

    @ViewBuilder
    private func worktreeMenu(repository: RepositoryModel, worktree: Worktree) -> some View {
        // 远程服务器上的工作树没有本机动作可给（Finder / 终端 / 编辑器都打不开），
        // 复制路径给 `user@host:path` 形态，可以直接贴进 ssh scp 之类。
        if repository.isRemote, let server = repository.server {
            Button("复制远程路径") {
                SystemActions.copyToPasteboard("\(server.destination):\(worktree.path.path)")
            }
        } else {
            Button("在终端打开") { SystemActions.openInTerminal(worktree.path) }
            Button("在编辑器打开") { SystemActions.openInEditor(worktree.path) }
            Button("在 Finder 显示") { SystemActions.revealInFinder(worktree.path) }
            Button("复制路径") { SystemActions.copyToPasteboard(worktree.path.path) }
        }

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

// MARK: - 工作树行

private struct WorktreeRow: View {
    let repository: RepositoryModel
    let worktree: Worktree
    let isSelected: Bool
    /// 这个检出在哪台机器上。混合项目里本地行也标「本机」，远程行始终标服务器名。
    var marker: LocationMarker?

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
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 16)

            // 单行。显示分支名 —— 这是工作树的身份；目录名与完整路径进悬停提示。
            // 以前目录名+分支名两行叠着，目录名还常与分支名重复，行行都像双倍行距的墙。
            Text(displayLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)

            // 同名分支在哪台机器上，靠这个胶囊区分。
            if let marker {
                LocationBadge(marker: marker)
            }

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
            if worktree.isDetached, let head = worktree.head {
                // 游离 HEAD：名字旁边给个短 SHA，其它细节看悬停。
                Text(String(head.prefix(7)))
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 2)

            trailingBadges
        }
        .padding(.vertical, 2)
        .frame(minHeight: SidebarMetrics.rowHeight, alignment: .center)
        // plain Button 默认只命中文字和图标；撑满并声明命中形状，
        // 让整条侧栏行（包括中间空白）都能点击。
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(tooltip)
    }

    /// 行上显示的名字：分支优先（目录名常常就是分支名，两行叠着反而重复）。
    private var displayLabel: String {
        if let branch = worktree.branch, !branch.isEmpty { return branch }
        return worktree.name
    }

    /// 悬停提示把完整信息补齐：检出状态 + 目录名 + 完整路径。
    private var tooltip: String {
        var lines = ["检出：\(worktree.checkoutLabel)"]
        if worktree.name != displayLabel {
            lines.append("目录：\(worktree.name)")
        }
        lines.append(worktree.path.path)
        return lines.joined(separator: "\n")
    }

    private var icon: String {
        if worktree.isBare { return "archivebox" }
        // 主工作树不用 house：那是仓库行（主页）的图标，两栋房子换在一起
        // 分不清谁是入口谁是检出。主检出用硬盘，别的用叶子。
        if worktree.isPrimary { return "externaldrive" }
        return "leaf"
    }

    @ViewBuilder
    private var trailingBadges: some View {
        HStack(spacing: 4) {
            // 这个分支最新一条流水线的状态：推完不用打开 CI 页也知道绿了没。
            if let branch = worktree.branch,
               let ci = repository.pipelineStatusByRef[branch] {
                Image(systemName: ci.systemImage)
                    .font(.system(size: 9))
                    .foregroundStyle(ci.tint)
                    .help("CI：\(ci.label)（\(branch)）")
            }

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

/// 仓库行：项目名即主页入口。点进去是项目主页（PR、CI/CD 等分栏），
/// 菜单里放仓库级操作（原仓库标题行的功能全部搬过来了）。
private struct RepositoryHomeRow: View {
    @Environment(AppModel.self) private var model
    let repository: RepositoryModel
    let isSelected: Bool
    @Binding var sheet: RootView.ActiveSheet?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "house")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 16)

            Text(repository.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)

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

                if repository.isRemote, let server = repository.server {
                    Button("复制远程路径") {
                        SystemActions.copyToPasteboard("\(server.destination):\(repository.root.path)")
                    }
                } else {
                    Button("在 Finder 显示") { SystemActions.revealInFinder(repository.root) }
                    Button("复制路径") { SystemActions.copyToPasteboard(repository.root.path) }
                }

                Divider()

                Button("从 Grove 移除", role: .destructive) {
                    if repository.isRemote {
                        model.closeRemoteProject(repository)
                    } else {
                        model.closeRepository(repository)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 3)
        // 行高与工作树行统一（同一个常数），不然一行高一行矮很潦草。
        .frame(minHeight: SidebarMetrics.rowHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - 服务器管理行

/// 列表底部的服务器行：状态点 + 名字 + 菜单。项目在上面按 origin 合并了，
/// 这里只负责增删改；点这一行直接进入「添加项目」。
private struct RemoteServerRow: View {
    @Environment(AppModel.self) private var model
    let server: RemoteServer
    @Binding var sheet: RootView.ActiveSheet?

    enum ProbeState: Equatable {
        case unknown
        case checking
        case ready(String)
        case failed(String)
    }

    @State private var probe: ProbeState = .unknown

    var body: some View {
        HStack(spacing: 6) {
            Button {
                sheet = .addRemoteProject(server)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Text(server.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)

                    statusDot

                    Spacer(minLength: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在这台服务器上添加项目")

            Menu {
                Button("添加项目…") { sheet = .addRemoteProject(server) }
                Divider()
                Button("编辑服务器…") { sheet = .editRemoteServer(server) }
                Button(role: .destructive) {
                    model.removeRemoteServer(server)
                } label: {
                    Text("移除服务器")
                }
            } label: {
                // 不设 secondary：灰色在菜单按钮上像禁用态。
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 3)
        .frame(minHeight: SidebarMetrics.rowHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 配置变了（编辑过服务器）重新探一次；视图出现时探第一次。
        .task(id: server) { await runProbe() }
    }

    private var statusDot: some View {
        let summary = probeSummary
        return Circle()
            .fill(summary.color)
            .frame(width: 6, height: 6)
            .help(summary.text)
    }

    private var probeSummary: (text: String, color: Color) {
        switch probe {
        case .unknown: ("尚未检测连接", .gray.opacity(0.45))
        case .checking: ("正在检测连接…", .gray.opacity(0.45))
        case .ready(let version): (version, .green)
        case .failed(let reason): ("连接失败：\(reason)", .red)
        }
    }

    private func runProbe() async {
        probe = .checking
        guard let transport = model.remoteTransport(for: server) else {
            probe = .failed("找不到 ssh")
            return
        }
        do {
            probe = .ready(try await transport.probe())
        } catch {
            probe = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 小组件

/// 工作树行的位置标记：这个检出在哪台机器上。
struct LocationMarker: Equatable {
    var text: String
    var systemImage: String?

    /// 本机。只在「混合项目」里显示 —— 纯本地项目里那是默认态，标了反而吵。
    static let local = LocationMarker(text: "本机", systemImage: nil)

    static func server(_ server: RemoteServer) -> LocationMarker {
        LocationMarker(text: server.displayName, systemImage: "server.rack")
    }
}

/// 位置标记的胶囊形态：跟 Badge 一个家族，但更安静 ——
/// 它是身份信息（在哪台机器上），不是需要行动的告警。
struct LocationBadge: View {
    let marker: LocationMarker

    var body: some View {
        HStack(spacing: 2.5) {
            if let systemImage = marker.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 7.5, weight: .semibold))
            }
            Text(marker.text)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(.quaternary.opacity(0.7), in: Capsule())
        .fixedSize()
    }
}

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
