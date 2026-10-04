import XCTest
@testable import Grove

final class CITests: XCTestCase {
    // MARK: - 状态规范化

    func testGitLabStatusVocabulary() {
        XCTAssertEqual(CIStatus.gitlab("running"), .running)
        XCTAssertEqual(CIStatus.gitlab("success"), .success)
        XCTAssertEqual(CIStatus.gitlab("failed"), .failed)
        XCTAssertEqual(CIStatus.gitlab("canceled"), .canceled)
        XCTAssertEqual(CIStatus.gitlab("skipped"), .skipped)
        XCTAssertEqual(CIStatus.gitlab("manual"), .manual)
        // 老版本 GitLab（13.x）会出现的「还没跑起来」们，全算等待中。
        for raw in ["created", "pending", "waiting_for_resource", "preparing", "scheduled"] {
            XCTAssertEqual(CIStatus.gitlab(raw), .pending, raw)
        }
    }

    func testGitHubStatusVocabulary() {
        XCTAssertEqual(CIStatus.github(status: "queued", conclusion: nil), .pending)
        XCTAssertEqual(CIStatus.github(status: "in_progress", conclusion: nil), .running)
        XCTAssertEqual(CIStatus.github(status: "completed", conclusion: "success"), .success)
        XCTAssertEqual(CIStatus.github(status: "completed", conclusion: "failure"), .failed)
        XCTAssertEqual(CIStatus.github(status: "completed", conclusion: "timed_out"), .failed)
        XCTAssertEqual(CIStatus.github(status: "completed", conclusion: "cancelled"), .canceled)
        XCTAssertEqual(CIStatus.github(status: "completed", conclusion: "skipped"), .skipped)
        // 完成了但没有结论：按等待处理，别把怪数据渲染成失败。
        XCTAssertEqual(CIStatus.github(status: "completed", conclusion: nil), .pending)
    }

    func testFinalStatuses() {
        XCTAssertTrue(CIStatus.success.isFinal)
        XCTAssertTrue(CIStatus.failed.isFinal)
        XCTAssertFalse(CIStatus.running.isFinal)
        XCTAssertFalse(CIStatus.manual.isFinal)
    }

    // MARK: - 日志清洗

    func testLogStripsANSIColorCodes() {
        let raw = "\u{1B}[31mFAIL\u{1B}[0m ok \u{1B}[1;32mPASS\u{1B}[0m"
        XCTAssertEqual(CILog.plain(raw), "FAIL ok PASS")
    }

    func testLogStripsCursorAndTitleSequences() {
        let raw = "\u{1B}[2Kclean line\u{1B}]0;window title\u{1B}\\\u{1B}Mtail"
        XCTAssertEqual(CILog.plain(raw), "clean linetail")
    }

    func testLogNormalizesCarriageReturns() {
        // docker pull 式进度条：\r 覆盖行。当换行处理才不会糊成一行。
        XCTAssertEqual(CILog.plain("pulling 10%\rpulling 99%\rdone\r\n"), "pulling 10%\npulling 99%\ndone\n")
    }

    // MARK: - 展示格式

    func testDurationFormatting() {
        XCTAssertEqual(CIFormat.duration(nil), "—")
        XCTAssertEqual(CIFormat.duration(0.4), "—")
        XCTAssertEqual(CIFormat.duration(45), "45 秒")
        XCTAssertEqual(CIFormat.duration(83), "1 分 23 秒")
        XCTAssertEqual(CIFormat.duration(3661), "1 时 1 分")
    }

    // MARK: - 分支 → 状态索引

    private func makePipeline(_ id: Int, ref: String, status: CIStatus, createdAt: Date = .init(timeIntervalSince1970: 0)) -> CIPipeline {
        CIPipeline(
            id: id,
            status: status,
            ref: ref,
            sha: "000000000000000000000000000000000000000\(id)",
            title: nil,
            trigger: nil,
            createdAt: createdAt,
            duration: nil,
            webURL: nil
        )
    }

    func testLatestStatusByRefFirstWins() {
        // 列表新到旧：同一个分支的第一条就是最新的。
        let list = [
            makePipeline(3, ref: "main", status: .success),
            makePipeline(2, ref: "feature", status: .running),
            makePipeline(1, ref: "main", status: .failed)
        ]
        let index = CIPipelineIndex.latestStatusByRef(list)
        XCTAssertEqual(index["main"], .success)
        XCTAssertEqual(index["feature"], .running)
    }

    func testLatestStatusByRefEmptyRefIgnored() {
        let list = [
            makePipeline(1, ref: "", status: .failed),
            makePipeline(2, ref: "dev", status: .pending)
        ]
        let index = CIPipelineIndex.latestStatusByRef(list)
        XCTAssertNil(index[""])
        XCTAssertEqual(index["dev"], .pending)
    }

    // MARK: - 失败摘要

    func testFailureExcerptsTraceback() {
        let lines = [
            "$ python -m pytest tests/",
            "test_a ... ok",
            "Traceback (most recent call last):",
            "  File \"app.py\", line 3, in <module>",
            "ZeroDivisionError: division by zero",
            "",
            "Some unrelated output afterwards"
        ]
        let excerpts = CILog.failureExcerpts(lines: lines)
        XCTAssertEqual(excerpts.count, 1)
        XCTAssertEqual(excerpts[0].lineNumber, 3)
        XCTAssertTrue(excerpts[0].snippet.contains("Traceback"))
        XCTAssertTrue(excerpts[0].snippet.contains("ZeroDivisionError"))
    }

    func testFailureExcerptsPytestAndMake() {
        let lines = [
            "step 1",
            "--- FAIL: TestBuild (build_test.go:12)",
            "    assertion failed",
            "0",
            "1",
            "2",
            "3",
            "4",
            "5",
            "6",
            "7",
            "make[1]: *** [Makefile:8: test] Error 1"
        ]
        let excerpts = CILog.failureExcerpts(lines: lines)
        XCTAssertEqual(excerpts.count, 2)
        XCTAssertEqual(excerpts[0].lineNumber, 2)
        XCTAssertEqual(excerpts[1].lineNumber, 12)
    }

    func testFailureExcerptsCleanLogIsEmpty() {
        let lines = [
            "Cloning into ...",
            "Resolving deltas: 100% done",
            "All tests passed"
        ]
        XCTAssertTrue(CILog.failureExcerpts(lines: lines).isEmpty)
    }

    func testFailureExcerptsDedupGap() {
        // 相邻两处报错隔太近（≤6 行）算同一段，只取第一处。
        let lines = [
            "ERROR: first",
            "ERROR: second right after",
            "10 unrelated lines follow",
            "2", "3", "4", "5", "6", "7", "8", "9", "10",
            "11", "12", "13", "14", "15",
            "ERROR: far enough"
        ]
        let excerpts = CILog.failureExcerpts(lines: lines)
        XCTAssertEqual(excerpts.count, 2)
        XCTAssertEqual(excerpts[0].lineNumber, 1)
        XCTAssertEqual(excerpts[1].lineNumber, 18)
    }

    // MARK: - 平台能力

    func testJobLogAvailabilityByPlatformAndStatus() {
        for forge in ForgeKind.allCases {
            for status in [CIStatus.pending, .manual, .skipped] {
                XCTAssertFalse(forge.supportsJobLog(status: status))
            }
            for status in [CIStatus.success, .failed, .canceled] {
                XCTAssertTrue(forge.supportsJobLog(status: status))
            }
        }
        XCTAssertFalse(ForgeKind.github.supportsJobLog(status: .running))
        XCTAssertTrue(ForgeKind.gitlab.supportsJobLog(status: .running))
    }

    func testJobLevelControlCapability() {
        XCTAssertTrue(ForgeKind.gitlab.supportsJobLevelControl)
        XCTAssertFalse(ForgeKind.github.supportsJobLevelControl)
    }
}
