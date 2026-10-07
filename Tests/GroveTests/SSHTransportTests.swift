import XCTest
@testable import Grove

/// SSH 通道的命令拼装。这些测试只断言 argv 形状，不真的连服务器 ——
/// 转义错了就是「在别人服务器上执行了预料之外的命令」，必须钉死。
final class SSHTransportTests: XCTestCase {
    private let ssh = URL(fileURLWithPath: "/usr/bin/ssh")

    private func makeServer(
        alias: String = "开发机",
        host: String = "dev.example.com",
        user: String? = "jamie",
        port: Int? = nil
    ) -> RemoteServer {
        var server = RemoteServer()
        server.alias = alias
        server.host = host
        server.user = user
        server.port = port
        return server
    }

    // MARK: - shell 转义

    func testShellQuotedWrapsInSingleQuotes() {
        XCTAssertEqual(SSHTransport.shellQuoted("/home/jamie/code"), "'/home/jamie/code'")
    }

    func testShellQuotedEscapesEmbeddedSingleQuote() {
        // 单引号里的单引号只能拼成 '\''，这是唯一稳定的写法。
        XCTAssertEqual(SSHTransport.shellQuoted("it's"), "'it'\\''s'")
    }

    func testShellQuotedKeepsUnicode() {
        XCTAssertEqual(SSHTransport.shellQuoted("/home/jamie/中文 目录"), "'/home/jamie/中文 目录'")
    }

    // MARK: - git 脚本拼装

    func testGitScriptCdIntoWorktreeThenExecGit() {
        let transport = SSHTransport(sshExecutable: ssh, server: makeServer())
        let script = transport.gitScript(["status", "--porcelain=v2"], worktreePath: "/srv/app")
        XCTAssertTrue(script.hasPrefix("cd -- '/srv/app' && exec git "))
        XCTAssertTrue(script.contains("'status'"))
        XCTAssertTrue(script.contains("'--porcelain=v2'"))
    }

    func testGitScriptQuotesPathWithSpacesAndQuotes() {
        let transport = SSHTransport(sshExecutable: ssh, server: makeServer())
        let script = transport.gitScript(["commit", "--message", "fix: it's broken"],
                                         worktreePath: "/opt/my app")
        XCTAssertTrue(script.contains("cd -- '/opt/my app'"))
        XCTAssertTrue(script.contains("'--message' 'fix: it'\\''s broken'"))
    }

    func testGitScriptExpandsOnlyRemoteHomeAndQuotesSuffix() {
        // 家目录由远端展开，路径后缀的空格和元字符必须保留字面语义。
        let transport = SSHTransport(sshExecutable: ssh, server: makeServer())
        let script = transport.gitScript(["status"], worktreePath: "~/code/my $(project)")
        XCTAssertTrue(script.contains("cd -- \"$HOME\"'/code/my $(project)' && exec git"))
    }

    // MARK: - ssh argv

    func testSSHArgumentsIncludeConnectionOptions() {
        let transport = SSHTransport(sshExecutable: ssh, server: makeServer(port: 2222))
        let arguments = transport.sshArguments(script: "true")

        // 密钥专用：绝不弹密码提示（GUI 里没人能回答）。
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
        // 连接复用 + 首次连接不卡交互确认。
        XCTAssertTrue(arguments.contains("ControlMaster=auto"))
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=accept-new"))
        // 自定义端口生效。
        if let portIndex = arguments.firstIndex(of: "-p") {
            XCTAssertEqual(arguments[portIndex + 1], "2222")
        } else {
            XCTFail("缺少 -p 端口参数")
        }
        // 目标是倒数第二个参数，远端脚本是最后一个。
        XCTAssertEqual(arguments[arguments.count - 2], "jamie@dev.example.com")
        XCTAssertEqual(arguments.last, "export LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true; export PATH=\"/usr/local/bin:/usr/bin:/bin:$PATH\"; true")
    }

    func testSSHArgumentsOmitPortWhenDefault() {
        let transport = SSHTransport(sshExecutable: ssh, server: makeServer(port: nil))
        let arguments = transport.sshArguments(script: "true")
        XCTAssertFalse(arguments.contains("-p"))
    }

    func testRunGitScriptCarriesEnvironmentGuarantees() {
        let transport = SSHTransport(sshExecutable: ssh, server: makeServer())
        let script = transport.sshArguments(script: transport.gitScript(["log"], worktreePath: "/srv/app")).last!
        // 输出稳定、无分页、无凭据交互、无编辑器 —— 跟本地子进程同一套约束。
        XCTAssertTrue(script.contains("GIT_TERMINAL_PROMPT=0"))
        XCTAssertTrue(script.contains("GIT_PAGER=cat"))
        XCTAssertTrue(script.contains("GIT_EDITOR=true"))
        XCTAssertTrue(script.contains("LC_ALL=C"))
    }

    // MARK: - 端到端冒烟

    /// 把 SSHTransport 拼出来的远端脚本交给本机 sh 执行（跳过 ssh 本身 ——
    /// 那是 OpenSSH 的事）。环境前缀、cd、参数转义任何一环拼错了，
    /// 这条测试都会直接失败。
    func testGeneratedScriptRunsUnderLocalShell() async throws {
        let repository = try await makeTemporaryRepository()
        defer { try? FileManager.default.removeItem(at: repository) }

        let transport = SSHTransport(sshExecutable: ssh, server: makeServer())
        let script = transport.sshArguments(script: transport.gitScript(
            ["status", "--porcelain=v2", "--branch"],
            worktreePath: repository.path
        )).last!

        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        XCTAssertTrue(result.isSuccess, "脚本执行失败：\(result.stderr)")
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        XCTAssertTrue(output.contains("# branch.oid"), "应该输出 porcelain v2 的分支头，实际：\(output)")
    }

    /// 路径带空格和单引号时，脚本依然要原样工作 —— 这是最容易拼错的形态。
    func testGeneratedScriptHandlesPathWithSpacesAndQuotes() async throws {
        let uuidSegment = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove ssh 'test'-\(uuidSegment)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["init", "-q"],
            workingDirectory: root
        )

        let transport = SSHTransport(sshExecutable: ssh, server: makeServer())
        let script = transport.sshArguments(script: transport.gitScript(
            ["rev-parse", "--show-toplevel"],
            worktreePath: root.path
        )).last!

        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
        XCTAssertTrue(result.isSuccess, "路径含空格/单引号时脚本失败：\(result.stderr)")
        // 比较带空格和单引号的路径段而不是整条路径：macOS 对 /var 与
        // /private/var 的解析在不同入口形态不一（temporaryDirectory 给
        // /var/…，rev-parse 给 /private/var/…），那不是这里要验证的东西。
        // 要验证的是：棘手路径段经转义后原样到达了远端命令。
        XCTAssertTrue(
            result.trimmedStdout.hasSuffix("grove ssh 'test'-\(uuidSegment)"),
            "路径段应原样保留，实际：\(result.trimmedStdout)"
        )
    }

    private func makeTemporaryRepository() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["init", "-q"],
            workingDirectory: url
        )
        XCTAssertTrue(result.isSuccess, "git init 失败：\(result.stderr)")
        return url
    }

    /// 用本地 shell 代替 ssh，只执行最后一个脚本参数，不连接真实服务器。
    private func localShellTransport(in directory: URL) throws -> SSHTransport {
        let executable = directory.appendingPathComponent("fake-ssh")
        try Data("""
        #!/bin/sh
        for argument in "$@"; do script=$argument; done
        exec /bin/sh -c "$script"
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return SSHTransport(sshExecutable: executable, server: makeServer())
    }

    func testAtomicWritePreservesPermissionsAndRejectsSymbolicLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grove-atomic-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = try localShellTransport(in: directory)
        for mode in [0o755, 0o600] {
            let file = directory.appendingPathComponent("权限 '\(mode).txt")
            try Data("旧内容".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
            try await transport.writeData(Data("新内容".utf8), toPath: file.path, atomic: true)
            XCTAssertEqual(try Data(contentsOf: file), Data("新内容".utf8))
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, mode)
        }
        let target = directory.appendingPathComponent("链接目标")
        try Data("保留内容".utf8).write(to: target)
        let link = directory.appendingPathComponent("链接")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            try await transport.writeData(Data("不得写入".utf8), toPath: link.path, atomic: true)
            XCTFail("原子写符号链接应明确拒绝")
        } catch let failure as CommandFailure {
            XCTAssertTrue(failure.output.contains("符号链接"))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), Data("保留内容".utf8))
        let folder = directory.appendingPathComponent("不是文件")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try await transport.writeData(Data("不得写入".utf8), toPath: folder.path, atomic: true)
            XCTFail("失败的保存应清理临时文件")
        } catch is CommandFailure {
            // 目录不能当作普通文件替换，失败后仍应保留目录。
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains(".grove-") })
    }

    func testRemoteRepositoryRootHandlesRawTildeAndShellCharacters() async throws {
        let directory = try await makeTemporaryRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = try localShellTransport(in: directory)
        let child = directory.appendingPathComponent("子目录 ' $(touch 被执行)")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        // 从真实家目录返回根目录再到临时仓库，避免写入用户家目录。
        let parents = String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1)
        let rawPath = "~/" + parents + child.path.dropFirst()
        let root = await transport.repositoryRoot(forPath: rawPath)
        XCTAssertEqual(root?.path, directory.resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("被执行").path))
    }
    // MARK: - 标识

    func testRepoIDDistinguishesServersWithSamePath() {
        let oneServer = makeServer(alias: "a", host: "a.example.com")
        let one = RepoID(location: .remote(oneServer),
                         root: URL(fileURLWithPath: "/srv/app"))
        let two = RepoID(location: .remote(makeServer(alias: "b", host: "b.example.com")),
                         root: URL(fileURLWithPath: "/srv/app"))
        let local = RepoID(location: .local, root: URL(fileURLWithPath: "/srv/app"))

        XCTAssertNotEqual(one, two)
        XCTAssertNotEqual(one, local)
        XCTAssertEqual(one.identityKey, "\(oneServer.id.uuidString):/srv/app")
        XCTAssertEqual(local.identityKey, "local:/srv/app")
    }

    func testServerDestination() {
        XCTAssertEqual(makeServer().destination, "jamie@dev.example.com")
        XCTAssertEqual(makeServer(user: nil).destination, "dev.example.com")
        XCTAssertEqual(makeServer(alias: "  ").displayName, "jamie@dev.example.com")
        XCTAssertEqual(makeServer().displayName, "开发机")
    }
}

/// 服务器与项目配置的持久化。
final class RemoteServerStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RemoteServerStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testServerRoundtrip() {
        let store = RemoteServerStore(defaults: defaults)
        var server = RemoteServer()
        server.alias = "构建机"
        server.host = "10.0.0.8"
        server.user = "ci"
        server.port = 2222
        store.save([server])

        let loaded = RemoteServerStore(defaults: defaults).load()
        XCTAssertEqual(loaded, [server])
    }

    func testMissingDataLoadsEmpty() {
        XCTAssertTrue(RemoteServerStore(defaults: defaults).load().isEmpty)
    }

    func testProjectRoundtrip() {
        let store = RemoteProjectStore(defaults: defaults)
        let id = UUID().uuidString
        store.save([id: ["/srv/app", "/home/ci/tool"]])

        let loaded = RemoteProjectStore(defaults: defaults).load()
        XCTAssertEqual(loaded[id], ["/srv/app", "/home/ci/tool"])
    }
}
