import Foundation
import Observation

/// 一个工作树的详细状态：变更、历史、diff，以及关联的 PR。
@MainActor
@Observable
final class WorktreeModel: Identifiable {
    /// 工作树的路径。`worktree` 本身是可变的（刷新时会替换），所以身份标识
    /// 另存一份不可变的 —— `Identifiable` 的 `id` 要能从非隔离上下文读，
    /// 而且一个模型对象的身份本来就不该在生命周期内变化。
    nonisolated let identity: URL
    var worktree: Worktree
    private(set) weak var repository: RepositoryModel?
    private let git: GitClient
    private weak var app: AppModel?

    var status = WorktreeStatus.empty
    var commits: [CommitSummary] = []
    /// 历史筛选条件。改动后由视图调 `reloadHistory()`。
    var logQuery = LogQuery()
    /// 提交图的布局。跟 `commits` 一起算好，视图直接取用。
    private(set) var graph = CommitGraphLayout.Graph.empty

    /// 筛选后的提交不是完整 DAG，相邻行可能没有真实父子关系，不能连图。
    var showsGraph: Bool { !logQuery.isActive && !graph.rows.isEmpty }
    /// 图的选中路径和右侧 diff 选中提交相互独立，清除聚焦不会关闭正在看的 diff。
    var graphFocus: String?
    /// nil 表示当前工作树；非 nil 时历史列表只读取这个分支的真实提交范围。
    var historyBranch: String?
    var displayGraph: CommitGraphLayout.Graph {
        graph.projected(maxDynamicLanes: 4, focusOID: graphFocus)
    }
    var historyBranches: [Branch] { repository?.branches ?? [] }
    var historyRemoteBranches: [RemoteBranch] { repository?.remoteBranches ?? [] }
    var historyBranchLabel: String { historyBranch ?? worktree.branch ?? "当前工作树" }
    /// 这个仓库出现过的提交身份，填筛选下拉框用。
    var knownAuthors: [CommitAuthor] = []
    var isLoadingHistory = false
    var linkedPullRequest: PullRequest?

    var isLoading = false
    var activity: String?

    /// 拉取 / 推送按钮自己的短暂反馈。`activity` 只表示「还在执行」，操作结束后
    /// 立刻消失，用户无法区分成功和卡住；这里把结果再保留一小会儿给按钮展示。
    struct SyncFeedback: Equatable {
        enum Action: Equatable { case pull, push }
        enum Phase: Equatable { case running, succeeded, failed }

        var action: Action
        var phase: Phase
    }

    private(set) var syncFeedback: SyncFeedback?
    @ObservationIgnored private var syncFeedbackResetTask: Task<Void, Never>?

    struct SafeForcePushProposal {
        var remote: NamedRemote?
        var branch: String?
    }

    private(set) var safeForcePushProposal: SafeForcePushProposal?

    /// 当前选中的文件。切换时会去取它的 diff。
    var selectedPath: String? {
        didSet {
            guard selectedPath != oldValue else { return }
            diff = nil
            diffTask?.cancel()
            diffTask = Task { await loadDiff() }
        }
    }

    /// 看的是工作区改动还是暂存区改动。
    var diffSide: DiffSide = .worktree {
        didSet {
            guard diffSide != oldValue else { return }
            diffTask?.cancel()
            diffTask = Task { await loadDiff() }
        }
    }

    enum DiffSide: String, CaseIterable, Identifiable, Sendable {
        case worktree, staged

        var id: String { rawValue }
        var label: String {
            switch self {
            case .worktree: "工作区"
            case .staged: "暂存区"
            }
        }
    }

    private(set) var diff: [FileDiff]?
    private var diffTask: Task<Void, Never>?

    /// 用户在 diff 里勾中的行（按 `DiffLine.id`）。用于「只提交其中一行」。
    ///
    /// 行 id 是每次解析 diff 时重新编号的，所以 diff 一重载就必须清空 ——
    /// 留着旧 id 会让勾选落到完全不相干的行上，那是会丢代码的。
    var selectedLines: Set<Int> = []

    /// 提交信息输入框的内容。存在模型里而不是视图里，这样切走再切回来草稿不丢 ——
    /// 写了半屏的提交信息因为点了下别的工作树就没了，是最让人火大的那种 bug。
    var commitMessage = ""
    var amendLastCommit = false
    private(set) var isGeneratingCommitMessage = false
    private(set) var hasGeneratedCommitMessage = false
    private(set) var generatedFromTruncatedDiff = false
    private(set) var canRetryCommitMessageGeneration = false
    @ObservationIgnored private var commitMessageTask: Task<Void, Never>?

    /// 选中的提交（历史 tab 里点开看 diff 用）。
    var selectedCommit: String? {
        didSet {
            guard selectedCommit != oldValue else { return }
            commitDiff = nil
            guard let selectedCommit else { return }
            Task { await loadCommitDiff(selectedCommit) }
        }
    }
    private(set) var commitDiff: [FileDiff]?

    // MARK: 冲突状态

    /// 选中的冲突文件在工作区里是什么样。
    enum ConflictContent {
        /// 文本文件，标记已解析出来，可以逐块选。
        case editor(ConflictEditor)
        /// 二进制，没有「块」可言，只能整个文件选一边。
        case binary
        /// 不是合法 UTF-8。改写会把内容写坏，所以只允许整文件选边或去外部编辑器。
        case undecodable
        /// 工作区里没有这个文件（一侧删除的形态）。
        case missing
    }

    /// 一个冲突文件的逐块解决进度。
    struct ConflictEditor {
        var change: FileChange
        var document: ConflictDocument
        var resolutions: [Int: ConflictResolution] = [:]
        /// 上次读盘或写盘时的全文。写盘前先跟磁盘比对：不一样说明用户在外部编辑器里
        /// 改过，这时候按我们手里的版本覆盖回去会把那些改动吃掉。
        var lastKnownText: String

        var unresolvedBlocks: [ConflictBlock] {
            document.blocks.filter { resolutions[$0.id] == nil }
        }
        var remainingCount: Int { unresolvedBlocks.count }
        var isFullyResolved: Bool { remainingCount == 0 }
    }

    private(set) var conflictContent: ConflictContent?
    /// 冲突两侧各是谁。有冲突或有进行中的操作时才去查。
    private(set) var conflictContext: ConflictContext?

    enum ConflictViewMode: String, CaseIterable, Identifiable {
        case resolve = "解决冲突"
        case diff = "合并 diff"
        var id: String { rawValue }
    }

    /// 冲突文件的右侧面板看哪个：逐块解决，还是 git 的 combined diff。
    var conflictViewMode: ConflictViewMode = .resolve

    nonisolated var id: URL { identity }
    var path: URL { worktree.path }
    var repositoryRoot: URL { repository?.root ?? worktree.path }
    var isAICommitEnabled: Bool { app?.canUseAIGeneration == true }

    init(worktree: Worktree, repository: RepositoryModel?, git: GitClient, app: AppModel?) {
        self.identity = worktree.path
        self.worktree = worktree
        self.repository = repository
        self.git = git
        self.app = app
    }

    // MARK: - 刷新

    /// 只刷状态。侧边栏要给**每个**工作树显示改动数和领先/落后角标，
    /// 而完整的 `refresh()` 还要拉历史、查 PR —— 一个仓库挂十几个工作树的话
    /// 那就是几十次 git 调用外加十几次网络请求。
    func refreshStatus() async {
        do {
            status = try await git.status(in: path)
        } catch is CancellationError {
            // 刷新任务被取消（比如用户切走了）：留着上一次的状态，
            // 不能把一份好好的状态清成「干净」。
            return
        } catch {
            // 侧边栏的角标读不出来不值得打断用户 —— 大概率是这个工作树的目录
            // 被手工删了，它本来就会被标成「可清理」。
            status = .empty
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        await refreshStatus()
        await refreshConflictContext()

        await reloadHistory()

        if knownAuthors.isEmpty {
            knownAuthors = await git.authors(in: path)
        }

        // 选中的文件可能已经不在变更列表里了（被暂存/丢弃/提交掉）。
        // 不清掉的话 diff 面板会一直显示一份过时内容。
        if let selectedPath,
           let change = status.changes.first(where: { $0.path == selectedPath }) {
            let validSide = Self.validDiffSide(for: change, preferred: diffSide)
            if validSide != diffSide {
                // 暂存/取消暂存后，当前文件可能从一侧完整移动到另一侧。
                // 自动跟过去，不能把用户留在已经没有内容的空面板。
                diffSide = validSide
            } else {
                // 文件还在，但内容可能变了，重新取一次 diff。
                diffTask?.cancel()
                diffTask = Task { await loadDiff() }
            }
        } else if let first = status.conflictedChanges.first ?? status.changes.first {
            // 有冲突时先落到第一个冲突文件上：它是此刻唯一要处理的东西。
            diffSide = Self.validDiffSide(for: first, preferred: .worktree)
            self.selectedPath = first.path
        } else {
            self.selectedPath = nil
        }

        await refreshLinkedPullRequest()
    }

    /// 按当前筛选条件重新拉历史。
    func reloadHistory() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            commits = try await git.log(
                in: path,
                revision: historyBranch,
                query: logQuery,
                remotes: repository?.remotes.map(\.name) ?? []
            )
            graph = CommitGraphLayout.build(
                commits,
                context: .init(
                    defaultBranch: repository?.defaultBranch,
                    currentBranch: historyBranch ?? worktree.branch
                )
            )
        } catch {
            graph = .empty
            // 筛选条件本身不会让 git 报错（空结果就是空结果），
            // 走到这儿基本是仓库还没有任何提交。
            commits = []
        }
        // 筛完之后原来选中的提交可能已经不在列表里了。
        if let selectedCommit, !commits.contains(where: { $0.oid == selectedCommit }) {
            self.selectedCommit = nil
        }
        if let graphFocus, !commits.contains(where: { $0.oid == graphFocus }) {
            self.graphFocus = nil
        }
    }

    func focusGraph(on oid: String) {
        guard commits.contains(where: { $0.oid == oid }) else { return }
        graphFocus = oid
    }

    func clearGraphFocus() {
        graphFocus = nil
    }

    func selectHistoryBranch(_ branch: String?) async {
        guard historyBranch != branch else { return }
        historyBranch = branch
        // `--all` 与指定 revision 同时使用会把筛选退化回全仓库历史。
        logQuery.allBranches = false
        graphFocus = nil
        await reloadHistory()
    }

    /// 勾选 / 取消勾选一个提交人。
    func toggleAuthor(_ author: CommitAuthor) async {
        let token = author.filterToken
        if let index = logQuery.authors.firstIndex(of: token) {
            logQuery.authors.remove(at: index)
        } else {
            logQuery.authors.append(token)
        }
        await reloadHistory()
    }

    func isAuthorSelected(_ author: CommitAuthor) -> Bool {
        logQuery.authors.contains(author.filterToken)
    }

    func clearAuthors() async {
        logQuery.authors.removeAll()
        await reloadHistory()
    }

    /// 筛选栏上「提交人」按钮的文字。
    var authorFilterLabel: String {
        switch logQuery.authors.count {
        case 0: "提交人"
        case 1:
            // 显示姓名而不是存进去的邮箱 —— 邮箱又长又不好认。
            knownAuthors.first { $0.filterToken == logQuery.authors[0] }?.name
                ?? logQuery.authors[0]
        default: "提交人（\(logQuery.authors.count)）"
        }
    }

    func clearLogQuery() async {
        logQuery = LogQuery()
        await reloadHistory()
    }

    func refreshLinkedPullRequest() async {
        guard let forge = repository?.forge, let branch = worktree.branch, repository?.slug != nil else {
            linkedPullRequest = nil
            return
        }

        // 先用仓库已经拉到的列表填上（瞬时、无网络），界面不会先空一下再跳出来。
        // 那份列表只有开放的 PR，所以紧接着再按完整规则查一次确认。
        linkedPullRequest = repository?.pullRequest(forBranch: branch)

        linkedPullRequest = await forge.linkedPullRequest(
            branch: branch,
            defaultBranch: repository?.defaultBranch,
            in: path
        )
    }

    private func loadDiff() async {
        selectedLines.removeAll()
        guard let selectedPath else {
            diff = nil
            conflictContent = nil
            return
        }
        guard let change = status.changes.first(where: { $0.path == selectedPath }) else {
            diff = nil
            conflictContent = nil
            return
        }

        if change.isConflicted {
            await loadConflictContent(for: change)
            guard !Task.isCancelled else { return }
        } else {
            conflictContent = nil
        }

        // 未跟踪文件 git 不认，得自己造 diff。
        if change.unstaged == .untracked {
            let synthetic = await git.untrackedFileDiff(in: path, path: selectedPath)
            guard !Task.isCancelled else { return }
            diff = synthetic.map { [$0] } ?? []
            return
        }

        do {
            // 重命名要把来源路径也传给 git，否则 `git diff -- <新路径>` 拿不到内容。
            var paths = [selectedPath]
            if let originalPath = change.originalPath { paths.append(originalPath) }
            let result = try await git.diff(in: path, paths: paths, staged: diffSide == .staged)
            guard !Task.isCancelled else { return }
            diff = result
        } catch {
            guard !Task.isCancelled else { return }
            diff = []
            app?.report(title: "读取 diff 失败", error: error)
        }
    }

    private func loadCommitDiff(_ oid: String) async {
        do {
            let result = try await git.commitDiff(in: path, oid: oid)
            guard !Task.isCancelled else { return }
            commitDiff = result
        } catch {
            commitDiff = []
        }
    }

    /// 选中的文件在当前 diffSide 下是否可能没有内容 —— 用来在界面上给出解释，
    /// 而不是显示一片空白让人以为坏了。
    var selectedChange: FileChange? {
        guard let selectedPath else { return nil }
        return status.changes.first { $0.path == selectedPath }
    }

    // MARK: - 暂存

    func stage(_ change: FileChange) async {
        await mutate("暂存 \(change.displayName)") {
            try await self.git.stage(paths: [change.path], in: self.path)
        }
    }

    func stageAll() async {
        // 有冲突时不能 `add --all`：它会把还带着 `<<<<<<<` 标记的文件一起标成已解决。
        // 只加那些真正的未暂存改动，冲突文件走「标记为已解决」那条路。
        let unresolved = status.changes.filter { $0.unstaged != nil && !$0.isConflicted }.map(\.path)
        if status.hasConflicts {
            guard !unresolved.isEmpty else { return }
        }
        await mutate("全部暂存") {
            if self.status.hasConflicts {
                try await self.git.stage(paths: unresolved, in: self.path)
            } else {
                try await self.git.stageAll(in: self.path)
            }
        }
    }

    func unstage(_ change: FileChange) async {
        await mutate("取消暂存 \(change.displayName)") {
            try await self.git.unstage(paths: [change.path], in: self.path)
        }
    }

    func unstageAll() async {
        let staged = status.changes.filter(\.isStaged).map(\.path)
        guard !staged.isEmpty else { return }
        await mutate("全部取消暂存") {
            try await self.git.unstage(paths: staged, in: self.path)
        }
    }

    func discard(_ change: FileChange) async {
        await mutate("丢弃 \(change.displayName) 的改动") {
            if change.unstaged == .untracked {
                try await self.git.discard(paths: [], untracked: [change.path], in: self.path)
            } else {
                // 重命名的情况下来源路径也要恢复，不然旧文件不会回来。
                var paths = [change.path]
                if let originalPath = change.originalPath { paths.append(originalPath) }
                try await self.git.discard(paths: paths, untracked: [], in: self.path)
            }
        }
    }

    // MARK: - 分行暂存

    func toggleLine(_ line: DiffLine) {
        guard line.kind == .addition || line.kind == .deletion else { return }
        if selectedLines.contains(line.id) {
            selectedLines.remove(line.id)
        } else {
            selectedLines.insert(line.id)
        }
    }

    /// 整块勾上 / 取消。逐行点在大 hunk 上太累，而「这一块整个要」是最常见的意图。
    func toggleHunk(_ hunk: DiffHunk) {
        let changed = hunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id)
        guard !changed.isEmpty else { return }
        if changed.allSatisfy(selectedLines.contains) {
            selectedLines.subtract(changed)
        } else {
            selectedLines.formUnion(changed)
        }
    }

    func hunkSelectionState(_ hunk: DiffHunk) -> HunkSelection {
        let changed = hunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id)
        guard !changed.isEmpty else { return .none }
        let picked = changed.filter(selectedLines.contains).count
        if picked == 0 { return .none }
        return picked == changed.count ? .all : .partial
    }

    enum HunkSelection { case none, partial, all }

    /// 保留用户想看的侧；如果这一侧已经没有内容，就切到仍有内容的另一侧。
    nonisolated static func validDiffSide(for change: FileChange, preferred: DiffSide) -> DiffSide {
        if preferred == .staged, change.staged != nil { return .staged }
        if preferred == .worktree, change.unstaged != nil { return .worktree }
        return change.staged != nil ? .staged : .worktree
    }

    var selectedLineCount: Int { selectedLines.count }

    /// 选中的行能不能做分行操作。二进制文件和未跟踪文件没有可裁的补丁，冲突文件的 combined diff 也不行。
    var canApplySelectedLines: Bool {
        guard !selectedLines.isEmpty, activity == nil, selectedChange?.isConflicted != true else { return false }
        guard let diff, diff.contains(where: { !$0.isBinary && !$0.hunks.isEmpty }) else { return false }
        return selectedChange?.unstaged != .untracked
    }

    /// 把选中的行暂存 / 取消暂存。方向由当前看的是哪一侧决定：
    /// 看工作区就是「加进索引」，看暂存区就是「从索引撤掉」。
    func applySelectedLines() async {
        let staged = diffSide == .staged
        await applyPatch(
            direction: staged ? .reverse : .forward,
            cached: true,
            reverse: staged,
            label: staged ? "取消暂存选中行" : "暂存选中行"
        )
    }

    /// 丢弃工作区里选中的行。不可撤销，调用方必须先确认过。
    func discardSelectedLines() async {
        await applyPatch(direction: .reverse, cached: false, reverse: true, label: "丢弃选中行")
    }

    private func applyPatch(
        direction: PatchBuilder.Direction,
        cached: Bool,
        reverse: Bool,
        label: String
    ) async {
        guard let diff else { return }
        activity = "正在\(label)…"
        defer { activity = nil }

        do {
            for file in diff {
                guard let patch = PatchBuilder.patch(
                    for: file, selecting: selectedLines, direction: direction
                ) else { continue }
                try await git.applyPatch(patch, in: path, cached: cached, reverse: reverse)
            }
            selectedLines.removeAll()
        } catch {
            app?.report(title: "\(label)失败", error: error)
        }
        await refresh()
    }

    // MARK: - 变基

    /// 变基的默认目标：优先当前分支的上游，其次 `origin/<默认分支>`。
    /// 「把我的分支同步到主干最新」是绝大多数变基的实际意图。
    var suggestedRebaseTarget: String? {
        if let upstream = status.upstream { return upstream }
        guard let repository else { return nil }
        if let defaultBranch = repository.defaultBranch {
            let remote = repository.remotes.first { $0.name == "origin" } ?? repository.remotes.first
            if let remote { return "\(remote.name)/\(defaultBranch)" }
            return defaultBranch
        }
        return nil
    }

    /// 变基会重放多少个提交。nil 表示目标引用不存在或算不出来。
    func rebaseCommitCount(onto target: String) async -> Int? {
        guard await git.refExists(target, in: path) else { return nil }
        return await git.commitCount(from: target, in: path)
    }

    /// 开始变基。冲突导致中断**不算失败** —— 那是变基的正常分支，
    /// 界面会切到「变基进行中」的状态让用户解决。
    func rebase(onto target: String, autostash: Bool) async {
        activity = "正在变基到 \(target)…"
        defer { activity = nil }
        do {
            try await git.rebase(onto: target, autostash: autostash, in: path)
        } catch {
            await refresh()
            // 停在冲突上时 git 也是非零退出。这时候不该报「失败」——
            // 用户接下来要做的是解决冲突，而不是以为操作没生效。
            if status.operation == .rebase {
                app?.report(
                    title: "变基遇到冲突",
                    detail: "在「冲突」区把每个文件解决并标记为已解决，再点上方的「继续」；不想继续就点「中止」，仓库会回到变基前的样子。"
                )
            } else {
                app?.report(title: "变基失败", error: error)
            }
            return
        }
        await refresh()
        await repository?.refresh()
    }

    /// 多步操作（合并 / 变基 / 拣选 / 回退）中途的继续、跳过、中止。
    func operationStep(_ step: GitClient.OperationStep) async {
        guard let operation = steppableOperation else { return }
        let label: String
        switch step {
        case .cont: label = "继续\(operation.verb)"
        case .skip: label = "跳过这个提交"
        case .abort: label = "中止\(operation.verb)"
        }
        activity = "正在\(label)…"
        defer { activity = nil }
        do {
            try await git.operationStep(step, of: operation, in: path)
        } catch {
            await refresh()
            // `--continue` 在还有未解决冲突时会拒绝，这是提醒不是故障。
            if status.operation == operation, step == .cont, status.hasConflicts {
                app?.report(
                    title: "还有冲突没解决",
                    detail: "把「冲突」区里的每个文件解决并标记为已解决之后，再点「继续」。"
                )
            } else {
                app?.report(title: "\(label)失败", error: error)
            }
            return
        }
        await refresh()
        await repository?.refresh()
    }

    func rebaseStep(_ step: GitClient.RebaseStep) async {
        await operationStep(step)
    }

    /// 正处在变基中途。
    var isRebasing: Bool { status.operation == .rebase }

    /// 正处在某个能从 Grove 里「继续 / 中止」的多步操作中途。界面据此显示顶部那条横幅。
    var steppableOperation: RepositoryOperation? {
        guard let operation = status.operation, operation.isSteppable else { return nil }
        return operation
    }

    // MARK: - 冲突

    private func refreshConflictContext() async {
        guard status.hasConflicts || status.operation != nil else {
            conflictContext = nil
            return
        }
        let context = await git.conflictContext(
            operation: status.operation,
            branch: status.branch,
            in: path
        )
        // 被取消的刷新里 git 调用全部失败，算出来的是「MERGE_HEAD」这种兜底标签；
        // 别让它盖掉之前查到的真实分支名。
        guard !Task.isCancelled else { return }
        conflictContext = context
    }

    /// 整个文件采用一侧。
    func resolveConflict(_ change: FileChange, taking side: GitClient.ConflictSide) async {
        guard let kind = change.conflict else { return }
        await mutate("\(side.actionLabel)：\(change.displayName)") {
            try await self.git.resolveConflict(path: change.path, taking: side, kind: kind, in: self.path)
        }
    }

    /// 所有冲突文件都采用同一侧。调用方必须先确认过 —— 这是一口气把所有文件定下来。
    func resolveAllConflicts(taking side: GitClient.ConflictSide) async {
        let conflicted = status.conflictedChanges
        guard !conflicted.isEmpty else { return }
        await mutate("全部\(side.actionLabel)") {
            for change in conflicted {
                guard let kind = change.conflict else { continue }
                try await self.git.resolveConflict(path: change.path, taking: side, kind: kind, in: self.path)
            }
        }
    }

    /// 把工作区里现在的内容当作解决结果（`git add` / `git rm`）。
    func markConflictResolved(_ change: FileChange) async {
        await mutate("标记 \(change.displayName) 为已解决") {
            try await self.git.markConflictResolved(path: change.path, in: self.path)
        }
    }

    /// 文件里现在还剩几个冲突块。标记为已解决之前用它拦一下 ——
    /// 带着 `<<<<<<<` 提交出去是冲突解决里最常见的事故。
    func unresolvedMarkerCount(in change: FileChange) -> Int {
        guard case .text(let text, _) = Self.readConflictSource(at: path.appendingPathComponent(change.path)) else {
            return 0
        }
        return ConflictParser.parse(text).blocks.count
    }

    /// 把文件恢复成 git 刚合并完、带冲突标记的样子。会丢掉用户在这个文件里做的所有改动。
    func restoreConflictMarkers(_ change: FileChange) async {
        await mutate("恢复 \(change.displayName) 的冲突标记") {
            try await self.git.restoreConflictMarkers(path: change.path, in: self.path)
        }
    }

    /// 给一个冲突块定结果（nil = 撤销之前的选择），然后把整份文件重写到磁盘。
    func resolveBlock(_ block: ConflictBlock, with resolution: ConflictResolution?) {
        guard case .editor(let editor) = conflictContent else { return }
        var resolutions = editor.resolutions
        if let resolution {
            resolutions[block.id] = resolution
        } else {
            resolutions.removeValue(forKey: block.id)
        }
        writeConflictEditor(editor, resolutions: resolutions)
    }

    /// 剩下的块全部按同一个选择解决。已经选过的块不动。
    func resolveRemainingBlocks(with resolution: ConflictResolution) {
        guard case .editor(let editor) = conflictContent else { return }
        var resolutions = editor.resolutions
        for block in editor.unresolvedBlocks { resolutions[block.id] = resolution }
        writeConflictEditor(editor, resolutions: resolutions)
    }

    /// 重新从磁盘读一遍。用户在外部编辑器里改完回来时点它。
    func reloadConflictContent() async {
        guard let change = selectedChange, change.isConflicted else { return }
        await loadConflictContent(for: change)
    }

    private func writeConflictEditor(_ editor: ConflictEditor, resolutions: [Int: ConflictResolution]) {
        let url = path.appendingPathComponent(editor.change.path)

        // 写之前确认磁盘上还是我们上次见到的内容。
        if case .text(let onDisk, _) = Self.readConflictSource(at: url), onDisk != editor.lastKnownText {
            app?.report(
                title: "文件已在外部被修改",
                detail: "「\(editor.change.displayName)」跟 Grove 上次读到的不一样，已重新读取。这次的选择没有写入，请重新选。"
            )
            Task { await reloadConflictContent() }
            return
        }

        var editor = editor
        editor.resolutions = resolutions
        let text = editor.document.rendered(with: resolutions)
        var data = Data(text.utf8)
        if editor.document.hasByteOrderMark {
            data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
        }
        do {
            // 不用 atomic：原地写才能保住文件的权限位和 inode
            // （可执行脚本、正被别的程序打开着的文件）。
            try data.write(to: url)
            editor.lastKnownText = text
            conflictContent = .editor(editor)
        } catch {
            app?.report(title: "写入 \(editor.change.displayName) 失败", error: error)
        }
    }

    private func loadConflictContent(for change: FileChange) async {
        let url = path.appendingPathComponent(change.path)
        let source = await Task.detached(priority: .userInitiated) {
            Self.readConflictSource(at: url)
        }.value
        guard !Task.isCancelled else { return }

        switch source {
        case .missing:
            conflictContent = .missing
        case .binary:
            conflictContent = .binary
        case .undecodable:
            conflictContent = .undecodable
        case .text(let text, let hasByteOrderMark):
            // 磁盘内容还是我们上次写的那份：保留已做的选择，以及撤销它们的能力。
            // 每次刷新都重新解析的话，选过的块会变成普通文本，「撤销」就没了。
            if case .editor(var existing) = conflictContent,
               existing.change.path == change.path,
               existing.lastKnownText == text {
                existing.change = change
                conflictContent = .editor(existing)
                return
            }
            var document = ConflictParser.parse(text)
            document.hasByteOrderMark = hasByteOrderMark
            conflictContent = .editor(ConflictEditor(change: change, document: document, lastKnownText: text))
        }
    }

    enum ConflictSource {
        case text(String, hasByteOrderMark: Bool)
        case binary
        case undecodable
        case missing
    }

    /// 读一个冲突文件。解码必须是**严格**的 UTF-8：宽松解码会把非法字节换成 U+FFFD，
    /// 写回去文件就坏了 —— 所以解不出来的一律归为「不可改写」。
    nonisolated static func readConflictSource(at url: URL) -> ConflictSource {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return .missing }
        guard var data = try? Data(contentsOf: url) else { return .missing }

        // 判定二进制：前 8000 字节里出现 NUL。这也是 git 自己的启发式。
        if data.prefix(8000).contains(0) { return .binary }

        var hasByteOrderMark = false
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            hasByteOrderMark = true
            data.removeFirst(3)
        }
        guard let text = String(data: data, encoding: .utf8) else { return .undecodable }
        return .text(text, hasByteOrderMark: hasByteOrderMark)
    }

    // MARK: - 提交与同步

    var canCommit: Bool {
        guard !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard status.operation == nil || status.hasConflicts == false else { return false }
        // amend 不需要有暂存内容（可以只改提交信息）。
        return amendLastCommit || status.stagedCount > 0
    }

    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        activity = "正在提交…"
        defer { activity = nil }
        do {
            try await git.commit(message: message, amend: amendLastCommit, in: path)
            // 只有提交真的成功了才清空草稿。失败还清了，用户就得重写一遍。
            commitMessage = ""
            amendLastCommit = false
            hasGeneratedCommitMessage = false
            generatedFromTruncatedDiff = false
        } catch {
            app?.report(title: "提交失败", error: error)
        }
        await refresh()
    }

    // MARK: - AI 提交信息

    func startCommitMessageGeneration() {
        guard isAICommitEnabled, status.stagedCount > 0, !isGeneratingCommitMessage else { return }
        guard let service = app?.aiService else { return }
        isGeneratingCommitMessage = true
        canRetryCommitMessageGeneration = false
        generatedFromTruncatedDiff = false

        commitMessageTask = Task { [weak self] in
            guard let self else { return }
            do {
                let generated = try await CodexCommitGenerator.generate(
                    in: self.path,
                    git: self.git,
                    model: self.app?.aiCommitModel ?? .luna,
                    service: service
                )
                try Task.checkCancellation()
                self.commitMessage = generated.text
                self.generatedFromTruncatedDiff = generated.wasTruncated
                self.hasGeneratedCommitMessage = true
            } catch is CancellationError {
                // 用户主动取消不属于失败，静默回到空闲状态。
            } catch {
                self.canRetryCommitMessageGeneration = AIGenerationFailure.isTimeout(error)
                self.app?.report(title: "AI 提交信息生成失败", error: error)
            }
            self.isGeneratingCommitMessage = false
            self.commitMessageTask = nil
        }
    }

    func cancelCommitMessageGeneration() {
        commitMessageTask?.cancel()
    }

    func generatePullRequestDescription(base: String) async throws
        -> CodexPullRequestGenerator.GeneratedDescription {
        guard let service = app?.aiService else { throw AIAPIError.invalidConfiguration }
        return try await CodexPullRequestGenerator.generate(
            in: path,
            base: base,
            git: git,
            model: app?.aiCommitModel ?? .luna,
            service: service
        )
    }

    func pull() async {
        await performSync(.pull, activity: "正在拉取…") {
            try await self.git.pull(in: self.path)
        }
    }

    /// 当前分支的上游在哪个远端。没设上游时为 nil。
    var upstreamRemoteName: String? {
        guard let upstream = status.upstream else { return nil }
        return RemoteListParser.remoteName(
            inUpstream: upstream,
            knownRemotes: repository?.remotes.map(\.name) ?? []
        )
    }

    /// 一键推送时默认推去哪：优先分支自己的上游，其次 origin，再退回第一个远端。
    var defaultPushRemote: NamedRemote? {
        let remotes = repository?.remotes ?? []
        if let name = upstreamRemoteName, let match = remotes.first(where: { $0.name == name }) {
            return match
        }
        return remotes.first { $0.name == "origin" } ?? remotes.first
    }

    /// 推送到指定远端。`remote` 为 nil 表示「按分支自己的上游推」，
    /// 也就是终端里裸 `git push` 的行为。
    func push(to remote: NamedRemote? = nil) async {
        let label = remote.map { "正在推送到 \($0.name)…" } ?? "正在推送…"
        await performSync(
            .push,
            activity: label,
            refreshPullRequests: true,
            onFailure: { error in
                if await self.canOfferSafeForcePush(after: error, to: remote) {
                    self.safeForcePushProposal = .init(
                        remote: remote,
                        branch: self.worktree.branch
                    )
                } else {
                    self.app?.report(title: "推送失败", error: error)
                }
            }
        ) {
            // 没有上游就顺手建立跟踪关系。不然第一次 push 会被 git 拒掉，
            // 并要求用户去终端里敲 --set-upstream。
            //
            // 但**已经有上游**时不动它：用户显式推到另一个远端（比如备份仓库）
            // 不代表他想把分支改跟踪到那边去，悄悄改掉会让之后的 pull 拉错地方。
            let needsUpstream = self.status.upstream == nil
            try await self.git.push(
                in: self.path,
                remote: remote?.name,
                branch: self.worktree.branch,
                setUpstream: needsUpstream
            )
        }
    }

    func dismissSafeForcePushProposal() {
        safeForcePushProposal = nil
    }

    func confirmSafeForcePush() async {
        guard let proposal = safeForcePushProposal else { return }
        safeForcePushProposal = nil
        let label = proposal.remote.map { "正在安全强制推送到 \($0.name)…" }
            ?? "正在安全强制推送…"

        await performSync(.push, activity: label, refreshPullRequests: true) {
            try await self.git.push(
                in: self.path,
                remote: proposal.remote?.name,
                branch: proposal.branch,
                setUpstream: false,
                forceWithLease: true
            )
        }
    }

    private func canOfferSafeForcePush(after error: Error, to remote: NamedRemote?) async -> Bool {
        guard status.upstream != nil else { return false }
        if let remote, remote.name != upstreamRemoteName { return false }
        guard let failure = error as? CommandFailure else { return false }
        let output = failure.output.lowercased()
        guard output.contains("non-fast-forward") || output.contains("fetch first") else { return false }
        return await git.upstreamMatchesPreviousHead(in: path)
    }

    private func performSync(
        _ action: SyncFeedback.Action,
        activity label: String,
        refreshPullRequests: Bool = false,
        onFailure: ((Error) async -> Void)? = nil,
        _ work: @escaping () async throws -> Void
    ) async {
        syncFeedbackResetTask?.cancel()
        syncFeedback = .init(action: action, phase: .running)
        activity = label

        do {
            try await work()
            activity = nil
            showSyncResult(action, phase: .succeeded)
        } catch {
            activity = nil
            showSyncResult(action, phase: .failed)
            if let onFailure {
                await onFailure(error)
            } else {
                let title = action == .pull ? "拉取失败" : "推送失败"
                app?.report(title: title, error: error)
            }
        }

        await refresh()
        if refreshPullRequests {
            await repository?.refreshPullRequests()
        }
    }

    private func showSyncResult(_ action: SyncFeedback.Action, phase: SyncFeedback.Phase) {
        let result = SyncFeedback(action: action, phase: phase)
        syncFeedback = result
        syncFeedbackResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self?.syncFeedback == result else { return }
            self?.syncFeedback = nil
        }
    }

    private func mutate(_ label: String, _ work: @escaping () async throws -> Void) async {
        activity = "正在\(label)…"
        defer { activity = nil }
        do {
            try await work()
        } catch {
            app?.report(title: "\(label)失败", error: error)
        }
        await refresh()
    }

    // MARK: - PR

    /// 头部那个评审按钮此刻该是什么。
    ///
    /// 刻意不返回一个光秃秃的 Bool：条件不满足时**按钮不能直接消失**。
    /// 一个说没就没的按钮会让人以为功能坏了或者自己点错了地方，
    /// 而真正的原因（在默认分支上 / 远端没登录 / 已经有 PR 了）界面上一个字都没提。
    /// 所以这里连原因一起给出来，视图把按钮留在原位、禁用掉、把原因放进提示。
    var pullRequestAction: PullRequestAction {
        if let linkedPullRequest { return .view(linkedPullRequest) }

        guard let repository else { return .unavailable("仓库信息还没加载完。") }
        let term = repository.reviewTerm

        if let reason = repository.pullRequestUnavailableReason {
            return .unavailable(reason)
        }
        guard let branch = worktree.branch, !worktree.isDetached else {
            return .unavailable("当前是游离 HEAD，没有分支可以提\(term)。先切到一个分支。")
        }
        if branch == repository.defaultBranch {
            return .unavailable(
                "当前在默认分支 \(branch) 上。\(term)要从另一个分支提出 —— "
                + "用工具栏的「新建工作树」开一个功能分支。"
            )
        }
        return .create(term: term)
    }

    enum PullRequestAction {
        case view(PullRequest)
        case create(term: String)
        case unavailable(String)
    }

    /// 提 PR 之前必须先把分支推上去。这个方法把「推送 + 创建」串成一步，
    /// 因为分开做的话用户十次里有九次会忘记先推。
    func createPullRequest(title: String, body: String, base: String, isDraft: Bool) async -> String? {
        guard let forge = repository?.forge, let branch = worktree.branch else { return nil }

        activity = "正在推送分支…"
        defer { activity = nil }

        do {
            if status.upstream == nil {
                // 提 PR 必须推到 origin —— 托管商就是按 origin 认的。
                try await git.push(in: path, remote: "origin", branch: branch, setUpstream: true)
            } else if status.ahead > 0 {
                try await git.push(in: path, remote: nil, branch: branch, setUpstream: false)
            }
        } catch {
            app?.report(title: "推送分支失败", error: error)
            return nil
        }

        activity = "正在创建 PR…"
        do {
            let url = try await forge.createPullRequest(
                NewPullRequest(
                    title: title, body: body, base: base, head: branch, isDraft: isDraft
                ),
                in: path
            )
            await refresh()
            await repository?.refreshPullRequests()
            return url
        } catch {
            app?.report(title: "创建 PR 失败", error: error)
            return nil
        }
    }

    /// 提 PR 时的默认标题：优先用最新提交的标题，那几乎总是用户想要的。
    var suggestedPullRequestTitle: String {
        if let subject = commitsAheadOfBase.first?.subject, !subject.isEmpty { return subject }
        return worktree.branch ?? ""
    }

    /// 提 PR 时的默认正文：多个提交时把标题列成清单，单个提交就留空
    /// （标题已经说完了，正文再重复一遍是噪音）。
    var suggestedPullRequestBody: String {
        let ahead = commitsAheadOfBase
        guard ahead.count > 1 else { return "" }
        return ahead.map { "- \($0.subject)" }.joined(separator: "\n")
    }

    /// 相对上游领先的那些提交。没有上游时退回最近的提交列表。
    private var commitsAheadOfBase: [CommitSummary] {
        guard status.ahead > 0 else { return Array(commits.prefix(1)) }
        return Array(commits.prefix(status.ahead))
    }
}
