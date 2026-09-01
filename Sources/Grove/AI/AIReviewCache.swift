import Foundation

struct CachedPullRequestAIReview: Codable, Sendable, Equatable {
    var review: PullRequestAIReview
    var diffFingerprint: String
    var createdAt: Date
}

/// AI Review 按仓库和请求编号落盘。切换页面或重启应用都不会丢，
/// 只有新 Review 覆盖旧结果，或者请求合并成功后才删除。
struct AIReviewCache {
    private struct Entry: Codable {
        var repositoryPath: String
        var pullRequestNumber: Int
        var value: CachedPullRequestAIReview
    }

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "grove.aiReview.results.v2") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func review(for repository: URL, pullRequestNumber: Int) -> CachedPullRequestAIReview? {
        entries.first {
            $0.repositoryPath == repositoryKey(repository)
                && $0.pullRequestNumber == pullRequestNumber
        }?.value
    }

    func save(
        _ review: PullRequestAIReview,
        diffFingerprint: String,
        for repository: URL,
        pullRequestNumber: Int,
        createdAt: Date = Date()
    ) {
        var updated = entries
        let path = repositoryKey(repository)
        let entry = Entry(
            repositoryPath: path,
            pullRequestNumber: pullRequestNumber,
            value: CachedPullRequestAIReview(
                review: review,
                diffFingerprint: diffFingerprint,
                createdAt: createdAt
            )
        )
        if let index = updated.firstIndex(where: {
            $0.repositoryPath == path && $0.pullRequestNumber == pullRequestNumber
        }) {
            updated[index] = entry
        } else {
            updated.append(entry)
        }
        persist(updated)
    }

    func remove(for repository: URL, pullRequestNumber: Int) {
        let path = repositoryKey(repository)
        persist(entries.filter {
            $0.repositoryPath != path || $0.pullRequestNumber != pullRequestNumber
        })
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

    private var entries: [Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persist(_ entries: [Entry]) {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func repositoryKey(_ repository: URL) -> String {
        repository.standardizedFileURL.path
    }
}
