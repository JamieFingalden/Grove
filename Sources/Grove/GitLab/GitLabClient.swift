import Foundation

/// 通过 GitLab CLI（`glab`）访问 Merge Request。
///
/// 跟 GitHub 那一侧同样的取舍：认证交给 `glab`，Grove 不碰任何 token。
/// 自建实例（尤其是内网的 http + 非标准端口）的认证细节相当琐碎，
/// `glab auth login` 已经把它做完了，重写一遍只会多一处出错的地方。
///
/// 读操作一律走 `glab api` 直连 REST 接口，而不是 `glab mr list -F json`：
/// 前者能自己控制查询参数（`with_labels_details`、分页、按分支过滤），
/// 拿到的也是 GitLab 原始 JSON，字段含义有官方文档可查。
/// 写操作走 `glab mr` 的子命令 —— 合并、批准这些动作有额外语义，让 CLI 处理更稳。
struct GitLabClient: ForgeClient {
    let executable: URL
    let environment: [String: String]

    var kind: ForgeKind { .gitlab }

    static func resolve() async -> GitLabClient? {
        guard let executable = await ToolLocator.shared.locate("glab") else { return nil }
        return GitLabClient(
            executable: executable,
            environment: await ToolLocator.shared.childEnvironment()
        )
    }

    // MARK: - 底层调用

    private func run(_ arguments: [String], in directory: URL?) async throws -> CommandResult {
        try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment,
            timeout: ProcessRunner.networkTimeout
        )
    }

    @discardableResult
    private func runChecked(_ arguments: [String], in directory: URL?) async throws -> CommandResult {
        try await ProcessRunner.runChecked(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment,
            timeout: ProcessRunner.networkTimeout
        )
    }

    /// 调一个 REST 接口。
    ///
    /// `:id` 占位符由 glab 用当前目录的 git remote 解析成项目 ID —— 这也顺带
    /// 决定了用哪个 GitLab 主机，所以内网实例不需要额外传 `--hostname`。
    private func api(
        _ path: String,
        in directory: URL,
        fields: [String: String] = [:]
    ) async throws -> Data {
        var arguments = ["api", path]
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            // `--raw-field` 不做类型推断，原样当字符串传。评论正文里出现
            // 数字、`true` 这种内容时不会被误转成 JSON 标量。
            arguments.append(contentsOf: ["--raw-field", "\(key)=\(value)"])
        }
        let result = try await runChecked(arguments, in: directory)
        return result.standardOutput
    }

    // MARK: - 可用性

    func isAuthenticated() async -> Bool {
        let result = try? await run(["auth", "status"], in: nil)
        return result?.isSuccess ?? false
    }

    func configuredHosts() async -> Set<String> {
        // 注意：这里返回的是「配置过的」主机，不保证每个都登录成功。
        // 用途只是判断某个远端归不归 GitLab 管，够用了；真正的认证失败
        // 会在后续 API 调用时带着 glab 的原始错误信息浮出来。
        guard let result = try? await run(["auth", "status"], in: nil) else { return [] }
        // glab 把 auth status 写在 stderr 上，stdout 是空的。
        return AuthStatusParser.hosts(in: result.stdout + "\n" + result.stderr)
    }

    func repositorySlug(in directory: URL) async -> String? {
        struct Project: Decodable { var pathWithNamespace: String }
        guard let data = try? await api("projects/:id", in: directory),
              let project = try? Self.decoder.decode(Project.self, from: data) else {
            return nil
        }
        return project.pathWithNamespace
    }

    // MARK: - 查询

    func pullRequests(in directory: URL, limit: Int, includeClosed: Bool) async throws -> [PullRequest] {
        var query = "projects/:id/merge_requests?per_page=\(limit)&order_by=updated_at"
        query += "&with_labels_details=true"
        query += includeClosed ? "&state=all" : "&state=opened"

        let data = try await api(query, in: directory)
        let merges = try Self.decoder.decode([GitLabMergeRequest].self, from: data)
        // 列表视图不逐个去拉审批和任务列表 —— 那会变成几十个串行请求。
        return merges.map { $0.asPullRequest() }
    }

    func pullRequest(number: Int, in directory: URL) async throws -> PullRequest {
        let data = try await api(
            "projects/:id/merge_requests/\(number)?with_labels_details=true",
            in: directory
        )
        let merge = try Self.decoder.decode(GitLabMergeRequest.self, from: data)

        // 详情页才值得补齐这两样。任何一个失败都不该让整个详情页打不开 ——
        // 自建实例上审批是收费功能，社区版直接返回 404。
        let approvals = try? await approvals(number: number, in: directory)
        let jobs = await pipelineJobs(pipelineID: merge.headPipeline?.id, in: directory)
        return merge.asPullRequest(approvals: approvals, jobs: jobs)
    }

    func pullRequest(forBranch branch: String, in directory: URL) async throws -> PullRequest? {
        guard let encoded = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        let data = try await api(
            "projects/:id/merge_requests?source_branch=\(encoded)&state=all&per_page=10&with_labels_details=true",
            in: directory
        )
        let merges = try Self.decoder.decode([GitLabMergeRequest].self, from: data)
        // 同一个分支可能提过多个 MR（提了、关了、又提一个），挑最该展示的那个。
        return GitHubClient.mostRelevant(of: merges.map { $0.asPullRequest() })
    }

    private func approvals(number: Int, in directory: URL) async throws -> GitLabApprovals {
        let data = try await api("projects/:id/merge_requests/\(number)/approvals", in: directory)
        return try Self.decoder.decode(GitLabApprovals.self, from: data)
    }

    private func pipelineJobs(pipelineID: Int?, in directory: URL) async -> [GitLabJob]? {
        guard let pipelineID else { return nil }
        guard let data = try? await api(
            "projects/:id/pipelines/\(pipelineID)/jobs?per_page=100",
            in: directory
        ) else { return nil }
        return try? Self.decoder.decode([GitLabJob].self, from: data)
    }

    func reviewThreads(number: Int, in directory: URL) async throws -> [ReviewThread] {
        let data = try await api(
            "projects/:id/merge_requests/\(number)/discussions?per_page=100",
            in: directory
        )
        let discussions = try Self.decoder.decode([GitLabDiscussion].self, from: data)
        return discussions.compactMap { $0.asReviewThread() }
    }

    // MARK: - 操作

    func createPullRequest(_ request: NewPullRequest, in directory: URL) async throws -> String {
        var arguments = [
            "mr", "create",
            "--title", request.title,
            "--description", request.body.isEmpty ? " " : request.body,
            "--source-branch", request.head,
            "--target-branch", request.base,
            // 不加 --yes 会停在交互确认上，GUI 里没人能回答。
            "--yes"
        ]
        if request.isDraft { arguments.append("--draft") }

        let result = try await runChecked(arguments, in: directory)
        let output = result.trimmedStdout + "\n" + result.stderr
        return output
            .components(separatedBy: .whitespacesAndNewlines)
            .last(where: { $0.contains("://") }) ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func merge(number: Int, strategy: MergeStrategy, deleteBranch: Bool, in directory: URL) async throws {
        var arguments = ["mr", "merge", String(number), "--yes"]
        switch strategy {
        case .squash: arguments.append("--squash")
        case .rebase: arguments.append("--rebase")
        case .merge: break      // 默认就是普通合并提交
        }
        if deleteBranch { arguments.append("--remove-source-branch") }

        // 关键：`glab mr merge` 在流水线还在跑时**默认启用 auto-merge**
        // （等流水线过了再合），而不是立刻合并。用户在 Grove 里点「合并」
        // 期待的是现在就合，不写这个参数会表现成「点了没反应」。
        arguments.append("--auto-merge=false")

        try await runChecked(arguments, in: directory)
    }

    func approve(number: Int, in directory: URL) async throws {
        try await runChecked(["mr", "approve", String(number)], in: directory)
    }

    func requestChanges(number: Int, body: String, in directory: URL) async throws {
        // GitLab 没有「要求修改」这个独立动作（那是 GitHub 评审模型的概念）。
        // 最接近的等价物是留一条评论 —— 加个前缀让对方一眼看出意图。
        try await comment(number: number, body: "**要求修改**\n\n\(body)", in: directory)
    }

    func comment(number: Int, body: String, in directory: URL) async throws {
        // 用 API 而不是 `glab mr note`：后者的正文参数在不同版本间有过变化，
        // 而 notes 接口十年没动过。
        _ = try await api(
            "projects/:id/merge_requests/\(number)/notes",
            in: directory,
            fields: ["body": body]
        )
    }

    // MARK: -

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom(GitLabClient.decodeDate)
        return decoder
    }()

    /// GitLab 的时间戳带毫秒（`2026-08-28T10:45:10.425Z`），而 GitHub 的不带。
    ///
    /// 不用 `JSONDecoder` 内置的 `.iso8601` 策略，是因为它对小数秒的支持没有文档
    /// 保证：早期的 Foundation 实现遇到小数秒直接失败，新版本才变得宽松。
    /// 而「日期解析失败」在这里的后果是**整条 MR 解不出来**、界面上一个都不显示，
    /// 错误信息还只含糊地说某个字段格式不对 —— 不值得赌运行时的宽容度。
    /// `Date.ISO8601FormatStyle` 两种写法都明确支持，而且是值类型、天然 Sendable。
    static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = DateParsing.iso8601(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析时间戳：\(text)"
            )
        }
        return date
    }
}
