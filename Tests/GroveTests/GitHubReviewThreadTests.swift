import XCTest
@testable import Grove

/// GitHub 评论线程的归组。
///
/// 数据取自 cli/cli 的真实 PR #14198（`gh api repos/cli/cli/pulls/14198/comments`）。
final class GitHubReviewThreadTests: XCTestCase {
    /// 三条行内评论，其中第三条是对第一条的回复。
    private let commentsJSON = """
    [
      {
        "id": 3830020570,
        "in_reply_to_id": null,
        "path": "internal/ghcmd/cmd.go",
        "line": 309,
        "original_line": 309,
        "created_at": "2026-08-21T12:05:29Z",
        "user": { "login": "Copilot" },
        "body": "Requirement: Preserve the target command's help"
      },
      {
        "id": 3830302851,
        "in_reply_to_id": null,
        "path": "internal/ghcmd/cmd.go",
        "line": 305,
        "original_line": 305,
        "created_at": "2026-08-21T12:48:53Z",
        "user": { "login": "babakks" },
        "body": "printError, fullHelp"
      },
      {
        "id": 3831062915,
        "in_reply_to_id": 3830020570,
        "path": "internal/ghcmd/cmd.go",
        "line": 309,
        "original_line": 309,
        "created_at": "2026-08-21T14:29:52Z",
        "user": { "login": "niik" },
        "body": "Good catch, this was a real regression."
      }
    ]
    """

    private func decode() throws -> [GitHubComment] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubComment].self, from: Data(commentsJSON.utf8))
    }

    func testDecodesRealCommentPayload() throws {
        let comments = try decode()
        XCTAssertEqual(comments.count, 3)
        XCTAssertEqual(comments[0].path, "internal/ghcmd/cmd.go")
        XCTAssertEqual(comments[0].line, 309)
        XCTAssertEqual(comments[2].in_reply_to_id, 3830020570)
        XCTAssertNotNil(comments[0].created_at)
    }

    /// 回复必须归到它所回复的那条下面。
    ///
    /// GitHub 返回的是平铺数组，回复靠 `in_reply_to_id` 指回去。不归组的话，
    /// 一来一回的讨论会散成一堆孤立条目，读的人完全不知道谁在回谁。
    func testRepliesAreGroupedUnderTheirRootComment() throws {
        let threads = GitHubClient.threads(from: try decode(), source: "pulls/14198/comments")

        // 3 条评论、其中一条是回复 → 2 条线程。
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(threads[0].notes.count, 2)
        XCTAssertEqual(threads[0].notes.map(\.authorLogin), ["Copilot", "niik"])
        XCTAssertEqual(threads[1].notes.count, 1)
        XCTAssertEqual(threads[1].notes[0].authorLogin, "babakks")
    }

    func testInlineThreadsCarryFileAndLine() throws {
        let threads = GitHubClient.threads(from: try decode(), source: "x")
        XCTAssertTrue(threads[0].isInline)
        XCTAssertEqual(threads[0].filePath, "internal/ghcmd/cmd.go")
        XCTAssertEqual(threads[0].line, 309)
        XCTAssertEqual(threads[1].line, 305)
    }

    func testFallsBackToOriginalLineWhenLineIsNull() throws {
        // 评论指向的那一行如果已经不在最新 diff 里，GitHub 会把 `line` 置空。
        // 这时退回 `original_line`（评论刚发时的行号）比完全不显示行号有用。
        let json = """
        [{"id":1,"path":"a.go","line":null,"original_line":42,
          "created_at":"2026-08-21T12:05:29Z","user":{"login":"me"},"body":"x"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let comments = try decoder.decode([GitHubComment].self, from: Data(json.utf8))
        let threads = GitHubClient.threads(from: comments, source: "x")
        XCTAssertEqual(threads[0].line, 42)
    }

    func testGeneralCommentsWithoutPathAreNotInline() throws {
        // `issues/N/comments` 返回的整体讨论没有 path/line 字段。
        let json = """
        [{"id":9,"created_at":"2026-08-21T12:05:29Z","user":{"login":"me"},"body":"整体意见"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let comments = try decoder.decode([GitHubComment].self, from: Data(json.utf8))
        let threads = GitHubClient.threads(from: comments, source: "x")
        XCTAssertFalse(threads[0].isInline)
        XCTAssertNil(threads[0].filePath)
    }

    func testThreadIDsAreUniqueAcrossSources() throws {
        // 行内评论和整体讨论是两个接口，各自的 id 空间独立，可能撞号。
        // 线程 id 不带来源的话，SwiftUI 的 ForEach 会认成同一条而漏渲染。
        let comments = try decode()
        let inline = GitHubClient.threads(from: comments, source: "pulls/1/comments")
        let general = GitHubClient.threads(from: comments, source: "issues/1/comments")
        XCTAssertTrue(Set(inline.map(\.id)).isDisjoint(with: Set(general.map(\.id))))
    }
}

final class GitHubPullRequestDiffTests: XCTestCase {
    func testLoadsColorlessPullRequestDiff() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("gh")
        let script = """
        #!/bin/sh
        if [ "$1" = "pr" ] && [ "$2" = "diff" ] && [ "$3" = "42" ] && [ "$4" = "--color" ] && [ "$5" = "never" ]; then
          printf 'diff --git a/app.swift b/app.swift\n--- a/app.swift\n+++ b/app.swift\n@@ -1 +1 @@\n-old\n+new\n'
          exit 0
        fi
        exit 2
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = GitHubClient(
            executable: executable,
            environment: ProcessInfo.processInfo.environment
        )
        let diff = try await client.pullRequestDiff(number: 42, in: directory)

        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff[0].displayPath, "app.swift")
        XCTAssertEqual(diff[0].additions, 1)
        XCTAssertEqual(diff[0].deletions, 1)
    }
}

/// 真的去打 GitHub 接口的实测。默认跳过 —— 要联网、要 `gh` 已登录。
///
/// ```sh
/// GROVE_LIVE=1 swift test --filter GitHubLiveTests
/// ```
/// 只读，不会往任何仓库写东西。
final class GitHubLiveTests: XCTestCase {
    func testReviewThreadsAgainstRealRepository() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["GROVE_LIVE"] == "1",
            "设置 GROVE_LIVE=1 才会联网实测"
        )
        guard let client = await GitHubClient.resolve(), await client.isAuthenticated() else {
            throw XCTSkip("gh 不可用或未登录")
        }

        // 建一个只有 remote 的空仓库 —— gh 靠 remote 解析项目，不需要真的克隆内容。
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for arguments in [["init", "-q"], ["remote", "add", "origin", "https://github.com/cli/cli.git"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }

        let threads = try await client.reviewThreads(number: 14198, in: root)
        XCTAssertFalse(threads.isEmpty, "PR #14198 上确实有行内评论")
        XCTAssertTrue(threads.contains { $0.isInline })
        XCTAssertTrue(threads.allSatisfy { !$0.notes.isEmpty })
    }
}
