import AppKit
import Foundation

/// 跟系统其他 app 打交道：在 Finder 显示、在终端打开、用编辑器打开、开网页。
enum SystemActions {
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openInBrowser(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 在终端里打开这个目录。
    ///
    /// 用 `NSWorkspace.open(_:withApplicationAt:)` 而不是 AppleScript：走 AppleScript
    /// 要申请 Automation 权限，会弹一个吓人的系统授权框，而我们只是想开个终端。
    /// 把目录「用终端应用打开」不需要任何权限。
    static func openInTerminal(_ url: URL) {
        let candidates = [
            "/Applications/iTerm.app",
            "/Applications/Ghostty.app",
            "/Applications/Warp.app",
            "/Applications/WezTerm.app",
            "/System/Applications/Utilities/Terminal.app"
        ]
        let terminal = candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/System/Applications/Utilities/Terminal.app"

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: URL(fileURLWithPath: terminal),
            configuration: configuration
        )
    }

    /// 用用户偏好的编辑器打开目录。找不到就退回系统默认（一般是 Finder）。
    static func openInEditor(_ url: URL) {
        let candidates = [
            "/Applications/Cursor.app",
            "/Applications/Visual Studio Code.app",
            "/Applications/Zed.app",
            "/Applications/Sublime Text.app",
            "/Applications/Xcode.app"
        ]
        guard let editor = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: URL(fileURLWithPath: editor),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// 打开工作树里的某个具体文件。
    static func openFile(in worktree: URL, path: String) {
        let fileURL = worktree.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        NSWorkspace.shared.open(fileURL)
    }

    static func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
