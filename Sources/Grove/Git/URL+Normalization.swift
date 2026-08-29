import Foundation

extension URL {
    /// 归一化文件路径，用于比较两个 URL 是不是指向同一个位置。
    ///
    /// 必须解符号链接，因为 git 的不同子命令返回的形式不一样：
    /// `rev-parse --git-common-dir` 原样回显你传进去的路径，而 `worktree list`
    /// 返回的是内核解析过的真实路径。macOS 上 `/tmp` 就是 `/private/tmp` 的符号链接，
    /// 于是同一个工作树会以两种写法出现，字符串比较必然失配 ——
    /// 表现是「新建工作树成功了，但界面没跳过去」。
    ///
    /// `standardizedFileURL` 只处理 `..` 和 `.`，解不了符号链接，单用它不够。
    var groveResolved: URL {
        standardizedFileURL.resolvingSymlinksInPath()
    }

    /// 两个路径是否指向同一位置。
    func isSameLocation(as other: URL) -> Bool {
        groveResolved.path == other.groveResolved.path
    }
}
