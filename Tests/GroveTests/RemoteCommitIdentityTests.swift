import XCTest
@testable import Grove

/// 远程服务器常常没配 user.name/user.email，在那上面提交会报
/// "Committer identity unknown"。客户端构造时应该把缺口用本机身份补上：
/// 缺哪个补哪个、不覆盖远端已配的、只进命令行参数不落远端配置文件。
@MainActor
final class RemoteCommitIdentityTests: XCTestCase {
    private var root: URL!
    private var scratch: URL!
    private let executable = URL(fileURLWithPath: "/usr/bin/git")

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-remote-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-remote-identity-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try await remote().run(["init", "-q", "-b", "main"], in: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// 模拟那台没配身份的服务器：全局/系统配置全部指到空处，家目录换成
    /// 临时目录，环境里的身份变量也清掉 —— 这个客户端眼里没有任何身份。
    private func remote() -> GitClient {
        GitClient(executable: executable, environment: isolatedEnvironment(globalConfig: nil))
    }

    /// 「本机」客户端：全局配置指向受控的 fixture。名字带空格，顺带压住
    /// 「只在第一个空格处切」的解析。
    private func local(
        name: String = "Jamie Yang",
        email: String = "jamie@example.com"
    ) throws -> GitClient {
        let fixture = scratch.appendingPathComponent("gitconfig")
        try "[user]\n\tname = \(name)\n\temail = \(email)\n"
            .write(to: fixture, atomically: true, encoding: .utf8)
        return GitClient(executable: executable, environment: isolatedEnvironment(globalConfig: fixture.path))
    }

    private func isolatedEnvironment(globalConfig: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = scratch.path
        environment["XDG_CONFIG_HOME"] = scratch.appendingPathComponent(".config").path
        environment["GIT_CONFIG_GLOBAL"] = globalConfig ?? "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        // 身份也可能从环境变量来，全部摘掉，测试不依赖跑在哪台机器上。
        for key in ["EMAIL", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
                    "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"] {
            environment.removeValue(forKey: key)
        }
        // 有的 git 构建（比如 macOS 的 Apple git）会默默接受自动探测出来的
        // user@hostname 身份，让「没配身份就拒绝提交」在别的机器上不成立。
        // useConfigOnly 禁掉自动探测；注入的 -c 身份算显式配置，不受影响。
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "user.useConfigOnly"
        environment["GIT_CONFIG_VALUE_0"] = "true"
        return environment
    }

    @discardableResult
    private func commitSomething(_ git: GitClient) async throws -> String {
        try "内容\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git.stageAll(in: root)
        try await git.commit(message: "提交", in: root)
        return try await git.run(["log", "-1", "--format=%an|%ae|%cn|%ce"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 复现原始报错：身份一个都没有时，git 拒绝提交。
    func testCommitFailsWhenNoIdentityAnywhere() async throws {
        let git = remote()
        try "内容\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git.stageAll(in: root)
        do {
            try await git.commit(message: "提交", in: root)
            XCTFail("没有任何身份配置时提交应该失败")
        } catch {}
    }

    /// 缺的键用本机身份补上，作者和提交人都是本机身份。
    func testIdentityFallbackCommitsWithLocalIdentity() async throws {
        let git = await remote().withIdentityFallback(from: try local(), probingRepoAt: root)
        let summary = try await commitSomething(git)
        XCTAssertEqual(
            summary,
            "Jamie Yang|jamie@example.com|Jamie Yang|jamie@example.com"
        )
        // 身份只进命令行：远端配置文件里不该多出 user.name/user.email。
        // 得用没注入过的客户端查 —— 命令行 -c 的配置也会被 --list 列进去。
        let config = try await remote().run(["config", "--local", "--list"], in: root)
        XCTAssertFalse(config.contains("user.name"))
        XCTAssertFalse(config.contains("user.email"))
    }

    /// 远端自己配过身份的不覆盖 —— 那台机器可能有意用另一个身份。
    func testIdentityFallbackKeepsRemoteConfiguredIdentity() async throws {
        try await remote().run(["config", "user.name", "服务器身份"], in: root)
        try await remote().run(["config", "user.email", "server@grove.test"], in: root)
        let git = await remote().withIdentityFallback(from: try local(), probingRepoAt: root)
        let summary = try await commitSomething(git)
        XCTAssertEqual(summary, "服务器身份|server@grove.test|服务器身份|server@grove.test")
    }

    /// 只补缺的那一半：远端有名字没邮箱时，邮箱用本机的。
    func testIdentityFallbackFillsOnlyTheMissingHalf() async throws {
        try await remote().run(["config", "user.name", "服务器身份"], in: root)
        let git = await remote().withIdentityFallback(from: try local(), probingRepoAt: root)
        let summary = try await commitSomething(git)
        XCTAssertEqual(summary, "服务器身份|jamie@example.com|服务器身份|jamie@example.com")
    }

    /// 探查命令跑不起来时不能假设远端没配身份 —— 保持原样，不注入，
    /// 行为退回 git 自己的报错。
    func testIdentityFallbackDoesNothingWhenProbeCannotRun() async throws {
        let wrapper = scratch.appendingPathComponent("git-refuses-probe")
        try """
        #!/bin/sh
        case "$*" in *--get-regexp*) exit 255;; esac
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let stubborn = GitClient(executable: wrapper, environment: isolatedEnvironment(globalConfig: nil))
        let filled = await stubborn.withIdentityFallback(from: try local(), probingRepoAt: root)
        try "内容\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await filled.stageAll(in: root)
        do {
            try await filled.commit(message: "提交", in: root)
            XCTFail("探查失败时不该注入身份，提交应该维持失败")
        } catch {}
    }
}
