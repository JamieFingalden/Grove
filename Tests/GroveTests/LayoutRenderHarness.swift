import AppKit
import SwiftUI
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
        app.selection = .worktree(repository: repository.root, worktree: worktreePath)

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

        model.selectedCommit = model.commits.first?.oid
        try await Task.sleep(for: .milliseconds(400))

        // 「历史」tab 的切换状态是 WorktreeDetailView 内部的 @State，外面设不了。
        // 直接把 HistoryView 放进 NavigationSplitView 的详情栏 —— 之前的 bug 正是
        // 「详情栏里的视图不撑满」，这个容器条件跟真实 app 一致，足以验证。
        let historyPage = NavigationSplitView {
            Text("侧栏")
        } detail: {
            VStack(spacing: 0) {
                Text("头部占位").padding(12).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                HistoryView(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(app)

        try render(historyPage, size: CGSize(width: 1280, height: 860), to: "/tmp/grove-render-history.png")
    }

    // MARK: -

    private func seedRepository(at root: URL) throws {
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
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

        // 配两个远端，推送按钮才会变成分离式（多远端选择）。
        try git(["remote", "add", "origin", "http://10.0.0.1:8929/internal-group/demo.git"])
        try git(["remote", "add", "github", "https://github.com/example-owner/demo.git"])

        // 多建一个工作树，侧边栏才有内容可看。
        try git(["branch", "feature/login"])
        try git(["worktree", "add", "-q",
                 root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-worktrees/feature-login").path,
                 "feature/login"])
    }

    private func render(_ view: some View, size: CGSize, to path: String) throws {
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
