import XCTest
@testable import Grove

/// GROVE-003 量化：AIReviewCache 的全部条目存在单个 UserDefaults key 里，
/// 每次读写都全量解码 / 重编码。这里量出真实耗时曲线，验证 300 条上限
/// （AIReviewCache.entryLimit）是否把成本压在可接受范围。
///
/// 不是功能门禁，只为拿到数字。N=100 常规跑；500/1000 按 GROVE_SCALE=1
/// 显式开启（对齐渲染测试 GROVE_RENDER=1 的先例），避免拖慢常规 CI。
final class AIReviewCacheScaleTests: XCTestCase {
    private var suiteName: String!
    private var suite: UserDefaults!
    private var cache: AIReviewCache!

    override func setUp() {
        super.setUp()
        suiteName = "grove-cache-scale-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        cache = AIReviewCache(defaults: suite, storageKey: "grove.aiReview.results.scaleTest")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - 构造真实形状的数据

    /// 一条接近实际评审结果的条目：五个评估项 + 风险 findings，
    /// summary/evidence 各几十到两百字，单条 JSON 约 1-2KB。
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

    private func repository(_ index: Int) -> URL {
        URL(fileURLWithPath: "/tmp/scale-repo-\(index % 10)")
    }

    /// 逐条 save（真实的累积方式：每次 save 都全量重写）。
    private func populate(_ count: Int) {
        let start = ContinuousClock.now
        for index in 0..<count {
            cache.save(
                makeReview(seed: index),
                diffFingerprint: String(format: "%016x", index),
                for: repository(index),
                pullRequestNumber: index / 10 + 1,
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let millis = Double(start.duration(to: .now).components.attoseconds) / 1e15
            + Double(start.duration(to: .now).components.seconds) * 1000
        print("[GROVE-003] N=\(count) 累积 \(count) 次 save 总耗时 \(String(format: "%.0f", millis))ms")
    }

    /// 单次 save 的手动计时（一个测试方法只允许一个 measure 块，保存路径用打印）。
    private func measureOneSave() {
        let start = ContinuousClock.now
        cache.save(
            makeReview(seed: .max),
            diffFingerprint: "updated",
            for: repository(0),
            pullRequestNumber: 1
        )
        let duration = start.duration(to: .now)
        let millis = Double(duration.components.attoseconds) / 1e15
            + Double(duration.components.seconds) * 1000
        print("[GROVE-003] 单次 save 耗时 \(String(format: "%.1f", millis))ms")
    }

    // MARK: - 测量

    func testScale100Lookup() throws {
        try runLookupScale(100)
    }

    func testScale500LookupAndSave() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GROVE_SCALE"] == "1",
                          "设置 GROVE_SCALE=1 才测量 500/1000 规模")
        try runLookupScale(500)
        measureOneSave()
    }

    func testScale1000LookupAndSave() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GROVE_SCALE"] == "1",
                          "设置 GROVE_SCALE=1 才测量 500/1000 规模")
        try runLookupScale(1000)
        measureOneSave()
    }

    private func runLookupScale(_ count: Int) throws {
        populate(count)
        // 十次查找（含未命中）——每次都走全量解码路径。
        measure {
            for number in 0..<10 {
                _ = cache.review(for: repository(number), pullRequestNumber: number)
            }
        }
    }
}
