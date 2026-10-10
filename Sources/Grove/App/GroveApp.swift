import AppKit
import SwiftUI
import UserNotifications

@MainActor
struct GroveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    /// 通知点击路由：挂住 delegate 的长命对象。
    /// 点击「CI 失败」通知 → 打开对应仓库的项目主页。
    private let notificationRouter: PipelineNotificationRouter

    init() {
        let model = AppModel()
        _model = State(initialValue: model)

        let router = PipelineNotificationRouter()
        router.openRepository = { root in
            // 主页的分栏自己带加载；这里只负责把仓库送到眼前。
            // 只有本机仓库会有流水线通知，所以按本机位置构造 RepoID。
            if model.repository(matching: RepoID(location: .local, root: root)) != nil {
                model.selection = .repositoryHome(repository: RepoID(location: .local, root: root))
            }
        }
        router.reviewPullRequest = { root, number in
            model.startRequestedAIReview(for: root, pullRequestNumber: number)
        }
        UNUserNotificationCenter.current().delegate = router
        notificationRouter = router
        Task { await AIReviewNotifier.registerActions() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { GroveCommands(model: model) }

        Settings {
            PreferencesView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !flag, let window = sender.windows.first(where: { $0.canBecomeKey }) else {
            return true
        }
        window.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

/// 菜单栏命令。做成独立类型是因为 `@State` 的模型没法直接在 `.commands` 闭包里捕获。
struct GroveCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开仓库…") {
                Task { await FolderPicker.openRepository(into: model) }
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button("刷新") {
                Task {
                    await model.selectedRepository?.refresh()
                    await model.selectedWorktreeModel?.refresh()
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.selectedRepository == nil)

            Button("抓取远端") {
                Task { await model.selectedRepository?.fetch() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.selectedRepository?.hasRemote != true)
        }
    }
}

enum FolderPicker {
    /// 选一个目录并作为仓库打开。
    @MainActor
    static func openRepository(into model: AppModel) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择一个 git 仓库目录"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        await model.openRepository(at: url)
    }

    /// 选一个目录作为新工作树的位置。允许选不存在的路径（用 `nameFieldStringValue`）。
    @MainActor
    static func chooseWorktreeLocation(suggesting url: URL) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择新工作树的位置"
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = url.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
