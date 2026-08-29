import XCTest
@testable import Grove

final class RefParserTests: XCTestCase {
    private func line(_ fields: String...) -> String {
        fields.joined(separator: "\0")
    }

    func testParsesBranchWithTracking() {
        let output = line(
            "feature/login",
            "a1b2c3d4",
            "origin/feature/login",
            "[ahead 3, behind 1]",
            "/Users/me/proj-worktrees/feature-login",
            "2026-08-27T14:03:09+08:00",
            "加上登录页"
        )

        let branches = RefParser.parseBranches(output, currentBranch: "main")

        XCTAssertEqual(branches.count, 1)
        let branch = branches[0]
        XCTAssertEqual(branch.name, "feature/login")
        XCTAssertEqual(branch.upstream, "origin/feature/login")
        XCTAssertEqual(branch.ahead, 3)
        XCTAssertEqual(branch.behind, 1)
        XCTAssertFalse(branch.upstreamIsGone)
        // 被工作树占用的分支不能再检出一次，界面要靠这个字段禁掉选项。
        XCTAssertEqual(branch.worktreePath?.lastPathComponent, "feature-login")
        XCTAssertTrue(branch.isCheckedOut)
        XCTAssertNotNil(branch.lastCommitDate)
        XCTAssertEqual(branch.subject, "加上登录页")
    }

    func testTrackParsingCoversEveryShape() {
        XCTAssertEqual(RefParser.parseTrack("[ahead 2, behind 1]").ahead, 2)
        XCTAssertEqual(RefParser.parseTrack("[ahead 2, behind 1]").behind, 1)
        XCTAssertEqual(RefParser.parseTrack("[ahead 5]").ahead, 5)
        XCTAssertEqual(RefParser.parseTrack("[ahead 5]").behind, 0)
        XCTAssertEqual(RefParser.parseTrack("[behind 4]").behind, 4)
        // `[gone]` = 上游在远端被删了，通常是 PR 合并后的残留分支。
        XCTAssertTrue(RefParser.parseTrack("[gone]").isGone)
        // 空串 = 没设上游，不是错误。
        XCTAssertFalse(RefParser.parseTrack("").isGone)
        XCTAssertEqual(RefParser.parseTrack("").ahead, 0)
    }

    func testBranchWithoutUpstreamHasNilUpstream() {
        let output = line("local-only", "abc123", "", "", "", "2026-08-27T14:03:09Z", "本地实验")
        let branches = RefParser.parseBranches(output, currentBranch: nil)

        XCTAssertNil(branches[0].upstream)
        XCTAssertFalse(branches[0].hasUpstream)
        XCTAssertNil(branches[0].worktreePath)
        XCTAssertFalse(branches[0].isCheckedOut)
    }

    func testRemoteBranchesStripPrefixAndDropHead() {
        let output = [
            line("origin/HEAD", "aaa", "2026-08-27T14:03:09Z"),
            line("origin/main", "bbb", "2026-08-27T14:03:09Z"),
            line("origin/feature/deep/name", "ccc", "2026-08-26T10:00:00Z")
        ].joined(separator: "\n")

        let remotes = RefParser.parseRemoteBranches(output)

        // origin/HEAD 是符号引用，不是真分支，检出它没意义。
        XCTAssertEqual(remotes.count, 2)
        XCTAssertEqual(remotes.map(\.localName), ["main", "feature/deep/name"])
    }

    func testStripRemotePrefixOnlyRemovesFirstSegment() {
        XCTAssertEqual(RefParser.stripRemotePrefix("origin/feature/login"), "feature/login")
        XCTAssertEqual(RefParser.stripRemotePrefix("upstream/main"), "main")
        XCTAssertEqual(RefParser.stripRemotePrefix("noslash"), "noslash")
    }
}

final class LogParserTests: XCTestCase {
    private func record(oid: String, parents: String, author: String, email: String, date: String, subject: String) -> String {
        [oid, parents, author, email, date, subject].joined(separator: "\u{1F}") + "\u{1E}\n"
    }

    func testParsesCommits() {
        let output = record(
            oid: "8ed3be38fdf01cc1431c7b2c00971214a729e5c8",
            parents: "a1b2c3d4",
            author: "张三",
            email: "zhang@example.com",
            date: "2026-08-27T14:03:09+08:00",
            subject: "修复登录跳转"
        ) + record(
            oid: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
            parents: "aaa bbb",
            author: "李四",
            email: "li@example.com",
            date: "2026-08-26T09:00:00Z",
            subject: "Merge branch 'feature'"
        )

        let commits = LogParser.parse(output)

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].subject, "修复登录跳转")
        XCTAssertEqual(commits[0].authorName, "张三")
        XCTAssertEqual(commits[0].shortOID, "8ed3be3")
        XCTAssertFalse(commits[0].isMerge)
        // 两个父提交 = 合并提交，界面上用不同图标区分。
        XCTAssertEqual(commits[1].parentCount, 2)
        XCTAssertTrue(commits[1].isMerge)
    }

    func testSubjectWithSeparatorLikeCharactersSurvives() {
        // 提交标题里出现制表符、竖线是常事，所以字段分隔用的是 0x1F 控制字符。
        let output = record(
            oid: "aaa", parents: "", author: "me", email: "m@e",
            date: "2026-08-27T14:03:09Z", subject: "重构\t表格 | 顺便改了下样式"
        )

        let commits = LogParser.parse(output)
        XCTAssertEqual(commits[0].subject, "重构\t表格 | 顺便改了下样式")
        XCTAssertEqual(commits[0].parentCount, 0)
    }

    func testEmptyOutputYieldsNoCommits() {
        XCTAssertTrue(LogParser.parse("").isEmpty)
        XCTAssertTrue(LogParser.parse("\n").isEmpty)
    }
}
