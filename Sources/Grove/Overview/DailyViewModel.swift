import Foundation
import Observation

@MainActor
@Observable
final class DailyViewModel {
    var commits: [DailyCommit] = [] {
        didSet { rebuildActivityIndex() }
    }
    private struct DayActivity {
        var commits: [DailyCommit]
        var repositoryCount: Int
        var summary: String
    }
    private var activityByDay: [Date: DayActivity] = [:]
    var branches: [DailyBranch] = []
    var issues: [OverviewIssue] = []
    var isRefreshing = false
    var isCached = false
    var lastRefresh: Date?
    var selectedDate = Calendar.current.startOfDay(for: Date())
    private var snapshots: [String: DailyActivityService.Snapshot] = [:]
    private var loadedCache = false
    private let cacheName: String
    @ObservationIgnored private var lastSourceKeys: [String]?
    @ObservationIgnored private var lastScanDay: Date?

    init(cacheName: String = "daily-v1") { self.cacheName = cacheName }

    var days: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (-6...0).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }
    func activity(on day: Date) -> [DailyCommit] { activityByDay[Calendar.current.startOfDay(for: day)]?.commits ?? [] }
    func activeRepositories(on day: Date) -> Int { activityByDay[Calendar.current.startOfDay(for: day)]?.repositoryCount ?? 0 }
    func projectSummary(on day: Date) -> String { activityByDay[Calendar.current.startOfDay(for: day)]?.summary ?? "" }

    /// 只在提交数据变化时汇总，日期切换不再反复扫描整周记录。
    private func rebuildActivityIndex() {
        let calendar = Calendar.current
        activityByDay = Dictionary(grouping: commits, by: { calendar.startOfDay(for: $0.date) }).mapValues { commits in
            let repositories = Dictionary(grouping: commits, by: \.repositoryIdentity)
            let summary = repositories.values.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return ($0.first?.repositoryName ?? "") < ($1.first?.repositoryName ?? "")
            }.map { "\($0.first?.repositoryName ?? "") · \($0.count) 个提交" }.joined(separator: "   ")
            return DayActivity(commits: commits, repositoryCount: repositories.count, summary: summary)
        }
    }
    var aheadRepositoryCount: Int { Set(branches.filter { ($0.ahead ?? 0) > 0 }.map(\.repositoryIdentity)).count }

    func refresh(in app: AppModel, ifNeeded: Bool = false) async {
        guard !Task.isCancelled, !isRefreshing, let git = app.git else { return }
        let sourceKeys = app.repositories.map(\.id.identityKey)
        let scanDay = Calendar.current.startOfDay(for: Date())
        if ifNeeded, lastSourceKeys == sourceKeys, lastScanDay == scanDay,
           issues.isEmpty, !isCached, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 30 {
            publish(emails: app.navigation.authorEmails)
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        if !loadedCache {
            snapshots = await OverviewCache.read(cacheName, as: [String: DailyActivityService.Snapshot].self) ?? [:]
            loadedCache = true
            isCached = !snapshots.isEmpty
            lastRefresh = snapshots.values.map(\.syncedAt).min()
            publish(emails: app.navigation.authorEmails)
        }
        isCached = !snapshots.isEmpty
        issues = []
        var sources: [DailyActivityService.Source] = []
        var seen = Set<String>()
        var failedRepositories = Set<String>()
        for repository in app.repositories {
            guard !Task.isCancelled else { return }
            do {
                let identity = try await DailyActivityService.repositoryIdentity(git: git, root: repository.root)
                guard seen.insert(identity).inserted else { continue }
                sources.append(.init(identity: identity, repositoryKey: repository.id.identityKey, name: repository.name, root: repository.root, git: git))
            } catch {
                failedRepositories.insert(repository.id.identityKey)
                issues.append(.init(source: repository.name, message: "读取仓库身份失败：\(error.localizedDescription)"))
            }
        }
        // 身份读取失败时仍保留该路径的旧缓存；关闭的仓库则移除。
        snapshots = snapshots.filter { seen.contains($0.key) || $0.value.commits.contains { failedRepositories.contains($0.repositoryKey) } || $0.value.branches.contains { failedRepositories.contains($0.repositoryKey) } }
        for source in sources {
            if var snapshot = snapshots[source.identity] {
                snapshot.commits = snapshot.commits.map { var item = $0; item.repositoryKey = source.repositoryKey; item.repositoryName = source.name; return item }
                snapshot.branches = snapshot.branches.map { var item = $0; item.repositoryKey = source.repositoryKey; item.repositoryName = source.name; return item }
                snapshots[source.identity] = snapshot
            }
        }
        publish(emails: app.navigation.authorEmails)
        let start = days.first ?? selectedDate
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        await withTaskGroup(of: (String, DailyActivityService.Snapshot?, String?).self) { group in
            var iterator = sources.makeIterator()
            func add(_ source: DailyActivityService.Source) {
                group.addTask {
                    do { return (source.identity, try await DailyActivityService.scan(source, start: start, end: end), nil) }
                    catch { return (source.identity, nil, "\(source.name)：\(error.localizedDescription)") }
                }
            }
            for _ in 0..<3 { if let source = iterator.next() { add(source) } }
            while let (identity, snapshot, error) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let snapshot { snapshots[identity] = snapshot }
                if let error { issues.append(.init(source: "Daily", message: error)) }
                publish(emails: app.navigation.authorEmails)
                if let next = iterator.next() { add(next) }
            }
        }
        guard !Task.isCancelled else { return }
        lastRefresh = Date()
        lastSourceKeys = sourceKeys
        lastScanDay = scanDay
        isCached = !issues.isEmpty
        if let error = await OverviewCache.write(snapshots, name: cacheName) { issues.append(.init(source: "Daily", message: error)) }
    }

    func publish(emails: [String]) {
        let start = days.first ?? selectedDate
        commits = DailyActivityService.personal(snapshots.values.flatMap(\.commits).filter { $0.date >= start }, emails: emails)
        branches = snapshots.values.flatMap(\.branches).sorted { ($0.repositoryName, $0.name) < ($1.repositoryName, $1.name) }
    }
}
