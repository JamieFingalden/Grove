import Foundation

/// 一个待评审的变更请求 —— GitHub 上叫 Pull Request、GitLab 上叫 Merge Request。
///
/// 名字沿用 GitHub 的叫法只是因为它更广为人知；这个类型同时承载两个平台的数据，
/// 由 `forge` 区分来源。界面上的称呼按 `forge.termLong` 走，不会给 GitLab 用户
/// 显示「Pull Request」这种他们不认识的说法。
///
/// 字段名跟 `gh pr list --json` 的输出一一对应，所以 GitHub 那侧可以直接
/// `Decodable`；GitLab 那侧由 `GitLabMergeRequest.asPullRequest()` 映射过来。
struct PullRequest: Identifiable, Hashable, Sendable, Decodable {
    var number: Int
    var title: String
    var state: String            // OPEN / CLOSED / MERGED
    var isDraft: Bool
    var headRefName: String
    var baseRefName: String
    var url: String
    var author: Author?
    var updatedAt: Date
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    /// APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED。没人被要求评审时 GitHub 返回 null。
    var reviewDecision: String?
    /// MERGEABLE / CONFLICTING / UNKNOWN。GitHub 是异步算这个的，
    /// 刚推完代码去查往往是 UNKNOWN，过几秒才有结果。
    var mergeable: String?
    var isCrossRepository: Bool
    var labels: [Label]
    var statusCheckRollup: [StatusCheck]?
    var body: String?
    /// 来源仓库的 owner。跨仓库 PR（从 fork 提的）时跟当前仓库不同，
    /// 决定了检出这个 PR 要用哪种 refspec。
    var headRepositoryOwner: Owner?
    /// 当前登录用户是否已批准。GitHub 列表接口不提供这个字段，默认为 false。
    var viewerHasApproved = false

    /// 请求创建时间。列表用它表示“提交了多久”，缺失时才退回最近更新时间。
    var createdAt: Date? = nil

    /// 来源平台。GitHub 的 JSON 里没有这个字段，解码后由客户端补上。
    var forge: ForgeKind = .github

    var id: Int { number }

    /// 界面上的编号写法：GitHub 是 `#123`，GitLab 是 `!123`。
    var displayNumber: String { "\(forge.numberPrefix)\(number)" }

    var listTimestamp: Date { createdAt ?? updatedAt }

    // GitHub 的 JSON 里没有 forge 字段，得显式列出要解码的键，
    // 否则合成的 CodingKeys 会去找一个不存在的 "forge" 而失败。
    enum CodingKeys: String, CodingKey {
        case number, title, state, isDraft, headRefName, baseRefName, url, author
        case updatedAt, createdAt, additions, deletions, changedFiles, reviewDecision, mergeable
        case isCrossRepository, labels, statusCheckRollup, body, headRepositoryOwner
    }

    struct Author: Hashable, Sendable, Decodable {
        var login: String
        var name: String?
        var isBot: Bool?

        // gh 这个字段用的是蛇形命名（`is_bot`），跟同一份 JSON 里其他字段的驼峰不一致。
        // 不显式映射的话机器人 PR 会被当成普通用户。
        enum CodingKeys: String, CodingKey {
            case login
            case name
            case isBot = "is_bot"
        }

        var displayName: String {
            if let name, !name.isEmpty { return name }
            // 机器人的 login 形如 `app/dependabot`，前缀对用户没意义。
            if let slash = login.firstIndex(of: "/") {
                return String(login[login.index(after: slash)...])
            }
            return login
        }
    }

    struct Owner: Hashable, Sendable, Decodable {
        var login: String
    }

    struct Label: Hashable, Sendable, Decodable, Identifiable {
        var name: String
        /// 六位十六进制，不带 `#`。
        var color: String
        var id: String { name }
    }

    // MARK: - 派生状态

    var status: Status {
        switch state.uppercased() {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: isDraft ? .draft : .open
        }
    }

    /// 只有开放和草稿请求仍然占用工作树的评审入口。
    /// 已合并、已关闭的请求只是历史记录，不应阻止同一分支再次发起请求。
    var isActive: Bool {
        status == .open || status == .draft
    }

    enum Status: Sendable, Hashable {
        case open, draft, merged, closed

        var label: String {
            switch self {
            case .open: "开放"
            case .draft: "草稿"
            case .merged: "已合并"
            case .closed: "已关闭"
            }
        }

        var systemImage: String {
            switch self {
            case .open: "arrow.triangle.pull"
            case .draft: "pencil.line"
            case .merged: "arrow.triangle.merge"
            case .closed: "xmark.circle"
            }
        }
    }

    var review: ReviewState {
        switch reviewDecision?.uppercased() {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .pending
        default: .none
        }
    }

    enum ReviewState: Sendable, Hashable {
        case approved, changesRequested, pending, none

        var label: String? {
            switch self {
            case .approved: "已批准"
            case .changesRequested: "要求修改"
            case .pending: "待评审"
            case .none: nil
            }
        }

        var systemImage: String? {
            switch self {
            case .approved: "checkmark.seal.fill"
            case .changesRequested: "exclamationmark.bubble.fill"
            case .pending: "clock.fill"
            case .none: nil
            }
        }
    }

    /// 所有检查汇总成一个结论。有任意失败就是失败，还有在跑的就是进行中。
    var checks: CheckRollup {
        guard let statusCheckRollup, !statusCheckRollup.isEmpty else { return .none }
        var passed = 0, failed = 0, running = 0
        for check in statusCheckRollup {
            switch check.outcome {
            case .success: passed += 1
            case .failure: failed += 1
            case .pending: running += 1
            case .skipped: break
            }
        }
        if failed > 0 { return .failing(passed: passed, failed: failed, total: statusCheckRollup.count) }
        if running > 0 { return .running(passed: passed, total: statusCheckRollup.count) }
        if passed > 0 { return .passing(total: passed) }
        return .none
    }

    enum CheckRollup: Sendable, Hashable {
        case passing(total: Int)
        case failing(passed: Int, failed: Int, total: Int)
        case running(passed: Int, total: Int)
        case none

        var label: String? {
            switch self {
            case .passing(let total): "\(total) 项检查通过"
            case .failing(_, let failed, let total): "\(failed)/\(total) 项检查失败"
            case .running(let passed, let total): "检查中 \(passed)/\(total)"
            case .none: nil
            }
        }

        var systemImage: String? {
            switch self {
            case .passing: "checkmark.circle.fill"
            case .failing: "xmark.circle.fill"
            case .running: "clock.arrow.trianglehead.counterclockwise.rotate.90"
            case .none: nil
            }
        }
    }
}

/// 本地分支名和 PR 之间的命名约定。
///
/// 只有一个地方定义这套规则：`RepositoryModel` 按它生成分支名，`WorktreeModel`
/// 按它反查 PR。两边各写一份的话，改了生成规则而忘了改反查，
/// 表现就是「检出的 PR 工作树莫名其妙不显示 PR 信息」。
enum PullRequestNaming {
    /// 检出某个 PR 时本地分支应该叫什么。
    ///
    /// 同仓库的 PR 直接沿用它的头分支名 —— 这样能跟远端建立跟踪关系，改完可以推回去。
    /// 从 fork 提来的 PR 用 `pr-<编号>`：对方的分支名可能跟我们本地已有分支撞名
    /// （`main`、`dev` 这种），而且我们对它的 fork 没有写权限，沿用原名只会造成误解。
    static func branchName(for pullRequest: PullRequest) -> String {
        pullRequest.isCrossRepository ? "pr-\(pullRequest.number)" : pullRequest.headRefName
    }

    /// `pr-14264` → 14264。不是这个格式就返回 nil。
    static func number(fromBranch branch: String) -> Int? {
        guard branch.hasPrefix("pr-") else { return nil }
        let digits = branch.dropFirst(3)
        // 必须全是数字：`pr-fix-login` 是个正常的功能分支名，不是 PR 编号。
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}

/// 一项 CI 检查。
///
/// GitHub 的 `statusCheckRollup` 是个异构数组：GitHub Actions 之类的走 `CheckRun`
/// （有 `name`/`status`/`conclusion`），而老式的第三方服务走 `StatusContext`
/// （有 `context`/`state`）。两种形状字段名完全不同，所以全声明成可选，
/// 再由 `outcome` 统一成一个结论。
struct StatusCheck: Hashable, Sendable, Decodable, Identifiable {
    var __typename: String?
    // CheckRun 形状
    var name: String?
    var status: String?          // QUEUED / IN_PROGRESS / COMPLETED
    var conclusion: String?      // SUCCESS / FAILURE / NEUTRAL / CANCELLED / SKIPPED / TIMED_OUT / ACTION_REQUIRED
    var detailsUrl: String?
    var workflowName: String?
    // StatusContext 形状
    var context: String?
    var state: String?           // SUCCESS / FAILURE / PENDING / ERROR / EXPECTED
    var targetUrl: String?

    var id: String { displayName + (detailsUrl ?? targetUrl ?? "") }

    var displayName: String {
        if let name, !name.isEmpty {
            if let workflowName, !workflowName.isEmpty, workflowName != name {
                return "\(workflowName) / \(name)"
            }
            return name
        }
        return context ?? "检查"
    }

    var link: URL? {
        URL(string: detailsUrl ?? targetUrl ?? "")
    }

    enum Outcome: Sendable, Hashable {
        case success, failure, pending, skipped
    }

    var outcome: Outcome {
        // CheckRun：没跑完就是 pending，跑完看 conclusion。
        if let status = status?.uppercased(), status != "COMPLETED" {
            return .pending
        }
        if let conclusion = conclusion?.uppercased() {
            switch conclusion {
            case "SUCCESS": return .success
            case "SKIPPED", "NEUTRAL": return .skipped
            default: return .failure   // FAILURE / CANCELLED / TIMED_OUT / ACTION_REQUIRED / STARTUP_FAILURE
            }
        }
        // StatusContext
        switch state?.uppercased() {
        case "SUCCESS": return .success
        case "PENDING", "EXPECTED": return .pending
        case "FAILURE", "ERROR": return .failure
        default: return .pending
        }
    }
}
