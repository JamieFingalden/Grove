import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceAggregationService {
    struct Source: Sendable {
        var key: String
        var repositoryKey: String
        var name: String
        var root: URL
        var forge: any ForgeClient
        var git: GitClient?
    }
    struct Snapshot: Codable, Sendable {
        var items: [WorkspaceItem]
        var syncedAt: Date
        var viewer: String?
    }
    private struct Result: Sendable {
        var source: Source
        var requests: [WorkspaceItem]?
        var pipelines: [WorkspaceItem]?
        var issues: [OverviewIssue]
        var failedHistory = false
        var viewer: String?
    }
    var items: [WorkspaceItem] = []
    var issues: [OverviewIssue] = []
    var isRefreshing = false
    var lastRefresh: Date?
    var isCached = false
    private var snapshots: [String: Snapshot] = [:]
    private var verifiedViewers: [String: String] = [:]
    private var cachedProjects = Set<String>()
    private var loadedCache = false
    private let cacheName: String

    init(cacheName: String = "workspace-v1") { self.cacheName = cacheName }

    func refresh(in app: AppModel) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if !loadedCache {
            snapshots = await OverviewCache.read(cacheName, as: [String: Snapshot].self) ?? [:]
            loadedCache = true
            isCached = !snapshots.isEmpty
        }
        var seen = Set<String>()
        let sources = app.repositories.compactMap { repository -> Source? in
            guard let forge = repository.forge, let origin = repository.origin else { return nil }
            let key = WorkspaceItem.projectIdentity(provider: forge.kind, origin: origin)
            guard seen.insert(key).inserted else { return nil }
            return Source(key: key, repositoryKey: repository.id.identityKey, name: repository.name, root: repository.root, forge: forge, git: app.git)
        }
        let sourceKeys = Set(sources.map(\.key))
        cachedProjects = sourceKeys
        if lastRefresh == nil { lastRefresh = snapshots.values.map(\.syncedAt).min() }
        snapshots = snapshots.filter { sourceKeys.contains($0.key) }
        publish(sources)
        isCached = !items.isEmpty
        issues = app.repositories.compactMap { repository in
            guard repository.origin != nil, repository.forge == nil else { return nil }
            return OverviewIssue(source: repository.name, message: repository.forgeSetup?.summary ?? "平台服务不可用，请在设置中检查 CLI 与认证。")
        }
        // ponytail: 同时最多扫描三个项目；超大项目集可改为带优先级的请求队列。
        await withTaskGroup(of: Result.self) { group in
            var providers = ForgeKind.allCases.map { kind in sources.filter { $0.forge.kind == kind }.makeIterator() }
            var schedule: [Source] = []
            while schedule.count < sources.count {
                for index in providers.indices { if let source = providers[index].next() { schedule.append(source) } }
            }
            var iterator = schedule.makeIterator()
            for _ in 0..<3 { if let source = iterator.next() { group.addTask { await Self.load(source) } } }
            while let result = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let next = iterator.next() { group.addTask { await Self.load(next) } }
                guard app.repositories.contains(where: {
                    $0.id.identityKey == result.source.repositoryKey && $0.origin.map {
                        WorkspaceItem.projectIdentity(provider: result.source.forge.kind, origin: $0)
                    } == result.source.key
                }) else { continue }
                verifiedViewers[result.source.key] = result.viewer
                let old = snapshots[result.source.key]?.items ?? []
                var requests = result.requests ?? old.filter { $0.pullRequest != nil }
                if result.failedHistory { requests += old.filter { oldItem in oldItem.pullRequest?.isActive == false && !requests.contains(where: { $0.id == oldItem.id }) } }
                let pipelines = result.pipelines ?? old.filter { $0.pipeline != nil }
                if result.requests != nil || result.pipelines != nil {
                    snapshots[result.source.key] = Snapshot(items: requests + pipelines,
                        syncedAt: result.issues.isEmpty ? Date() : snapshots[result.source.key]?.syncedAt ?? Date(),
                        viewer: result.requests != nil ? result.viewer : snapshots[result.source.key]?.viewer)
                }
                if result.issues.isEmpty { cachedProjects.remove(result.source.key) }
                issues += result.issues
                publish(sources)
            }
        }
        guard !Task.isCancelled else { return }
        lastRefresh = Date()
        isCached = !issues.isEmpty
        if let error = await OverviewCache.write(snapshots, name: cacheName) {
            issues.append(OverviewIssue(source: "Workspace", message: error))
        }
    }

    private func publish(_ sources: [Source]) {
        items = sources.flatMap { source in
            (snapshots[source.key]?.items ?? []).map { item in
                var item = item
                item.repositoryKey = source.repositoryKey
                item.repositoryName = source.name
                item.cacheTimestamp = snapshots[source.key]?.syncedAt
                item.isCached = cachedProjects.contains(source.key)
                if item.pullRequest != nil { item.pullRequest?.forge = item.provider }
                // 缓存不能借用上次登录账号的个人归属；确认当前账号一致后才恢复 Inbox。
                if verifiedViewers[source.key] == nil || verifiedViewers[source.key]?.lowercased() != snapshots[source.key]?.viewer?.lowercased() {
                    item.inboxReasons = []
                    item.relatedToMe = false
                }
                return item
            }
        }.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
    }

    nonisolated private static func load(_ source: Source) async -> Result {
        var result = Result(source: source, issues: [])
        if let git = source.git {
            guard let raw = await git.remoteURL(in: source.root), let remote = GitRemote.parse(raw),
                  WorkspaceItem.projectIdentity(provider: source.forge.kind, origin: remote) == source.key else {
                result.issues.append(.init(source: source.name, message: "origin 已变化或无法读取，请先刷新原仓库；本次保留旧快照。"))
                return result
            }
        }
        var viewer: String?
        do { viewer = try await source.forge.currentUser(in: source.root) }
        catch { result.issues.append(.init(source: source.name, message: "个人身份不可用，Inbox 不推断归属：\(error.localizedDescription)")) }
        result.viewer = viewer
        do {
            let open = try await source.forge.pullRequests(in: source.root, limit: RepositoryModel.openPullRequestLimit, state: .open)
            var recent: [PullRequest] = []
            do { recent = try await source.forge.pullRequests(in: source.root, limit: 50, state: .all) }
            catch {
                result.failedHistory = true
                result.issues.append(.init(source: source.name, message: "历史快照同步失败：\(error.localizedDescription)"))
            }
            var requests: [Int: PullRequest] = [:]
            for request in recent + open { requests[request.number] = request }
            var normalized: [WorkspaceItem] = []
            var detailsLoaded = 0
            for var request in requests.values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                // GitLab 列表没有逐项检查；只补本人或指定给本人的开放请求，避免对全部 MR 发详情请求。
                if source.forge.kind == .gitlab && request.isActive && viewer != nil &&
                    (request.author?.login.lowercased() == viewer?.lowercased() || request.reviewRequests?.contains { $0.login?.lowercased() == viewer?.lowercased() } == true) {
                    // ponytail: 每项目最多补充 50 条相关 MR 详情；更大收件箱可改为按需加载。
                    if detailsLoaded < 50 {
                        detailsLoaded += 1
                        do { request = try await source.forge.pullRequest(number: request.number, in: source.root) }
                        catch { result.issues.append(.init(source: source.name, message: "MR !\(request.number) 详情不可用：\(error.localizedDescription)")) }
                    } else if detailsLoaded == 50 {
                        detailsLoaded += 1
                        result.issues.append(.init(source: source.name, message: "本次最多补充 50 条相关 MR 详情，其余仅显示列表可确认的状态。"))
                    }
                }
                normalized.append(.request(request, viewer: viewer, project: source.key, repository: source.repositoryKey, name: source.name))
            }
            result.requests = normalized
            if open.count >= RepositoryModel.openPullRequestLimit {
                result.issues.append(.init(source: source.name, message: "开放请求达到 1000 条上限；历史快照最多包含最近 50 条。"))
            }
        } catch { result.issues.append(.init(source: source.name, message: "PR/MR 同步失败：\(error.localizedDescription)")) }
        do {
            let pipelines = try await source.forge.pipelines(in: source.root, limit: 50)
            var seen = Set<Int>()
            result.pipelines = pipelines.filter { seen.insert($0.id).inserted }.map {
                WorkspaceItem(projectKey: source.key, repositoryKey: source.repositoryKey, repositoryName: source.name,
                              provider: source.forge.kind, pipeline: $0, relatedToMe: false, inboxReasons: [])
            }
        } catch { result.issues.append(.init(source: source.name, message: "CI 同步失败：\(error.localizedDescription)")) }
        return result
    }
}
