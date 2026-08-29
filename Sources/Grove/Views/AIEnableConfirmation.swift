import AppKit

enum AIEnableConfirmation {
    @MainActor
    static func confirm(repository: RepositoryModel, byteCount: Int) -> Bool {
        let formattedBytes = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "为“\(repository.name)”开启 AI 生成功能？"
        alert.informativeText = """
        生成提交信息时，会把已暂存的 diff 和最近 20 条提交标题发送给 codex；生成 PR 描述时，会把目标分支到当前 HEAD 的已提交 diff 和提交标题发送给 codex。本次大约会发送 \(formattedBytes)（\(byteCount) 字节）。

        不会发送未暂存改动、未跟踪文件、仓库地址或分支名。此开关只对这个仓库生效。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "开启")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
