import Foundation

struct OverviewIssue: Identifiable, Sendable {
    var source: String
    var message: String
    var id: String { source + message }
}

/// 事项身份属于远端项目；本地路径只负责跳回原有页面。
struct WorkspaceItem: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, CaseIterable, Codable { case pullRequest, ci, conflict }
    var projectKey: String
    var repositoryKey: String
    var repositoryName: String
    var provider: ForgeKind
    var pullRequest: PullRequest?
    var pipeline: CIPipeline?
    var relatedToMe: Bool
    var inboxReasons: [String]
    var cacheTimestamp: Date? = nil
    var isCached: Bool? = nil

    var id: String {
        "\(projectKey):\(pullRequest.map { "pr:\($0.number)" } ?? "pipeline:\(pipeline?.id ?? 0)")"
    }
    var kind: Kind { pullRequest?.mergeable == "CONFLICTING" && pullRequest?.isActive == true ? .conflict : pullRequest != nil ? .pullRequest : .ci }
    var title: String { pullRequest?.title ?? pipeline?.title ?? "CI Pipeline" }
    var objectLabel: String {
        if let pr = pullRequest { return "\(provider.shortTerm) \(provider.numberPrefix)\(pr.number)" }
        return "Pipeline #\(pipeline?.id ?? 0)"
    }
    var timestamp: Date? { pullRequest?.updatedAt ?? pipeline?.updatedAt ?? pipeline?.createdAt }
    var statusLabel: String { pullRequest?.status.label ?? pipeline?.status.label ?? "未知" }
    var branch: String { pullRequest.map { "\($0.headRefName) → \($0.baseRefName)" } ?? pipeline?.ref ?? "" }
    var priority: Int { kind == .conflict ? 3 : inboxReasons.contains("CI 检查失败") ? 2 : 1 }

    func matches(type: String, status: String) -> Bool {
        let matchesType: Bool
        switch Kind(rawValue: type) {
        case .pullRequest: matchesType = pullRequest != nil
        case .ci: matchesType = pipeline != nil || (pullRequest.map { $0.checks != .none } ?? false)
        case .conflict: matchesType = kind == .conflict
        case nil: matchesType = true
        }
        if status == "开放 / 草稿" { return matchesType && pullRequest?.isActive == true }
        var statuses = Set([statusLabel])
        if let pr = pullRequest {
            if let review = pr.review.label { statuses.insert(review) }
            if kind == .conflict { statuses.insert("Git 冲突") }
            switch pr.checks {
            case .failing: statuses.insert("已失败")
            case .running: statuses.insert("运行中")
            case .passing: statuses.insert("已通过")
            case .none: break
            }
        }
        return matchesType && (status.isEmpty || statuses.contains(status))
    }

    static func projectIdentity(provider: ForgeKind, origin: GitRemote) -> String {
        // GitHub 路径大小写不敏感，GitLab 路径则保留服务器给出的大小写。
        let path = provider == .github ? origin.path.lowercased() : origin.path
        return "\(provider.rawValue):\(origin.hostWithPort.lowercased()):\(path)"
    }

    static func request(_ pr: PullRequest, viewer: String?, project: String, repository: String, name: String) -> Self {
        let login = viewer?.lowercased()
        let mine = login != nil && pr.author?.login.lowercased() == login
        let requested = login != nil && pr.reviewRequests?.contains { $0.login?.lowercased() == login } == true
        var reasons: [String] = []
        if pr.isActive {
            if requested && !pr.isDraft && !pr.viewerHasApproved { reasons.append("请求我评审") }
            if mine {
                if pr.mergeable == "CONFLICTING" { reasons.append("Git 合并冲突") }
                if case .failing = pr.checks { reasons.append("CI 检查失败") }
                if pr.review == .changesRequested { reasons.append("评审要求修改") }
            }
        }
        return Self(projectKey: project, repositoryKey: repository, repositoryName: name,
                    provider: pr.forge, pullRequest: pr, relatedToMe: mine || requested, inboxReasons: reasons)
    }
}
