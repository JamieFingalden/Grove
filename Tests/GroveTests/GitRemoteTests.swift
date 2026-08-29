import XCTest
@testable import Grove

/// 远端地址解析。判断「仓库托管在哪」全靠它，认错了会导致界面显示
/// 另一个仓库的 PR —— 比什么都不显示更糟。
final class GitRemoteTests: XCTestCase {
    func testParsesHTTPSGitHub() {
        let remote = GitRemote.parse("https://github.com/example-owner/backup-mirror.git")
        XCTAssertEqual(remote?.host, "github.com")
        XCTAssertEqual(remote?.path, "example-owner/backup-mirror")
        XCTAssertEqual(remote?.slug, "example-owner/backup-mirror")
        XCTAssertEqual(remote?.name, "backup-mirror")
    }

    func testParsesSCPStyleSSH() {
        // `git@github.com:owner/repo.git` 没有 `//`，冒号后面直接跟路径。
        // 交给 URLComponents 会把 `owner/repo.git` 当端口解析失败。
        let remote = GitRemote.parse("git@github.com:owner/repo.git")
        XCTAssertEqual(remote?.host, "github.com")
        XCTAssertEqual(remote?.slug, "owner/repo")
    }

    func testParsesSSHURLForm() {
        let remote = GitRemote.parse("ssh://git@github.com/owner/repo.git")
        XCTAssertEqual(remote?.host, "github.com")
        XCTAssertEqual(remote?.slug, "owner/repo")
    }

    func testParsesSelfHostedGitLabWithPort() {
        // 内网 GitLab 的典型形态：IP + 非标准端口。
        let remote = GitRemote.parse("http://10.0.0.1:8929/internal-group/internal-repo.git")
        XCTAssertEqual(remote?.host, "10.0.0.1")
        XCTAssertEqual(remote?.path, "internal-group/internal-repo")
        // 端口不能混进主机名，否则跟 gh 的已登录主机列表永远对不上。
        XCTAssertFalse(remote?.host.contains(":") ?? true)
    }

    func testGitLabNestedGroupsKeepFullPathButSlugTakesLastTwo() {
        // GitLab 允许多层子群组，路径可以有三段以上；
        // 而 gh / GitHub API 只认 owner/repo 两段。
        let remote = GitRemote.parse("https://gitlab.corp.example/团队/子组/项目.git")
        XCTAssertEqual(remote?.path, "团队/子组/项目")
        XCTAssertEqual(remote?.slug, "子组/项目")
    }

    func testTrailingSlashAndMissingGitSuffix() {
        XCTAssertEqual(GitRemote.parse("https://github.com/owner/repo")?.slug, "owner/repo")
        XCTAssertEqual(GitRemote.parse("https://github.com/owner/repo/")?.slug, "owner/repo")
    }

    func testRejectsNonHostedRemotes() {
        // 本地路径远端没有托管商可言，不能被当成某个主机。
        XCTAssertNil(GitRemote.parse("/Users/me/mirrors/repo.git"))
        XCTAssertNil(GitRemote.parse("file:///Users/me/mirrors/repo.git"))
        XCTAssertNil(GitRemote.parse(""))
        XCTAssertNil(GitRemote.parse("   "))
    }

    func testSchemeIsKeptForSetupHints() {
        // 内网实例大量是明文 http。生成 `glab auth login` 时不带
        // `--api-protocol http` 的话，glab 会默认 https，登录会以一个
        // 跟协议毫无关系的报错失败 —— 用户几乎不可能自己想到那一步。
        let insecure = GitRemote.parse("http://10.0.0.1:8929/团队/项目.git")
        XCTAssertEqual(insecure?.scheme, "http")
        XCTAssertTrue(insecure?.isInsecureHTTP ?? false)

        let secure = GitRemote.parse("https://gitlab.corp.example/团队/项目.git")
        XCTAssertFalse(secure?.isInsecureHTTP ?? true)

        // scp 写法走 ssh，API 协议无从得知，不该瞎猜成 http。
        let ssh = GitRemote.parse("git@gitlab.corp.example:团队/项目.git")
        XCTAssertNil(ssh?.scheme)
        XCTAssertFalse(ssh?.isInsecureHTTP ?? true)
    }

    func testGitProtocol() {
        let remote = GitRemote.parse("git://github.com/owner/repo.git")
        XCTAssertEqual(remote?.host, "github.com")
        XCTAssertEqual(remote?.slug, "owner/repo")
    }
}
