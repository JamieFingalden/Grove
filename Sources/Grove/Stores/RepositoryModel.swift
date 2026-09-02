import Foundation
import Observation

/// 一个仓库：它的所有工作树、分支，以及（如果是 GitHub 仓库）PR 列表。
@MainActor
@Observable
final class RepositoryModel: Identifiable {
    /// 标记成 `nonisolated` 是为了让 `Identifiable` 的 `id` 能在主 actor 之外访问 ——
    /// SwiftUI 的 sheet 路由、`ForEach` 的去重都会从非隔离上下文读它。
    /// 这是安全的：它是 `let`，而 `URL` 是 `Sendable`。
    nonisolated let root: URL
    private let git: GitClient
    private weak var app: AppModel?

    /// 这个仓库对应的托管商客户端，按 `origin` 的主机在刷新时决定。
    /// nil 表示 Grove 认不出这个远端属于哪个平台 —— 评审功能整块关闭。
    private(set) var forge: (any ForgeClient)?

    var worktrees: [Worktree] = []
    var branches: [Branch] = []
    var remoteBranches: [RemoteBranch] = []
    var pullRequests: [PullRequest] = []
    /// `owner/repo`。nil 表示不是 GitHub 仓库（或者 `gh` 不可用）。
    var slug: String?
    /// 解析过的 `origin` 地址。判断托管商只看它，不看别的 remote。
    var origin: GitRemote?
    /// 仓库配置的所有远端。多于一个时，推送要让用户选推到哪。
    var remotes: [NamedRemote] = []
    var defaultBranch: String?
    var hasOrigin = false
    var hasRemote = false

    var isRefreshing = false
    var isRefreshingPullRequests = false
    /// 正在进行的长操作描述（"正在拉取…"）。nil 表示空闲。
    var activity: String?
    var aiCommitEnabled: Bool { app?.isAIGenerationEnabled == true }

    struct InitialPushTarget {
        var directory: URL
        var branch: String
    }

    nonisolated var id: URL { root }
    nonisolated var name: String { root.lastPathComponent }

    /// 每个工作树的详情模型，按路径缓存。切回来的时候不用重新加载，
    /// 之前看到哪个文件、写了一半的提交信息都还在。
    ///
    /// 标 `@ObservationIgnored`：这是缓存，不是界面状态。不标的话，
    /// 视图在 body 里查一次就会触发一次「观察到的属性被修改」，
    /// SwiftUI 会认为需要重绘，然后再查一次 —— 死循环。
    @ObservationIgnored private var worktreeModels: [URL: WorktreeModel] = [:]

    init(
        root: URL,
        git: GitClient,
        app: AppModel?
    ) {
        self.root = root
        self.git = git
        self.app = app
    }

    /// 只读查找，不会创建也不会修改任何东西。**视图里只能用这个** ——
    /// 在 body 里创建或修改模型属于「在 SwiftUI 更新过程中改状态」，
    /// 轻则控制台刷告警，重则无限重绘。
    ///
    /// 能这么用是因为 `refresh()` 已经把所有工作树的模型都建好了。
    func worktreeModel(for path: URL) -> WorktreeModel? {
        worktreeModels[path]
    }

    // MARK: - 刷新

    func refresh(loadForgeMetadata: Bool = true) async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            async let loadedWorktrees = git.worktrees(in: root)
            async let loadedBranches = git.branches(in: root)
            async let loadedRemoteBranches = git.remoteBranches(in: root)
            let loaded = try await (loadedWorktrees, loadedBranches, loadedRemoteBranches)
            worktrees = loaded.0
            branches = loaded.1
            remoteBranches = loaded.2
        } catch {
            app?.report(title: "读取 \(name) 失败", error: error)
            return
        }

        async let loadedRemotes = try? git.remotes(in: root)
        async let loadedOriginURL = git.remoteURL(in: root)
        async let loadedDefaultBranch = git.defaultBranch(in: root)
        let (resolvedRemotes, originURL, resolvedDefaultBranch) = await (
            loadedRemotes, loadedOriginURL, loadedDefaultBranch
        )
        remotes = resolvedRemotes ?? []
        hasOrigin = originURL != nil
        hasRemote = !remotes.isEmpty
        origin = originURL.flatMap(GitRemote.parse)
        // 托管商只按 origin 认。一个仓库可能同时挂着内网 GitLab 的 origin 和
        // GitHub 备份 remote，让 CLI 自己去猜会认错到另一个仓库上。
        forge = app?.forge(for: origin)
        defaultBranch = resolvedDefaultBranch

        // 已经不存在的工作树，把缓存的详情模型也清掉，免得内存里挂着一堆死对象。
        let livePaths = Set(worktrees.map(\.path))
        worktreeModels = worktreeModels.filter { livePaths.contains($0.key) }

        // 给每个工作树都备好模型。全部在这里建，视图里才能用纯只读的查找 ——
        // 在 body 里现建会在 SwiftUI 更新过程中改状态。
        for worktree in worktrees {
            if let existing = worktreeModels[worktree.path] {
                existing.worktree = worktree
            } else {
                worktreeModels[worktree.path] = WorktreeModel(
                    worktree: worktree, repository: self, git: git, app: app
                )
            }
        }

        // 只有 origin 确实指向 GitHub 才去问 gh 要仓库名。
        //
        // 不能直接信 `gh repo view`：它会扫一遍所有 remote 挑任意一个 GitHub 的用。
        // 一个 origin 在内网 GitLab、另外挂了个 GitHub remote 做备份的仓库，
        // 会被它认成那个备份仓库，于是界面上显示的是**另一个仓库**的 PR ——
        // 而且「检出 PR」会拿着 GitHub 的分支名去 GitLab 上 fetch。
        if loadForgeMetadata { await refreshForgeMetadata() }

        // 并发刷新所有工作树的状态。侧边栏上「哪个工作树有未提交的改动、
        // 领先/落后远端多少」是挑工作树时最主要的依据，不能等点进去才显示。
        // 只刷状态，不刷历史和 PR —— 那两样只有当前正在看的那个才需要。
        await withTaskGroup(of: Void.self) { group in
            for model in worktreeModels.values {
                group.addTask { await model.refreshStatus() }
            }
        }

        // 当前正在看的那个再做一次完整刷新（历史 + 关联的 PR）。
        if let selected = app?.selectedWorktreeModel, selected.repositoryRoot == root {
            await selected.refresh()
        }
    }

    /// 只补托管商归属和仓库标识，不重复扫描工作树、分支和未提交文件。
    /// 启动和「重新检测」都走这里，网络慢时不会连本地 Git 一起重跑。
    func refreshForgeMetadata() async {
        let previousKind = forge?.kind
        forge = app?.forge(for: origin)
        if previousKind != forge?.kind {
            slug = nil
            pullRequests = []
        }
        guard slug == nil, let forge else { return }
        slug = await forge.repositorySlug(in: root)
    }

    func refreshPullRequests() async {
        guard let forge, slug != nil else { return }
        isRefreshingPullRequests = true
        defer { isRefreshingPullRequests = false }
        do {
            pullRequests = try await forge.pullRequests(in: root, limit: 50, includeClosed: false)
        } catch {
            app?.report(title: "读取 PR 列表失败", error: error)
        }
    }

    /// 某个分支对应的 PR。工作树列表和详情头部靠它显示 PR 角标。
    func pullRequest(forBranch branch: String?) -> PullRequest? {
        guard let branch else { return nil }
        return pullRequests.first { $0.headRefName == branch }
    }

    /// 托管平台确认合并成功后先更新本地列表，避免等待后续网络刷新时仍显示已合并的请求。
    func removeMergedPullRequest(number: Int) {
        pullRequests.removeAll { $0.number == number }
    }

    // MARK: - 同步操作

    func fetch() async {
        await perform("正在抓取远端…") {
            try await self.git.fetch(in: self.root)
        }
        await refresh()
        await refreshPullRequests()
    }

    func initialPushTarget() -> InitialPushTarget? {
        if let selected = app?.selectedWorktreeModel,
           selected.repositoryRoot == root,
           let branch = selected.worktree.branch,
           selected.worktree.head != nil {
            return InitialPushTarget(directory: selected.path, branch: branch)
        }
        guard let primary = worktrees.first(where: \.isPrimary),
              let branch = primary.branch,
              primary.head != nil else { return nil }
        return InitialPushTarget(directory: primary.path, branch: branch)
    }

    func createRemoteRepository(
        _ request: NewRemoteRepository,
        push target: InitialPushTarget?
    ) async throws {
        guard !hasOrigin else { throw RemoteRepositoryCreationError.originAlreadyExists }
        guard let forge = app?.forge(of: request.kind) else {
            throw RemoteRepositoryCreationError.forgeUnavailable(request.kind)
        }

        activity = "正在创建远程仓库…"
        defer { activity = nil }

        do {
            try await forge.createRepository(request, in: root)
            if let target {
                try await git.push(
                    in: target.directory,
                    remote: "origin",
                    branch: target.branch,
                    setUpstream: true
                )
            }
        } catch {
            // 平台创建成功但首次推送失败时，也要立刻识别刚添加的 origin。
            await refresh()
            throw error
        }
        await refresh()
    }

    private func perform(_ label: String, _ work: @escaping () async throws -> Void) async {
        activity = label
        defer { activity = nil }
        do {
            try await work()
        } catch {
            app?.report(title: label.replacingOccurrences(of: "正在", with: "").replacingOccurrences(of: "…", with: "") + "失败", error: error)
        }
    }

    // MARK: - 工作树管理

    /// 新建工作树的默认放置位置。
    ///
    /// 放在仓库的**兄弟目录** `<repo>-worktrees/<分支名>` 而不是仓库内部的子目录：
    /// 放里面的话每个工作树都会出现在其他工作树的 `git status` 里（需要额外
    /// gitignore），而且 `rm -rf` 仓库时会连带删掉别的工作树。放外面干净得多。
    func suggestedWorktreePath(for branchName: String) -> URL {
        let container = root.deletingLastPathComponent()
            .appendingPathComponent("\(name)-worktrees")
        return container.appendingPathComponent(Self.sanitize(branchName))
    }

    /// 分支名可以带斜杠（`feature/login`），直接当目录名会多建一层目录。
    /// 换成连字符，保持工作树目录是平的。
    static func sanitize(_ branchName: String) -> String {
        branchName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 检查分支是否已被其他工作树占用。git 不允许同一分支同时检出到两处，
    /// 提前拦下来能给出比 git 原始报错清楚得多的解释。
    func worktreeHoldingBranch(_ branchName: String) -> Worktree? {
        worktrees.first { $0.branch == branchName }
    }

    func createWorktree(at path: URL, source: GitClient.WorktreeSource) async -> Worktree? {
        if FileManager.default.fileExists(atPath: path.path) {
            app?.report(title: "新建工作树失败", error: GroveError.worktreePathExists(path))
            return nil
        }
        if case .existingBranch(let branch) = source, let holder = worktreeHoldingBranch(branch) {
            app?.report(
                title: "新建工作树失败",
                error: GroveError.branchAlreadyCheckedOut(branch: branch, worktree: holder.path)
            )
            return nil
        }

        // 父目录不存在时 git worktree add 会直接失败，先建好。
        let parent = path.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                app?.report(title: "无法创建目录 \(parent.lastPathComponent)", error: error)
                return nil
            }
        }

        activity = "正在创建工作树…"
        defer { activity = nil }
        do {
            try await git.addWorktree(at: path, source: source, in: root)
        } catch {
            app?.report(title: "新建工作树失败", error: error)
            return nil
        }

        await refresh()
        return worktrees.first { $0.path.isSameLocation(as: path) }
    }

    /// 把某个 PR 检出成一个新工作树 —— Grove 的招牌操作。
    ///
    /// 同仓库 PR 和 fork PR 的处理不一样：
    /// - 同仓库：建立跟 `origin/<分支>` 的跟踪关系，之后能直接 push 回去改。
    /// - fork 来的：本地分支叫 `pr-<编号>`，并且**不设**上游 —— 我们没有对方
    ///   fork 的写权限，设了上游只会让 push 在几秒后失败得莫名其妙。
    ///   走 `pull/<编号>/head` 这个 GitHub 恒定提供的 ref 来抓取。
    func createWorktree(forPullRequest pullRequest: PullRequest) async -> Worktree? {
        let isFork = pullRequest.isCrossRepository
        let branchName = PullRequestNaming.branchName(for: pullRequest)
        let path = suggestedWorktreePath(for: branchName)

        if let holder = worktreeHoldingBranch(branchName) {
            app?.report(
                title: "检出 PR #\(pullRequest.number) 失败",
                error: GroveError.branchAlreadyCheckedOut(branch: branchName, worktree: holder.path)
            )
            return nil
        }

        activity = "正在检出 PR #\(pullRequest.number)…"
        defer { activity = nil }

        do {
            let alreadyLocal = await git.localBranchExists(branchName, in: root)

            if isFork {
                // `+` 前缀允许非 fast-forward 更新：PR 作者 force-push 之后
                // 不加这个会抓取失败，而 force-push 在 PR 里太常见了。
                try await git.fetchRefspec(
                    pullRequest.forge.headRefspec(number: pullRequest.number, localBranch: branchName),
                    in: root
                )
                try await git.addWorktree(at: path, source: .existingBranch(branchName), in: root)
            } else {
                // 必须写完整的 refspec，不能只写分支名。
                //
                // `git fetch origin <分支>` 只保证更新 FETCH_HEAD；要不要顺带更新
                // `refs/remotes/origin/<分支>`，取决于该仓库配置的 fetch refspec。
                // 单分支克隆（`clone --single-branch`、`--depth=1`）的 refspec 只覆盖
                // 一个分支，于是 `origin/<分支>` 根本不会被创建，下一步 worktree add
                // 直接报 "invalid reference"。写死 refspec 就跟仓库配置无关了。
                let ref = pullRequest.headRefName
                try await git.fetchRefspec("+refs/heads/\(ref):refs/remotes/origin/\(ref)", in: root)

                if alreadyLocal {
                    try await git.addWorktree(at: path, source: .existingBranch(branchName), in: root)
                } else {
                    // 刻意不传 `--track`。git 默认就会在起点是远端跟踪分支时建立跟踪关系；
                    // 而单分支克隆里它建不了，这时显式 `--track` 会**直接失败**、
                    // 连工作树都建不出来。把工作树建出来是主要目的，跟踪关系是附赠 ——
                    // 真没建上，之后首次推送会自动带 `--set-upstream` 补齐。
                    try await git.addWorktree(
                        at: path,
                        source: .newBranch(name: branchName, startPoint: "origin/\(ref)"),
                        in: root
                    )
                }
            }
        } catch {
            app?.report(title: "检出 PR #\(pullRequest.number) 失败", error: error)
            return nil
        }

        await refresh()
        return worktrees.first { $0.path.isSameLocation(as: path) }
    }

    /// 删除工作树。`deleteBranch` 为真时连分支一起删（PR 合并后的常规清理）。
    func removeWorktree(_ worktree: Worktree, force: Bool, deleteBranch: Bool) async {
        guard !worktree.isPrimary else { return }
        let branch = worktree.branch

        activity = "正在删除工作树…"
        defer { activity = nil }
        do {
            try await git.removeWorktree(at: worktree.path, force: force, in: root)
            if deleteBranch, let branch {
                // 分支删除用 `-D`（强制）：走到这一步用户已经在确认框里明确勾了
                // 「同时删除分支」，再因为「分支未合并」被 git 拦一次没有意义。
                try await git.deleteBranch(branch, force: true, in: root)
            }
        } catch {
            app?.report(title: "删除工作树失败", error: error)
        }

        worktreeModels[worktree.path] = nil
        await refresh()
    }

    func pruneWorktrees() async {
        await perform("正在清理失效工作树…") {
            try await self.git.pruneWorktrees(in: self.root)
        }
        await refresh()
    }

    func setLock(_ locked: Bool, on worktree: Worktree, reason: String? = nil) async {
        await perform(locked ? "正在锁定…" : "正在解锁…") {
            if locked {
                try await self.git.lockWorktree(at: worktree.path, reason: reason, in: self.root)
            } else {
                try await self.git.unlockWorktree(at: worktree.path, in: self.root)
            }
        }
        await refresh()
    }

    // MARK: - 分支

    func deleteBranch(_ branch: Branch, force: Bool) async {
        await perform("正在删除分支 \(branch.name)…") {
            try await self.git.deleteBranch(branch.name, force: force, in: self.root)
        }
        await refresh()
    }

    /// 需要让用户选推送目标吗。只有一个远端时多问一步纯属添乱。
    var hasMultipleRemotes: Bool { remotes.count > 1 }

    /// 上游已经在远端消失的分支 —— 通常是 PR 合并后残留的。批量清理入口。
    var staleBranches: [Branch] {
        branches.filter { $0.upstreamIsGone && !$0.isCheckedOut }
    }

    // MARK: - 托管商

    /// 这个仓库的评审功能由哪个平台提供。
    var forgeKind: ForgeKind? { forge?.kind }

    /// 界面上该用「Pull Request」还是「合并请求」。认不出平台时用中性说法。
    var reviewTerm: String { forgeKind?.termLong ?? "评审请求" }

    /// 认不出托管商时，接入这台实例要做的事。
    var forgeSetup: AppModel.ForgeSetup? {
        guard forge == nil else { return nil }
        return app?.forgeSetup(for: origin)
    }

    /// 评审功能对这个仓库不可用的原因。nil 表示可用。
    /// 「没远端」「平台认不出来」「CLI 没装/没登录」三种情况用户要做的事完全不同，
    /// 笼统说一句「不可用」等于没说。
    var pullRequestUnavailableReason: String? {
        guard hasRemote else { return "这个仓库没有配置远端。" }
        guard origin != nil else { return "无法识别 origin 的地址。" }
        guard forge != nil else { return app?.forgeSetup(for: origin)?.summary }
        if let forge, let message = app?.availability(of: forge.kind).message { return message }
        if slug == nil, let forge { return "\(forge.kind.termLong)：无法识别这个仓库。" }
        return nil
    }
}
