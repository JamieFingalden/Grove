import AppKit

enum AIEnableConfirmation {
    @MainActor
    static func confirm() -> Bool {
        let alert = NSAlert()
        alert.messageText = "为 Grove 开启 AI 生成功能？"
        alert.informativeText = """
        生成提交信息时，会把已暂存的 diff 和最近 20 条提交标题发送给 Codex；生成 PR 描述时，会把目标分支到当前 HEAD 的已提交 diff 和提交标题发送给 Codex。

        不会发送未暂存改动、未跟踪文件、仓库地址或分支名。此设置对 Grove 中打开的所有仓库生效，可随时在设置中关闭。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "开启")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
