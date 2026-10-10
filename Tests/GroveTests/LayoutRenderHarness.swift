import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Grove

/// 离屏渲染工具：把真实视图渲染成 PNG，用来肉眼检查布局。
///
/// SwiftUI 的布局 bug（视图不撑满、内容被裁、元素被推出可视区）编译器和断言都发现不了，
/// 只能看。这个工具把渲染结果落成图片，改一次看一次，不用每次都装 app 去点。
/// 它自己就抓出过「详情区垂直居中留大片空白」「diff 末尾多一行幻影空行」
/// 「文件名被截成 …pp.swift」三个问题。
///
/// **已知伪影**：`cacheDisplay` 不会解析深色外观下的材质和层次色
/// （`.quaternary`、`.bar`、`.regularMaterial`、按钮的 chrome 都渲成白色）。
/// 于是深色模式下那些地方的白色文字会「消失」在白底上 —— 那是渲染问题，
/// 不是布局问题，别照着它去改代码。要看的是**尺寸和位置**：谁没撑满、
/// 谁被裁了、谁被推出了可视区。
///
/// 默认不跑 —— 它要转 run loop、写文件，会拖慢日常的 `swift test`。需要时：
/// ```sh
/// GROVE_RENDER=1 swift test --filter LayoutRenderHarness
/// ```
/// 产物在 /tmp/grove-render-*.png。
@MainActor
final class LayoutRenderHarness: XCTestCase {
    private var shouldRun: Bool {
        ProcessInfo.processInfo.environment["GROVE_RENDER"] == "1"
    }

    func testRenderFailureContext() throws {
        try XCTSkipUnless(shouldRun, "设置 GROVE_RENDER=1 才会渲染")
        let app = AppModel()
        let repository = RepositoryModel(root: URL(fileURLWithPath: "/Users/jamie/Documents/code/tools/Grove"),
            git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:]), app: app)
        app.report(title: "自动 AI Review 检查失败", error: CommandFailure(
            executable: "/opt/homebrew/bin/gh", arguments: ["pr", "list"], exitCode: 1,
            output: "HTTP 403: Resource not accessible by integration"
        ), repository: repository, context: "PR #42 · 读取最新提交 · https://github.com/example/Grove/pull/42")
        let failure = try XCTUnwrap(app.failures.first)
        let view = FailureBanner(failure: failure, dismiss: {})
            .padding(20)
            .frame(width: 600, height: 300, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        try render(view, size: CGSize(width: 600, height: 300), to: "/tmp/grove-render-failure-context.png")
    }

    func testRenderWorktreeDetail() async throws {
        try XCTSkipUnless(shouldRun, "设置 GROVE_RENDER=1 才会渲染")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-render-\(UUID().uuidString)")
        // 工作树建在 root 的兄弟目录里，得一起清掉，不然每跑一次就往 /tmp 里留一份。
        let worktreeContainer = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-worktrees")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: worktreeContainer)
        }

        try seedRepository(at: root)

        let app = AppModel()
        await app.bootstrap()
        guard let repository = await app.openRepository(at: root, persist: false, select: false) else {
            XCTFail("打不开临时仓库"); return
        }
        guard let worktreePath = repository.worktrees.first?.path,
              let model = repository.worktreeModel(for: worktreePath) else {
            XCTFail("没有工作树"); return
        }
        await model.refresh()
        app.selection = .worktree(repository: repository.id, worktree: worktreePath)

        // 选中一个未跟踪目录里的文件，顺便验证 `-uall` 之后目录被展开了。
        model.selectedPath = model.status.changes.first { $0.path.hasPrefix("try/") }?.path
            ?? model.status.changes.first?.path
        // selectedPath 的 didSet 会异步去取 diff，等它落地再渲染。
        try await Task.sleep(for: .milliseconds(600))

        // 挑一个有真实改动的文件，勾一行 —— 分行提交的勾选框和操作条才会出现。
        model.selectedPath = model.status.changes.first { $0.path.hasSuffix("app.swift") }?.path
            ?? model.selectedPath
        try await Task.sleep(for: .milliseconds(600))
        if let line = model.diff?.first?.hunks.first?.lines.first(where: { $0.kind == .addition }) {
            model.toggleLine(line)
        }

        // 必须渲染整个 RootView，而不是单独渲 WorktreeDetailView：
        // NSHostingView 会把根视图强行拉满自己的 bounds，直接渲子视图会把
        // 「子视图自己不撑满」这个 bug 完全盖掉。套上 NavigationSplitView 才跟真实 app 一致。
        try render(RootView().environment(app),
                   size: CGSize(width: 1280, height: 860),
                   to: "/tmp/grove-render-changes.png")

        // 渲染前重新取一次状态：上一次 render 里 RootView 的 .task 会并发地
        // 再刷一遍，不等它落定就渲染，拿到的可能是刷新中途的空列表。
        await model.refresh()
        model.selectedCommit = model.commits.first?.oid
        if let featureTip = model.commits.first(where: { commit in
            commit.refs.contains { $0.name == "feature/login" }
        }) {
            model.focusGraph(on: featureTip.oid)
        }
        try await Task.sleep(for: .milliseconds(600))

        // 「历史」tab 的切换状态是 WorktreeDetailView 内部的 @State，外面设不了。
        // 直接把 HistoryView 放进 NavigationSplitView 的详情栏 —— 之前的 bug 正是
        // 「详情栏里的视图不撑满」，这个容器条件跟真实 app 一致，足以验证。
        let historyPage = NavigationSplitView {
            Text("侧栏")
        } detail: {
            VStack(spacing: 0) {
                Text("头部占位").padding(12).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                HistoryView(model: model, sheet: .constant(nil))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(app)

        try render(historyPage, size: CGSize(width: 1280, height: 860), to: "/tmp/grove-render-history.png")

        // 建标签弹窗：seed 出的两个远端正好能渲出「多远端选择器」的形态。
        if let commit = model.commits.first {
            let tagSheet = NewTagSheet(model: model, commit: commit)
                .environment(app)
            try render(tagSheet, size: CGSize(width: 480, height: 420), to: "/tmp/grove-render-new-tag.png")
        }
    }

    func testRenderNewTagAI() async throws {
        try XCTSkipUnless(shouldRun, "设置 GROVE_RENDER=1 才会渲染")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try await GitClient.resolve()
        try await git.run(["init", "-b", "main"], in: root)
        try await git.run(["config", "user.name", "测试"], in: root)
        try await git.run(["config", "user.email", "test@example.invalid"], in: root)
        try await git.run(["commit", "--allow-empty", "-m", "创建标签测试"], in: root)
        try await git.createTag("v1.0.0", message: "发布说明", at: "HEAD", in: root)
        let commits = try await git.log(in: root, limit: 1)
        let commit = try XCTUnwrap(commits.first)
        let suite = "grove-tag-render-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AIGenerationSettings(defaults: defaults)
        settings.setEnabled(true)
        settings.setProvider(.codex)
        let app = AppModel(aiGenerationSettings: settings)
        let repository = RepositoryModel(root: root, git: git, app: app)
        let worktree = Worktree(path: root, head: commit.oid, branch: "main", isBare: false,
                                isDetached: false, lockReason: nil, prunableReason: nil)
        let model = WorktreeModel(worktree: worktree, repository: repository, git: git, app: app)
        try render(
            NewTagSheet(model: model, commit: commit)
                .environment(app)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 480, height: 420), to: "/tmp/grove-render-new-tag-ai.png"
        )
    }

    func testSidebarSelectionInsets() throws {
        try XCTSkipUnless(shouldRun, "设置 GROVE_RENDER=1 才会渲染")
        try render(
            List {
                Label("Grove", systemImage: "house")
                    .frame(height: SidebarMetrics.rowHeight)
                    .listRowBackground(sidebarSelectionBackground(false))
                Label("main", systemImage: "externaldrive")
                    .foregroundStyle(.blue)
                    .frame(height: SidebarMetrics.rowHeight)
                    .listRowBackground(sidebarSelectionBackground(true))
                Label("LightSnap", systemImage: "house")
                    .frame(height: SidebarMetrics.rowHeight)
                    .listRowBackground(sidebarSelectionBackground(false))
            }
                .listStyle(.sidebar)
                .environment(\.colorScheme, .light),
            size: CGSize(width: 280, height: 160),
            to: "/tmp/grove-render-sidebar-selection-insets.png"
        )
    }

    func testSidebarPullRequestIcons() throws {
        try XCTSkipUnless(shouldRun, "设置 GROVE_RENDER=1 才会渲染")
        let states = ["OPEN", "MERGED", "CLOSED"]
        let requests = states.enumerated().map { index, state in
            PullRequest(
                number: index + 1, title: "评审", state: state, isDraft: false,
                headRefName: "feature", baseRefName: "main", url: "u", author: nil,
                updatedAt: Date(), additions: 0, deletions: 0, changedFiles: 0,
                reviewDecision: nil, mergeable: nil, isCrossRepository: false,
                labels: [], statusCheckRollup: nil, body: nil, headRepositoryOwner: nil
            )
        }
        for status in [PullRequest.Status.open, .draft, .merged, .closed] {
            let resource = try XCTUnwrap(PullRequestBadge.iconBundle.url(
                forResource: PullRequestBadge.iconName(for: status), withExtension: "png"
            ))
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: resource)))
            XCTAssertEqual(image.pixelsWide, 64)
            XCTAssertEqual(image.pixelsHigh, 64)
            XCTAssertTrue(image.hasAlpha, "官方图标必须保留透明背景")
            XCTAssertNotNil(PullRequestBadge.iconImage(for: status))
            let visiblePixels = (0..<image.pixelsWide).reduce(0) { count, horizontal in
                count + (0..<image.pixelsHigh).filter { vertical in
                    (image.colorAt(x: horizontal, y: vertical)?.alphaComponent ?? 0) > 0.1
                }.count
            }
            XCTAssertGreaterThan(visiblePixels, 0, "图标不能是全透明的空图片")
            XCTAssertLessThan(visiblePixels, image.pixelsWide * image.pixelsHigh, "图标背景必须透明")
        }
        try render(
            VStack(spacing: 0) {
                ForEach(requests) { request in
                    HStack(spacing: 8) {
                        Image(systemName: "leaf")
                            .foregroundStyle(.secondary)
                        Text("feature/\(request.state.lowercased())")
                        Spacer()
                        PullRequestBadge(pullRequest: request)
                    }
                    .font(.system(size: 13))
                    .frame(height: SidebarMetrics.rowHeight)
                }
            }
                .padding(16)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 320, height: 180),
            to: "/tmp/grove-render-sidebar-pr-states.png"
        )
    }

    func testRenderLongCommitBody() throws {
        try XCTSkipUnless(shouldRun, "设置 GROVE_RENDER=1 才会渲染")
        let commit = CommitSummary(
            oid: String(repeating: "a", count: 40), subject: "feat: 超长提交说明",
            authorName: "测试", authorEmail: "test@example.com", date: Date(),
            parents: [], refs: [],
            body: (1...100).map { "第 \($0) 行：提交说明不应挤走文件列表和差异视图。" }.joined(separator: "\n")
        )
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        for isExpanded in [false, true] {
            let header = CommitHeader(commit: commit, isBodyExpanded: .constant(isExpanded))
            let hosting = try render(
                VStack(spacing: 0) {
                    header.fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Color.gray.opacity(0.1)
                }
                    .environment(\.colorScheme, .light)
                    .background(Color.white),
                size: CGSize(width: 600, height: 400),
                to: "/tmp/grove-render-commit-body-\(isExpanded ? "expanded" : "collapsed").png"
            )
            let scrollViews = descendants(of: hosting).compactMap { $0 as? NSScrollView }
                .filter { $0.documentView is NSTextView }
            if isExpanded {
                let scrollView = try XCTUnwrap(scrollViews.first)
                let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
                XCTAssertEqual(textView.string, commit.body)
                XCTAssertFalse(textView.isEditable)
                XCTAssertTrue(textView.isSelectable)
                XCTAssertTrue(scrollView.hasVerticalScroller)
                XCTAssertFalse(scrollView.autohidesScrollers)
                XCTAssertEqual(scrollView.scrollerStyle, .legacy)
                let scroller = try XCTUnwrap(scrollView.verticalScroller)
                XCTAssertFalse(scroller.isHidden, "展开后必须显示滚动条")
                XCTAssertLessThan(scroller.knobProportion, 1, "超长正文应显示可拖动的滚动条")
                XCTAssertEqual(scrollView.frame.height, 180, accuracy: 1)
                let frame = scrollView.convert(scrollView.bounds, to: hosting)
                XCTAssertTrue(hosting.bounds.contains(frame), "正文滚动区必须留在窗口内")
                XCTAssertGreaterThan(textView.frame.height, scrollView.contentView.bounds.height)
                textView.scrollToEndOfDocument(nil)
                XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 0, "必须能滚动到正文末尾")
                XCTAssertEqual(textView.visibleRect.maxY, textView.bounds.maxY, accuracy: 5)
            } else {
                XCTAssertTrue(scrollViews.isEmpty, "默认收起时不应显示正文滚动区")
            }
        }
    }

    func testRenderHistoryLongBranch() async throws {
        try XCTSkipUnless(shouldRun, "设置 GROVE_RENDER=1 才会渲染")
        let git = try await GitClient.resolve()
        let model = WorktreeModel(
            worktree: Worktree(
                path: URL(fileURLWithPath: "/tmp/grove-history-layout"), head: nil,
                branch: nil, isBare: false, isDetached: false,
                lockReason: nil, prunableReason: nil
            ),
            repository: nil, git: git, app: nil
        )

        // 同时覆盖截图里的名称和超长多级名称；不建仓库、不请求远端。
        for (name, branch) in [
            ("normal", "JamieFingalden/dev-tag"),
            ("long", "feature/" + String(repeating: "very-long-branch-name/", count: 6) + "dev-tag")
        ] {
            model.worktree.branch = branch
            model.commits = [CommitSummary(
                oid: String(repeating: "a", count: 40),
                subject: "feat: 长分支名下，提交标题应在列表内正常换行显示",
                authorName: "测试", authorEmail: "test@example.com", date: Date(),
                parents: [], refs: [
                    CommitRef(name: branch, kind: .head),
                    CommitRef(name: "origin/main", kind: .remoteBranch),
                    CommitRef(name: "main", kind: .localBranch)
                ]
            )]
            for width in [800.0, 1280.0] {
                let hosting = try render(
                    HistoryView(model: model, sheet: .constant(nil))
                        .environment(\.colorScheme, .light)
                        .background(Color.white),
                    size: CGSize(width: width, height: 500),
                    to: "/tmp/grove-render-history-\(name)-\(Int(width)).png"
                )
                func descendants(of view: NSView) -> [NSView] {
                    view.subviews.flatMap { [$0] + descendants(of: $0) }
                }
                let views = descendants(of: hosting)
                let split = try XCTUnwrap(views.compactMap { $0 as? NSSplitView }.first)
                let list = try XCTUnwrap(split.subviews.first)
                let search = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
                    $0.placeholderString == "搜索提交信息"
                })
                let searchFrame = search.convert(search.bounds, to: list)
                XCTAssertGreaterThanOrEqual(searchFrame.minX, 0, "搜索框左侧不应被裁掉")
                XCTAssertLessThanOrEqual(searchFrame.maxX, list.bounds.width, "搜索框应留在列表内")
                XCTAssertGreaterThan(searchFrame.width, 180, "窄栏也应保留可用的搜索空间")
            }
        }
    }

    func testCITaskLoadingIgnoresCancelledRequest() async throws {
        try XCTSkipUnless(shouldRun, "设置 GROVE_RENDER=1 才会渲染")
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-ci-loading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 用本地脚本控制响应时机：第一条还在加载时切到第二条，不访问网络。
        try #"""
        case "$1" in
          list) printf '%s' '[{"databaseId":1,"status":"completed","conclusion":"success","headBranch":"first"},{"databaseId":2,"status":"completed","conclusion":"success","headBranch":"second"}]' ;;
          view)
            touch "started-$2"
            while [ ! -f "finish-$2" ]; do sleep 0.05; done
            printf '{"jobs":[{"databaseId":%s,"name":"任务-%s","status":"completed","conclusion":"success"}]}' "$2" "$2"
            ;;
        esac
        """#.write(to: root.appendingPathComponent("run"), atomically: true, encoding: .utf8)
        let repository = RepositoryModel(
            root: root, git: try await GitClient.resolve(), app: nil,
            forge: GitHubClient(executable: URL(fileURLWithPath: "/bin/sh"),
                                environment: ProcessInfo.processInfo.environment)
        )
        let hosting = NSHostingView(rootView: CIView(repository: repository)
            .environment(\.colorScheme, .light).background(Color.white))
        hosting.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        func waitUntil(_ predicate: () throws -> Bool) async throws {
            for _ in 0..<100 {
                hosting.layoutSubtreeIfNeeded()
                if try predicate() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTFail("等待界面状态超时")
        }
        func labels() throws -> [String] {
            // 离屏窗口的辅助功能树可能为空，直接检查实际渲染出的文字。
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("started-1").path) }
        let table = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSTableView }.first)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("started-2").path) }
        // 给旧任务的取消回调一次执行机会，加载提示仍应保留。
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/grove-render-ci-loading.png"))
        let loadingLabels = try labels().joined(separator: "\n")
        XCTAssertTrue(loadingLabels.contains("正在加载任务"), loadingLabels)
        XCTAssertFalse(loadingLabels.contains("CancellationError"), loadingLabels)
        XCTAssertFalse(loadingLabels.contains("没有任务"), loadingLabels)
        try Data().write(to: root.appendingPathComponent("finish-2"))
        try await waitUntil { try labels().contains { $0.contains("任务-2") } }
        XCTAssertFalse(try labels().contains { $0.contains("任务-1") })
    }

    // MARK: -

    private func seedRepository(at root: URL) throws {
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = root
            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            try process.run()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // 非零退出必须炸出来。之前 stderr 丢进 /dev/null 又不看退出码，
            // seed 中间某步失败时毫无痕迹，最后只看到一个空列表，
            // 还得去猜是渲染错了还是数据没出来。
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "seed", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) 失败：\(String(decoding: errorData, as: UTF8.self))"
                ])
            }
        }

        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@example.com"])
        try git(["config", "user.name", "测试"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "print(\"hello\")\n".write(to: root.appendingPathComponent("src/app.swift"), atomically: true, encoding: .utf8)
        try "# 说明\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "-A"])
        try git(["commit", "-qm", "初始提交"])
        try "print(\"hello\")\nprint(\"world\")\n".write(to: root.appendingPathComponent("src/app.swift"), atomically: true, encoding: .utf8)
        try "# 说明\n新增一行\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "README.md"])
        try "未跟踪内容\n".write(to: root.appendingPathComponent("src/新文件.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("try"), withIntermediateDirectories: true)
        try "目录里的文件\n".write(to: root.appendingPathComponent("try/inner.txt"), atomically: true, encoding: .utf8)

        // 造一段有分叉和合并的历史，提交图才有结构可看。
        try git(["checkout", "-q", "-b", "feature/login"])
        try "登录页\n".write(to: root.appendingPathComponent("login.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"]); try git(["commit", "-qm", "feat: 加上登录页"])
        try "校验\n".write(to: root.appendingPathComponent("valid.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"]); try git(["commit", "-qm", "feat: 加上表单校验"])
        try git(["checkout", "-q", "main"])
        try "主干\n".write(to: root.appendingPathComponent("trunk.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"]); try git(["commit", "-qm", "chore: 主干推进"])
        try git(["merge", "-q", "--no-ff", "feature/login", "-m", "Merge branch 'feature/login'"])
        try "收尾\n".write(to: root.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"]); try git(["commit", "-qm", "docs: 补充说明"])

        // 配两个远端，推送按钮才会变成分离式（多远端选择）。
        try git(["remote", "add", "origin", "http://10.0.0.1:8929/internal-group/demo.git"])
        try git(["remote", "add", "github", "https://github.com/example-owner/demo.git"])

        // 多建一个工作树，侧边栏才有内容可看。
        try git(["worktree", "add", "-q",
                 root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-worktrees/feature-login").path,
                 "feature/login"])
    }

    @discardableResult
    private func render(_ view: some View, size: CGSize, to path: String) throws -> NSHostingView<some View> {
        // 用 NSHostingView + cacheDisplay 而不是 SwiftUI 的 ImageRenderer：
        // List / HSplitView 在 macOS 上是 AppKit 控件包出来的，ImageRenderer 渲不出它们的内容。
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        // 转几圈 run loop，让 AppKit 把 NSTableView 之类的内容真正铺出来。
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        hosting.layoutSubtreeIfNeeded()

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "render", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建位图"])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "render", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG"])
        }
        try data.write(to: URL(fileURLWithPath: path))
        print("已渲染：\(path)")
        return hosting
    }
}

/// 渲染 PR 详情页（含新加的评审区）。需要联网和 `gh` 已登录，只读。
///
/// ```sh
/// GROVE_LIVE=1 GROVE_RENDER=1 swift test --filter LivePullRequestRenderHarness
/// ```
@MainActor
final class LivePullRequestRenderHarness: XCTestCase {
    func testRenderPullRequestDetail() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["GROVE_RENDER"] == "1" && environment["GROVE_LIVE"] == "1",
            "需要 GROVE_RENDER=1 GROVE_LIVE=1"
        )

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-pr-render-\(UUID().uuidString)")
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

        let app = AppModel()
        await app.bootstrap()
        guard let repository = await app.openRepository(at: root, persist: false, select: false) else {
            XCTFail("打不开仓库"); return
        }
        await repository.refreshPullRequests()
        guard !repository.pullRequests.isEmpty else { throw XCTSkip("没有开放的 PR 可渲染") }

        // 挑一个真的有讨论的 PR，评审区才有内容可看。
        let target = repository.pullRequests.first { $0.number == 14198 }?.number
            ?? repository.pullRequests.first!.number

        let page = NavigationSplitView {
            Text("侧栏")
        } detail: {
            PullRequestListView(repository: repository, initialSelection: target)
        }
        .environment(app)

        try await Task.sleep(for: .seconds(1))
        try render(page, size: CGSize(width: 1280, height: 900), to: "/tmp/grove-render-pr.png")
    }

    private func render(_ view: some View, size: CGSize, to path: String) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        hosting.layoutSubtreeIfNeeded()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("无法创建位图"); return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            XCTFail("无法编码 PNG"); return
        }
        try data.write(to: URL(fileURLWithPath: path))
        print("已渲染：\(path)")
    }
}

/// 渲染冲突解决面板：一个双方修改、一个传入侧删除，外加变基/合并横幅。
///
/// ```sh
/// GROVE_RENDER=1 swift test --filter ConflictRenderHarness
/// ```
@MainActor
final class ConflictRenderHarness: XCTestCase {
    func testRenderConflictResolution() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GROVE_RENDER"] == "1", "设置 GROVE_RENDER=1 才会渲染")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-render-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = try await GitClient.resolve()
        func write(_ text: String, to name: String) throws {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await git.run(["init", "-q", "-b", "main"], in: root)
        try await git.run(["config", "user.email", "t@example.com"], in: root)
        try await git.run(["config", "user.name", "测试"], in: root)
        try write((1...40).map { "line \($0)" }.joined(separator: "\n") + "\n", to: "src/app.swift".replacingOccurrences(of: "src/", with: ""))
        try write("keep\n", to: "delme.txt")
        try await git.run(["add", "-A"], in: root); try await git.run(["commit", "-qm", "初始"], in: root)
        try await git.run(["checkout", "-q", "-b", "feature/login"], in: root)
        var lines = (1...40).map { "line \($0)" }
        lines[4] = "func login() { /* feature */ }"
        lines[30] = "let retries = 5"
        try write(lines.joined(separator: "\n") + "\n", to: "app.swift")
        try FileManager.default.removeItem(at: root.appendingPathComponent("delme.txt"))
        try await git.run(["add", "-A"], in: root); try await git.run(["commit", "-qm", "feat: 登录"], in: root)
        try await git.run(["checkout", "-q", "main"], in: root)
        lines = (1...40).map { "line \($0)" }
        lines[4] = "func login() { /* main */ }"
        lines[30] = "let retries = 3"
        try write(lines.joined(separator: "\n") + "\n", to: "app.swift")
        try write("keep\nmain-change\n", to: "delme.txt")
        try await git.run(["add", "-A"], in: root); try await git.run(["commit", "-qm", "chore: 主干"], in: root)
        _ = try? await git.run(["merge", "feature/login"], in: root)

        let app = AppModel()
        await app.bootstrap()
        guard let repository = await app.openRepository(at: root, persist: false, select: false) else {
            XCTFail("打不开临时仓库"); return
        }
        guard let worktreePath = repository.worktrees.first?.path,
              let model = repository.worktreeModel(for: worktreePath) else {
            XCTFail("没有工作树"); return
        }
        await model.refresh()
        app.selection = .worktree(repository: repository.id, worktree: worktreePath)
        model.selectedPath = "app.swift"
        try await Task.sleep(for: .milliseconds(800))
        if case .editor(let editor) = model.conflictContent, let first = editor.document.blocks.first {
            await model.resolveBlock(first, with: .both)
        }
        try await Task.sleep(for: .milliseconds(300))
        try render(RootView().environment(app), size: CGSize(width: 1280, height: 860), to: "/tmp/grove-render-conflict.png")

        model.selectedPath = "delme.txt"
        try await Task.sleep(for: .milliseconds(800))
        try render(RootView().environment(app), size: CGSize(width: 1280, height: 860), to: "/tmp/grove-render-conflict-deleted.png")
    }

    private func render(_ view: some View, size: CGSize, to path: String) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        hosting.layoutSubtreeIfNeeded()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("无法创建位图"); return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            XCTFail("无法编码 PNG"); return
        }
        try data.write(to: URL(fileURLWithPath: path))
        print("已渲染：\(path)")
    }
}
