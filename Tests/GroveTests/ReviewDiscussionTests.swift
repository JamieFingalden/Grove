import AppKit
import SwiftUI
import XCTest
@testable import Grove

/// 用本地 CLI 替身检查讨论读写，不向远端发送评论。
final class ReviewDiscussionTests: XCTestCase {
    private let diff = """
    diff --git a/old.swift b/new.swift
    --- a/old.swift
    +++ b/new.swift
    @@ -10,3 +10,3 @@
     before
    -removed
    +added
     after
    """

    private func fixture(_ script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("cli")
        try ("#!/bin/sh\nprintf '%s\\n' \"$@\" > arguments\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return root
    }

    private func github(_ root: URL) -> GitHubClient {
        GitHubClient(executable: root.appendingPathComponent("cli"), environment: ProcessInfo.processInfo.environment)
    }

    private func arguments(_ root: URL) throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8).components(separatedBy: "\n")
    }

    private var thread: ReviewThread {
        ReviewThread(id: "PRRT_thread", notes: [.init(id: "17", authorName: "作者", authorLogin: "author",
                                                     body: "原始意见", createdAt: nil, isSystem: false)],
                     filePath: "new.swift", line: 11, isResolved: false, isResolvable: true)
    }

    func testLocationsPreserveSideAndRename() throws {
        let file = try XCTUnwrap(DiffParser.parse(diff).first)
        let lines = file.hunks.flatMap(\.lines)
        let removed = try XCTUnwrap(lines.first { $0.kind == .deletion })
        let added = try XCTUnwrap(lines.first { $0.kind == .addition })
        let old = try XCTUnwrap(ReviewLocation(file: file, line: removed, isOldSide: true))
        let new = try XCTUnwrap(ReviewLocation(file: file, line: added, isOldSide: false))
        XCTAssertEqual(old.path, "old.swift")
        XCTAssertEqual(new.path, "new.swift")
        XCTAssertEqual(old.line, 11)
        XCTAssertEqual(new.line, 11)
        XCTAssertNil(ReviewLocation(file: file, line: removed, isOldSide: false))
        XCTAssertNil(new.oldLine)
    }

    func testOriginalExcerptWinsAndOutdatedDoesNotBorrowNewCode() throws {
        var original = thread
        original.diffHunk = "@@ -10,3 +10,3 @@\n before\n-original\n+reviewed\n after"
        original.isOutdated = true
        let files = DiffParser.parse(diff)
        XCTAssertTrue(original.excerpt(in: files).contains { $0.text == "reviewed" })
        XCTAssertFalse(original.excerpt(in: files).contains { $0.text == "added" })
        original.diffHunk = nil
        XCTAssertTrue(original.excerpt(in: files).isEmpty)
    }

    func testGitHubPublishesLiteralBodyAtReviewedCommitAndSide() async throws {
        let root = try fixture("""
        if [ "$1" = pr ]; then printf 'head-sha'; else printf '{}'; fi
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try XCTUnwrap(DiffParser.parse(diff).first)
        let line = try XCTUnwrap(file.hunks.flatMap(\.lines).first { $0.kind == .deletion })
        let location = try XCTUnwrap(ReviewLocation(file: file, line: line, isOldSide: true))
        let body = "检查 `name` 与 $(literal)\n第二行"
        try await github(root).createDiscussion(number: 5, body: body, location: location, expectedHead: "head-sha", in: root)
        let args = try arguments(root)
        XCTAssertTrue(args.contains("path=new.swift"))
        XCTAssertTrue(args.contains("side=LEFT"))
        XCTAssertTrue(args.contains("line=11"))
        XCTAssertTrue(args.contains("commit_id=head-sha"))
        let raw = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
        XCTAssertTrue(raw.contains("body=\(body)"))
    }

    func testChangedHeadRejectsCommentBeforeWriting() async throws {
        let root = try fixture("printf 'new-head'")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try XCTUnwrap(DiffParser.parse(diff).first)
        let line = try XCTUnwrap(file.hunks.flatMap(\.lines).first { $0.kind == .addition })
        do {
            try await github(root).createDiscussion(number: 5, body: "意见", location: ReviewLocation(file: file, line: line, isOldSide: false), expectedHead: "old-head", in: root)
            XCTFail("代码更新后不能发布到旧行号")
        } catch ReviewDiscussionError.changedHead {}
        XCTAssertEqual(try arguments(root).first, "pr")
    }

    func testReplyUsesRootCommentAndResolveUsesThreadNode() async throws {
        let root = try fixture("printf '{\"data\":{\"resolveReviewThread\":{\"thread\":{\"id\":\"PRRT_thread\"}}}}'")
        defer { try? FileManager.default.removeItem(at: root) }
        try await github(root).reply(number: 5, thread: thread, body: "回复", in: root)
        XCTAssertTrue(try arguments(root).contains("repos/{owner}/{repo}/pulls/5/comments/17/replies"))
        try await github(root).setResolved(number: 5, thread: thread, resolved: true, in: root)
        XCTAssertTrue(try arguments(root).contains("id=PRRT_thread"))
        XCTAssertTrue(try arguments(root).contains { $0.contains("resolveReviewThread(input:") })
    }

    func testGitHubLoadsResolvedMetadataAndAllCommentPages() async throws {
        let root = try fixture("""
        case "$1/$2" in
          repo/view) printf 'owner/repo' ;;
          api/graphql) cat state.json ;;
          api/*/pulls/*) cat inline.json ;;
          api/*/issues/*) printf '[[]]' ;;
          *) exit 2 ;;
        esac
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        [[{"id":17,"body":"原始意见","path":"new.swift","line":11,"side":"RIGHT"}],
         [{"id":18,"body":"回复","in_reply_to_id":17,"path":"new.swift","line":11}]]
        """.write(to: root.appendingPathComponent("inline.json"), atomically: true, encoding: .utf8)
        try """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{
          "nodes":[{"id":"PRRT_thread","isResolved":true,"isOutdated":true,"viewerCanResolve":false,
                    "viewerCanUnresolve":true,"comments":{"nodes":[{"databaseId":17}]}}],
          "pageInfo":{"hasNextPage":false,"endCursor":null}
        }}}}}
        """.write(to: root.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        let loaded = try await github(root).reviewThreads(number: 5, in: root)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "PRRT_thread")
        XCTAssertEqual(loaded[0].notes.count, 2)
        XCTAssertTrue(loaded[0].isResolved)
        XCTAssertTrue(loaded[0].isOutdated)
        XCTAssertTrue(loaded[0].canResolve)
    }

    func testReadFailureIsNotAnEmptyDiscussionList() async throws {
        let root = try fixture("exit 1")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await github(root).reviewThreads(number: 5, in: root)
            XCTFail("读取失败必须交给界面展示，不能伪装成空讨论")
        } catch {}
    }

    func testGitLabDiscussionIncludesDiffRefsAndContextCoordinates() async throws {
        let root = try fixture("""
        case "$2" in
          projects/:id/merge_requests/5) printf '{"sha":"head","diff_refs":{"base_sha":"base","head_sha":"head","start_sha":"start"}}' ;;
          *) printf '{}' ;;
        esac
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GitLabClient(executable: root.appendingPathComponent("cli"), environment: ProcessInfo.processInfo.environment)
        let file = try XCTUnwrap(DiffParser.parse(diff).first)
        let line = try XCTUnwrap(file.hunks.flatMap(\.lines).first { $0.kind == .context })
        try await client.createDiscussion(number: 5, body: "上下文意见", location: ReviewLocation(file: file, line: line, isOldSide: false), expectedHead: "head", in: root)
        let args = try arguments(root)
        XCTAssertTrue(args.contains("position[base_sha]=base"))
        XCTAssertTrue(args.contains("position[start_sha]=start"))
        XCTAssertTrue(args.contains("position[old_path]=old.swift"))
        XCTAssertTrue(args.contains("position[new_path]=new.swift"))
        XCTAssertTrue(args.contains("position[old_line]=10"))
        XCTAssertTrue(args.contains("position[new_line]=10"))
    }

    func testGitLabOpenRequestsContinuePastFirstPage() async throws {
        let root = try fixture("""
        case "$2" in
          *page=1) cat first.json ;;
          *page=2) cat second.json ;;
          *) exit 2 ;;
        esac
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = (1...101).map { number in
            ["iid": number, "title": "请求 \(number)", "state": "opened",
             "source_branch": "feature-\(number)", "target_branch": "main",
             "web_url": "https://example.invalid/merge_requests/\(number)"] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: Array(requests.prefix(100)))
            .write(to: root.appendingPathComponent("first.json"))
        try JSONSerialization.data(withJSONObject: Array(requests.suffix(1)))
            .write(to: root.appendingPathComponent("second.json"))
        let client = GitLabClient(executable: root.appendingPathComponent("cli"), environment: ProcessInfo.processInfo.environment)
        let loaded = try await client.pullRequests(in: root, limit: 1000, state: .open)
        XCTAssertEqual(loaded.count, 101)
        XCTAssertEqual(loaded.last?.number, 101)
        XCTAssertTrue(try arguments(root).contains { $0.contains("per_page=100") && $0.contains("state=opened") && $0.hasSuffix("page=2") })
    }
}

/// 按需检查真实 PR 页的宽窄窗口布局，所有数据来自本地替身。
@MainActor
final class ReviewDiscussionRenderTests: XCTestCase {
    func testRenderReviewPage() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GROVE_RENDER"] == "1", "设置 GROVE_RENDER=1 才渲染界面")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grove-review-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request: [String: Any] = [
            "number": 5, "title": "feat: 工具栏标签按钮与版本号自动预填", "state": "OPEN", "isDraft": false,
            "headRefName": "feature/dev-tag", "baseRefName": "main", "isCrossRepository": false,
            "url": "https://github.com/example/grove/pull/5", "updatedAt": "2026-10-08T02:00:00Z",
            "additions": 152, "deletions": 1, "changedFiles": 3, "labels": [], "mergeable": "MERGEABLE",
            "author": ["login": "Jamie"], "body": "## 改动\n\n- 工具栏添加 **标签** 按钮。\n- 打开弹窗后自动预填下一个版本号。\n\n## 验证\n\n版本号解析与异步输入保护检查通过。",
            "statusCheckRollup": [["__typename": "CheckRun", "name": "测试与打包", "status": "COMPLETED", "conclusion": "SUCCESS"]]
        ]
        try JSONSerialization.data(withJSONObject: request).write(to: root.appendingPathComponent("request.json"))
        try JSONSerialization.data(withJSONObject: [request]).write(to: root.appendingPathComponent("list.json"))
        let inline: [[String: Any]] = [[
            "id": 17, "path": "Sources/Grove/Views/Sheets.swift", "line": 11, "side": "RIGHT",
            "created_at": "2026-10-08T02:01:00Z", "user": ["login": "codex-review"],
            "body": "**等待查询后再次检查标签输入**\n\n标签查询可能通过 SSH 花费数秒。用户在等待时已经输入内容，返回后应再次检查 `name.isEmpty`，防止覆盖用户输入。",
            "diff_hunk": "@@ -10,2 +10,3 @@\n if name.isEmpty {\n+    name = await suggestedTagName()\n }"
        ]]
        try JSONSerialization.data(withJSONObject: [inline]).write(to: root.appendingPathComponent("inline.json"))
        try """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{
        "nodes":[{"id":"PRRT_demo","isResolved":false,"isOutdated":false,"viewerCanResolve":true,
        "viewerCanUnresolve":true,"comments":{"nodes":[{"databaseId":17}]}}],
        "pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
        """.write(to: root.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        try """
        diff --git a/Sources/Grove/Views/Sheets.swift b/Sources/Grove/Views/Sheets.swift
        --- a/Sources/Grove/Views/Sheets.swift
        +++ b/Sources/Grove/Views/Sheets.swift
        @@ -10,2 +10,3 @@
         if name.isEmpty {
        +    name = await suggestedTagName()
         }
        """.write(to: root.appendingPathComponent("diff.txt"), atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("gh")
        try """
        #!/bin/sh
        case "$1/$2" in
          pr/list) cat list.json ;;
          pr/view) if [ "$5" = headRefOid ]; then printf 'review-head'; else cat request.json; fi ;;
          pr/diff) cat diff.txt ;;
          repo/view) printf 'example/grove' ;;
          api/graphql) cat state.json ;;
          api/*/pulls/*) cat inline.json ;;
          api/*/issues/*) printf '[[]]' ;;
          *) exit 2 ;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let app = AppModel()
        let repository = RepositoryModel(root: root, git: try await GitClient.resolve(), app: nil,
                                         forge: GitHubClient(executable: executable, environment: ProcessInfo.processInfo.environment))
        repository.slug = "example/grove"
        repository.hasRemote = true
        repository.origin = GitRemote.parse("https://github.com/example/grove.git")
        for width in [1600, 1000] {
            let hosting = NSHostingView(rootView: PullRequestListView(repository: repository, initialSelection: 5)
                .environment(app).environment(\.colorScheme, .light).background(Color.white))
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            hosting.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            for _ in 0..<25 {
                try await Task.sleep(for: .milliseconds(100))
                hosting.layoutSubtreeIfNeeded()
            }
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/grove-review-\(width).png"))
            window.contentView = nil
        }
    }
}
