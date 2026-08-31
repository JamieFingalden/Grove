import Foundation
import Observation

/// 一次操作失败的记录，用来在界面上显示横幅。
struct GroveFailure: Identifiable, Sendable {
    let id = UUID()
    var title: String
    var detail: String
    /// 面向开发者的原始输出默认收起来，避免一整屏 stderr 冒充用户提示。
    var technicalDetail: String?
    var date: Date

    init(title: String, error: Error) {
        self.title = title
        if let failure = error as? CommandFailure {
            self.detail = Self.friendlyGitMessage(failure.output)
            self.technicalDetail = [failure.commandLine, failure.output]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        } else if error is CommandTimeout {
            self.detail = "远端响应时间过长，操作已经停止。请检查网络或 VPN，确认远端服务可用后再试。"
            self.technicalDetail = error.localizedDescription
        } else {
            self.detail = error.localizedDescription
            self.technicalDetail = nil
        }
        self.date = Date()
    }

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
        self.technicalDetail = nil
        self.date = Date()
    }

    /// 把 Git 面向终端的报错翻译成用户能直接采取行动的说明。
    private static func friendlyGitMessage(_ output: String) -> String {
        let message = output.lowercased()

        if message.contains("diverging branches") || message.contains("not possible to fast-forward") {
            return "本地和远端都有新的提交，无法直接拉取。请先点「变基」，把本地提交接到远端最新提交之后，再重新拉取。"
        }
        if message.contains("stale info") || message.contains("force-with-lease") {
            return "远端在你上次同步后又发生了变化，安全强制推送已阻止覆盖。请先抓取远端并检查新增提交，再决定如何处理。"
        }
        if message.contains("non-fast-forward") || message.contains("fetch first") {
            return "远端有本地尚未包含的提交，因此拒绝了推送。请先拉取；如果提示分支已分叉，就先完成变基，再重新推送。"
        }
        if message.contains("authentication failed")
            || message.contains("could not read username")
            || message.contains("permission denied (publickey)")
            || message.contains("http basic: access denied") {
            return "远端身份验证失败。请检查 Git 凭据或 SSH 密钥，确认当前账号有这个仓库的访问权限后重试。"
        }
        if message.contains("could not resolve host")
            || message.contains("failed to connect")
            || message.contains("connection timed out")
            || message.contains("unable to access") {
            return "无法连接远端仓库。请检查网络、VPN 和远端地址，确认服务可访问后重试。"
        }
        if message.contains("repository not found") {
            return "找不到远端仓库，或当前账号没有访问权限。请检查远端地址和账号权限。"
        }
        if message.contains("protected branch")
            || message.contains("pre-receive hook declined") {
            return "远端规则拒绝了这次推送。该分支可能受保护，请改用功能分支并提交合并请求。"
        }
        if message.contains("has no upstream branch") {
            return "当前分支还没有关联远端分支。请从推送按钮的菜单选择目标远端，首次推送会自动建立关联。"
        }
        if message.contains("could not resolve to a pullrequest") {
            return "远端找不到这个评审请求。它可能已经结束、被删除，或者当前仓库与请求不匹配；请刷新后重新选择。"
        }

        return "Git 没有完成这次操作。请展开「技术详情」查看原始信息，处理后再试。"
    }
}

/// 应用顶层状态：工具链、打开的仓库、当前选中项。
@MainActor
@Observable
final class AppModel {
    private(set) var git: GitClient?
    private(set) var github: GitHubClient?
    private(set) var gitlab: GitLabClient?
    /// CLI 装了但没登录。这个区别要告诉用户 —— 一个是去装，一个是去登录。
    private(set) var githubNeedsAuth = false
    private(set) var gitlabNeedsAuth = false
    /// 各 CLI 配置过的主机。用来判断一个远端归哪个托管商管 ——
    /// 包括自建的 GitHub Enterprise 和内网 GitLab，只要用户
    /// `auth login --hostname` 过就认得出来。
    private(set) var githubHosts: Set<String> = []
    private(set) var gitlabHosts: Set<String> = []
    private(set) var toolsReady = false

    var repositories: [RepositoryModel] = []
    var selection: Selection?
    var failures: [GroveFailure] = []
    private(set) var isAIGenerationEnabled: Bool
    private(set) var aiGenerationModel: AIGenerationModel

    /// 侧边栏选中项。仓库和工作树用同一个枚举，`NavigationSplitView` 的选择才好绑。
    enum Selection: Hashable, Sendable {
        case worktree(repository: URL, worktree: URL)
        /// 仓库级的 PR 列表（不属于任何单个工作树）。
        case pullRequests(repository: URL)
    }

    private let bookmarks = RepositoryBookmarks()
    @ObservationIgnored private let aiGenerationSettings: AIGenerationSettings

    init(aiGenerationSettings: AIGenerationSettings = AIGenerationSettings()) {
        self.aiGenerationSettings = aiGenerationSettings
        self.isAIGenerationEnabled = aiGenerationSettings.isEnabled
        self.aiGenerationModel = aiGenerationSettings.model
    }

    func setAIGenerationEnabled(_ enabled: Bool) {
        aiGenerationSettings.setEnabled(enabled)
        isAIGenerationEnabled = enabled
    }

    func setAIGenerationModel(_ model: AIGenerationModel) {
        aiGenerationSettings.setModel(model)
        aiGenerationModel = model
    }

    // MARK: - 启动

    func bootstrap() async {
        do {
            git = try await GitClient.resolve()
        } catch {
            report(GroveFailure(title: "无法启动", error: error))
            toolsReady = true
            return
        }

        // git 就绪后界面已经能工作，托管商和旧仓库恢复都放到后台并发进行。
        // 一台离线的自建 GitLab 不应该把整个窗口锁在「正在准备」一分钟。
        toolsReady = true

        async let repositoryRestore: Void = restoreBookmarkedRepositories()
        await detectForges()
        await repositoryRestore

        // 启动恢复刻意只读本地 Git 状态；托管商探测完成后再补仓库标识。
        // 这一步即使网络慢，仓库和工作树也早已可以使用。
        for repository in repositories {
            await repository.refreshForgeMetadata()
        }
    }

    private func detectForges() async {
        async let resolvedGitHub = GitHubClient.resolve()
        async let resolvedGitLab = GitLabClient.resolve()
        let (github, gitlab) = await (resolvedGitHub, resolvedGitLab)
        self.github = github
        self.gitlab = gitlab

        async let githubProbe = probeGitHub(github)
        async let gitlabProbe = probeGitLab(gitlab)
        let (githubState, gitlabState) = await (githubProbe, gitlabProbe)
        githubNeedsAuth = githubState.needsAuth
        githubHosts = githubState.hosts
        gitlabNeedsAuth = gitlabState.needsAuth
        gitlabHosts = gitlabState.hosts
    }

    private func probeGitHub(_ client: GitHubClient?) async -> (needsAuth: Bool, hosts: Set<String>) {
        guard let client else { return (false, []) }
        async let authenticated = client.isAuthenticated()
        async let hosts = client.configuredHosts()
        return await (!(authenticated), hosts)
    }

    private func probeGitLab(_ client: GitLabClient?) async -> (needsAuth: Bool, hosts: Set<String>) {
        guard let client else { return (false, []) }
        async let authenticated = client.isAuthenticated()
        async let hosts = client.configuredHosts()
        return await (!(authenticated), hosts)
    }

    /// 某个远端该由哪个托管商客户端处理。认不出来返回 nil —— 评审功能就整块关闭，
    /// git 那半边完全不受影响。
    ///
    /// 只看 `origin`（由调用方保证），因为一个仓库完全可能同时挂着内网 GitLab 的
    /// origin 和一个 GitHub 备份 remote。按「随便找一个认识的」来挑，
    /// 会把另一个仓库的 PR 显示到这个仓库上 —— 这个坑真踩过。
    func forge(for remote: GitRemote?) -> (any ForgeClient)? {
        guard let remote else { return nil }
        // 公有云主机名是确定的，先认。
        if remote.matchesHost("github.com") { return github }
        if remote.matchesHost("gitlab.com") { return gitlab }
        // 自建实例只能靠 CLI 配置过的主机列表认。带端口和不带端口两种写法都试，
        // 因为 glab 的配置键取决于登录时 `--hostname` 是怎么写的。
        if githubHosts.contains(where: { remote.matchesHost($0) }) { return github }
        if gitlabHosts.contains(where: { remote.matchesHost($0) }) { return gitlab }
        return nil
    }

    /// 认不出托管商时，给一份**能照着做完**的指引。
    ///
    /// 不只是「不支持」四个字：把要装什么、要跑哪条命令、命令里该填什么
    /// 全部拼好。新接一个自建实例时，用户不该还得自己去翻 glab 的文档。
    func forgeSetup(for remote: GitRemote?) -> ForgeSetup? {
        guard let remote else {
            return ForgeSetup(summary: "这个仓库没有配置远端。", steps: [])
        }

        var steps: [ForgeSetup.Step] = []

        if gitlab == nil {
            steps.append(.init(
                text: "安装 GitLab CLI（自建 GitLab 用）",
                command: "brew install glab"
            ))
        }
        if github == nil {
            steps.append(.init(
                text: "安装 GitHub CLI（GitHub / GitHub Enterprise 用）",
                command: "brew install gh"
            ))
        }

        // 自建实例最常见的情况：装了，但没给这台主机登录过。
        // 认证主机要跟 git remote 中的 host:port 完全一致，否则 glab
        // 会把它们当成两台不同的主机，无法从当前仓库解析项目。
        var glabCommand = "glab auth login --hostname \(remote.hostWithPort)"
        // 内网实例大量是明文 http。不带这个参数 glab 会默认 https，
        // 登录会以一个跟协议毫无关系的报错失败 —— 极难自己想到。
        if remote.isInsecureHTTP {
            glabCommand += " --api-protocol http"
        }
        steps.append(.init(text: "登录这台 GitLab", command: glabCommand))
        steps.append(.init(
            text: "如果它其实是 GitHub Enterprise，改用这条",
            command: "gh auth login --hostname \(remote.host)"
        ))

        return ForgeSetup(
            summary: "origin 指向 \(remote.hostWithPort)，Grove 还不知道它属于哪个平台。"
                + "按下面任一条登录之后，点「重新检测」即可，不用重启。",
            steps: steps
        )
    }

    /// 接一个新的自建实例要做的事。
    struct ForgeSetup: Sendable, Equatable {
        var summary: String
        var steps: [Step]

        struct Step: Sendable, Equatable, Identifiable {
            var text: String
            var command: String
            var id: String { command }
        }
    }

    /// 重新探测两个 CLI 的安装和登录状态。
    ///
    /// 主机列表只在启动时读一次，所以用户在终端里 `glab auth login` 之后，
    /// 不刷新的话 Grove 还认为这台主机不认识 —— 「登录完还得重启 app」
    /// 是个很没道理的要求。
    func redetectForges() async {
        await detectForges()

        // 每个仓库都要重新判一次归属，否则刚登录的那台还是灰的。
        for repository in repositories {
            await repository.refreshForgeMetadata()
        }
    }

    private func restoreBookmarkedRepositories() async {
        for path in bookmarks.load() {
            let url = URL(fileURLWithPath: path)
            // 上次打开的目录可能已经被删/改名了，静默跳过 —— 启动时弹一串
            // 「找不到仓库」的错误没有任何帮助。
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let repository = await openRepository(
                at: url,
                persist: false,
                select: false,
                loadForgeMetadata: false
            ), selection == nil {
                // 不等剩下的仓库全部刷新，第一座仓库可用后立刻进入它。
                selectDefaultWorktree(in: repository)
            }
        }
        bookmarks.save(repositories.map(\.root.path))

        if selection == nil, let first = repositories.first {
            selectDefaultWorktree(in: first)
        }
    }

    // MARK: - 仓库管理

    @discardableResult
    func openRepository(
        at url: URL,
        persist: Bool = true,
        select: Bool = true,
        loadForgeMetadata: Bool = true
    ) async -> RepositoryModel? {
        guard let git else { return nil }

        guard let root = await git.repositoryRoot(for: url) else {
            report(GroveFailure(title: "打开失败", error: GroveError.notARepository(url)))
            return nil
        }

        // 已经开着了就直接选中它，不要重复添加。用户很可能是从子目录再拖进来一次。
        if let existing = repositories.first(where: { $0.root == root }) {
            if select { selectDefaultWorktree(in: existing) }
            return existing
        }

        let repository = RepositoryModel(root: root, git: git, app: self)
        repositories.append(repository)
        repositories.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        await repository.refresh(loadForgeMetadata: loadForgeMetadata)
        if persist { bookmarks.save(repositories.map(\.root.path)) }
        if select { selectDefaultWorktree(in: repository) }
        return repository
    }

    func closeRepository(_ repository: RepositoryModel) {
        repositories.removeAll { $0.root == repository.root }
        bookmarks.save(repositories.map(\.root.path))
        if case .worktree(let repositoryRoot, _) = selection, repositoryRoot == repository.root {
            selection = nil
        }
        if case .pullRequests(let repositoryRoot) = selection, repositoryRoot == repository.root {
            selection = nil
        }
    }

    private func selectDefaultWorktree(in repository: RepositoryModel) {
        guard let worktree = repository.worktrees.first else { return }
        selection = .worktree(repository: repository.root, worktree: worktree.path)
    }

    // MARK: - 查找

    func repository(for root: URL) -> RepositoryModel? {
        repositories.first { $0.root == root }
    }

    var selectedRepository: RepositoryModel? {
        switch selection {
        case .worktree(let root, _): repository(for: root)
        case .pullRequests(let root): repository(for: root)
        case nil: nil
        }
    }

    var selectedWorktreeModel: WorktreeModel? {
        guard case .worktree(let root, let path) = selection,
              let repository = repository(for: root) else { return nil }
        return repository.worktreeModel(for: path)
    }

    // MARK: - 错误

    func report(_ failure: GroveFailure) {
        failures.append(failure)
        // 只留最近几条。错误横幅堆到十几条就把界面挤没了，而旧的那些用户早就不看了。
        if failures.count > 4 { failures.removeFirst(failures.count - 4) }
    }

    func report(title: String, error: Error) {
        report(GroveFailure(title: title, error: error))
    }

    func report(title: String, detail: String) {
        report(GroveFailure(title: title, detail: detail))
    }

    func dismiss(_ failure: GroveFailure) {
        failures.removeAll { $0.id == failure.id }
    }

    /// 某个托管商的 CLI 是否可用，以及不可用的原因。
    func availability(of kind: ForgeKind) -> ForgeAvailability {
        switch kind {
        case .github:
            if github == nil { return .notInstalled(kind) }
            return githubNeedsAuth ? .notAuthenticated(kind) : .ready
        case .gitlab:
            if gitlab == nil { return .notInstalled(kind) }
            return gitlabNeedsAuth ? .notAuthenticated(kind) : .ready
        }
    }

    enum ForgeAvailability: Sendable, Equatable {
        case ready
        case notInstalled(ForgeKind)
        case notAuthenticated(ForgeKind)

        var isReady: Bool { self == .ready }

        var message: String? {
            switch self {
            case .ready:
                nil
            case .notInstalled(let kind):
                "\(kind.termLong)功能需要命令行工具。在终端里运行 \(kind.setupHint) 之后重启 Grove。"
            case .notAuthenticated(let kind):
                "\(kind == .github ? "GitHub CLI" : "GitLab CLI") 还没登录。运行 \(kind.setupHint) 之后重启 Grove。"
            }
        }
    }
}

/// 打开过的仓库路径，存在 UserDefaults 里。
///
/// 这里存的是裸路径而不是 security-scoped bookmark，因为 Grove 没开沙盒 ——
/// 一个要调用系统 git、要读任意目录的开发者工具，开沙盒只会处处受限。
/// 不开沙盒就不需要 bookmark，路径本身就够了。
struct RepositoryBookmarks {
    private let key = "grove.repositories"
    private let defaults = UserDefaults.standard

    func load() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    func save(_ paths: [String]) {
        defaults.set(paths, forKey: key)
    }
}
