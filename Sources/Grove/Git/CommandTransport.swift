import Foundation

/// git 命令与文件操作的执行通道：本机子进程，或经 SSH 在远程服务器上执行。
///
/// 所有 git 交互都汇到这一个抽象上，`GitClient` 的高层方法（状态、diff、提交、
/// 工作树……）因此不知道自己跑在哪 —— 远程服务器上的 git 输出格式与本地完全
/// 一致，解析层一行都不用改。文件原语（存在性、读写、mtime）是给 diff 面板
/// 编辑、冲突重写这类「git 之外」的文件操作用的：本地走 FileManager，
/// 远程走同一条 ssh 连接。
protocol CommandTransport: Sendable {
    /// 错误信息里展示的执行者：本地是 git 路径，远程是 `ssh user@host`。
    var label: String { get }

    /// 在某个仓库路径下执行 git 子命令（`arguments` 不含 `git` 本身）。
    func runGit(
        _ arguments: [String],
        worktreePath: String,
        timeout: Double,
        standardInput: Data?
    ) async throws -> CommandResult

    // MARK: - 文件原语

    func fileExists(atPath path: String) async -> Bool
    func directoryExists(atPath path: String) async -> Bool
    /// 文件读不出来（不存在、无权限）返回 nil。
    func readData(atPath path: String) async -> Data?
    /// `atomic` 为 true 时先写临时文件再改名（编辑器保存）；
    /// false 原地写 —— 冲突重写要保住文件的权限位和 inode。
    func writeData(_ data: Data, toPath path: String, atomic: Bool) async throws
    func modificationDate(atPath path: String) async -> Date?
    func createDirectory(atPath path: String) async throws
}

// MARK: - 本机

/// 现状的原样搬运：`ProcessRunner` + `workingDirectory`。语义（符号链接、
/// 原子写、mtime 来源）保持与重构前一致，本地路径不应该感知到这次改动。
struct LocalTransport: CommandTransport {
    let executable: URL
    let environment: [String: String]

    var label: String { executable.path }

    func runGit(
        _ arguments: [String],
        worktreePath: String,
        timeout: Double,
        standardInput: Data?
    ) async throws -> CommandResult {
        try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: URL(fileURLWithPath: worktreePath),
            environment: environment,
            timeout: timeout,
            standardInput: standardInput
        )
    }

    func fileExists(atPath path: String) async -> Bool {
        // 沿用 attributesOfItem 而不是 fileExists：后者会顺着符号链接走，
        // 一个指向已删目标的链接会被误判成「文件没了」（markConflictResolved
        // 依赖这个区别决定 add 还是 rm）。
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    func directoryExists(atPath path: String) async -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func readData(atPath path: String) async -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    func writeData(_ data: Data, toPath path: String, atomic: Bool) async throws {
        try data.write(
            to: URL(fileURLWithPath: path),
            options: atomic ? .atomic : []
        )
    }

    func modificationDate(atPath path: String) async -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }

    func createDirectory(atPath path: String) async throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path),
            withIntermediateDirectories: true
        )
    }
}

// MARK: - SSH 远程

/// 在远程服务器上执行命令。走系统 `ssh` 二进制而不是 SSH 库：
/// 密钥、agent、known_hosts、跳板配置全部继承用户的 `~/.ssh`，
/// 用户在终端里能连上，这里就能连上。
///
/// 连接复用靠 ControlMaster：首次握手约一秒，之后同一台服务器的所有
/// 命令共用一条长连接，开销毫秒级 —— 侧边栏批量刷新工作树状态才扛得住。
struct SSHTransport: CommandTransport {
    let sshExecutable: URL
    let server: RemoteServer

    var label: String { "ssh \(server.destination)" }

    /// ControlMaster 的 socket 目录。`%C` 是 OpenSSH 对
    /// `%l%h%p%r` 的哈希，避免长路径超出 socket 名字长度限制。
    private static let controlDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grove/ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// 远端脚本的头一段。跟 `ToolLocator.childEnvironment` 给本地进程的
    /// 约束一致：输出必须是稳定的机器格式、绝不弹凭据提示和编辑器。
    /// 非交互 ssh 不加载完整登录配置，git 可能不在默认 PATH 里，兜一份。
    private static let remoteScriptPrefix =
        "export LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true; "
        + "export PATH=\"/usr/local/bin:/usr/bin:/bin:$PATH\"; "

    private var baseArguments: [String] {
        [
            // 只走密钥认证。密码提示在 GUI 里没人能回答，必须立刻失败。
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(Self.controlDirectory.path)/cm-%C",
            "-o", "ControlPersist=10m",
            // 首次连接自动记录主机指纹，不卡在交互确认（GUI 里同样没人回答）。
            "-o", "StrictHostKeyChecking=accept-new",
        ] + (server.port.map { ["-p", String($0)] } ?? [])
            + [server.destination]
    }

    // MARK: - 命令拼装（拆出来是为了可测试）

    /// 单引号包裹一段文本，内嵌单引号换成 `'\''` —— shell 里最稳的转义方式。
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 远端脚本：进到工作树目录后把 git 参数原样交给远端 shell。
    func gitScript(_ arguments: [String], worktreePath: String) -> String {
        let gitArguments = arguments.map(Self.shellQuoted).joined(separator: " ")
        // `~` 开头的路径不加引号：引号会挡住远端 shell 的波浪号展开，
        // 用户手敲的 ~/code/… 就到不了家目录。校验通过后存下来的
        // 都是 rev-parse 给的绝对路径，不受这条影响。
        let cdTarget = worktreePath == "~" || worktreePath.hasPrefix("~/")
            ? worktreePath
            : Self.shellQuoted(worktreePath)
        return "cd \(cdTarget) && exec git \(gitArguments)"
    }

    private func fullScript(_ command: String) -> String {
        Self.remoteScriptPrefix + command
    }

    /// 完整的本地 argv（测试里断言它的形状，不真的连服务器）。
    func sshArguments(script: String) -> [String] {
        baseArguments + [fullScript(script)]
    }

    // MARK: - 执行

    private func run(
        script: String,
        timeout: Double,
        standardInput: Data? = nil
    ) async throws -> CommandResult {
        try await ProcessRunner.run(
            executable: sshExecutable,
            arguments: sshArguments(script: script),
            environment: ProcessInfo.processInfo.environment,
            timeout: timeout,
            standardInput: standardInput
        )
    }

    /// 非零退出转成 `CommandFailure`，报错优先 stderr（跟 ProcessRunner.runChecked
    /// 同一套规则；ssh 的连接错误都写在 stderr）。
    @discardableResult
    private func checked(_ result: CommandResult, script: String) throws -> CommandResult {
        guard !result.isSuccess else { return result }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = result.trimmedStdout
        throw CommandFailure(
            executable: label,
            arguments: [fullScript(script)],
            exitCode: result.exitCode,
            output: message.isEmpty ? fallback : message
        )
    }

    func runGit(
        _ arguments: [String],
        worktreePath: String,
        timeout: Double,
        standardInput: Data?
    ) async throws -> CommandResult {
        let script = gitScript(arguments, worktreePath: worktreePath)
        return try await run(script: script, timeout: timeout, standardInput: standardInput)
    }

    // MARK: - 文件原语

    func fileExists(atPath path: String) async -> Bool {
        let script = "test -e \(Self.shellQuoted(path))"
        let result = try? await run(script: script, timeout: 15)
        return result?.isSuccess ?? false
    }

    func directoryExists(atPath path: String) async -> Bool {
        let script = "test -d \(Self.shellQuoted(path))"
        let result = try? await run(script: script, timeout: 15)
        return result?.isSuccess ?? false
    }

    func readData(atPath path: String) async -> Data? {
        let script = "cat \(Self.shellQuoted(path))"
        guard let result = try? await run(script: script, timeout: 60),
              result.isSuccess else { return nil }
        return result.standardOutput
    }

    func writeData(_ data: Data, toPath path: String, atomic: Bool) async throws {
        let quoted = Self.shellQuoted(path)
        let script: String
        if atomic {
            // 先写临时文件再改名：远端读者要么看到旧内容、要么看到新内容，
            // 不会读到半个文件。改名发生在同一目录里，跨文件系统也不会失败。
            let temporary = path + ".grove-\(UUID().uuidString).tmp"
            script = "cat > \(Self.shellQuoted(temporary)) && mv \(Self.shellQuoted(temporary)) \(quoted)"
        } else {
            script = "cat > \(quoted)"
        }
        let result = try await run(script: script, timeout: 60, standardInput: data)
        try checked(result, script: script)
    }

    func modificationDate(atPath path: String) async -> Date? {
        // GNU coreutils（Linux）写 `-c %Y`，BSD（macOS 服务器）写 `-f %m`。
        // 两种都试，谁成出谁。
        let quoted = Self.shellQuoted(path)
        let script = "stat -c %Y \(quoted) 2>/dev/null || stat -f %m \(quoted)"
        guard let result = try? await run(script: script, timeout: 15),
              result.isSuccess,
              let seconds = Double(result.trimmedStdout) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func createDirectory(atPath path: String) async throws {
        let script = "mkdir -p \(Self.shellQuoted(path))"
        let result = try await run(script: script, timeout: 30)
        try checked(result, script: script)
    }

    // MARK: - 连接检测

    /// 连接与远端 git 可用性检测。成功返回 `git version …` 描述。
    /// 添加/编辑服务器的表单和侧边栏的状态点都用它。
    func probe() async throws -> String {
        let script = "command -v git >/dev/null && git --version"
        let result = try await run(script: script, timeout: 20)
        let success = try checked(result, script: script)
        let version = success.trimmedStdout
        return version.isEmpty ? "git 可用" : version
    }
}
