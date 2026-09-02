import Foundation

/// GitLab REST API 返回的 Merge Request。字段是 snake_case，靠解码器的
/// `convertFromSnakeCase` 自动对应到这里的驼峰属性。
///
/// 所有字段都尽量声明成可选：GitLab 的列表接口和详情接口返回的字段集合不一样
/// （比如 `head_pipeline`、`changes_count` 只有详情接口才有），
/// 而自建实例的版本可能比 gitlab.com 老好几个大版本，字段有增有减。
/// 少一个字段就整条解码失败的话，界面上会变成「一个 MR 都读不出来」。
struct GitLabMergeRequest: Decodable, Sendable {
    var iid: Int
    var title: String
    var description: String?
    /// opened / closed / merged / locked
    var state: String
    var draft: Bool?
    /// 老版本 GitLab 用这个字段名，新版本改叫 `draft`，两个都读。
    var workInProgress: Bool?
    var sourceBranch: String
    var targetBranch: String
    var webUrl: String
    var author: GitLabUser?
    var updatedAt: Date?
    var createdAt: Date?
    var changesCount: GitLabFlexibleCount?
    /// can_be_merged / cannot_be_merged / checking / unchecked
    var mergeStatus: String?
    /// 比 mergeStatus 细：not_approved / discussions_not_resolved / conflict / ci_still_running…
    var detailedMergeStatus: String?
    var hasConflicts: Bool?
    var sourceProjectId: Int?
    var targetProjectId: Int?
    var labels: [GitLabLabel]?
    var headPipeline: GitLabPipeline?
    var userNotesCount: Int?
    var reviewers: [GitLabUser]?

    /// 从 fork 提过来的：源项目和目标项目不是同一个。
    var isCrossProject: Bool {
        guard let sourceProjectId, let targetProjectId else { return false }
        return sourceProjectId != targetProjectId
    }

    var isDraft: Bool { draft ?? workInProgress ?? false }
}

struct GitLabUser: Decodable, Sendable, Hashable {
    var username: String
    var name: String?
}

struct GitLabPipeline: Decodable, Sendable, Hashable {
    var id: Int
    /// created / waiting_for_resource / preparing / pending / running /
    /// success / failed / canceled / skipped / manual / scheduled
    var status: String
    var webUrl: String?
}

/// GitLab 的 CI 任务。等价于 GitHub 的一项 check。
struct GitLabJob: Decodable, Sendable {
    var id: Int
    var name: String
    var stage: String?
    var status: String
    var webUrl: String?
    /// 允许失败的任务挂了不该把整体判成失败 —— 这是项目自己声明的「非阻塞」。
    var allowFailure: Bool?
}

/// `changes_count` 可能是数字 `6`，也可能是字符串 `"6"`，
/// 超过上限时 GitLab 还会返回 `"1000+"`。三种都要吃下来。
struct GitLabFlexibleCount: Decodable, Sendable, Hashable {
    var value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = number
            return
        }
        let text = (try? container.decode(String.self)) ?? ""
        // "1000+" 取前面的数字部分。
        value = Int(text.prefix { $0.isNumber }) ?? 0
    }
}

/// 标签。`with_labels_details=true` 时是对象（带颜色），否则只是字符串。
/// 两种形状都得认 —— 老版本 GitLab 不支持那个查询参数。
struct GitLabLabel: Decodable, Sendable, Hashable {
    var name: String
    var color: String?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let plain = try? container.decode(String.self) {
            name = plain
            color = nil
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        name = try keyed.decode(String.self, forKey: .name)
        color = try? keyed.decode(String.self, forKey: .color)
    }

    enum CodingKeys: String, CodingKey {
        case name, color
    }
}

/// 审批状态，来自 `/merge_requests/:iid/approvals`。
struct GitLabApprovals: Decodable, Sendable {
    var approvalsRequired: Int?
    var approvalsLeft: Int?
    var approvedBy: [ApprovedBy]?
    var userHasApproved: Bool?
    var userCanApprove: Bool?

    struct ApprovedBy: Decodable, Sendable {
        var user: GitLabUser?
    }

    var isApproved: Bool {
        if let approvalsLeft { return approvalsLeft == 0 }
        return !(approvedBy?.isEmpty ?? true)
    }
}

/// 评论线程，来自 `/merge_requests/:iid/discussions`。
struct GitLabDiscussion: Decodable, Sendable {
    var id: String
    var individualNote: Bool?
    var notes: [Note]?

    struct Note: Decodable, Sendable {
        var id: Int
        var body: String?
        var author: GitLabUser?
        var createdAt: Date?
        var system: Bool?
        var resolvable: Bool?
        var resolved: Bool?
        var position: Position?

        struct Position: Decodable, Sendable {
            var newPath: String?
            var oldPath: String?
            var newLine: Int?
            var oldLine: Int?
        }
    }
}

// MARK: - 映射到 Grove 的统一模型

extension GitLabMergeRequest {
    /// 转成 Grove 内部统一的 `PullRequest`。
    ///
    /// `approvals` 和 `jobs` 是可选的额外数据：列表视图为了少发几十个请求不取它们，
    /// 详情视图才补齐。缺了也能显示，只是审批状态和逐项 CI 结果为空。
    func asPullRequest(
        approvals: GitLabApprovals? = nil,
        jobs: [GitLabJob]? = nil
    ) -> PullRequest {
        PullRequest(
            number: iid,
            title: title,
            state: Self.normalizedState(state),
            isDraft: isDraft,
            headRefName: sourceBranch,
            baseRefName: targetBranch,
            url: webUrl,
            author: author.map {
                PullRequest.Author(login: $0.username, name: $0.name, isBot: nil)
            },
            updatedAt: updatedAt ?? createdAt ?? Date(timeIntervalSince1970: 0),
            // GitLab 的 MR 列表不带增删行数，要另外拉 diff 才有 —— 为了一个角标
            // 给每个 MR 多发一个重请求不划算。这里留 0，界面上会隐藏这两个数字，
            // 而不是显示误导性的「+0 −0」。
            additions: 0,
            deletions: 0,
            changedFiles: changesCount?.value ?? 0,
            reviewDecision: Self.reviewDecision(approvals: approvals, detailedStatus: detailedMergeStatus),
            mergeable: Self.mergeable(status: mergeStatus, hasConflicts: hasConflicts),
            isCrossRepository: isCrossProject,
            labels: (labels ?? []).map {
                PullRequest.Label(name: $0.name, color: $0.color ?? "")
            },
            statusCheckRollup: Self.checks(pipeline: headPipeline, jobs: jobs),
            body: description,
            headRepositoryOwner: nil,
            viewerHasApproved: approvals?.userHasApproved ?? false,
            createdAt: createdAt,
            forge: .gitlab
        )
    }

    static func normalizedState(_ raw: String) -> String {
        switch raw.lowercased() {
        case "merged": "MERGED"
        case "closed": "CLOSED"
        // `locked` 是合并过程中的临时状态，对用户来说它还是开着的。
        default: "OPEN"
        }
    }

    static func mergeable(status: String?, hasConflicts: Bool?) -> String? {
        if hasConflicts == true { return "CONFLICTING" }
        switch status?.lowercased() {
        case "can_be_merged": return "MERGEABLE"
        case "cannot_be_merged": return "CONFLICTING"
        case "checking", "unchecked": return "UNKNOWN"
        default: return nil
        }
    }

    static func reviewDecision(approvals: GitLabApprovals?, detailedStatus: String?) -> String? {
        // 有精确的审批数据就用它。
        if let approvals {
            if approvals.isApproved { return "APPROVED" }
            if (approvals.approvalsRequired ?? 0) > 0 { return "REVIEW_REQUIRED" }
            return nil
        }
        // 没取审批数据时（列表视图），退回用 detailed_merge_status 给个粗略信号。
        // GitLab 没有「要求修改」这个状态，所以只可能是「待评审」或未知。
        if detailedStatus?.lowercased() == "not_approved" { return "REVIEW_REQUIRED" }
        return nil
    }

    /// 把流水线映射成 Grove 的检查列表。
    ///
    /// 有逐项任务数据就展开成一条条（跟 GitHub 的 checks 列表对齐）；
    /// 没有就用流水线整体状态合成一条 —— 列表视图里给每个 MR 拉一遍任务列表
    /// 会打出几十个请求，不值得。
    static func checks(pipeline: GitLabPipeline?, jobs: [GitLabJob]?) -> [StatusCheck]? {
        if let jobs, !jobs.isEmpty {
            return jobs.map { job in
                StatusCheck(
                    __typename: "GitLabJob",
                    name: job.name,
                    status: Self.jobIsFinished(job.status) ? "COMPLETED" : "IN_PROGRESS",
                    conclusion: Self.jobConclusion(job),
                    detailsUrl: job.webUrl,
                    workflowName: job.stage,
                    context: nil,
                    state: nil,
                    targetUrl: nil
                )
            }
        }

        guard let pipeline else { return nil }
        return [
            StatusCheck(
                __typename: "GitLabPipeline",
                name: "流水线",
                status: Self.jobIsFinished(pipeline.status) ? "COMPLETED" : "IN_PROGRESS",
                conclusion: Self.pipelineConclusion(pipeline.status),
                detailsUrl: pipeline.webUrl,
                workflowName: nil,
                context: nil,
                state: nil,
                targetUrl: nil
            )
        ]
    }

    private static func jobIsFinished(_ status: String) -> Bool {
        !["created", "waiting_for_resource", "preparing", "pending", "running", "scheduled"]
            .contains(status.lowercased())
    }

    private static func jobConclusion(_ job: GitLabJob) -> String? {
        // `allow_failure` 的任务失败了不算失败 —— 项目自己声明了它不阻塞。
        // 当成失败会让一堆用了「可选任务」的项目永远显示红色。
        if job.allowFailure == true, job.status.lowercased() == "failed" {
            return "NEUTRAL"
        }
        return pipelineConclusion(job.status)
    }

    private static func pipelineConclusion(_ status: String) -> String? {
        switch status.lowercased() {
        case "success": "SUCCESS"
        case "skipped", "manual", "scheduled": "SKIPPED"
        case "failed": "FAILURE"
        case "canceled": "CANCELLED"
        default: nil    // 还在跑，没有结论
        }
    }
}

extension GitLabDiscussion {
    func asReviewThread() -> ReviewThread? {
        guard let notes, !notes.isEmpty else { return nil }
        let first = notes[0]
        return ReviewThread(
            id: id,
            notes: notes.map { note in
                ReviewNote(
                    id: String(note.id),
                    authorName: note.author?.name ?? note.author?.username ?? "未知",
                    authorLogin: note.author?.username ?? "",
                    body: note.body ?? "",
                    createdAt: note.createdAt,
                    isSystem: note.system ?? false
                )
            },
            filePath: first.position?.newPath ?? first.position?.oldPath,
            line: first.position?.newLine ?? first.position?.oldLine,
            isResolved: first.resolved ?? false,
            isResolvable: first.resolvable ?? false
        )
    }
}
