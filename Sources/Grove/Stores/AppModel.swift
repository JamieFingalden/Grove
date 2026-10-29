import Foundation
import Observation

struct AIReviewGenerationRequest: Sendable {
    var pullRequest: PullRequest
    var files: [FileDiff]
    var customInstructions: String
    var selectedAreas: Set<PullRequestAIReview.Assessment.Area>
    var model: AIGenerationModel
    var reasoningEffort: AIReviewReasoningEffort
    var service: AIGenerationService
    var repositoryRoot: URL
    var threads: [ReviewThread] = []
    var logContext: AIUsageLog.Context = .init()
}

typealias AIReviewGenerator = @Sendable (AIReviewGenerationRequest) async throws -> PullRequestAIReview
typealias AIReviewUpdateNotifier = @Sendable (URL, PullRequest, String) async -> Void

/// 一次操作失败的记录，用于系统通知和用户主动打开的错误详情。
struct GroveFailure: Identifiable, Sendable {
    let id = UUID()
    var title: String
    var context: String? = nil
    var repositoryID: RepoID? = nil
    var detail: String
    /// 面向开发者的原始输出默认收起来，避免一整屏 stderr 冒充用户提示。
    var technicalDetail: String?
    var date: Date

    init(title: String, error: Error) {
        self.title = title
        if let failure = error as? CommandFailure {
            let executable = URL(fileURLWithPath: failure.executable).lastPathComponent
            let reason = Self.commandReason(failure.output)
            self.detail = "\(executable) 执行失败（退出码 \(failure.exitCode)）：\(reason)"
            if let guidance = Self.friendlyCommandMessage(failure.output) {
                self.detail += "\n\(guidance)"
            }
            self.technicalDetail = [failure.commandLine, "退出码：\(failure.exitCode)", failure.output]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        } else if let timeout = error as? CommandTimeout {
            let executable = URL(fileURLWithPath: timeout.executable).lastPathComponent
            self.detail = "\(executable) 执行超过 \(Int(timeout.seconds)) 秒，已停止。请检查命令所访问的服务或网络后重试。"
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

    private static func commandReason(_ output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let errors = lines.filter {
            let line = $0.lowercased()
            return line.hasPrefix("fatal:") || line.hasPrefix("error:")
                || line.contains("failed") || line.contains("http ") || line.contains("失败")
        }
        let reason = (errors.isEmpty ? lines : errors).prefix(3)
            .map { $0.replacingOccurrences(of: #"^(fatal|error):\s*"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
        guard !reason.isEmpty else { return "命令没有返回错误说明。" }
        return reason.count > 500 ? String(reason.prefix(500)) + "…" : reason
    }

    private static func friendlyCommandMessage(_ output: String) -> String? {
        let message = output.lowercased()

        if message.contains("unmerged files")
            || message.contains("needs merge")
            || message.contains("resolve your current index first")
            || message.contains("unresolved conflict") {
            return "还有文件处于冲突状态。先在「冲突」区把每个文件解决并标记为已解决，再继续。"
        }
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
            || message.contains("http basic: access denied")
            || message.contains("not logged into")
            || message.contains("authentication required") {
            return "远端身份验证失败。请检查 Git 凭据或 SSH 密钥，确认当前账号有这个仓库的访问权限后重试。"
        }
        if message.contains("already exists") || message.contains("has already been taken") {
            return "目标已经存在。请检查同名仓库、分支、标签或目录，换一个名称后重试。"
        }
        if message.contains("403") || message.contains("forbidden") {
            return "服务拒绝了当前账号的访问。请检查账号对这个仓库或操作的权限，必要时联系管理员。"
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

        return nil
    }
}

/// 应用顶层状态：工具链、打开的仓库、当前选中项。
@MainActor
@Observable
final class AppModel {
    private struct AIReviewJobKey: Hashable {
        var repositoryPath: String
        var pullRequestNumber: Int

        init(repository: URL, pullRequestNumber: Int) {
            repositoryPath = repository.standardizedFileURL.path
            self.pullRequestNumber = pullRequestNumber
        }
    }

    private struct AIReviewJob {
        var id: UUID
        var serviceName: String
        var head: String?
        var automatic: Bool
        var requestURL: String
    }

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
    private(set) var overviewReady = false

    var repositories: [RepositoryModel] = []
    /// 远程服务器上的仓库。跟本机的分开存：持久化键不同（路径 → 服务器+路径），
    /// 侧边栏分组也不同，但选中和详情视图共用同一套 `RepositoryModel`。
    var remoteRepositories: [RepositoryModel] = []
    private(set) var remoteServers: [RemoteServer] = []
    let navigation: AppNavigationState
    let daily = DailyViewModel()
    let workspace = WorkspaceAggregationService()
    var selection: Selection? { didSet { navigation.selected(selection) } }
    var failures: [GroveFailure] = []
    var presentedFailure: GroveFailure?
    var notificationFallbackFailure: GroveFailure?
    private(set) var isAIGenerationEnabled: Bool
    private(set) var aiProvider: AIGenerationProvider
    private(set) var aiCommitModel: AIGenerationModel
    private(set) var aiReviewModel: AIGenerationModel
    private(set) var aiReviewReasoningEffort: AIReviewReasoningEffort
    private(set) var aiAPIBaseURL: String
    private(set) var aiAPIModel: String
    private(set) var aiAPIThinking: AIAPIThinkingMode
    private(set) var hasAIAPIKey: Bool
    private(set) var codexModels = CodexModelCatalog.defaults
    private(set) var apiModels: [String] = []
    private(set) var isLoadingCodexModels = false
    private(set) var isLoadingAPIModels = false
    private(set) var aiReviewResultsRevision = 0
    private(set) var automaticAIReviewSettingsRevision = 0
    private var aiReviewJobs: [AIReviewJobKey: AIReviewJob] = [:]
    private var pendingAIReviewHeads: [AIReviewJobKey: String] = [:]

    /// 侧边栏选中项。仓库和工作树用同一个枚举，`NavigationSplitView` 的选择才好绑。
    /// 仓库用 `RepoID`（位置 + 路径）做键：不同服务器上可以有同形路径。
    enum Selection: Hashable, Sendable {
        case worktree(repository: RepoID, worktree: URL)
        /// 仓库级的项目主页：PR、CI/CD 等仓库级功能都作为主页里的分栏。
        /// 以后再加仓库级能力只加 tab，侧边栏不再长行。
        case repositoryHome(repository: RepoID)
    }

    private let bookmarks = RepositoryBookmarks()
    private let remoteServerStore: RemoteServerStore
    private let remoteProjectStore: RemoteProjectStore
    /// 用户登记的项目独立于当前连接成功的模型，离线不能抹掉登记。
    @ObservationIgnored private var registeredRemoteProjects: [String: [String]]
    /// 定位一次就够；找不到时远程功能整体禁用（系统 ssh 一定在，这只是防御）。
    @ObservationIgnored private var sshExecutable: URL?
    @ObservationIgnored private let aiGenerationSettings: AIGenerationSettings
    @ObservationIgnored private let aiReviewCache: AIReviewCache
    @ObservationIgnored private let aiReviewGenerator: AIReviewGenerator
    @ObservationIgnored private let aiReviewUpdateNotifier: AIReviewUpdateNotifier
    @ObservationIgnored private let failureNotifier: @Sendable (GroveFailure) async -> Bool
    @ObservationIgnored private var aiReviewTasks: [AIReviewJobKey: Task<Void, Never>] = [:]

    @ObservationIgnored private var automaticAIReviewTask: Task<Void, Never>?
    @ObservationIgnored private var isPollingAutomaticAIReviews = false
    @ObservationIgnored private var automaticAIReviewRetryAfter: [String: Date] = [:]
    @ObservationIgnored private var automaticAIReviewNetworkFailures: [String: Int] = [:]
    @ObservationIgnored private var cancelledAutomaticHeads: [String: String] = [:]

    init(
        aiGenerationSettings: AIGenerationSettings = AIGenerationSettings(),
        navigation: AppNavigationState = AppNavigationState(),
        aiReviewCache: AIReviewCache = AIReviewCache(),
        remoteServerStore: RemoteServerStore = RemoteServerStore(),
        remoteProjectStore: RemoteProjectStore = RemoteProjectStore(),
        failureNotifier: @escaping @Sendable (GroveFailure) async -> Bool = { _ in false },
        aiReviewUpdateNotifier: @escaping AIReviewUpdateNotifier = { root, request, head in
            await AIReviewNotifier.notify(repositoryRoot: root, request: request, head: head)
        },
        aiReviewGenerator: @escaping AIReviewGenerator = { request in
            try await CodexPullRequestReviewGenerator.generate(
                pullRequest: request.pullRequest,
                files: request.files,
                customInstructions: request.customInstructions,
                selectedAreas: request.selectedAreas,
                model: request.model,
                reasoningEffort: request.reasoningEffort,
                service: request.service,
                threads: request.threads,
                context: request.logContext,
                in: request.repositoryRoot
            )
        }
    ) {
        self.navigation = navigation
        self.aiGenerationSettings = aiGenerationSettings
        self.failureNotifier = failureNotifier
        self.aiReviewUpdateNotifier = aiReviewUpdateNotifier
        self.aiReviewCache = aiReviewCache
        self.remoteServerStore = remoteServerStore
        self.remoteProjectStore = remoteProjectStore
        self.registeredRemoteProjects = remoteProjectStore.load()
        self.aiReviewGenerator = aiReviewGenerator
        self.isAIGenerationEnabled = aiGenerationSettings.isEnabled
        self.aiProvider = aiGenerationSettings.provider
        self.aiCommitModel = aiGenerationSettings.commitModel
        self.aiReviewModel = aiGenerationSettings.reviewModel
        self.aiReviewReasoningEffort = aiGenerationSettings.reviewReasoningEffort
        self.aiAPIBaseURL = aiGenerationSettings.apiBaseURL
        self.aiAPIModel = aiGenerationSettings.apiModel
        self.aiAPIThinking = aiGenerationSettings.apiThinking
        self.hasAIAPIKey = aiGenerationSettings.hasAPIKey
    }

    func setAIGenerationEnabled(_ enabled: Bool) {
        aiGenerationSettings.setEnabled(enabled)
        isAIGenerationEnabled = enabled
        if !enabled { cancelAutomaticAIReviews() }
    }

    /// 提交信息与 PR 描述沿用提交模型；Codex 的 Review 则必须保留单独的模型和思考深度。
    var aiService: AIGenerationService? { aiGenerationSettings.service }

    var aiReviewService: AIGenerationService? {
        switch aiProvider {
        case .codex:
            return .codex(model: aiReviewModel, reasoningEffort: aiReviewReasoningEffort)
        case .api:
            return aiGenerationSettings.service
        }
    }

    var availableAIReviewReasoningEfforts: [AIReviewReasoningEffort] {
        codexModels.first { $0.model == aiReviewModel }?.reasoningEfforts
            ?? AIReviewReasoningEffort.available(for: aiReviewModel)
    }

    var canUseAIGeneration: Bool {
        isAIGenerationEnabled && aiService != nil && aiReviewService != nil
    }

    var aiGenerationUnavailableMessage: String {
        guard isAIGenerationEnabled else { return "AI 生成功能已关闭。" }
        if aiProvider == .api {
            return "请在设置中填写 API 地址、模型和密钥。"
        }
        return "AI 服务尚未就绪。"
    }

    func setAIProvider(_ provider: AIGenerationProvider) {
        aiGenerationSettings.setProvider(provider)
        aiProvider = provider
    }

    func setAIAPIBaseURL(_ url: String) {
        aiGenerationSettings.setAPIBaseURL(url)
        aiAPIBaseURL = url
    }

    func setAIAPIModel(_ model: String) {
        aiGenerationSettings.setAPIModel(model)
        aiAPIModel = model
    }

    func setAIAPIThinking(_ mode: AIAPIThinkingMode) {
        aiGenerationSettings.setAPIThinking(mode)
        aiAPIThinking = mode
    }

    func fetchCodexModels() async {
        guard !isLoadingCodexModels else { return }
        isLoadingCodexModels = true
        defer { isLoadingCodexModels = false }
        do {
            codexModels = try await CodexModelCatalog.fetch()
            if !availableAIReviewReasoningEfforts.contains(aiReviewReasoningEffort),
               let first = availableAIReviewReasoningEfforts.first {
                setAIReviewReasoningEffort(first)
            }
        } catch is CancellationError {
            // 用户关闭设置时不显示失败提醒。
        } catch {
            report(title: "获取 Codex 模型失败", error: error, context: "设置 · AI · Codex 模型列表")
        }
    }

    func fetchAPIModels() async {
        guard !isLoadingAPIModels else { return }
        guard let key = AIAPIKeychain.read() else {
            report(title: "获取 API 模型失败", error: AIAPIError.invalidConfiguration, context: "设置 · AI · API 模型列表 · \(aiAPIBaseURL)")
            return
        }
        isLoadingAPIModels = true
        defer { isLoadingAPIModels = false }
        do {
            apiModels = try await OpenAICompatibleRunner.listModels(configuration: .init(
                baseURL: aiAPIBaseURL,
                model: aiAPIModel,
                apiKey: key
            ))
        } catch is CancellationError {
            // 用户关闭设置时不显示失败提醒。
        } catch {
            report(title: "获取 API 模型失败", error: error, context: "设置 · AI · API 模型列表 · \(aiAPIBaseURL)")
        }
    }

    func saveAIAPIKey(_ key: String) throws {
        try aiGenerationSettings.saveAPIKey(key)
        hasAIAPIKey = aiGenerationSettings.hasAPIKey
    }

    func removeAIAPIKey() throws {
        try aiGenerationSettings.removeAPIKey()
        hasAIAPIKey = aiGenerationSettings.hasAPIKey
    }

    func setAICommitModel(_ model: AIGenerationModel) {
        aiGenerationSettings.setCommitModel(model)
        aiCommitModel = model
    }

    func setAIReviewModel(_ model: AIGenerationModel) {
        aiGenerationSettings.setReviewModel(model)
        aiReviewModel = model
        if !availableAIReviewReasoningEfforts.contains(aiReviewReasoningEffort),
           let first = availableAIReviewReasoningEfforts.first {
            setAIReviewReasoningEffort(first)
        }
    }

    func setAIReviewReasoningEffort(_ effort: AIReviewReasoningEffort) {
        guard availableAIReviewReasoningEfforts.contains(effort) else { return }
        aiGenerationSettings.setReviewReasoningEffort(effort)
        aiReviewReasoningEffort = effort
    }

    func aiReviewInstructions(for repository: URL) -> String {
        aiGenerationSettings.reviewInstructions(for: repository)
    }

    func setAIReviewInstructions(_ instructions: String, for repository: URL) {
        aiGenerationSettings.setReviewInstructions(instructions, for: repository)
    }

    func resetAIReviewInstructions(for repository: URL) {
        aiGenerationSettings.resetReviewInstructions(for: repository)
    }

    func aiReviewAreas(for repository: URL) -> Set<PullRequestAIReview.Assessment.Area> {
        aiGenerationSettings.reviewAreas(for: repository)
    }

    func setAIReviewAreas(
        _ areas: Set<PullRequestAIReview.Assessment.Area>,
        for repository: URL
    ) {
        aiGenerationSettings.setReviewAreas(areas, for: repository)
    }

    func cachedAIReview(for repository: URL, pullRequestNumber: Int) -> CachedPullRequestAIReview? {
        aiReviewCache.review(for: repository, pullRequestNumber: pullRequestNumber)
    }

    func saveAIReview(
        _ review: PullRequestAIReview,
        diffFingerprint: String,
        for repository: URL,
        pullRequestNumber: Int,
        head: String? = nil,
        requestURL: String? = nil
    ) {
        aiReviewCache.save(
            review,
            diffFingerprint: diffFingerprint,
            for: repository,
            pullRequestNumber: pullRequestNumber,
            head: head,
            requestURL: requestURL
        )
        aiReviewResultsRevision &+= 1
    }

    func removeCachedAIReview(
        for repository: URL,
        pullRequestNumber: Int,
        requestURL: String? = nil
    ) {
        cancelAIReview(for: repository, pullRequestNumber: pullRequestNumber)
        aiReviewCache.remove(for: repository, pullRequestNumber: pullRequestNumber)
        if let requestURL {
            // 请求已合并 / 关闭：顺手清掉它的自动评审 head 状态，
            // 否则三个按 URL 累积的字典会随历史 PR 无限增长。
            aiGenerationSettings.removeAutomaticReviewState(for: requestURL)
        }
        aiReviewResultsRevision &+= 1
    }

    func isAIReviewing(for repository: URL, pullRequestNumber: Int) -> Bool {
        aiReviewJobs[AIReviewJobKey(
            repository: repository,
            pullRequestNumber: pullRequestNumber
        )] != nil
    }

    func aiReviewingModel(for repository: URL, pullRequestNumber: Int) -> String? {
        aiReviewJobs[AIReviewJobKey(
            repository: repository,
            pullRequestNumber: pullRequestNumber
        )]?.serviceName
    }

    var activeAIReviewCount: Int { aiReviewJobs.count }

    func hasPendingAIReview(for repository: URL, pullRequestNumber: Int) -> Bool {
        pendingAIReviewHeads[AIReviewJobKey(repository: repository, pullRequestNumber: pullRequestNumber)] != nil
    }

    /// 用户点击通知里的按钮才进入这条路径，重新读取最新提交与历史讨论。
    /// confirmedByUser：这是用户明确确认的重审，发布策略跟自动链路走
    /// （项目开了「自动发布」就发布）；纯手动 Review 不在此列。
    func startRequestedAIReview(for root: URL, pullRequestNumber: Int) {
        guard canUseAIGeneration, !isAIReviewing(for: root, pullRequestNumber: pullRequestNumber), let service = aiReviewService,
              let repository = repositories.first(where: { $0.root == root }),
              let request = repository.pullRequests.first(where: { $0.number == pullRequestNumber && $0.isActive }) else { return }
        startAIReview(.init(pullRequest: request, files: [], customInstructions: aiReviewInstructions(for: root),
                            selectedAreas: aiReviewAreas(for: root), model: aiReviewModel,
                            reasoningEffort: aiReviewReasoningEffort, service: service, repositoryRoot: root),
                      confirmedByUser: true)
    }

    func automaticAIReviewEnabled(for repository: URL) -> Bool {
        _ = automaticAIReviewSettingsRevision
        return aiGenerationSettings.automaticReviewEnabled(for: repository)
    }

    func setAutomaticAIReviewEnabled(_ enabled: Bool, for repository: URL) {
        aiGenerationSettings.setAutomaticReviewEnabled(enabled, for: repository)
        automaticAIReviewSettingsRevision &+= 1
        if !enabled { cancelAutomaticAIReviews(for: repository) }
    }

    /// 自动审查的风险发现是否自动发布到平台讨论区。默认关闭。
    func automaticAIReviewPublishEnabled(for repository: URL) -> Bool {
        _ = automaticAIReviewSettingsRevision
        return aiGenerationSettings.automaticReviewPublishEnabled(for: repository)
    }

    func setAutomaticAIReviewPublishEnabled(_ enabled: Bool, for repository: URL) {
        aiGenerationSettings.setAutomaticReviewPublishEnabled(enabled, for: repository)
        automaticAIReviewSettingsRevision &+= 1
    }

    private func cancelAutomaticAIReviews(for repository: URL? = nil) {
        for (key, job) in aiReviewJobs where job.automatic {
            if let repository, key.repositoryPath != repository.standardizedFileURL.path { continue }
            aiReviewTasks.removeValue(forKey: key)?.cancel()
            aiReviewJobs.removeValue(forKey: key)
        }
    }

    private func startAutomaticAIReviewMonitoring() {
        guard automaticAIReviewTask == nil else { return }
        automaticAIReviewTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollAutomaticAIReviews()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    func pollAutomaticAIReviews(now: Date = Date()) async {
        guard !isPollingAutomaticAIReviews, canUseAIGeneration, let service = aiReviewService else { return }
        isPollingAutomaticAIReviews = true
        defer { isPollingAutomaticAIReviews = false }
        for repository in repositories where !repository.isRemote && automaticAIReviewEnabled(for: repository.root) {
            guard !Task.isCancelled else { return }
            guard let forge = repository.forge else { continue }
            let expectedOrigin = repository.origin
            let retryKey = repository.root.path
            guard (automaticAIReviewRetryAfter[retryKey] ?? .distantPast) <= now else { continue }
            var step = "读取开放 PR 列表"
            do {
                // ponytail: 每轮最多检查 1000 个开放请求；超大仓库可改为平台事件订阅。
                let requests = try await forge.pullRequests(in: repository.root, limit: RepositoryModel.openPullRequestLimit, state: .open)
                guard repository.origin == expectedOrigin, repositories.contains(where: { $0 === repository }) else { continue }
                repository.updateOpenPullRequests(requests, fromOrigin: expectedOrigin)
                let activeNumbers = Set(requests.filter(\.isActive).map(\.number))
                pendingAIReviewHeads = pendingAIReviewHeads.filter {
                    $0.key.repositoryPath != repository.root.standardizedFileURL.path || activeNumbers.contains($0.key.pullRequestNumber)
                }
                for (key, job) in aiReviewJobs where job.automatic && key.repositoryPath == repository.root.standardizedFileURL.path {
                    if !activeNumbers.contains(key.pullRequestNumber) {
                        aiReviewTasks.removeValue(forKey: key)?.cancel()
                        aiReviewJobs.removeValue(forKey: key)
                    }
                }
                for request in requests where request.isActive {
                    guard !Task.isCancelled, canUseAIGeneration, automaticAIReviewEnabled(for: repository.root),
                          repository.origin == expectedOrigin else { break }
                    step = "PR #\(request.number) · 读取最新提交 · \(request.url)"
                    let head: String
                    if let listedHead = request.headRefOid, !listedHead.isEmpty {
                        head = listedHead
                    } else {
                        head = try await forge.reviewHead(number: request.number, in: repository.root)
                    }
                    guard !Task.isCancelled, repository.origin == expectedOrigin else { break }
                    guard !head.isEmpty else { continue }
                    let key = AIReviewJobKey(repository: repository.root, pullRequestNumber: request.number)
                    if let job = aiReviewJobs[key], !job.automatic || job.head == head { continue }
                    if let job = aiReviewJobs[key], job.automatic {
                        cancelAIReview(for: repository.root, pullRequestNumber: request.number, suppressAutomatic: false)
                    }
                    let reviewedHead = aiGenerationSettings.automaticReviewHead(for: request.url)
                    if reviewedHead == head {
                        pendingAIReviewHeads.removeValue(forKey: key)
                        continue
                    }
                    let initialHead = aiGenerationSettings.initialReviewHead(for: request.url)
                    let cached = cachedAIReview(for: repository.root, pullRequestNumber: request.number)
                    let previous = cached.flatMap { $0.requestURL == nil || $0.requestURL == request.url ? $0 : nil }
                    let hasNewCommit = reviewedHead != nil
                        || (initialHead.map { $0 != head } ?? (previous != nil && previous?.head != head))
                    if hasNewCommit {
                        pendingAIReviewHeads[key] = head
                        if !aiGenerationSettings.hasNotifiedReviewHead(head, for: request.url) {
                            aiGenerationSettings.setNotifiedReviewHead(head, for: request.url)
                            await aiReviewUpdateNotifier(repository.root, request, head)
                        }
                        continue
                    }
                    guard cancelledAutomaticHeads[request.url] != head,
                          (automaticAIReviewRetryAfter["\(request.url):\(head)"] ?? .distantPast) <= now,
                          activeAIReviewCount < 2 else { continue }
                    if initialHead == nil { aiGenerationSettings.setInitialReviewHead(head, for: request.url) }
                    startAIReview(.init(
                        pullRequest: request, files: [],
                        customInstructions: aiReviewInstructions(for: repository.root),
                        selectedAreas: aiReviewAreas(for: repository.root), model: aiReviewModel,
                        reasoningEffort: aiReviewReasoningEffort, service: service,
                        repositoryRoot: repository.root
                    ), automatic: true, expectedHead: head)
                }
                automaticAIReviewNetworkFailures.removeValue(forKey: retryKey)
                automaticAIReviewRetryAfter.removeValue(forKey: retryKey)
            } catch is CancellationError {
                return
            } catch {
                if AIReviewAutomation.isTransientNetworkFailure(error) {
                    let previous = automaticAIReviewNetworkFailures[retryKey] ?? 0
                    let failures = min(previous + 1, 3)
                    automaticAIReviewNetworkFailures[retryKey] = failures
                    automaticAIReviewRetryAfter[retryKey] = now.addingTimeInterval(failures < 3 ? 60 : 300)
                    // 短暂断网先等下一轮；持续失败只通知一次，完整检查成功后重置。
                    guard failures == 3, previous < 3 else { continue }
                } else {
                    automaticAIReviewNetworkFailures.removeValue(forKey: retryKey)
                    automaticAIReviewRetryAfter[retryKey] = now.addingTimeInterval(300)
                }
                report(title: "自动 AI Review 检查失败", error: error, repository: repository, context: step)
            }
        }
    }

    /// - Parameter confirmedByUser: 用户在通知里点了「重新审查」——重审本身是
    ///   用户明确发起的，发布策略跟随自动链路的项目开关。
    func startAIReview(
        _ request: AIReviewGenerationRequest,
        automatic: Bool = false,
        expectedHead: String? = nil,
        confirmedByUser: Bool = false
    ) {
        let key = AIReviewJobKey(repository: request.repositoryRoot, pullRequestNumber: request.pullRequest.number)
        cancelAIReview(for: request.repositoryRoot, pullRequestNumber: request.pullRequest.number, suppressAutomatic: false)
        pendingAIReviewHeads.removeValue(forKey: key)
        let repository = repositories.first { $0.root == request.repositoryRoot }
        let forge = repository?.forge
        let expectedOrigin = repository?.origin
        let jobID = UUID()
        aiReviewJobs[key] = AIReviewJob(id: jobID, serviceName: request.service.displayName, head: expectedHead, automatic: automatic, requestURL: request.pullRequest.url)
        aiReviewTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            var input = request
            var head = expectedHead
            var step = "准备评审"
            @MainActor func validate() async throws {
                try Task.checkCancellation()
                guard aiReviewJobs[key]?.id == jobID else { throw CancellationError() }
                if automatic {
                    guard canUseAIGeneration, automaticAIReviewEnabled(for: input.repositoryRoot) else { throw CancellationError() }
                }
                if let repository, let forge {
                    step = "校验 PR 状态与提交版本"
                    guard repository.origin == expectedOrigin,
                          repositories.contains(where: { $0 === repository }) else { throw CancellationError() }
                    let fresh = try await forge.pullRequest(number: input.pullRequest.number, in: input.repositoryRoot)
                    guard fresh.isActive, fresh.url == request.pullRequest.url else { throw CancellationError() }
                    guard try await forge.reviewHead(number: fresh.number, in: input.repositoryRoot) == head else {
                        throw ReviewDiscussionError.changedHead
                    }
                    try Task.checkCancellation()
                    guard repository.origin == expectedOrigin, aiReviewJobs[key]?.id == jobID else { throw CancellationError() }
                }
            }
            do {
                if let forge {
                    step = "读取最新提交"
                    head = try await forge.reviewHead(number: input.pullRequest.number, in: input.repositoryRoot)
                    if let expectedHead, head != expectedHead { throw ReviewDiscussionError.changedHead }
                    try Task.checkCancellation()
                    guard aiReviewJobs[key]?.id == jobID else { throw CancellationError() }
                    aiReviewJobs[key]?.head = head
                    if let head, aiGenerationSettings.initialReviewHead(for: input.pullRequest.url) == nil {
                        aiGenerationSettings.setInitialReviewHead(head, for: input.pullRequest.url)
                    }
                    step = "读取 PR 详情"
                    input.pullRequest = try await forge.pullRequest(number: input.pullRequest.number, in: input.repositoryRoot)
                    step = "读取 PR 差异"
                    input.files = try await forge.pullRequestDiff(number: input.pullRequest.number, in: input.repositoryRoot)
                    step = "读取评审讨论"
                    input.threads = try await forge.reviewThreads(number: input.pullRequest.number, in: input.repositoryRoot)
                } else if automatic { throw ReviewDiscussionError.unavailable }
                // 发布链路的去重与回复匹配只信任当前用户自己的评论——
                // marker 是明文，平台上任何人都能复制伪造；见
                // AIReviewAutomation.contains。只在这次会发布时取一次身份。
                let publishesFindings = (automatic || confirmedByUser)
                    && aiGenerationSettings.automaticReviewPublishEnabled(for: input.repositoryRoot)
                var trustedAuthor: String?
                if publishesFindings, let forge {
                    trustedAuthor = try? await forge.currentUser(in: input.repositoryRoot)
                }
                try await validate()
                if automatic, let head,
                   AIReviewAutomation.contains(
                       AIReviewAutomation.marker(head: head, area: "complete"),
                       in: input.threads, trustedAuthor: trustedAuthor
                   ) {
                    aiGenerationSettings.setAutomaticReviewHead(head, for: input.pullRequest.url)
                    finishAIReview(key: key, jobID: jobID)
                    return
                }
                let cached = cachedAIReview(for: input.repositoryRoot, pullRequestNumber: input.pullRequest.number)
                let fingerprint = AIReviewCache.diffFingerprint(input.files)
                let result: PullRequestAIReview
                if automatic, let cached, cached.head == head, cached.requestURL == input.pullRequest.url, cached.diffFingerprint == fingerprint {
                    result = cached.review
                } else {
                    input.logContext = .init(trigger: automatic ? "自动" : "手动",
                                             pullRequestNumber: input.pullRequest.number, head: head)
                    step = "\(input.service.displayName) · 生成 AI 评审"
                    result = try await aiReviewGenerator(input)
                }
                try await validate()
                saveAIReview(result, diffFingerprint: fingerprint, for: input.repositoryRoot,
                             pullRequestNumber: input.pullRequest.number, head: head, requestURL: input.pullRequest.url)
                // 「这个 head 已完成」的记录时机分两种：
                // - 发布（未开启、或非自动/非确认路径）：保存即完成——不记录的话
                //   60 秒轮询会对同一个 head 无限重复评审。
                // - 发布：全部风险发现发完才记录。部分发布失败时保持未记录，
                //   下一轮轮询用缓存结果重试补发，不会重新生成。
                // 发布与生成分离：只有自动链路（或用户在通知里确认的重审）、且该项目
                // 显式开启了「自动发布」，风险发现才以用户账号发到平台讨论区。
                // 纯手动 Review 一律不自动发布，结果保留在本地，
                // 由详情页的「添加讨论…」逐条发布。
                if publishesFindings, let forge, let head {
                    for assessment in result.discussionFindings {
                        let marker = AIReviewAutomation.marker(head: head, area: AIReviewAutomation.issueKey(assessment))
                        if AIReviewAutomation.contains(marker, in: input.threads, trustedAuthor: trustedAuthor) { continue }
                        try await validate()
                        let body = AIReviewAutomation.body(for: assessment, head: head)
                        if let thread = AIReviewAutomation.existingDiscussion(for: assessment, threads: input.threads, trustedAuthor: trustedAuthor) {
                            step = "回复评审讨论 \(thread.id)"
                            try await forge.reply(number: input.pullRequest.number, thread: thread, body: body, in: input.repositoryRoot)
                        } else {
                            step = "发布评审讨论\(assessment.file.map { " · \($0)" } ?? "")"
                            try await forge.createDiscussion(number: input.pullRequest.number, body: body,
                                location: AIReviewAutomation.location(for: assessment, files: input.files),
                                expectedHead: head, in: input.repositoryRoot)
                        }
                    }
                    try await validate()
                    try Task.checkCancellation()
                    aiGenerationSettings.setAutomaticReviewHead(head, for: input.pullRequest.url)
                    pendingAIReviewHeads.removeValue(forKey: key)
                    aiReviewResultsRevision &+= 1
                } else if let head {
                    aiGenerationSettings.setAutomaticReviewHead(head, for: input.pullRequest.url)
                    pendingAIReviewHeads.removeValue(forKey: key)
                    aiReviewResultsRevision &+= 1
                }
            } catch is CancellationError {
                // 用户取消、请求结束或设置关闭时静默停止。
            } catch ReviewDiscussionError.changedHead {
                // 下一轮仅提醒新提交，旧版本的结果不能继续发布。
            } catch {
                if aiReviewJobs[key]?.id == jobID {
                    if automatic { automaticAIReviewRetryAfter["\(input.pullRequest.url):\(head ?? "")"] = Date().addingTimeInterval(300) }
                    let source = repository == nil ? "\(input.repositoryRoot.lastPathComponent) · 本机 · \(input.repositoryRoot.path) · " : ""
                    report(title: automatic ? "自动 AI Review 失败" : "AI Review 失败", error: error,
                           repository: repository, context: "\(source)PR #\(input.pullRequest.number) · \(step) · \(input.pullRequest.url)")
                }
            }
            finishAIReview(key: key, jobID: jobID)
        }
    }

    func cancelAIReview(for repository: URL, pullRequestNumber: Int, suppressAutomatic: Bool = true) {
        let key = AIReviewJobKey(repository: repository, pullRequestNumber: pullRequestNumber)
        if suppressAutomatic, let job = aiReviewJobs[key], job.automatic, let head = job.head {
            cancelledAutomaticHeads[job.requestURL] = head
        }
        aiReviewTasks.removeValue(forKey: key)?.cancel()
        aiReviewJobs.removeValue(forKey: key)
    }

    private func finishAIReview(key: AIReviewJobKey, jobID: UUID) {
        guard aiReviewJobs[key]?.id == jobID else { return }
        aiReviewTasks.removeValue(forKey: key)
        aiReviewJobs.removeValue(forKey: key)
    }

    // MARK: - 启动

    /// bootstrap 只跑一次：多窗口（⌘N）会让第二个 RootView 的 `.task`
    /// 再触发一次，恢复流程重入会把内存里的仓库翻倍。
    @ObservationIgnored private var didBootstrap = false

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        Task { await AIUsageLog.shared.startMaintenance() }
        // 评审缓存装载（旧 UserDefaults 存储在此一次性迁移到 Caches 目录）。
        // 装载完成前的读取按未命中处理；完成后 bump 修订计数，
        // 让可能已经渲染过的缓存角标刷新。
        await aiReviewCache.loadIfNeeded()
        aiReviewResultsRevision &+= 1

        do {
            git = try await GitClient.resolve()
        } catch {
            report(title: "无法启动", error: error, context: "Grove · 启动 · 查找 Git 工具")
            toolsReady = true
            return
        }

        // git 就绪后界面已经能工作，托管商和旧仓库恢复都放到后台并发进行。
        // 一台离线的自建 GitLab 不应该把整个窗口锁在「正在准备」一分钟。
        toolsReady = true

        // ssh 先定位再恢复远程仓库：远程的 GitClient 构造要用它。
        // 定位本身很快（/usr/bin/ssh 在候选目录首位）。
        async let sshLocation: URL? = ToolLocator.shared.locate("ssh")
        async let repositoryRestore: Void = restoreBookmarkedRepositories()
        await detectForges()
        await repositoryRestore
        // 顺手清一次「路径已不在本机且未打开」的仓库的项目级 AI 设置——
        // 提示词/审查范围/自动审查/自动发布四个字典只有这里能收敛。
        aiGenerationSettings.pruneRepositorySettings(keeping: repositories.map(\.root))
        overviewReady = true
        sshExecutable = await sshLocation
        // 本地评审入口不等 SSH 环境恢复，也不等其他项目的网络请求。
        navigation.restore(in: self)
        async let forgeRefresh: Void = refreshLocalForgeMetadata()
        await restoreRemoteRepositories()
        navigation.restore(in: self)
        await forgeRefresh
        startAutomaticAIReviewMonitoring()

        // CI 状态点（工作树行的绿红点）也在这个时候首次拉取；
        // 之后靠抓取/刷新和 CI 分栏的轮询续命。
        await withTaskGroup(of: Void.self) { group in
            for repository in repositories where repository.forge != nil {
                group.addTask { await repository.refreshPipelineStatuses() }
            }
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

    func forge(of kind: ForgeKind) -> (any ForgeClient)? {
        switch kind {
        case .github: github
        case .gitlab: gitlab
        }
    }

    func configuredHosts(for kind: ForgeKind) -> [String] {
        let hosts = switch kind {
        case .github: githubHosts
        case .gitlab: gitlabHosts
        }
        return hosts.sorted()
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

        await refreshLocalForgeMetadata()
    }

    /// 所有本地入口先更新，再限制并发加载列表，单个项目不会挡住其他项目。
    private func refreshLocalForgeMetadata() async {
        let locals = repositories
        for repository in locals { repository.resolveForgeMetadata() }
        await withTaskGroup(of: Void.self) { group in
            var iterator = locals.filter { $0.forge != nil && $0.slug != nil }.makeIterator()
            for _ in 0..<3 {
                if let repository = iterator.next() { group.addTask { await repository.refreshPullRequests(ifNeeded: true) } }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let repository = iterator.next() { group.addTask { await repository.refreshPullRequests(ifNeeded: true) } }
            }
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
                selectDefaultWorktree(in: repository, restoring: true)
            }
        }
        bookmarks.save(repositories.map(\.root.path))

        if selection == nil, let first = repositories.first {
            selectDefaultWorktree(in: first, restoring: true)
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
            report(title: "打开仓库失败", error: GroveError.notARepository(url), context: "本机 · \(url.path)")
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
        clearSelectionIfPointing(at: repository.id)
    }

    /// 选中项如果正指着这个仓库（主页或它的某个工作树），清掉。
    private func clearSelectionIfPointing(at id: RepoID) {
        switch selection {
        case .worktree(let repository, _), .repositoryHome(let repository):
            if repository == id { selection = nil }
        case nil:
            break
        }
    }

    func selectDefaultWorktree(in repository: RepositoryModel, restoring: Bool = false) {
        guard !restoring || !navigation.hasUserNavigated else { return }
        guard let worktree = repository.worktrees.first else { return }
        if restoring {
            navigation.withRestoration { selection = .worktree(repository: repository.id, worktree: worktree.path) }
        } else {
            selection = .worktree(repository: repository.id, worktree: worktree.path)
        }
    }

    // MARK: - 远程服务器

    /// 远程仓库的 git 客户端。ssh 还没定位好（理论上不会）返回 nil。
    /// 构造时以 `root` 为探查目录，把远端缺失的 user.name/user.email 用本机的
    /// 补上 —— 服务器常常没配身份，直接提交会报 "Committer identity unknown"。
    func remoteGitClient(for server: RemoteServer, probingRepoAt root: URL) async -> GitClient? {
        guard let sshExecutable else { return nil }
        return await GitClient.remote(
            server, sshExecutable: sshExecutable, identityFallbackFrom: git, probingRepoAt: root
        )
    }

    /// 侧边栏「测试连接」用：不经过 AppModel 状态，直接起一个通道探测。
    func remoteTransport(for server: RemoteServer) -> SSHTransport? {
        guard let sshExecutable else { return nil }
        return SSHTransport(sshExecutable: sshExecutable, server: server)
    }

    func addRemoteServer(_ server: RemoteServer) {
        remoteServers.append(server)
        remoteServers.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        remoteServerStore.save(remoteServers)
    }

    /// 编辑服务器后同步：持久化、按新配置重建它的仓库模型
    /// （主机 / 端口 / 用户变了，绑定的 GitClient 全部作废）。
    func updateRemoteServer(_ server: RemoteServer) async {
        guard let index = remoteServers.firstIndex(where: { $0.id == server.id }) else { return }
        remoteServers[index] = server
        remoteServerStore.save(remoteServers)

        let paths = registeredRemoteProjects[server.id.uuidString] ?? []
        for repository in remoteRepositories where repository.server?.id == server.id {
            clearSelectionIfPointing(at: repository.id)
        }
        remoteRepositories.removeAll { $0.server?.id == server.id }
        for path in paths {
            await addRemoteProject(path, on: server)
        }
        persistRemoteProjects()
    }

    func removeRemoteServer(_ server: RemoteServer) {
        remoteServers.removeAll { $0.id == server.id }
        remoteServerStore.save(remoteServers)
        for repository in remoteRepositories where repository.server?.id == server.id {
            clearSelectionIfPointing(at: repository.id)
        }
        remoteRepositories.removeAll { $0.server?.id == server.id }
        registeredRemoteProjects.removeValue(forKey: server.id.uuidString)
        persistRemoteProjects()
    }

    /// 某台服务器下的仓库，按名字排序（侧边栏分组用）。
    func remoteRepositories(for server: RemoteServer) -> [RepositoryModel] {
        remoteRepositories.filter { $0.server?.id == server.id }
    }

    /// 添加远程项目。路径先用远端 git 归一化成仓库根目录，失败返回 nil 并报错。
    @discardableResult
    func addRemoteProject(_ path: String, on server: RemoteServer) async -> RepositoryModel? {
        guard let transport = remoteTransport(for: server) else {
            report(title: "连接 \(server.displayName) 失败", error: GroveError.sshNotFound,
                   context: "\(server.displayName) · \(server.destination) · \(path)")
            return nil
        }

        let entered = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = await transport.repositoryRoot(forPath: entered) else {
            report(title: "添加远程仓库失败",
                   detail: "「\(entered)」在 \(server.destination) 上不是一个 git 仓库（或目录不存在）。",
                   context: "\(server.displayName) · \(server.destination) · \(entered)")
            return nil
        }
        // 连接确认可用之后再补身份 —— 那本身是一次 SSH 往返，不该让连不上的
        // 服务器先多等一轮超时。
        guard let git = await remoteGitClient(for: server, probingRepoAt: root) else { return nil }
        guard remoteServers.contains(server) else { return nil }

        var paths = registeredRemoteProjects[server.id.uuidString] ?? []
        paths.removeAll { $0 == entered && $0 != root.path }
        if !paths.contains(root.path) { paths.append(root.path) }
        registeredRemoteProjects[server.id.uuidString] = paths
        persistRemoteProjects()

        if let existing = remoteRepositories.first(where: { $0.root.path == root.path && $0.server?.id == server.id }) {
            selectDefaultWorktree(in: existing)
            return existing
        }

        let repository = RepositoryModel(root: root, git: git, app: self, server: server)
        remoteRepositories.append(repository)

        await repository.refresh(loadForgeMetadata: false)
        if remoteRepositories.contains(where: { $0 === repository }) {
            selectDefaultWorktree(in: repository)
        }
        return repository
    }

    func closeRemoteProject(_ repository: RepositoryModel) {
        remoteRepositories.removeAll { $0.id == repository.id }
        clearSelectionIfPointing(at: repository.id)
        if let serverID = repository.server?.id.uuidString {
            registeredRemoteProjects[serverID]?.removeAll { $0 == repository.root.path }
        }
        persistRemoteProjects()
    }

    /// 只写用户登记；连接成功与否不影响持久化记录。
    private func persistRemoteProjects() {
        registeredRemoteProjects = registeredRemoteProjects.mapValues { paths in
            var seen = Set<String>()
            return paths.filter { seen.insert($0).inserted }
        }
        remoteProjectStore.save(registeredRemoteProjects)
    }

    /// 启动恢复：逐台服务器、逐个路径重建仓库模型。连不上的跳过 ——
    /// 状态点会红，等网络好了手动刷新，不该用一串报错迎接用户。
    ///
    /// 全量重建（先清空）而不是追加：恢复期间主线程会因 SSH 往返挂起，
    /// 用户此刻添加的项目会交错进来；追加式恢复跑两遍或与用户操作交错，
    /// 就会出现同一仓库两份 —— 侧边栏里整个项目的工作树全部翻倍。
    private func restoreRemoteRepositories() async {
        remoteServers = remoteServerStore.load()
        let stored = registeredRemoteProjects

        remoteRepositories.removeAll()

        for server in remoteServers {
            // 先探一次连接：服务器不在线时一次探测就完事，
            // 不用每个项目都各等一次连接超时。身份补齐也放在连接确认之后 ——
            // 它本身是一次 SSH 往返。
            guard let transport = remoteTransport(for: server),
                  (try? await transport.probe()) != nil,
                  remoteServers.contains(server) else {
                continue
            }
            // 同一服务器下同路径只留第一份 —— 存储可能已经被写坏过；
            // 用户也可能在恢复的 SSH 往返间隙已经把同一个项目加进来了。
            // 身份补齐跟着仓库走（探查以仓库根目录为工作目录，仓库级配置才
            // 看得见），所以放在拿到 root 之后逐仓库构造。
            var seenPaths = Set<String>()
            for path in stored[server.id.uuidString] ?? [] {
                guard seenPaths.insert(path).inserted else { continue }
                guard let root = await transport.repositoryRoot(forPath: path),
                      remoteServers.contains(server),
                      registeredRemoteProjects[server.id.uuidString]?.contains(path) == true else { continue }
                if path != root.path {
                    registeredRemoteProjects[server.id.uuidString]?.removeAll { $0 == path }
                    registeredRemoteProjects[server.id.uuidString]?.append(root.path)
                }
                guard !remoteRepositories.contains(where: {
                    $0.server?.id == server.id && $0.root.path == root.path
                }) else { continue }
                guard let git = await remoteGitClient(for: server, probingRepoAt: root) else { continue }
                let repository = RepositoryModel(root: root, git: git, app: self, server: server)
                remoteRepositories.append(repository)
            }
        }

        guard !remoteRepositories.isEmpty else { return }
        // 并发刷新所有远程仓库；无法连接的登记留待下次恢复。
        await withTaskGroup(of: Void.self) { group in
            for repository in remoteRepositories {
                group.addTask { await repository.refresh(loadForgeMetadata: false) }
            }
        }
        remoteRepositories.sort {
            let serverOrder = ($0.server?.displayName ?? "").localizedStandardCompare($1.server?.displayName ?? "")
            return serverOrder == .orderedSame
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : serverOrder == .orderedAscending
        }
        persistRemoteProjects()

        // 本机和远程都有仓库时，默认进本机的第一个 —— 那是响应最快的一个。
        if selection == nil, repositories.isEmpty, let first = remoteRepositories.first {
            selectDefaultWorktree(in: first, restoring: true)
        }
    }

    // MARK: - 查找

    var allRepositories: [RepositoryModel] {
        repositories + remoteRepositories
    }

    // MARK: - 项目分组（侧边栏）

    /// 侧边栏以**项目**为单位：同一项目的本地副本和远程副本按归一化后的
    /// origin 合并成一组，工作树行上再用位置标记（本机 / 服务器名）区分。
    /// 认不出 origin 的仓库（没配远端）各自成组，永不合并。
    struct ProjectGroup: Identifiable {
        var key: String
        var name: String
        var locals: [RepositoryModel]
        /// 各台服务器上的副本，按服务器排序。
        var remotes: [RepositoryModel]

        var id: String { key }
        var local: RepositoryModel? { locals.first }
        var repositories: [RepositoryModel] { locals + remotes }
        /// 主页入口指向哪个仓库：本地优先（PR / CI 只在本地可用）。
        var homeRepository: RepositoryModel? { local ?? remotes.first }
        /// 本地和远程副本同时存在 —— 工作树行需要位置标记来区分。
        var isMixed: Bool { local != nil && !remotes.isEmpty }

        /// 组内全部工作树，按服务器身份与路径去重。同一个仓库可能被打开成多个条目
        /// （比如把各个工作树目录分别拖进 Grove），每个条目都会列出全部
        /// 工作树 —— 不去重的话每行要出现 N 遍。远端路径不经过本机符号链接解析。
        @MainActor
        var mergedWorktrees: [(id: RepoID, worktree: Worktree, repository: RepositoryModel)] {
            var seen = Set<RepoID>()
            var merged: [(RepoID, Worktree, RepositoryModel)] = []
            for repository in repositories {
                for worktree in repository.worktrees {
                    let id = RepoID(location: repository.location, root: worktree.path)
                    guard seen.insert(id).inserted else { continue }
                    merged.append((id, worktree, repository))
                }
            }
            return merged
        }
    }

    var projects: [ProjectGroup] {
        var groups: [String: ProjectGroup] = [:]
        var order: [String] = []

        for repository in allRepositories {
            let key: String
            if let origin = repository.origin {
                // 忽略 scheme 和端口差异：http/ssh、带不带端口访问的都是同一座仓库。
                key = "origin:\(origin.host.lowercased()):\(origin.path)"
            } else {
                key = "solo:\(repository.id.identityKey)"
            }

            if groups[key] == nil {
                order.append(key)
                groups[key] = ProjectGroup(key: key, name: repository.name, locals: [], remotes: [])
            }
            if repository.isRemote {
                groups[key]?.remotes.append(repository)
            } else {
                if groups[key]?.locals.contains(where: { $0.id == repository.id }) == false {
                    groups[key]?.locals.append(repository)
                }
            }
        }

        // 名字以本地副本为准（服务器上的目录名可能不同）。
        var result = order.map { groups[$0]! }
        for index in result.indices {
            if let local = result[index].local {
                result[index].name = local.name
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func repository(matching id: RepoID) -> RepositoryModel? {
        allRepositories.first { $0.id == id }
    }

    var selectedRepository: RepositoryModel? {
        guard navigation.page == .repositories else { return nil }
        return switch selection {
        case .worktree(let repositoryID, _): repository(matching: repositoryID)
        case .repositoryHome(let repositoryID): repository(matching: repositoryID)
        case nil: nil
        }
    }

    var selectedWorktreeModel: WorktreeModel? {
        guard case .worktree(let repositoryID, let path) = selection,
              let model = repository(matching: repositoryID) else { return nil }
        return model.worktreeModel(for: path)
    }

    // MARK: - 错误

    func report(_ failure: GroveFailure, repository: RepositoryModel? = nil, context: String? = nil) {
        var failure = failure
        if let repository {
            failure.repositoryID = repository.id
            let server = repository.server.map { "\($0.displayName)（\($0.destination)）" } ?? "本机"
            failure.context = "\(repository.name) · \(server) · \(repository.root.path)"
        }
        failure.context = [failure.context, context].compactMap { $0 }.joined(separator: "\n")
        if failure.context?.isEmpty != false { failure.context = "Grove · 应用" }
        guard !failures.contains(where: {
            $0.title == failure.title && $0.repositoryID == failure.repositoryID && $0.context == failure.context
                && $0.detail == failure.detail && $0.technicalDetail == failure.technicalDetail
                && failure.date.timeIntervalSince($0.date) < 60
        }) else { return }
        failures.append(failure)
        // 最近记录只用于短时间去重；详情随通知保存，不依赖这份缓存。
        if failures.count > 4 { failures.removeFirst(failures.count - 4) }
        Task { [weak self, failureNotifier, failure] in
            guard !(await failureNotifier(failure)), let self else { return }
            // 授权等待可能让旧请求晚于新请求返回，不能把最新的兜底错误覆盖掉。
            guard (notificationFallbackFailure?.date ?? .distantPast) <= failure.date else { return }
            notificationFallbackFailure = failure
        }
    }

    func report(title: String, error: Error, repository: RepositoryModel? = nil, context: String? = nil) {
        // 取消不是失败：SwiftUI 的 .task 在视图切走 / 选中项变化时会取消
        // 进行中的请求，ProcessRunner 忠实地抛 CancellationError。把它当失败
        // 发通知，用户看到的就是那句莫名其妙的「未能完成操作」。
        guard !(error is CancellationError) else { return }
        report(GroveFailure(title: title, error: error), repository: repository, context: context)
    }

    func report(title: String, detail: String, repository: RepositoryModel? = nil, context: String? = nil) {
        report(GroveFailure(title: title, detail: detail), repository: repository, context: context)
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
