import XCTest
@testable import Grove

final class CommitGraphLayoutTests: XCTestCase {
    private func commit(
        _ oid: String,
        parents: [String] = [],
        refs: [CommitRef] = []
    ) -> CommitSummary {
        CommitSummary(
            oid: oid, subject: oid, authorName: "测试", authorEmail: "test@example.com",
            date: .distantPast, parents: parents, refs: refs
        )
    }

    private func ref(_ name: String) -> CommitRef {
        CommitRef(name: name, kind: .localBranch)
    }

    func testMainAndCurrentLanesStayFixedThroughForkAndMerge() {
        let commits = [
            commit("main-3", parents: ["main-2", "feature-2"], refs: [ref("main")]),
            commit("feature-2", parents: ["base"], refs: [ref("feature/login")]),
            commit("main-2", parents: ["base"]),
            commit("base")
        ]
        let graph = CommitGraphLayout.build(
            commits,
            context: .init(defaultBranch: "main", currentBranch: "feature/login")
        )

        XCTAssertEqual(graph.rows.first { $0.oid == "main-3" }?.commitLane, 0)
        XCTAssertEqual(graph.rows.first { $0.oid == "feature-2" }?.commitLane, 1)
        XCTAssertEqual(graph.rows.first { $0.oid == "base" }?.commitLane, 0)
        XCTAssertEqual(graph.rows.first { $0.oid == "feature-2" }?.color, 1)
    }

    func testReleasedDynamicLaneIsReused() {
        let graph = CommitGraphLayout.build([
            commit("merge-2", parents: ["main-1", "feature-2"], refs: [ref("main")]),
            commit("feature-2", parents: ["base"]),
            commit("main-1", parents: ["base"]),
            commit("base"),
            commit("later-tip", parents: [])
        ], context: .init(defaultBranch: "main", currentBranch: nil))

        XCTAssertEqual(graph.rows.first { $0.oid == "later-tip" }?.commitLane, 1)
        XCTAssertLessThanOrEqual(graph.laneCount, 2)
    }

    func testComplexDAGKeepsAllParentsAndReusesDynamicLane() {
        var commits: [CommitSummary] = [
            commit("main-20", parents: ["main-19", "current-20"], refs: [ref("main")]),
            commit("current-20", parents: ["main-0"], refs: [ref("feature/current")])
        ]
        for index in stride(from: 19, through: 1, by: -1) {
            commits.append(commit("main-\(index)", parents: ["main-\(index - 1)", "feature-\(index)"]))
            commits.append(commit("feature-\(index)", parents: ["main-\(index - 1)"]))
        }
        commits.append(commit("main-0"))

        let graph = CommitGraphLayout.build(
            commits,
            context: .init(defaultBranch: "main", currentBranch: "feature/current")
        )

        XCTAssertEqual(commits.count, 41)
        XCTAssertEqual(graph.rows.count, commits.count)
        XCTAssertEqual(graph.rows.first { $0.oid == "main-20" }?.commitLane, 0)
        XCTAssertEqual(graph.rows.first { $0.oid == "current-20" }?.commitLane, 1)
        XCTAssertLessThanOrEqual(graph.laneCount, 3)
        for commit in commits where commit.parents.count > 1 {
            let row = try! XCTUnwrap(graph.rows.first { $0.oid == commit.oid })
            XCTAssertEqual(row.outgoing.filter { $0.from == row.commitLane }.count, commit.parents.count)
        }
    }

    func testDynamicBranchesGetDistinctColorsAndPreserveTopology() {
        var commits = [
            commit("main-1", parents: ["base"], refs: [ref("main")]),
            commit("current", parents: ["base"], refs: [ref("feature/current")])
        ]
        for index in 1...5 {
            commits.append(commit("feature-\(index)", parents: ["base"], refs: [ref("feature/\(index)")]))
        }
        commits.append(commit("base"))

        let graph = CommitGraphLayout.build(
            commits,
            context: .init(defaultBranch: "main", currentBranch: "feature/current")
        )

        XCTAssertEqual(graph.rows.count, commits.count)
        XCTAssertEqual(graph.rows.first { $0.oid == "main-1" }?.color, 0)
        XCTAssertEqual(graph.rows.first { $0.oid == "current" }?.color, 1)

        // 验证动态分支分配了不同颜色
        let dynamicColors = graph.rows
            .filter { $0.oid.hasPrefix("feature-") }
            .map(\.color)
        let uniqueColors = Set(dynamicColors)
        XCTAssertGreaterThan(uniqueColors.count, 1, "多个并行动态分支应被赋予不同色彩")
    }

    func testFocusHighlightsSelectedLineageAndDimsOthers() {
        var commits = [
            commit("main-1", parents: ["base"], refs: [ref("main")]),
            commit("current", parents: ["base"], refs: [ref("feature/current")])
        ]
        for index in 1...9 {
            commits.append(commit("feature-\(index)", parents: ["base"], refs: [ref("feature/\(index)")]))
        }
        commits.append(commit("base"))
        let graph = CommitGraphLayout.build(
            commits,
            context: .init(defaultBranch: "main", currentBranch: "feature/current")
        )

        let focused = graph.projected(maxDynamicLanes: 4, focusOID: "feature-9")
        let target = try! XCTUnwrap(focused.rows.first { $0.oid == "feature-9" })
        let ancestor = try! XCTUnwrap(focused.rows.first { $0.oid == "base" })
        let unrelated = try! XCTUnwrap(focused.rows.first { $0.oid == "feature-1" })

        XCTAssertTrue(target.isFocused)
        XCTAssertFalse(target.isDimmed)
        XCTAssertTrue(ancestor.isFocused)
        XCTAssertFalse(ancestor.isDimmed)

        // 无关分支应被弱化暗显
        XCTAssertFalse(unrelated.isFocused)
        XCTAssertTrue(unrelated.isDimmed)

        // 目标路径连线应被高亮
        XCTAssertTrue(target.outgoing.contains {
            $0.sourceOID == "feature-9" && $0.targetOID == "base" && $0.isFocused
        })
    }

    func testFeatureBranchAndMergedBranchesGetDistinctColorsEvenWithoutMasterRef() {
        let commits = [
            commit("c1", parents: ["c2"], refs: [ref("fix/fgj")]),
            commit("c2", parents: ["c3"]),
            CommitSummary(
                oid: "c3", subject: "Merge branch 'djh-dev' into 'master'",
                authorName: "测试", authorEmail: "t@e.com", date: .distantPast,
                parents: ["c5", "c4"], refs: []
            ),
            commit("c4", parents: ["c5"], refs: [ref("origin/djh-dev")]),
            CommitSummary(
                oid: "c5", subject: "Merge remote-tracking branch '...'",
                authorName: "测试", authorEmail: "t@e.com", date: .distantPast,
                parents: ["c6"], refs: []
            ),
            CommitSummary(
                oid: "c6", subject: "Merge branch 'fix/old' into 'master'",
                authorName: "测试", authorEmail: "t@e.com", date: .distantPast,
                parents: ["c7", "c6-branch"], refs: []
            ),
            commit("c6-branch", parents: ["c7"]),
            commit("c7", parents: [])
        ]

        let graph = CommitGraphLayout.build(
            commits,
            context: .init(defaultBranch: "master", currentBranch: "fix/fgj")
        )

        // fix/fgj 当前分支专有提交为颜色 1 (Teal)
        XCTAssertEqual(graph.rows.first { $0.oid == "c1" }?.color, 1)
        XCTAssertEqual(graph.rows.first { $0.oid == "c2" }?.color, 1)

        // master 主干提交为颜色 0 (Blue)
        XCTAssertEqual(graph.rows.first { $0.oid == "c3" }?.color, 0)
        XCTAssertEqual(graph.rows.first { $0.oid == "c5" }?.color, 0)
        XCTAssertEqual(graph.rows.first { $0.oid == "c6" }?.color, 0)
        XCTAssertEqual(graph.rows.first { $0.oid == "c7" }?.color, 0)

        // 合并进来的 djh-dev 动态分支为颜色 2 (Purple)
        XCTAssertEqual(graph.rows.first { $0.oid == "c4" }?.color, 2)

        // 另一个动态分支为颜色 3 (Orange)
        XCTAssertEqual(graph.rows.first { $0.oid == "c6-branch" }?.color, 3)
    }

    func testThroughLaneIsNotBrokenWhenMergeCommitConnectsToIt() {
        let commits = [
            commit("c1", parents: ["c3"]),
            CommitSummary(
                oid: "c2", subject: "merge c4 and c3",
                authorName: "测试", authorEmail: "t@e.com", date: .distantPast,
                parents: ["c4", "c3"], refs: []
            ),
            commit("c3", parents: []),
            commit("c4", parents: [])
        ]

        let graph = CommitGraphLayout.build(commits)
        let row2 = try! XCTUnwrap(graph.rows.first { $0.oid == "c2" })

        // 验证 row2 的 outgoing 必须同时包含直行 (0 -> 0) 和汇入 (1 -> 0)
        let straightLink = row2.outgoing.first { $0.from == 0 && $0.to == 0 }
        let mergeLink = row2.outgoing.first { $0.from == row2.commitLane && $0.to == 0 }

        XCTAssertNotNil(straightLink, "直通车道连线不能被断开")
        XCTAssertNotNil(mergeLink, "合并连线应正常连接至目标车道")
    }
}
