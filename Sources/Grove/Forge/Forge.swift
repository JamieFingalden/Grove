import Foundation

/// 代码托管商。
///
/// GitHub 叫 Pull Request、GitLab 叫 Merge Request，但对使用者来说是同一件事：
/// 「有人提了一批改动，等着被看和被合」。Grove 内部统一用 `PullRequest` 这个模型
/// 表示两者，只在**界面文案**和**具体命令**上按托管商分流。
enum ForgeKind: String, Sendable, Hashable, CaseIterable {
    case github
    case gitlab

    /// 界面上的完整称呼。GitLab 用户不认识「Pull Request」这个说法，反之亦然，
    /// 用错术语会让人以为自己点错了地方。
    var termLong: String {
        switch self {
        case .github: "Pull Request"
        case .gitlab: "合并请求"
        }
    }

    /// 编号前面的短前缀：GitHub 写 `#123`，GitLab 写 `!123`。
    /// 这是两边社区都约定俗成的记法，跟着用能让人一眼认出是哪个平台。
    var numberPrefix: String {
        switch self {
        case .github: "#"
        case .gitlab: "!"
        }
    }

    var shortTerm: String {
        switch self {
        case .github: "PR"
        case .gitlab: "MR"
        }
    }

    /// 抓取某个 PR/MR 的完整 refspec。
    ///
    /// 两个平台都提供一个只读的服务端 ref 指向请求的头提交，不管它来自
    /// 本仓库还是 fork。这是检出别人的改动最可靠的途径 ——
    /// 不需要对方仓库的访问权限，也不用猜分支名。
    /// `+` 前缀允许非快进更新：作者 force-push 之后不加它会抓取失败。
    func headRefspec(number: Int, localBranch: String) -> String {
        switch self {
        case .github: "+refs/pull/\(number)/head:refs/heads/\(localBranch)"
        case .gitlab: "+refs/merge-requests/\(number)/head:refs/heads/\(localBranch)"
        }
    }

    /// 安装和登录的提示，工具缺失时显示给用户。
    var setupHint: String {
        switch self {
        case .github: "brew install gh && gh auth login"
        case .gitlab: "brew install glab && glab auth login --hostname <你的 GitLab 主机>"
        }
    }
}

/// 一条评论线程里的单条发言。
struct ReviewNote: Identifiable, Hashable, Sendable {
    var id: String
    var authorName: String
    var authorLogin: String
    var body: String
    var createdAt: Date?
    /// 系统自动生成的记录（"assigned to @x"、"changed title" 之类）。
    /// 它们数量很大且没有讨论价值，界面上默认折叠。
    var isSystem: Bool
}

/// 一条评论线程。行内评论会带上文件和行号。
struct ReviewThread: Identifiable, Hashable, Sendable {
    var id: String
    var notes: [ReviewNote]
    /// 行内评论所在的文件路径。整体评论为 nil。
    var filePath: String?
    /// 行内评论所在的行号（新文件侧）。
    var line: Int?
    var isResolved: Bool
    /// 这条线程是否支持「已解决」标记。普通评论不支持。
    var isResolvable: Bool

    var firstNote: ReviewNote? { notes.first }
    var isInline: Bool { filePath != nil }
    /// 整条线程都是系统记录 —— 界面上默认不显示。
    var isSystemOnly: Bool { notes.allSatisfy(\.isSystem) }
}

/// Grove 跟代码托管商打交道的统一入口。
///
/// GitHub 走 `gh`、GitLab 走 `glab`，两边的子命令、JSON 字段、概念名称都不一样，
/// 但界面只该看到一套模型。所有差异都收敛在各自的实现里。
protocol ForgeClient: Sendable {
    var kind: ForgeKind { get }

    /// CLI 是否已经登录。
    func isAuthenticated() async -> Bool
    /// CLI 配置过的主机列表。用来判断某个远端归哪个托管商管。
    func configuredHosts() async -> Set<String>

    /// 当前目录对应的仓库标识（`owner/repo` 或 `group/project`）。
    /// 不属于这个托管商时返回 nil。
    func repositorySlug(in directory: URL) async -> String?

    func pullRequests(in directory: URL, limit: Int, includeClosed: Bool) async throws -> [PullRequest]
    func pullRequest(number: Int, in directory: URL) async throws -> PullRequest
    /// 某个分支对应的 PR/MR。找不到返回 nil（不是错误）。
    func pullRequest(forBranch branch: String, in directory: URL) async throws -> PullRequest?
    /// 请求相对目标分支的完整代码改动。不需要先把请求检出成本地工作树。
    func pullRequestDiff(number: Int, in directory: URL) async throws -> [FileDiff]

    /// 评论线程。用于在 Grove 里读别人的评审意见。
    func reviewThreads(number: Int, in directory: URL) async throws -> [ReviewThread]

    func createPullRequest(_ request: NewPullRequest, in directory: URL) async throws -> String
    func merge(number: Int, strategy: MergeStrategy, deleteBranch: Bool, in directory: URL) async throws
    /// 批准。GitHub 是提交一条 APPROVE 评审，GitLab 是 approve 接口。
    func approve(number: Int, in directory: URL) async throws
    /// 撤销当前用户的批准。GitLab 原生支持；其他平台可以按能力降级。
    func unapprove(number: Int, in directory: URL) async throws
    /// 要求修改。GitLab 没有这个动作，实现里降级成一条普通评论。
    func requestChanges(number: Int, body: String, in directory: URL) async throws
    func comment(number: Int, body: String, in directory: URL) async throws
}

extension ForgeClient {
    func unapprove(number: Int, in directory: URL) async throws {
        throw ForgeReviewError.unapproveUnsupported
    }

    /// 某个工作树分支当前关联的开放 PR/MR。这是「工作树 ↔ 评审」这条主线的唯一入口，
    /// 界面和 `--doctor` 都走它，保证两边看到的是同一套规则。已结束的请求只算历史记录。
    func linkedPullRequest(branch: String, defaultBranch: String?, in directory: URL) async -> PullRequest? {
        // 默认分支不关联。它是所有请求的**目标**，不是任何请求的来源；
        // 按分支名去查会翻出历史上某个从 main 提出去的旧请求，纯属误导。
        if let defaultBranch, branch == defaultBranch { return nil }

        // Grove 给 fork / 跨仓库请求建的工作树分支叫 `pr-<编号>`，跟对方仓库里的
        // 源分支名对不上，只能按编号查。
        let linkedRequest: PullRequest?
        if let number = PullRequestNaming.number(fromBranch: branch) {
            linkedRequest = try? await pullRequest(number: number, in: directory)
        } else {
            linkedRequest = try? await pullRequest(forBranch: branch, in: directory)
        }

        return linkedRequest?.isActive == true ? linkedRequest : nil
    }
}

enum ForgeReviewError: LocalizedError, Sendable {
    case unapproveUnsupported

    var errorDescription: String? {
        switch self {
        case .unapproveUnsupported:
            "当前代码托管平台不支持在 Grove 中撤销批准，请暂时在浏览器里操作。"
        }
    }
}

/// 新建 PR/MR 的参数。
struct NewPullRequest: Sendable {
    var title: String
    var body: String
    var base: String
    var head: String
    var isDraft: Bool
}

/// 合并方式。两个平台的三种策略语义一致，只是命令行参数写法不同。
enum MergeStrategy: String, Sendable, CaseIterable, Identifiable {
    case squash, merge, rebase

    var id: String { rawValue }

    var label: String {
        switch self {
        case .squash: "压缩合并"
        case .merge: "创建合并提交"
        case .rebase: "变基合并"
        }
    }

    var detail: String {
        switch self {
        case .squash: "把整个请求压成一个提交，主干历史最干净"
        case .merge: "保留所有提交，并加一个合并提交"
        case .rebase: "把提交逐个接到目标分支顶端，不产生合并提交"
        }
    }
}

/// 从 `gh auth status` / `glab auth status` 的输出里挑出主机名。
///
/// 两个 CLI 的输出格式碰巧一致：主机名单独占一行、顶格不缩进，
/// 其下的详情行都有缩进。
enum AuthStatusParser {
    static func hosts(in output: String) -> Set<String> {
        var hosts: Set<String> = []
        for line in output.components(separatedBy: "\n") {
            guard let first = line.first, !first.isWhitespace else { continue }
            let candidate = line.trimmingCharacters(in: .whitespaces)
            // 顶格的还可能是 "ERROR" / "X could not authenticate..." 这类提示。
            // 主机名的特征：含点或冒号（域名 / IP / 带端口），且不含空格。
            guard !candidate.contains(" "),
                  candidate.contains(".") || candidate.contains(":") else { continue }
            hosts.insert(candidate.lowercased())
        }
        return hosts
    }
}
