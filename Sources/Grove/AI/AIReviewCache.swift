import Foundation

struct CachedPullRequestAIReview: Codable, Sendable, Equatable {
    var review: PullRequestAIReview
    var diffFingerprint: String
    var createdAt: Date
    var head: String? = nil
    var requestURL: String? = nil
}

/// AI Review 按仓库和请求编号的落盘缓存。
///
/// 存储：内存字典 + 单个 JSON 文件（`~/Library/Caches/Grove/AIReviews/entries.json`）。
/// 读取走内存 O(1)——视图在 body 里同步查缓存，这里不能有 IO；写盘在后台线程
/// 串行排队、整文件原子替换。这个形态取代旧版「全部条目塞一个 UserDefaults
/// key、每次读写全量解码重写」——那个方案的解码成本随条目数线性增长
/// （无界时 1000 条单次查找 ~17ms、累积保存平方级，量化结论留在
/// AIReviewCacheScaleTests 的历史注释里），UserDefaults 也不该当数据库用。
///
/// 装载在 bootstrap 里异步完成；装载完成前的读取按未命中处理，装载后由
/// 调用方 bump 修订计数刷新界面。旧版 UserDefaults 存储在首次装载时
/// 一次性迁移并删除原 key。切换页面或重启应用缓存都不丢；条目按
/// `createdAt` LRU 淘汰（上限 300），只有新 Review 覆盖旧结果，
/// 或者请求合并 / 关闭后由调用方删除。
@MainActor
final class AIReviewCache {
    struct Store: Codable, Sendable {
        var entries: [Entry]

        struct Entry: Codable, Sendable {
            var repositoryPath: String
            var pullRequestNumber: Int
            var value: CachedPullRequestAIReview
        }
    }

    private struct Key: Hashable, Sendable {
        let repositoryPath: String
        let pullRequestNumber: Int
    }

    /// 条目上限。300 条以内单条 JSON ~1-2KB、整文件 ~600KB 封顶，
    /// 超限按 createdAt 淘汰最旧。
    static let entryLimit = 300

    static let defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Grove/AIReviews", isDirectory: true)

    /// 旧版（UserDefaults 单 key）的存储键，装载时一次性迁移后删除。
    nonisolated private static let legacyStorageKey = "grove.aiReview.results.v2"

    private let fileURL: URL
    private var entries: [Key: CachedPullRequestAIReview] = [:]
    private var persistenceTask: Task<Void, Never>?
    private(set) var isLoaded = false

    init(storageDirectory: URL = AIReviewCache.defaultDirectory) {
        fileURL = storageDirectory.appendingPathComponent("entries.json")
    }

    // MARK: - 装载与迁移

    /// 异步装载（启动路径）：磁盘读取在后台线程。
    func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true
        let fileURL = self.fileURL
        var store = await Task.detached(priority: .utility) { () -> Store? in
            Self.readStore(at: fileURL)
        }.value
        var didMigrate = false
        if store == nil {
            store = await Task.detached(priority: .utility) { () -> Store? in
                Self.readLegacyStore()
            }.value
            didMigrate = store != nil
        }
        ingest(store)
        if didMigrate { schedulePersist() }
    }

    /// 同步装载（测试，或启动早期需要同步可见的场景）。与异步版本语义一致。
    func loadSynchronously() {
        guard !isLoaded else { return }
        isLoaded = true
        var didMigrate = false
        var store = Self.readStore(at: fileURL)
        if store == nil {
            store = Self.readLegacyStore()
            didMigrate = store != nil
        }
        ingest(store)
        if didMigrate { schedulePersist() }
    }

    private func ingest(_ store: Store?) {
        guard let store else { return }
        for entry in store.entries {
            entries[Key(repositoryPath: entry.repositoryPath, pullRequestNumber: entry.pullRequestNumber)] = entry.value
        }
        trimToLimit()
    }

    nonisolated private static func readStore(at fileURL: URL) -> Store? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Store.self, from: data)
    }

    /// 旧版迁移：读 UserDefaults 单 key 的全部条目，迁移成功即删除原 key。
    nonisolated private static func readLegacyStore() -> Store? {
        guard let data = UserDefaults.standard.data(forKey: legacyStorageKey) else { return nil }
        // 旧 Entry 形状与本版一致（repositoryPath/pullRequestNumber/value）。
        struct LegacyStore: Codable {
            var entries: [Store.Entry]
        }
        guard let legacy = try? JSONDecoder().decode(LegacyStore.self, from: data) else { return nil }
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
        return Store(entries: legacy.entries)
    }

    // MARK: - 读写

    func review(for repository: URL, pullRequestNumber: Int) -> CachedPullRequestAIReview? {
        entries[key(for: repository, pullRequestNumber: pullRequestNumber)]
    }

    func save(
        _ review: PullRequestAIReview,
        diffFingerprint: String,
        for repository: URL,
        pullRequestNumber: Int,
        createdAt: Date = Date(),
        head: String? = nil,
        requestURL: String? = nil
    ) {
        entries[key(for: repository, pullRequestNumber: pullRequestNumber)] = CachedPullRequestAIReview(
            review: review,
            diffFingerprint: diffFingerprint,
            createdAt: createdAt,
            head: head,
            requestURL: requestURL
        )
        trimToLimit()
        schedulePersist()
    }

    func remove(for repository: URL, pullRequestNumber: Int) {
        guard entries.removeValue(forKey: key(for: repository, pullRequestNumber: pullRequestNumber)) != nil else { return }
        schedulePersist()
    }

    static func diffFingerprint(_ files: [FileDiff]) -> String {
        // Swift Hasher 每次启动都会换种子，不能拿来判断跨启动的 diff 是否变化。
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in PullRequestReviewPromptBuilder.unifiedDiff(files).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func key(for repository: URL, pullRequestNumber: Int) -> Key {
        Key(repositoryPath: repository.standardizedFileURL.path, pullRequestNumber: pullRequestNumber)
    }

    private func trimToLimit() {
        guard entries.count > Self.entryLimit else { return }
        let excess = entries.count - Self.entryLimit
        let oldest = entries.sorted { $0.value.createdAt < $1.value.createdAt }.prefix(excess)
        for (key, _) in oldest {
            entries.removeValue(forKey: key)
        }
    }

    // MARK: - 持久化

    /// 后台写盘：整文件原子替换；任务串行排队，后一次快照永远覆盖前一次。
    private func schedulePersist() {
        let snapshot = Store(entries: entries
            .map { Store.Entry(repositoryPath: $0.key.repositoryPath, pullRequestNumber: $0.key.pullRequestNumber, value: $0.value) }
            .sorted { $0.value.createdAt < $1.value.createdAt })
        let target = fileURL
        let previous = persistenceTask
        persistenceTask = Task.detached(priority: .utility) {
            await previous?.value
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }
    }

    /// 等所有排队的写盘任务结束（测试用；装载后写入极快，正常路径无需等待）。
    func waitForPersistence() async {
        while let task = persistenceTask {
            persistenceTask = nil   // 先取走引用再等待；等待期间新入队的下一轮接住
            await task.value
        }
    }
}
