import XCTest
@testable import Grove

final class StatusParserTests: XCTestCase {
    /// 把若干条记录拼成 `git status -z` 那样的 NUL 分隔字节流。
    private func makeData(_ fields: [String]) -> Data {
        Data(fields.joined(separator: "\0").utf8) + Data([0])
    }

    func testParsesBranchHeaders() {
        let data = makeData([
            "# branch.oid 8ed3be38fdf01cc1431c7b2c00971214a729e5c8",
            "# branch.head feature/login",
            "# branch.upstream origin/feature/login",
            "# branch.ab +3 -2"
        ])

        let status = StatusParser.parse(data)

        XCTAssertEqual(status.branch, "feature/login")
        XCTAssertEqual(status.upstream, "origin/feature/login")
        XCTAssertEqual(status.ahead, 3)
        XCTAssertEqual(status.behind, 2)
        XCTAssertTrue(status.isClean)
    }

    func testInitialCommitAndDetachedHeadAreNil() {
        let data = makeData([
            "# branch.oid (initial)",
            "# branch.head (detached)"
        ])

        let status = StatusParser.parse(data)

        // 这两个是字面量哨兵值，不是真的 oid / 分支名。当成真值会让界面
        // 显示一个叫「(detached)」的分支。
        XCTAssertNil(status.oid)
        XCTAssertNil(status.branch)
    }

    func testOrdinaryChangeSplitsStagedAndUnstaged() {
        let data = makeData([
            "# branch.head main",
            "1 MM N... 100644 100644 100644 aaa bbb src/app.swift"
        ])

        let status = StatusParser.parse(data)

        XCTAssertEqual(status.changes.count, 1)
        let change = status.changes[0]
        XCTAssertEqual(change.path, "src/app.swift")
        // XY 两侧都是 M：暂存了一版，之后又改了 —— 界面必须两边都显示。
        XCTAssertEqual(change.staged, .modified)
        XCTAssertEqual(change.unstaged, .modified)
        XCTAssertTrue(change.isPartiallyStaged)
    }

    func testDotMeansNoChangeOnThatSide() {
        let data = makeData([
            "1 .M N... 100644 100644 100644 aaa bbb only-worktree.txt",
            "1 A. N... 000000 100644 100644 aaa bbb only-staged.txt"
        ])

        let status = StatusParser.parse(data)
        let byPath = Dictionary(uniqueKeysWithValues: status.changes.map { ($0.path, $0) })

        XCTAssertNil(byPath["only-worktree.txt"]?.staged)
        XCTAssertEqual(byPath["only-worktree.txt"]?.unstaged, .modified)
        XCTAssertEqual(byPath["only-staged.txt"]?.staged, .added)
        XCTAssertNil(byPath["only-staged.txt"]?.unstaged)
        XCTAssertTrue(byPath["only-staged.txt"]?.isFullyStaged ?? false)
    }

    func testRenameConsumesTwoFields() {
        // 这是 v2 格式最容易解析错的地方：重命名记录的来源路径在**下一个** NUL 段里。
        // 不消费掉它的话，"old.txt" 会被当成一条新记录去解析，然后整个后续流全部错位。
        let data = makeData([
            "2 R. N... 100644 100644 100644 aaa bbb R100 new/name.txt",
            "old/name.txt",
            "1 .M N... 100644 100644 100644 ccc ddd after-rename.txt"
        ])

        let status = StatusParser.parse(data)

        XCTAssertEqual(status.changes.count, 2)
        let rename = status.changes.first { $0.path == "new/name.txt" }
        XCTAssertEqual(rename?.originalPath, "old/name.txt")
        XCTAssertEqual(rename?.staged, .renamed)
        // 紧跟其后的那条记录必须被正确解析出来 —— 这才证明游标没错位。
        XCTAssertNotNil(status.changes.first { $0.path == "after-rename.txt" })
    }

    func testUnmergedEntryIsConflicted() {
        let data = makeData([
            "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflicted.swift"
        ])

        let status = StatusParser.parse(data)

        XCTAssertEqual(status.changes.count, 1)
        XCTAssertTrue(status.changes[0].isConflicted)
        XCTAssertEqual(status.changes[0].conflict, .bothModified)
        XCTAssertEqual(status.changes[0].path, "conflicted.swift")
        XCTAssertTrue(status.hasConflicts)
        XCTAssertEqual(status.conflictCount, 1)
        // 冲突文件不算已暂存：索引里是三个阶段的半成品，提交按钮不该把它数进去。
        XCTAssertEqual(status.stagedCount, 0)
        XCTAssertEqual(status.changes[0].unstaged, .unmerged)
    }

    func testUnmergedKindsFollowTheXYColumns() {
        let data = makeData([
            "u AA N... 000000 100644 100644 100644 h0 h2 h3 added.txt",
            "u UD N... 100644 100644 000000 100644 h1 h2 h0 deleted-by-them.txt",
            "u DU N... 100644 000000 100644 100644 h1 h0 h3 deleted-by-us.txt",
            "u AU N... 000000 100644 000000 100644 h0 h2 h0 added-by-us.txt",
            "u UA N... 000000 000000 100644 100644 h0 h0 h3 added-by-them.txt",
            "u DD N... 100644 000000 000000 000000 h1 h0 h0 both-deleted.txt"
        ])

        let status = StatusParser.parse(data)
        let byPath = Dictionary(uniqueKeysWithValues: status.changes.map { ($0.path, $0) })

        // 「采用一侧」要靠这个形态决定是检出还是删除，认错了会对着不存在的版本 checkout。
        XCTAssertEqual(byPath["added.txt"]?.conflict, .bothAdded)
        XCTAssertEqual(byPath["deleted-by-them.txt"]?.conflict, .deletedByThem)
        XCTAssertEqual(byPath["deleted-by-us.txt"]?.conflict, .deletedByUs)
        XCTAssertEqual(byPath["added-by-us.txt"]?.conflict, .addedByUs)
        XCTAssertEqual(byPath["added-by-them.txt"]?.conflict, .addedByThem)
        XCTAssertEqual(byPath["both-deleted.txt"]?.conflict, .bothDeleted)
        XCTAssertEqual(status.conflictCount, 6)

        XCTAssertTrue(ConflictKind.deletedByThem.oursExists)
        XCTAssertFalse(ConflictKind.deletedByThem.theirsExists)
        XCTAssertFalse(ConflictKind.deletedByUs.oursExists)
        XCTAssertTrue(ConflictKind.deletedByUs.theirsExists)
        XCTAssertFalse(ConflictKind.bothDeleted.oursExists)
        XCTAssertFalse(ConflictKind.bothDeleted.theirsExists)
        XCTAssertTrue(ConflictKind.bothAdded.hasTextualMarkers)
        XCTAssertFalse(ConflictKind.deletedByUs.hasTextualMarkers)
    }

    func testUnknownUnmergedCodeStillCountsAsConflict() {
        // 未来 git 新增的组合也不能让文件从列表里消失。
        let data = makeData(["u XX N... 100644 100644 100644 100644 h1 h2 h3 odd.txt"])
        let status = StatusParser.parse(data)
        XCTAssertTrue(status.changes[0].isConflicted)
    }

    func testUntrackedAndIgnored() {
        let data = makeData([
            "? new-file.txt",
            "! build/output.o"
        ])

        let status = StatusParser.parse(data)

        // 未跟踪要进列表（用户要能暂存它），被忽略的不进（那是噪音）。
        XCTAssertEqual(status.changes.count, 1)
        XCTAssertEqual(status.changes[0].path, "new-file.txt")
        XCTAssertEqual(status.changes[0].unstaged, .untracked)
    }

    func testPathsWithSpacesSurvive() {
        // 路径里的空格不能把字段切开 —— 路径是记录的最后一个字段，
        // 解析时必须限制切分次数。
        let data = makeData([
            "1 .M N... 100644 100644 100644 aaa bbb my documents/some file.txt"
        ])

        let status = StatusParser.parse(data)
        XCTAssertEqual(status.changes[0].path, "my documents/some file.txt")
    }

    func testChineseFilenamesSurvive() {
        let data = makeData([
            "1 .M N... 100644 100644 100644 aaa bbb 文档/项目说明.md"
        ])

        let status = StatusParser.parse(data)
        XCTAssertEqual(status.changes[0].path, "文档/项目说明.md")
        XCTAssertEqual(status.changes[0].displayName, "项目说明.md")
        XCTAssertEqual(status.changes[0].directory, "文档")
    }

    func testChangesAreSortedStably() {
        let data = makeData([
            "? zebra.txt",
            "1 .M N... 100644 100644 100644 aaa bbb alpha.txt",
            "? middle.txt"
        ])

        let status = StatusParser.parse(data)
        XCTAssertEqual(status.changes.map(\.path), ["alpha.txt", "middle.txt", "zebra.txt"])
    }
}
