import AppKit
import SwiftUI
import XCTest
@testable import Grove

/// 仅测试使用的原生窗口预览，模拟平台响应不进入正式运行逻辑。
///
/// **已知盲区**：窗口内容经 `NSHostingController` 装载，SwiftUI 的 `.toolbar`
/// 修饰符在这里不会创建真正的 NSToolbar，工具栏内容退化成内联排布、
/// 全部挤在左缘 —— **placement（导航/主操作）在这张截图里看不出来**。
/// 工具栏布局改动必须启动打包后的真 App（`scripts/build.sh` + `open` +
/// `screencapture -R`）验证，别信这里的工具栏区域。
@MainActor
final class VisualPolishRenderTests: XCTestCase {
    func testNativeWindowStates() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GROVE_RENDER"] == "1", "设置 GROVE_RENDER=1 才会渲染")
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("grove-polish-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Grove")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let suite = "grove.polish.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AIGenerationSettings(defaults: defaults)
        settings.setAutomaticReviewEnabled(false, for: root)
        let app = AppModel(aiGenerationSettings: settings, aiReviewCache: AIReviewCache(defaults: defaults),
                           remoteServerStore: RemoteServerStore(defaults: defaults),
                           remoteProjectStore: RemoteProjectStore(defaults: defaults))
        await app.bootstrap()
        let git = try await GitClient.resolve()
        try await git.run(["init", "-q", "-b", "main"], in: root)
        try await git.run(["config", "user.name", "视觉预览"], in: root)
        try await git.run(["config", "user.email", "preview@example.invalid"], in: root)
        try await git.run(["commit", "--allow-empty", "-qm", "预览初始提交"], in: root)
        try await git.run(["remote", "add", "origin", "https://gitlab.example.com/developer/Grove.git"], in: root)
        for branch in ["feature/status", "feature/remote-worktree-feedback"] {
            try await git.run(["worktree", "add", "-b", branch, container.appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-")).path], in: root)
        }
        let response = container.appendingPathComponent("response.json")
        let failure = container.appendingPathComponent("failure")
        let delay = container.appendingPathComponent("delay")
        let executable = container.appendingPathComponent("glab")
        try """
        #!/bin/sh
        if [ -f "\(failure.path)" ]; then
          echo 'HTTP 403: 当前身份无权读取合并请求，请检查登录身份或项目权限。' >&2
          exit 1
        fi
        if [ -f "\(delay.path)" ]; then sleep 2; fi
        cat "\(response.path)"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try "[]".write(to: response, atomically: true, encoding: .utf8)
        let repository = RepositoryModel(root: root, git: git, app: nil,
            forge: GitLabClient(executable: executable, environment: ProcessInfo.processInfo.environment))
        repository.slug = "developer/Grove"
        repository.origin = GitRemote.parse("https://gitlab.example.com/developer/Grove.git")
        repository.hasRemote = true
        repository.hasOrigin = true
        repository.defaultBranch = "main"
        repository.worktrees = try await git.worktrees(in: root)
        let companion = RepositoryModel(root: container.appendingPathComponent("Developer Tools"), git: git, app: nil)
        companion.worktrees = [Worktree(path: companion.root, head: nil, branch: "main", isBare: false,
            isDetached: false, lockReason: nil, prunableReason: nil)]
        app.repositories = [repository, companion]
        app.selection = .repositoryHome(repository: repository.id)
        app.addRemoteServer(RemoteServer(alias: "开发环境", host: "127.0.0.1", port: 1))

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-polish")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let controller = NSHostingController(rootView: RootView().environment(app).environment(\.colorScheme, .light)
            .frame(minWidth: 980, minHeight: 620))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Grove · 视觉预览"
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.appearance = NSAppearance(named: .aqua)
        defer { window.orderOut(nil); window.contentViewController = nil }
        window.setContentSize(NSSize(width: 1280, height: 800))
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        func capture(_ name: String, wait: Duration = .milliseconds(600)) async throws {
            try await Task.sleep(for: wait)
            window.layoutIfNeeded()
            XCTAssertGreaterThanOrEqual(window.frame.width, 980, "原生窗口不应被内容固有尺寸压缩")
            XCTAssertGreaterThanOrEqual(window.frame.height, 620, "原生窗口不应裁切主内容")
            let path = output.appendingPathComponent(name + ".png").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            let success = (try? process.run()) != nil && {
                process.waitUntilExit()
                return process.terminationStatus == 0
            }()
            if !success, let hosting = window.contentView {
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            print("已渲染原生窗口：\(path)")
        }

        await repository.refreshPullRequests()
        try await capture("empty-light")
        window.appearance = NSAppearance(named: .darkAqua)
        controller.rootView = RootView().environment(app).environment(\.colorScheme, .dark)
            .frame(minWidth: 980, minHeight: 620)
        try await capture("empty-dark")
        window.setContentSize(NSSize(width: 980, height: 680))
        try await capture("empty-compact-dark")

        try #"""
        [{"iid":42,"title":"优化仓库切换时的状态恢复","state":"opened","source_branch":"feature/status","target_branch":"main","web_url":"https://gitlab.example.com/developer/Grove/-/merge_requests/42","author":{"username":"preview","name":"开发者"},"updated_at":"2026-10-13T07:00:00Z","head_pipeline":{"id":1,"status":"success"}},
         {"iid":43,"title":"修复远程工作树同步反馈与连接状态显示","state":"opened","draft":true,"source_branch":"feature/remote-worktree-feedback","target_branch":"main","web_url":"https://gitlab.example.com/developer/Grove/-/merge_requests/43","author":{"username":"preview","name":"开发者"},"updated_at":"2026-10-13T06:00:00Z"}]
        """#.write(to: response, atomically: true, encoding: .utf8)
        await repository.refreshPullRequests()
        window.setContentSize(NSSize(width: 1280, height: 800))
        try await capture("list-dark")
        window.appearance = NSAppearance(named: .aqua)
        controller.rootView = RootView().environment(app).environment(\.colorScheme, .light)
            .frame(minWidth: 980, minHeight: 620)
        try await capture("list-light")
        try "[]".write(to: response, atomically: true, encoding: .utf8)
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let navigation = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == 2 && $0.label(forSegment: 0) == "合并请求" })
        let action = try XCTUnwrap(navigation.action)
        navigation.selectedSegment = 1
        XCTAssertTrue(navigation.sendAction(action, to: navigation.target), "导航必须保留真实的分栏切换动作")
        try await capture("ci-empty")
        // 分栏切换后原控件已被卸载，必须操作当前界面中的导航。
        let backNavigation = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == 2 && $0.label(forSegment: 0) == "合并请求" })
        backNavigation.selectedSegment = 0
        XCTAssertTrue(backNavigation.sendAction(try XCTUnwrap(backNavigation.action), to: backNavigation.target))
        await repository.refreshPullRequests()
        try Data().write(to: delay)
        let loading = Task { await repository.refreshPullRequests() }
        try await capture("loading", wait: .milliseconds(200))
        await loading.value
        try FileManager.default.removeItem(at: delay)
        try Data().write(to: failure)
        await repository.refreshPullRequests()
        XCTAssertNotNil(repository.pullRequestLoadError, "身份验证失败必须保持错误状态")
        try await capture("failure")
    }

    func testWorktreeDetailNativeWindowStates() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GROVE_RENDER"] == "1", "设置 GROVE_RENDER=1 才会渲染")
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("grove-worktree-polish-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Grove")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let suite = "grove.worktree.polish.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AIGenerationSettings(defaults: defaults)
        let app = AppModel(aiGenerationSettings: settings, aiReviewCache: AIReviewCache(defaults: defaults),
                           remoteServerStore: RemoteServerStore(defaults: defaults),
                           remoteProjectStore: RemoteProjectStore(defaults: defaults))
        await app.bootstrap()
        let git = try await GitClient.resolve()
        try await git.run(["init", "-q", "-b", "main"], in: root)
        try await git.run(["config", "user.name", "视觉预览"], in: root)
        try await git.run(["config", "user.email", "preview@example.invalid"], in: root)
        let readme = root.appendingPathComponent("README.md")
        try "# Grove\n\n高效的 Git 多工作树管理器。\n".write(to: readme, atomically: true, encoding: .utf8)
        try await git.run(["add", "README.md"], in: root)
        try await git.run(["commit", "-qm", "Initial commit"], in: root)
        try await git.run(["remote", "add", "origin", "https://gitlab.example.com/developer/Grove.git"], in: root)

        for branch in ["feature/status", "feature/remote-worktree-feedback"] {
            try await git.run(["worktree", "add", "-b", branch, container.appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-")).path], in: root)
        }

        try "# Grove\n\n高效的 Git 多工作树与远程环境协作工具。\n\n## 特性\n- 90% macOS 原生质感\n- 10% Linear 信息组织精度\n- 极致流畅交互\n".write(to: readme, atomically: true, encoding: .utf8)
        let helper = root.appendingPathComponent("Helper.swift")
        try "import Foundation\n\npublic struct Helper {\n    public static let version = \"1.0.0\"\n}\n".write(to: helper, atomically: true, encoding: .utf8)
        try await git.run(["add", "Helper.swift"], in: root)

        let repository = RepositoryModel(root: root, git: git, app: app)
        repository.slug = "developer/Grove"
        repository.origin = GitRemote.parse("https://gitlab.example.com/developer/Grove.git")
        repository.hasRemote = true
        repository.hasOrigin = true
        repository.defaultBranch = "main"
        repository.worktrees = try await git.worktrees(in: root)
        let companion = RepositoryModel(root: container.appendingPathComponent("Developer Tools"), git: git, app: app)
        companion.worktrees = [Worktree(path: companion.root, head: nil, branch: "main", isBare: false,
            isDetached: false, lockReason: nil, prunableReason: nil)]
        app.repositories = [repository, companion]
        await repository.refresh(loadForgeMetadata: false)
        let targetPath = repository.worktrees.first!.path
        app.selection = .worktree(repository: repository.id, worktree: targetPath)
        app.addRemoteServer(RemoteServer(alias: "开发环境", host: "127.0.0.1", port: 1))

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-polish")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let controller = NSHostingController(rootView: RootView().environment(app).environment(\.colorScheme, .light)
            .frame(minWidth: 980, minHeight: 620))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Grove · 工作树视图"
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.appearance = NSAppearance(named: .aqua)
        defer { window.orderOut(nil); window.contentViewController = nil }
        window.setContentSize(NSSize(width: 1280, height: 800))
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        func capture(_ name: String, wait: Duration = .milliseconds(800)) async throws {
            try await Task.sleep(for: wait)
            window.layoutIfNeeded()
            let path = output.appendingPathComponent(name + ".png").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            let success = (try? process.run()) != nil && {
                process.waitUntilExit()
                return process.terminationStatus == 0
            }()
            if !success, let hosting = window.contentView {
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            print("已渲染原生窗口：\(path)")
        }

        if let wtModel = repository.worktreeModel(for: targetPath) {
            await wtModel.refresh()
            wtModel.diffSide = .worktree
            wtModel.selectedPath = "README.md"
            wtModel.commitMessage = ""
        }

        try await capture("worktree-light")
        window.appearance = NSAppearance(named: .darkAqua)
        controller.rootView = RootView().environment(app).environment(\.colorScheme, .dark)
            .frame(minWidth: 980, minHeight: 620)
        try await capture("worktree-dark")
    }

    func testPullRequestReviewNativeWindowStates() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GROVE_RENDER"] == "1", "设置 GROVE_RENDER=1 才会渲染")
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("grove-pr-polish-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Grove")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let suite = "grove.pr.polish.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AIGenerationSettings(defaults: defaults)
        settings.setAutomaticReviewEnabled(false, for: root)
        let app = AppModel(aiGenerationSettings: settings, aiReviewCache: AIReviewCache(defaults: defaults),
                           remoteServerStore: RemoteServerStore(defaults: defaults),
                           remoteProjectStore: RemoteProjectStore(defaults: defaults))
        await app.bootstrap()
        let git = try await GitClient.resolve()
        try await git.run(["init", "-q", "-b", "main"], in: root)
        try await git.run(["config", "user.name", "视觉预览"], in: root)
        try await git.run(["config", "user.email", "preview@example.invalid"], in: root)
        try await git.run(["commit", "--allow-empty", "-qm", "预览初始提交"], in: root)
        try await git.run(["remote", "add", "origin", "https://gitlab.example.com/developer/Grove.git"], in: root)

        let executable = container.appendingPathComponent("glab")
        let script = """
        #!/bin/sh
        case "$*" in
          *"merge_requests/42/raw_diffs"*)
            cat << 'EOF'
        diff --git a/Sources/Grove/App/AppModel.swift b/Sources/Grove/App/AppModel.swift
        index 1111111..2222222 100644
        --- a/Sources/Grove/App/AppModel.swift
        +++ b/Sources/Grove/App/AppModel.swift
        @@ -10,6 +10,12 @@ public final class AppModel: ObservableObject {
             public var activeRepository: RepositoryModel?
        +    /// 恢复之前保存的工作区状态
        +    public func restoreWorkspaceState() {
        +        // 恢复选中项与滚动位置
        +        logger.info("Restoring workspace state")
        +    }
        +
             public func saveWorkspaceState() {
        diff --git a/Sources/Grove/Views/RootView.swift b/Sources/Grove/Views/RootView.swift
        index 3333333..4444444 100644
        --- a/Sources/Grove/Views/RootView.swift
        +++ b/Sources/Grove/Views/RootView.swift
        @@ -5,4 +5,8 @@ struct RootView: View {
             var body: some View {
        +        // 主工作区容器
        +        WorkspaceContainer()
             }
         }
        EOF
            ;;
          *"merge_requests/42"*)
            cat << 'EOF'
        {"iid":42,"title":"优化仓库切换时的状态恢复与工作区同步","description":"## 背景与动机\\n\\n此前在多个仓库之间切换时，界面的滚动位置和当前选中的工作树会丢失。\\n\\n本改动引入工作区持久化机制，并在切换后平滑恢复。\\n\\n### 改动明细\\n- 状态缓存模型：按仓库持久化最后选中的路径与滚动偏移量\\n- 异步恢复监听器：切换后等待视图挂载完毕再触发恢复\\n- 避免由于生命周期提前卸载导致的状态重置","state":"opened","source_branch":"feature/status","target_branch":"main","web_url":"https://gitlab.example.com/developer/Grove/-/merge_requests/42","author":{"username":"preview","name":"开发者"},"updated_at":"2026-10-13T07:00:00Z","sha":"abcdef123456","diff_refs":{"base_sha":"1111111","head_sha":"abcdef123456","start_sha":"1111111"},"head_pipeline":{"id":1,"status":"success"},"has_conflicts":false,"blocking_discussions_resolved":true}
        EOF
            ;;
          *"merge_requests"*)
            cat << 'EOF'
        [{"iid":42,"title":"优化仓库切换时的状态恢复与工作区同步","state":"opened","source_branch":"feature/status","target_branch":"main","web_url":"https://gitlab.example.com/developer/Grove/-/merge_requests/42","author":{"username":"preview","name":"开发者"},"updated_at":"2026-10-13T07:00:00Z","head_pipeline":{"id":1,"status":"success"}}]
        EOF
            ;;
          *)
            echo "[]"
            ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let repository = RepositoryModel(root: root, git: git, app: app,
            forge: GitLabClient(executable: executable, environment: ProcessInfo.processInfo.environment))
        repository.slug = "developer/Grove"
        repository.origin = GitRemote.parse("https://gitlab.example.com/developer/Grove.git")
        repository.hasRemote = true
        repository.hasOrigin = true
        repository.defaultBranch = "main"
        repository.worktrees = try await git.worktrees(in: root)
        app.repositories = [repository]

        await repository.refreshPullRequests()

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-polish")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let reviewView = NavigationSplitView {
            SidebarView(sheet: .constant(nil))
                .navigationSplitViewColumnWidth(min: 220, ideal: GroveStyle.sidebarWidth, max: 320)
        } detail: {
            PullRequestListView(repository: repository, initialSelection: 42)
        }
        .environment(app)

        let controller = NSHostingController(rootView: reviewView.environment(\.colorScheme, .light)
            .frame(minWidth: 980, minHeight: 620))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Grove · PR 评审视图"
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.appearance = NSAppearance(named: .aqua)
        defer { window.orderOut(nil); window.contentViewController = nil }
        window.setContentSize(NSSize(width: 1280, height: 800))
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        func capture(_ name: String, wait: Duration = .milliseconds(800)) async throws {
            try await Task.sleep(for: wait)
            window.layoutIfNeeded()
            let path = output.appendingPathComponent(name + ".png").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            let success = (try? process.run()) != nil && {
                process.waitUntilExit()
                return process.terminationStatus == 0
            }()
            if !success, let hosting = window.contentView {
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            print("已渲染原生窗口：\(path)")
        }

        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }

        // 1280 x 800 (Light) - Overview
        try await capture("pr-review-1280-overview", wait: .milliseconds(1200))

        // 1280 x 800 (Dark) - Overview
        window.appearance = NSAppearance(named: .darkAqua)
        controller.rootView = reviewView.environment(\.colorScheme, .dark)
            .frame(minWidth: 980, minHeight: 620)
        try await capture("pr-review-1280-dark")

        // 1560 x 900 (Light) - Overview
        window.appearance = NSAppearance(named: .aqua)
        controller.rootView = reviewView.environment(\.colorScheme, .light)
            .frame(minWidth: 980, minHeight: 620)
        window.setContentSize(NSSize(width: 1560, height: 900))
        try await capture("pr-review-1560-overview")

        // 1920 x 1080 (Light) - Overview
        window.setContentSize(NSSize(width: 1920, height: 1080))
        try await capture("pr-review-1920-overview")

        // Switch to "代码变更" tab
        if let tabSegment = descendants(controller.view).compactMap({ $0 as? NSSegmentedControl })
            .first(where: { control in
                (0..<control.segmentCount).contains { control.label(forSegment: $0)?.contains("代码变更") == true }
            }) {
            if let targetIdx = (0..<tabSegment.segmentCount).first(where: { tabSegment.label(forSegment: $0)?.contains("代码变更") == true }) {
                tabSegment.selectedSegment = targetIdx
                if let action = tabSegment.action {
                    tabSegment.sendAction(action, to: tabSegment.target)
                }
            }
        }

        // 1920 x 1080 - Code Diff
        try await capture("pr-review-1920-diff", wait: .milliseconds(1500))

        // 1560 x 900 - Code Diff
        window.setContentSize(NSSize(width: 1560, height: 900))
        try await capture("pr-review-1560-diff")

        // 1280 x 800 - Code Diff
        window.setContentSize(NSSize(width: 1280, height: 800))
        try await capture("pr-review-1280-diff")

        // Switch to Split Diff layout
        UserDefaults.standard.set(DiffLayout.split.rawValue, forKey: DiffLayout.storageKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        defer {
            UserDefaults.standard.set(DiffLayout.unified.rawValue, forKey: DiffLayout.storageKey)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        }

        // 1920 x 1080 - Split Diff
        window.setContentSize(NSSize(width: 1920, height: 1080))
        try await capture("pr-review-1920-split-diff", wait: .milliseconds(1500))

        // 1560 x 900 - Split Diff
        window.setContentSize(NSSize(width: 1560, height: 900))
        try await capture("pr-review-1560-split-diff")

        // 1280 x 800 - Split Diff
        window.setContentSize(NSSize(width: 1280, height: 800))
        try await capture("pr-review-1280-split-diff")
    }

    func testPullRequestListSelectionAndHoverPolish() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GROVE_RENDER"] == "1", "设置 GROVE_RENDER=1 才会渲染")
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("grove-pr-list-polish-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Grove")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let suite = "grove.pr.list.polish.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AIGenerationSettings(defaults: defaults)
        settings.setAutomaticReviewEnabled(false, for: root)
        let app = AppModel(aiGenerationSettings: settings, aiReviewCache: AIReviewCache(defaults: defaults),
                           remoteServerStore: RemoteServerStore(defaults: defaults),
                           remoteProjectStore: RemoteProjectStore(defaults: defaults))
        await app.bootstrap()
        let git = try await GitClient.resolve()
        try await git.run(["init", "-q", "-b", "main"], in: root)
        try await git.run(["config", "user.name", "视觉预览"], in: root)
        try await git.run(["config", "user.email", "preview@example.invalid"], in: root)
        try await git.run(["commit", "--allow-empty", "-qm", "预览初始提交"], in: root)
        try await git.run(["remote", "add", "origin", "https://gitlab.example.com/developer/Grove.git"], in: root)

        let executable = container.appendingPathComponent("glab")
        let script = """
        #!/bin/sh
        case "$*" in
          *"merge_requests"*)
            cat << 'EOF'
        [
          {"iid":10,"title":"fix: 仓库标识改为本地解析，评审入口不再等网络探测或 PR 列表加载","state":"merged","source_branch":"feature/new-page","target_branch":"main","web_url":"https://gitlab.example.com/developer/Grove/-/merge_requests/10","author":{"username":"jamie","name":"Jamie Fingalden"},"updated_at":"2026-10-15T07:00:00Z","head_pipeline":{"id":1,"status":"success"}},
          {"iid":9,"title":"feat: PR 详情改为列表/评审双模式全屏切换，详情重构为概览/代码/检查/评审四分区","state":"merged","source_branch":"feature/new-ui","target_branch":"main","web_url":"https://gitlab.example.com/developer/Grove/-/merge_requests/9","author":{"username":"jamie","name":"Jamie Fingalden"},"updated_at":"2026-10-14T07:00:00Z","head_pipeline":{"id":2,"status":"success"}},
          {"iid":8,"title":"feat: 引入统一设计系统 GroveStyle 与自绘图标体系，PR/CI 页新增加载/空/失败三态","state":"closed","source_branch":"feature/new-ui","target_branch":"main","web_url":"https://gitlab.example.com/developer/Grove/-/merge_requests/8","author":{"username":"jamie","name":"Jamie Fingalden"},"updated_at":"2026-10-13T07:00:00Z"}
        ]
        EOF
            ;;
          *)
            echo "[]"
            ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let repository = RepositoryModel(root: root, git: git, app: app,
            forge: GitLabClient(executable: executable, environment: ProcessInfo.processInfo.environment))
        repository.slug = "developer/Grove"
        repository.origin = GitRemote.parse("https://gitlab.example.com/developer/Grove.git")
        repository.hasRemote = true
        repository.hasOrigin = true
        repository.defaultBranch = "main"
        repository.worktrees = try await git.worktrees(in: root)
        app.repositories = [repository]

        await repository.refreshPullRequests()

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-polish")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let listView = NavigationSplitView {
            SidebarView(sheet: .constant(nil))
                .navigationSplitViewColumnWidth(min: 220, ideal: GroveStyle.sidebarWidth, max: 320)
        } detail: {
            PullRequestListView(repository: repository, initialSelection: 10, initialMode: .list, previewHoverNumber: 9)
        }
        .environment(app)

        let controller = NSHostingController(rootView: listView.environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .key)
            .frame(minWidth: 980, minHeight: 620))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Grove · PR 列表交互"
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.appearance = NSAppearance(named: .aqua)
        defer { window.orderOut(nil); window.contentViewController = nil }
        window.setContentSize(NSSize(width: 1280, height: 800))
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        func capture(_ name: String, wait: Duration = .milliseconds(800)) async throws {
            try await Task.sleep(for: wait)
            window.layoutIfNeeded()
            let path = output.appendingPathComponent(name + ".png").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            let success = (try? process.run()) != nil && {
                process.waitUntilExit()
                return process.terminationStatus == 0
            }()
            if !success {
                let rect = NSRect(origin: .zero, size: window.frame.size)
                if let bitmap = window.contentView?.bitmapImageRepForCachingDisplay(in: rect) {
                    window.contentView?.cacheDisplay(in: rect, to: bitmap)
                    let image = NSImage(size: rect.size)
                    image.addRepresentation(bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            print("已渲染原生窗口：\(path)")
        }

        try await capture("pr-list-polish-light")
        window.appearance = NSAppearance(named: .darkAqua)
        controller.rootView = listView.environment(\.colorScheme, .dark)
            .environment(\.controlActiveState, .key)
            .frame(minWidth: 980, minHeight: 620)
        try await capture("pr-list-polish-dark")
    }
}
