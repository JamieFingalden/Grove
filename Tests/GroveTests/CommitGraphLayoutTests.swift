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

    func testOverflowProjectionKeepsFullTopologyUntouched() {
        var commits = [
            commit("main-1", parents: ["base"], refs: [ref("main")]),
            commit("current", parents: ["base"], refs: [ref("feature/current")])
        ]
        for index in 1...9 {
            commits.append(commit("feature-\(index)", parents: ["base"], refs: [ref("feature/\(index)")]))
        }
        commits.append(commit("base"))

        let full = CommitGraphLayout.build(
            commits,
            context: .init(defaultBranch: "main", currentBranch: "feature/current")
        )
        let compact = full.projected(maxDynamicLanes: 4, focusOID: nil)

        XCTAssertGreaterThan(full.laneCount, compact.laneCount)
        XCTAssertEqual(compact.laneCount, 6)
        XCTAssertEqual(full.rows.count, commits.count)
        XCTAssertTrue(compact.rows.contains { $0.isCollapsed && $0.overflowCount > 0 })
        XCTAssertFalse(full.rows.contains { $0.isCollapsed })
    }

    func testFocusRestoresCollapsedBranchAndItsRealPath() {
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
        XCTAssertLessThanOrEqual(focused.laneCount, 6)
        XCTAssertTrue(focused.rows.first { $0.oid == "feature-9" }?.isFocused == true)
        XCTAssertTrue(focused.rows.first { $0.oid == "base" }?.isFocused == true)
        XCTAssertFalse(focused.rows.first { $0.oid == "feature-9" }?.isCollapsed == true)
        XCTAssertTrue(focused.rows.first { $0.oid == "feature-1" }?.isCollapsed == true)
        XCTAssertTrue(focused.rows.first { $0.oid == "feature-9" }?.outgoing.contains {
            $0.sourceOID == "feature-9" && $0.targetOID == "base" && $0.isFocused
        } == true)
        XCTAssertFalse(focused.rows.first { $0.oid == "feature-1" }?.outgoing.contains {
            $0.sourceOID == "feature-1" && $0.targetOID == "base"
        } == true)
    }
}
