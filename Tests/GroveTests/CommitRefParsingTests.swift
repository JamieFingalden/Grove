import XCTest
@testable import Grove

final class CommitRefParsingTests: XCTestCase {
    func testParsesRefDecoration() {
        let refs = CommitRef.parse("HEAD -> main, origin/main, tag: v1.0", remotes: ["origin"])
        XCTAssertEqual(refs.count, 3)
        XCTAssertEqual(refs[0], CommitRef(name: "main", kind: .head))
        XCTAssertEqual(refs[1], CommitRef(name: "origin/main", kind: .remoteBranch))
        XCTAssertEqual(refs[2], CommitRef(name: "v1.0", kind: .tag))
    }

    // MARK: - 提交正文（%b）

    /// 构造一条 `LogParser.format` 形状的记录。`refs` 和 `body` 由调用方补。
    private func record(subject: String, refs: String = "", body: String = "") -> String {
        "0123456789abcdef\u{1F}fedcba9876543210\u{1F}Jamie\u{1F}jamie@example.com"
            + "\u{1F}2026-01-02T03:04:05+08:00\u{1F}\(subject)\u{1F}\(refs)\u{1F}\(body)\u{1E}"
    }

    func testParseKeepsMultilineBody() {
        // `%b` 开头带标题后的空白分隔行；正文内部换行必须原样保留。
        let output = record(subject: "修复解析", body: "\n第一行说明\n\n- 列表项一\n- 列表项二\n")
        let commits = LogParser.parse(output)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].body, "第一行说明\n\n- 列表项一\n- 列表项二")
        XCTAssertEqual(commits[0].subject, "修复解析")
    }

    func testParseSubjectOnlyCommitHasEmptyBody() {
        let output = record(subject: "只有标题")
        XCTAssertEqual(LogParser.parse(output).first?.body, "")
    }

    func testParseOldFormatWithoutBodyFieldStillWorks() {
        // 兼容缺 `%b` 字段的旧输出：不该把 refs 错读成正文。
        let legacy = "0123456789abcdef\u{1F}fedcba9876543210\u{1F}Jamie\u{1F}jamie@example.com"
            + "\u{1F}2026-01-02T03:04:05+08:00\u{1F}标题\u{1F}HEAD -> main\u{1E}"
        let commits = LogParser.parse(legacy)
        XCTAssertEqual(commits.first?.refs.first?.name, "main")
        XCTAssertEqual(commits.first?.body, "")
    }

    func testEmptyDecorationYieldsNothing() {
        XCTAssertTrue(CommitRef.parse("").isEmpty)
        XCTAssertTrue(CommitRef.parse("   ").isEmpty)
    }

    func testDetachedHeadAlone() {
        XCTAssertEqual(CommitRef.parse("HEAD"), [CommitRef(name: "HEAD", kind: .head)])
    }

    func testLocalBranchWithSlashIsNotMistakenForRemote() {
        let refs = CommitRef.parse("feature/login", remotes: ["origin"])
        XCTAssertEqual(refs, [CommitRef(name: "feature/login", kind: .localBranch)])
    }

    func testRemoteBranchIsRecognizedByKnownRemoteName() {
        let refs = CommitRef.parse("origin/feature/login", remotes: ["origin"])
        XCTAssertEqual(refs, [CommitRef(name: "origin/feature/login", kind: .remoteBranch)])
    }

    func testRemoteNamePrefixDoesNotFalselyMatch() {
        let refs = CommitRef.parse("origin/main", remotes: ["orig"])
        XCTAssertEqual(refs[0].kind, .localBranch)
    }

    func testWithoutKnownRemotesEverythingIsLocal() {
        XCTAssertEqual(CommitRef.parse("origin/main")[0].kind, .localBranch)
    }
}
