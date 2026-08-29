import Foundation

/// 通过 GitHub CLI（`gh`）访问 PR。
///
/// 为什么用 `gh` 而不是直接调 GitHub REST/GraphQL API：认证。用 API 就得自己做
/// OAuth device flow、把 token 存进 Keychain、处理过期刷新、还要引导用户建 PAT。
/// 而 `gh` 已经把这些做完了，绝大多数会用 worktree 的人机器上本来就有它。
/// 于是 Grove 不碰任何凭据 —— 没有 token 落盘，也就没有泄露面。
///
/// 代价是多一个外部依赖。所以 `gh` 缺失或未登录时，PR 功能整块降级、
/// git 功能完全不受影响（见 `PullRequestStore` 里的 availability 处理）。
struct GitHubClient: ForgeClient {
    let executable: URL
    let environment: [String: String]

    var kind: ForgeKind { .github }

    /// 列表视图要的字段。刻意不含 `body` —— PR 正文可能几十 KB，
    /// 列一屏 30 个 PR 就是几 MB 的无用传输，正文留到详情页再单独取。
    private static let listFields = [
        "number", "title", "state", "isDraft", "headRefName", "baseRefName",
        "url", "author", "updatedAt", "additions", "deletions", "changedFiles",
        "reviewDecision", "mergeable", "isCrossRepository", "labels",
        "statusCheckRollup", "headRepositoryOwner"
    ].joined(separator: ",")

    private static let detailFields = listFields + ",body"

    static func resolve() async -> GitHubClient? {
        guard let executable = await ToolLocator.shared.locate("gh") else { return nil }
        return GitHubClient(
            executable: executable,
            environment: await ToolLocator.shared.childEnvironment()
        )
    }

    // MARK: - 底层调用
    //
    // `gh` 的每条子命令都要打 GitHub 的接口，所以统一用网络级超时 ——
    // 按本地查询的 30 秒来卡，网络一慢就会误伤。

    private func gh(_ arguments: [String], in directory: URL? = nil) async throws -> CommandResult {
        try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment,
            timeout: ProcessRunner.networkTimeout
        )
    }

    @discardableResult
    private func ghChecked(_ arguments: [String], in directory: URL? = nil) async throws -> CommandResult {
        try await ProcessRunner.runChecked(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment,
            timeout: ProcessRunner.networkTimeout
        )
    }

    // MARK: - 可用性

    /// `gh` 是否已登录。未登录时所有 PR 命令都会失败，提前问一次能给出准确的提示，
    /// 而不是让用户看到一句莫名其妙的 API 错误。
    func isAuthenticated() async -> Bool {
        let result = try? await gh(["auth", "status"])
        return result?.isSuccess ?? false
    }

    /// `gh` 配置过的主机列表。
    ///
    /// 用它来判断某个远端「是不是 GitHub」，而不是硬比 `github.com` ——
    /// 这样 GitHub Enterprise（公司自建的 GitHub）也能自动支持：
    /// 用户 `gh auth login --hostname ghe.corp.example` 之后它就出现在这个列表里。
    func configuredHosts() async -> Set<String> {
        guard let result = try? await gh(["auth", "status"]) else { return [] }
        // gh 把 auth status 写在 stderr 上。
        return AuthStatusParser.hosts(in: result.stdout + "\n" + result.stderr)
    }

    /// 当前目录对应的 GitHub 仓库全名（`owner/repo`）。不是 GitHub 仓库时返回 nil。
    ///
    /// **调用前必须先确认这个仓库的 origin 确实指向 GitHub**（见 `GitRemote`）。
    /// `gh repo view` 会扫所有 remote 挑一个 GitHub 的，不管它是不是 `origin` ——
    /// 直接信它会把「origin 在内网 GitLab、另挂了个 GitHub 备份」的仓库
    /// 认成那个备份仓库。
    func repositorySlug(in directory: URL) async -> String? {
        let result = try? await gh(
            ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
            in: directory
        )
        guard let result, result.isSuccess else { return nil }
        let slug = result.trimmedStdout
        return slug.isEmpty ? nil : slug
    }

    // MARK: - 查询

    func pullRequests(in directory: URL, limit: Int = 50, includeClosed: Bool = false) async throws -> [PullRequest] {
        var arguments = ["pr", "list", "--limit", String(limit), "--json", Self.listFields]
        // 默认只看开放的。已合并 / 已关闭的 PR 数量能到几千，全拉一遍又慢又没用。
        arguments.append(contentsOf: ["--state", includeClosed ? "all" : "open"])

        let result = try await ghChecked(arguments, in: directory)
        return try Self.decoder.decode([PullRequest].self, from: result.standardOutput)
    }

    func pullRequest(number: Int, in directory: URL) async throws -> PullRequest {
        let result = try await ghChecked(
            ["pr", "view", String(number), "--json", Self.detailFields],
            in: directory
        )
        return try Self.decoder.decode(PullRequest.self, from: result.standardOutput)
    }

    /// 某个分支对应的 PR。用来把工作树和 PR 关联起来 —— Grove 的核心视图。
    /// 该分支没有 PR 时返回 nil（不是错误）。
    ///
    /// 同一个分支可能有多个 PR（提了一个、关掉、又提一个），所以取一批再挑：
    /// 优先开放的，其次草稿，最后已合并 / 已关闭。只取第一条的话，
    /// 一个正在评审的 PR 可能被同分支上一个几个月前的废弃 PR 盖掉。
    func pullRequest(forBranch branch: String, in directory: URL) async throws -> PullRequest? {
        let result = try await gh(
            ["pr", "list", "--head", branch, "--state", "all",
             "--limit", "10", "--json", Self.detailFields],
            in: directory
        )
        guard result.isSuccess else { return nil }
        let list = try Self.decoder.decode([PullRequest].self, from: result.standardOutput)
        return Self.mostRelevant(of: list)
    }

    /// 某个工作树分支该关联哪个 PR/MR 的规则在 `ForgeClient` 的协议扩展里，
    /// GitHub 和 GitLab 共用同一套，保证界面和 `--doctor` 看到的一致。

    /// 从同一分支的多个 PR 里挑最该展示的那个。GitLab 那侧也用它。
    static func mostRelevant(of pullRequests: [PullRequest]) -> PullRequest? {
        func rank(_ pullRequest: PullRequest) -> Int {
            switch pullRequest.status {
            case .open: 0
            case .draft: 1
            case .merged: 2
            case .closed: 3
            }
        }
        return pullRequests.min {
            // 同一档里比更新时间，最近动过的更可能是用户关心的那个。
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.updatedAt > $1.updatedAt
        }
    }

    // MARK: - 操作

    /// 创建 PR，返回它的网页地址。
    ///
    /// 调用之前分支必须已经推到远端 —— `gh pr create` 自己也能推，但那会走交互式
    /// 提问（"Where should we push?"），在 GUI 里没人能回答。所以推送这一步由
    /// 调用方先用 git 做掉。
    func createPullRequest(_ request: NewPullRequest, in directory: URL) async throws -> String {
        var arguments = [
            "pr", "create",
            "--title", request.title,
            "--body", request.body,
            "--base", request.base,
            "--head", request.head
        ]
        if request.isDraft { arguments.append("--draft") }

        let result = try await ghChecked(arguments, in: directory)
        // gh 把 PR 地址打在 stdout 最后一行。
        return result.trimmedStdout
            .components(separatedBy: "\n")
            .last(where: { $0.contains("://") }) ?? result.trimmedStdout
    }

    func merge(
        number: Int,
        strategy: MergeStrategy,
        deleteBranch: Bool,
        in directory: URL
    ) async throws {
        var arguments = ["pr", "merge", String(number), "--\(strategy.rawValue)"]
        if deleteBranch { arguments.append("--delete-branch") }
        try await ghChecked(arguments, in: directory)
    }

    func approve(number: Int, in directory: URL) async throws {
        try await ghChecked(["pr", "review", String(number), "--approve"], in: directory)
    }

    func requestChanges(number: Int, body: String, in directory: URL) async throws {
        // GitHub 要求「要求修改」必须带正文，空的会被接口拒绝。
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        try await ghChecked(
            ["pr", "review", String(number), "--request-changes",
             "--body", text.isEmpty ? "请看行内评论。" : text],
            in: directory
        )
    }

    /// 草稿转正式。
    func markReady(number: Int, in directory: URL) async throws {
        try await ghChecked(["pr", "ready", String(number)], in: directory)
    }

    func close(number: Int, in directory: URL) async throws {
        try await ghChecked(["pr", "close", String(number)], in: directory)
    }

    func comment(number: Int, body: String, in directory: URL) async throws {
        try await ghChecked(["pr", "comment", String(number), "--body", body], in: directory)
    }

    /// 评论线程：行内评审意见 + 整体讨论。
    ///
    /// 走两个 REST 接口而不是 `gh pr view --json comments`：后者只给整体评论，
    /// 拿不到带文件和行号的行内意见 —— 而 review 时最要紧的恰恰是那些。
    func reviewThreads(number: Int, in directory: URL) async throws -> [ReviewThread] {
        async let inline = fetchComments(
            "repos/{owner}/{repo}/pulls/\(number)/comments?per_page=100", in: directory
        )
        async let general = fetchComments(
            "repos/{owner}/{repo}/issues/\(number)/comments?per_page=100", in: directory
        )
        let threads = await (inline + general)
        return threads.sorted { ($0.firstNote?.createdAt ?? .distantPast) < ($1.firstNote?.createdAt ?? .distantPast) }
    }

    private func fetchComments(_ path: String, in directory: URL) async -> [ReviewThread] {
        guard let result = try? await gh(["api", path], in: directory), result.isSuccess,
              let comments = try? Self.decoder.decode([GitHubComment].self, from: result.standardOutput)
        else { return [] }
        return Self.threads(from: comments, source: path)
    }

    /// 把评论按「回复关系」归成线程。
    ///
    /// GitHub 的接口返回的是一个平铺数组，回复靠 `in_reply_to_id` 指回它回复的那条。
    /// 不归组的话，一来一回的讨论会散成一堆孤立条目，读起来完全不知道谁在回谁。
    static func threads(from comments: [GitHubComment], source: String) -> [ReviewThread] {
        var roots: [Int: [GitHubComment]] = [:]
        var order: [Int] = []
        for comment in comments {
            let key = comment.in_reply_to_id ?? comment.id
            if roots[key] == nil { order.append(key) }
            roots[key, default: []].append(comment)
        }

        return order.compactMap { key in
            guard let group = roots[key], let first = group.first else { return nil }
            return ReviewThread(
                id: "\(source)-\(key)",
                notes: group.map { comment in
                    ReviewNote(
                        id: String(comment.id),
                        authorName: comment.user?.login ?? "未知",
                        authorLogin: comment.user?.login ?? "",
                        body: comment.body ?? "",
                        createdAt: comment.created_at,
                        isSystem: false
                    )
                },
                filePath: first.path,
                // `line` 在这一行已经不在最新 diff 里时会是 null，
                // 这时退回 `original_line`（评论刚发时的行号）总比不显示行号好。
                line: first.line ?? first.original_line,
                isResolved: false,
                isResolvable: false
            )
        }
    }

    // MARK: -

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // gh 输出的是 RFC 3339（`2026-08-27T14:03:09Z`），标准 iso8601 策略正好吃这个。
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}


/// GitHub 评论接口返回的一条评论。行内评审意见和整体讨论共用这个形状，
/// 只是整体讨论没有 `path` / `line`。
struct GitHubComment: Decodable, Sendable {
    var id: Int
    var body: String?
    var user: User?
    var created_at: Date?
    var path: String?
    var line: Int?
    var original_line: Int?
    /// 行内回复指向它所回复的那条评论。
    var in_reply_to_id: Int?

    struct User: Decodable, Sendable {
        var login: String
    }
}
