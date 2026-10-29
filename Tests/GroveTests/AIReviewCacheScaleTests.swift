import XCTest
@testable import Grove

/// AIReviewCache 的成本守门。
///
/// 历史结论（催生新设计的量化，2026-10-29）：旧版把全部条目塞一个
/// UserDefaults key，每次读写全量解码/重编码——无界时 1000 条单次查找
/// ~17ms（主线程）、逐条累积保存呈平方级（1000 次共 ~17s）；加 300 条
/// LRU 上限后稳态仍有 ~6ms/查找、~11ms/保存。
///
/// 新设计（内存字典 + 后台单文件写盘）目标：查找回到微秒级（视图在
/// body 里同步查缓存），写盘移出主线程。这里守住这两点不回退。
/// N=1000 的写入量按 GROVE_SCALE=1 显式开启（对齐 GROVE_RENDER 先例）。
@MainActor
final class AIReviewCacheScaleTests: XCTestCase {
    private var directory: URL!
    private var cache: AIReviewCache!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-cache-scale-\(UUID().uuidString)", isDirectory: true)
        cache = AIReviewCache(storageDirectory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// 一条接近实际评审结果的条目（五个评估项 + findings，~1-2KB）。
    private func makeReview(seed: Int) -> PullRequestAIReview {
        func text(_ prefix: String) -> String {
            prefix + String(repeating: "核对过的符号、路径与判断依据见 evidence。", count: 4)
        }
        let assessments = PullRequestAIReview.Assessment.Area.allCases.map { area in
            PullRequestAIReview.Assessment(
                area: area,
                status: area == .dataSafety ? .risk : .clear,
                summary: text("评估项 \(area.rawValue)："),
                evidence: text("触发条件：输入包含 \(seed) 时……"),
                file: "Sources/Grove/Module\(seed % 7)/File\(seed % 13).swift",
                line: seed % 400 + 1
            )
        }
        let findings = assessments.filter { $0.status == .risk }.map { assessment in
            PullRequestAIReview.Assessment(
                area: assessment.area, status: .risk,
                summary: assessment.summary,
                evidence: assessment.evidence,
                file: assessment.file, line: assessment.line
            )
        }
        return PullRequestAIReview(
            verdict: .needsChanges,
            summary: text("合并建议：存在一条数据安全风险，建议先处理再合并。"),
            assessments: assessments,
            wasTruncated: false,
            truncationNote: nil,
            findings: findings
        )
    }

    /// 查找必须停在内存字典上：一千次命中/未命中混合查找应在毫秒级。
    func testLookupStaysInMemoryFastAtCap() {
        for index in 0..<AIReviewCache.entryLimit {
            cache.save(
                makeReview(seed: index),
                diffFingerprint: String(index),
                for: URL(fileURLWithPath: "/tmp/scale-repo-\(index % 10)"),
                pullRequestNumber: index,
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        measure {
            for index in 0..<1000 {
                _ = cache.review(
                    for: URL(fileURLWithPath: "/tmp/scale-repo-\(index % 10)"),
                    pullRequestNumber: index % (AIReviewCache.entryLimit + 50)
                )
            }
        }
    }

    /// 满上限时的一次写盘（后台串行、整文件 ~600KB）——量的是后台耗时，
    /// 不在主线程；这里只验证往返正确与时延有界。
    func testPersistenceRoundTripAtCap() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GROVE_SCALE"] == "1",
                          "设置 GROVE_SCALE=1 才测量满上限写盘")
        for index in 0..<AIReviewCache.entryLimit {
            cache.save(
                makeReview(seed: index),
                diffFingerprint: String(index),
                for: URL(fileURLWithPath: "/tmp/scale-repo-\(index % 10)"),
                pullRequestNumber: index,
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        cache.save(
            makeReview(seed: .max),
            diffFingerprint: "updated",
            for: URL(fileURLWithPath: "/tmp/scale-repo-0"),
            pullRequestNumber: 1
        )
        let start = ContinuousClock.now
        await cache.waitForPersistence()
        let millis = Double(start.duration(to: .now).components.seconds) * 1000
            + Double(start.duration(to: .now).components.attoseconds) / 1e15
        print("[AIReviewCache] 满上限（\(AIReviewCache.entryLimit) 条）单次写盘 \(String(format: "%.1f", millis))ms（后台线程）")

        let reloaded = AIReviewCache(storageDirectory: directory)
        await reloaded.loadIfNeeded()
        XCTAssertNotNil(reloaded.review(for: URL(fileURLWithPath: "/tmp/scale-repo-0"), pullRequestNumber: 1))
        XCTAssertNil(reloaded.review(for: URL(fileURLWithPath: "/tmp/scale-repo-0"), pullRequestNumber: 0),
                     "LRU 淘汰在重装后仍然成立")
    }
}
