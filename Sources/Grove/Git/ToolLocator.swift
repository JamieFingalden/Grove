import Foundation

/// 定位 `git` / `gh` 可执行文件，并给子进程准备一份 PATH 够用的环境变量。
///
/// 这个类型存在的唯一原因是 macOS 的启动方式差异：从 Finder / Dock 启动的 app
/// 继承的是 launchd 的环境，PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin` ——
/// Homebrew 装的 `gh`（`/opt/homebrew/bin/gh`）完全不在里面。
/// 只在终端里 `swift run` 测试的话永远碰不到这个问题，装成 .app 就全线失效。
///
/// 所以这里不依赖 PATH 查找，而是：先扫一遍已知目录（无子进程开销），
/// 找不到再去问用户的登录 shell 要真实 PATH。结果缓存，避免每次 git 调用都重新找。
actor ToolLocator {
    static let shared = ToolLocator()

    /// 常见安装位置，按优先级排序。用户自己装的新版本应该盖过系统自带的旧版本，
    /// 所以 Homebrew 在 `/usr/bin` 前面。
    private static let candidateDirectories = [
        "/opt/homebrew/bin",        // Apple Silicon Homebrew
        "/usr/local/bin",           // Intel Homebrew、手工安装
        "/opt/local/bin",           // MacPorts
        "/run/current-system/sw/bin", // nix-darwin
        "/usr/bin",                 // 系统自带（git 一定在这儿）
        "/bin"
    ]

    private var resolved: [String: URL] = [:]
    private var notFound: Set<String> = []
    private var loginPath: String?

    private init() {}

    /// 找到某个命令行工具。找不到返回 nil —— 这是预期情况（比如用户没装 `gh`），
    /// 由调用点决定是降级还是提示安装。
    func locate(_ name: String) async -> URL? {
        if let cached = resolved[name] { return cached }
        if notFound.contains(name) { return nil }

        for directory in Self.candidateDirectories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if isExecutable(url) {
                resolved[name] = url
                return url
            }
        }

        // 已知目录里没有，说明装在了非常规位置（asdf / mise / volta / 自建前缀）。
        // 这时候只有用户的 shell 配置知道答案。
        if let url = await locateViaLoginShell(name) {
            resolved[name] = url
            return url
        }

        notFound.insert(name)
        return nil
    }

    /// 给子进程用的环境变量：在继承环境的基础上把已知目录并进 PATH。
    ///
    /// 光有 git 的绝对路径不够 —— git 自己还要 fork 出别的东西：
    /// credential helper、`ssh`、`diff` 驱动、以及 `credential.helper = !gh auth git-credential`
    /// 这种把 `gh` 当凭据源的配置。它们全都靠 PATH 找。
    func childEnvironment() async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var components = Self.candidateDirectories

        if let shellPath = await loginShellPath() {
            components.append(contentsOf: shellPath.split(separator: ":").map(String.init))
        }
        if let inherited = environment["PATH"] {
            components.append(contentsOf: inherited.split(separator: ":").map(String.init))
        }

        var seen = Set<String>()
        let merged = components.filter { seen.insert($0).inserted && !$0.isEmpty }
        environment["PATH"] = merged.joined(separator: ":")

        // git 默认会给分页器（less）套一层，在没有 tty 的子进程里会挂住或者塞进 ANSI 控制码。
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        // 绝不弹终端里的凭据提示：GUI 里没人能回答，只会让进程卡死。
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // git 的输出必须是稳定的机器格式，跟着系统语言变会把解析器打乱。
        environment["LC_ALL"] = "C"
        // 绝不让 git 打开编辑器。`rebase --continue`、`merge`、`commit --amend`
        // 在需要写提交信息时会去起 $EDITOR —— GUI 里那个编辑器要么起不来、
        // 要么起在别的地方，git 就永远等在那儿。`true` 是个立刻成功返回的空编辑器，
        // 效果是「接受默认信息」，正是这些场景该有的行为。
        environment["GIT_EDITOR"] = "true"
        // 交互式 rebase 的 todo 列表编辑器。Grove 不做交互式变基，
        // 但万一哪条命令走到那条路上，也不能挂死。
        environment["GIT_SEQUENCE_EDITOR"] = "true"
        return environment
    }

    private func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    private func locateViaLoginShell(_ name: String) async -> URL? {
        guard let path = await loginShellPath() else { return nil }
        for directory in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if isExecutable(url) { return url }
        }
        return nil
    }

    /// 问登录 shell 要它的 PATH。只跑一次，结果缓存。
    private func loginShellPath() async -> String? {
        if let loginPath { return loginPath }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // `-l` 走登录配置（.zprofile，Homebrew 的 shellenv 就装在这里），
        // `-i` 走交互配置（.zshrc，不少人把 PATH 写在这儿）。两个都要才覆盖得全。
        // 用 printf 而不是 echo：不带尾随换行，也不受 shell 差异影响。
        let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-ilc", "printf %s \"$PATH\""],
            environment: ProcessInfo.processInfo.environment,
            // 短超时：这一步挡在 app 启动路径上，用户的 .zshrc 里塞了什么无法预料
            // （版本管理器、补全框架、网络检查）。宁可退回内置的候选目录，
            // 也不能让 Grove 卡在启动画面上。
            timeout: 8
        )
        guard let output = result?.trimmedStdout, !output.isEmpty else {
            loginPath = ""
            return nil
        }
        loginPath = output
        return output
    }
}
