import AppKit
import SwiftUI

@MainActor
struct GroveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

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
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
            .disabled(model.selectedRepository == nil)
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
