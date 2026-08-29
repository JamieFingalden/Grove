import XCTest
@testable import Grove

/// 提交图的布局算法。
///
/// 这一层必须靠测试守住：分叉、合并、多道并行、道释放后复用 ——
/// 这些组合光看渲染出来的图，错了也未必看得出来（人眼会自动脑补成合理的图）。
final class CommitGraphLayoutTests: XCTestCase {
    private func commit(_ oid: String, parents: [String] = []) -> CommitSummary {
        CommitSummary(
            oid: oid, subject: oid, authorName: "t", authorEmail: "t@e",
            date: Date(timeIntervalSince1970: 0), parents: parents, refs: []
        )
    }

    /// 一条直线的历史：所有提交都在第 0 道。
    func testLinearHistoryStaysInOneLane() {
        let graph = CommitGraphLayout.build([
            commit("c", parents: ["b"]),
            commit("b", parents: ["a"]),
            commit("a")
        ])

        XCTAssertEqual(graph.laneCount, 1)
        XCTAssertEqual(graph.rows.map(\.commitLane), [0, 0, 0])
        // 中间那个提交上下都各有一条线，接起来是穿过圆点的直线。
        XCTAssertEqual(graph.rows[1].incoming, [.init(from: 0, to: 0, color: 0)])
        XCTAssertEqual(graph.rows[1].outgoing, [.init(from: 0, to: 0, color: 0)])
        // 根提交没有父，下半行不该再有线伸出去。
        XCTAssertTrue(graph.rows[2].outgoing.isEmpty)
    }

    /// 合并：两条道在合并提交处汇合，之后只剩一条。
    ///
    /// ```
    /// m      合并提交，父 = [main, feature]
    /// |\
    /// | f    feature
    /// |/
    /// b      共同祖先
    /// ```
    func testMergeConvergesTwoLanes() {
        let graph = CommitGraphLayout.build([
            commit("m", parents: ["a", "f"]),
            commit("f", parents: ["b"]),
            commit("a", parents: ["b"]),
            commit("b")
        ])

        XCTAssertEqual(graph.laneCount, 2, "合并之下应该有两条道并行")
        XCTAssertEqual(graph.rows[0].commitLane, 0)
        XCTAssertTrue(graph.rows[0].isMerge)

        // 合并提交的下半行要有两条线岔出去：第一父继承本道，第二父去新道。
        let out = graph.rows[0].outgoing
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.allSatisfy { $0.from == 0 }, "两条线都从合并点出发")
        XCTAssertEqual(Set(out.map(\.to)), [0, 1])

        // 最后的共同祖先处两条道重新收敛回一条。
        let last = graph.rows[3]
        XCTAssertEqual(last.incoming.count, 2)
        XCTAssertTrue(last.incoming.allSatisfy { $0.to == last.commitLane })
        XCTAssertTrue(last.outgoing.isEmpty)
    }

    /// 第一个父提交必须留在原道上 —— 主线在图上要是一条直线，
    /// 而不是每遇到一次合并就横跳一格。
    func testFirstParentKeepsTheLane() {
        let graph = CommitGraphLayout.build([
            commit("m1", parents: ["m2", "x"]),
            commit("m2", parents: ["m3", "y"]),
            commit("m3", parents: [])
        ])
        XCTAssertEqual(graph.rows.prefix(3).map(\.commitLane), [0, 0, 0])
    }

    /// 分支的起点：没有任何道在等它，要新开一条。
    func testUnreferencedTipStartsNewLane() {
        // 两个互不相干的头（比如 main 和一条还没合并的 feature）。
        let graph = CommitGraphLayout.build([
            commit("main2", parents: ["main1"]),
            commit("feat2", parents: ["feat1"]),
            commit("main1"),
            commit("feat1")
        ])
        XCTAssertEqual(graph.rows[0].commitLane, 0)
        XCTAssertEqual(graph.rows[1].commitLane, 1, "第二个头应该另起一条道")
        XCTAssertEqual(graph.laneCount, 2)
    }

    /// 道释放之后要能被后面的分支复用，否则图会越铺越宽。
    func testLanesAreReusedAfterRelease() {
        let graph = CommitGraphLayout.build([
            commit("m", parents: ["a", "f"]),   // 开出第 1 道
            commit("f", parents: ["b"]),
            commit("a", parents: ["b"]),
            commit("b"),                         // 两道在此收敛，第 1 道释放
            commit("later", parents: [])         // 独立的头，应该复用第 1 道之前的位置
        ])
        XCTAssertLessThanOrEqual(graph.laneCount, 2, "释放的道没被复用，图会一直变宽")
    }

    /// 同一条道在存活期间颜色不变 —— 颜色跳变会让人以为线断了。
    func testLaneColorIsStableWhileAlive() {
        let graph = CommitGraphLayout.build([
            commit("c", parents: ["b"]),
            commit("b", parents: ["a"]),
            commit("a")
        ])
        XCTAssertEqual(Set(graph.rows.map(\.color)).count, 1)
    }

    /// 穿行而过的道，上下两半必须对得上，接起来才是连续的一条线。
    func testPassThroughLanesLineUp() {
        let graph = CommitGraphLayout.build([
            commit("m", parents: ["a", "f"]),
            commit("a", parents: ["b"]),        // 这一行第 1 道（f 那条）只是路过
            commit("f", parents: ["b"]),
            commit("b")
        ])

        let middle = graph.rows[1]
        let passThroughIn = middle.incoming.first { $0.from == 1 }
        let passThroughOut = middle.outgoing.first { $0.from == 1 }
        XCTAssertNotNil(passThroughIn, "路过的道在上半行要有线")
        XCTAssertNotNil(passThroughOut, "路过的道在下半行也要有线")
        XCTAssertEqual(passThroughIn?.to, 1)
        XCTAssertEqual(passThroughOut?.to, 1)
        XCTAssertEqual(passThroughIn?.color, passThroughOut?.color, "上下两半颜色要一致")
    }

    func testEmptyInputYieldsEmptyGraph() {
        let graph = CommitGraphLayout.build([])
        XCTAssertTrue(graph.rows.isEmpty)
        XCTAssertEqual(graph.laneCount, 0)
    }

    /// 截断的历史：最老那个提交的父不在列表里（因为 --max-count 砍掉了）。
    /// 不能因此崩溃，也不该留下一条悬空的道让图显得没画完。
    func testTruncatedHistoryDoesNotCrash() {
        let graph = CommitGraphLayout.build([
            commit("c", parents: ["b"]),
            commit("b", parents: ["missing"])
        ])
        XCTAssertEqual(graph.rows.count, 2)
        // 最后一行仍然有一条指向「看不见的父」的线，这是对的 ——
        // 它表示历史还没到头。
        XCTAssertFalse(graph.rows[1].outgoing.isEmpty)
    }
}

final class CommitRefParsingTests: XCTestCase {
    func testParsesRefDecoration() {
        let refs = CommitRef.parse("HEAD -> main, origin/main, tag: v1.0", remotes: ["origin"])
        XCTAssertEqual(refs.count, 3)
        XCTAssertEqual(refs[0], CommitRef(name: "main", kind: .head))
        XCTAssertEqual(refs[1], CommitRef(name: "origin/main", kind: .remoteBranch))
        XCTAssertEqual(refs[2], CommitRef(name: "v1.0", kind: .tag))
    }

    func testEmptyDecorationYieldsNothing() {
        XCTAssertTrue(CommitRef.parse("").isEmpty)
        XCTAssertTrue(CommitRef.parse("   ").isEmpty)
    }

    func testDetachedHeadAlone() {
        XCTAssertEqual(CommitRef.parse("HEAD"), [CommitRef(name: "HEAD", kind: .head)])
    }

    /// 本地分支名带斜杠是常事，不能按斜杠判断远近。
    func testLocalBranchWithSlashIsNotMistakenForRemote() {
        let refs = CommitRef.parse("feature/login", remotes: ["origin"])
        XCTAssertEqual(refs, [CommitRef(name: "feature/login", kind: .localBranch)])
    }

    func testRemoteBranchIsRecognizedByKnownRemoteName() {
        let refs = CommitRef.parse("origin/feature/login", remotes: ["origin"])
        XCTAssertEqual(refs, [CommitRef(name: "origin/feature/login", kind: .remoteBranch)])
    }

    func testRemoteNamePrefixDoesNotFalselyMatch() {
        // 远端叫 `orig` 时，`origin/main` 不该被判成它的远端分支 ——
        // 比较时必须带上斜杠。跟推送那边「上游属于哪个远端」是同一个陷阱。
        let refs = CommitRef.parse("origin/main", remotes: ["orig"])
        XCTAssertEqual(refs[0].kind, .localBranch)
    }

    func testWithoutKnownRemotesEverythingIsLocal() {
        // 远端列表拿不到时宁可全判成本地：图标错一个，比把本地分支
        // 说成远端分支误导性小。
        XCTAssertEqual(CommitRef.parse("origin/main")[0].kind, .localBranch)
    }
}
