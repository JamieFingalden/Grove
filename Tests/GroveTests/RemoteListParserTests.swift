import XCTest
@testable import Grove

/// `git remote -v` 的解析，以及「上游属于哪个远端」的判断。
///
/// 这两件事错了的后果是推送推错地方 —— 比只是显示不对严重得多。
final class RemoteListParserTests: XCTestCase {
    /// 取自真实的多远端仓库：origin 是内网 GitLab，另挂了个 GitHub 备份。
    private let output = """
    github\thttps://github.com/example-owner/backup-mirror (fetch)
    github\thttps://github.com/example-owner/backup-mirror (push)
    origin\thttp://10.0.0.1:8929/internal-group/internal-repo.git (fetch)
    origin\thttp://10.0.0.1:8929/internal-group/internal-repo.git (push)
    """

    func testParsesMultipleRemotes() {
        let remotes = RemoteListParser.parse(output)

        XCTAssertEqual(remotes.count, 2)
        // 顺序按 git 的输出走，不重排 —— git 已经按字母序给了。
        XCTAssertEqual(remotes.map(\.name), ["github", "origin"])
        XCTAssertEqual(remotes[1].pushURL, "http://10.0.0.1:8929/internal-group/internal-repo.git")
    }

    func testFetchAndPushLinesCollapseIntoOneRemote() {
        // 每个远端占两行（fetch / push），不能变成两个条目 ——
        // 否则推送菜单里每个远端会出现两遍。
        let remotes = RemoteListParser.parse(output)
        XCTAssertEqual(Set(remotes.map(\.name)).count, remotes.count)
    }

    func testSeparatePushURLIsRespected() {
        // git 允许 fetch 和 push 用不同地址（`remote.<name>.pushurl`），
        // 比如读走只读镜像、写走可写地址。推送要用后者。
        let mixed = """
        origin\thttps://mirror.example/repo.git (fetch)
        origin\tgit@write.example:team/repo.git (push)
        """
        let remotes = RemoteListParser.parse(mixed)
        XCTAssertEqual(remotes.count, 1)
        XCTAssertEqual(remotes[0].fetchURL, "https://mirror.example/repo.git")
        XCTAssertEqual(remotes[0].pushURL, "git@write.example:team/repo.git")
    }

    func testSummaryShowsHostAndPath() {
        let remotes = RemoteListParser.parse(output)
        // 两个远端名字都很短，只看名字分不清推去了哪，菜单里要带上目标地址。
        XCTAssertEqual(remotes[1].summary, "10.0.0.1:8929/internal-group/internal-repo")
        XCTAssertEqual(remotes[0].summary, "github.com/example-owner/backup-mirror")
    }

    func testHandlesEmptyAndMalformedInput() {
        XCTAssertTrue(RemoteListParser.parse("").isEmpty)
        XCTAssertTrue(RemoteListParser.parse("没有制表符的一行").isEmpty)
    }

    // MARK: - 上游归属

    func testUpstreamRemoteIsMatchedAgainstKnownRemotes() {
        let known = ["origin", "github"]
        XCTAssertEqual(
            RemoteListParser.remoteName(inUpstream: "origin/main", knownRemotes: known),
            "origin"
        )
        // 分支名自己带斜杠 —— 不能按第一个斜杠之后就当成分支名结束。
        XCTAssertEqual(
            RemoteListParser.remoteName(inUpstream: "github/feature/login", knownRemotes: known),
            "github"
        )
    }

    func testUnknownRemoteInUpstreamYieldsNil() {
        // 只按第一个斜杠切的话，`upstream/main` 会被当成远端 `upstream`，
        // 即使这个仓库根本没有叫 upstream 的远端。那会让界面显示一个不存在的推送目标。
        XCTAssertNil(
            RemoteListParser.remoteName(inUpstream: "upstream/main", knownRemotes: ["origin"])
        )
    }

    func testRemoteNamesThatArePrefixesOfEachOtherDoNotCollide() {
        // `orig` 是 `origin` 的前缀。用 hasPrefix 判断时必须带上斜杠，
        // 否则 `origin/main` 会先命中 `orig`，推送就推到了错误的远端。
        let known = ["orig", "origin"]
        XCTAssertEqual(
            RemoteListParser.remoteName(inUpstream: "origin/main", knownRemotes: known),
            "origin"
        )
        XCTAssertEqual(
            RemoteListParser.remoteName(inUpstream: "orig/main", knownRemotes: known),
            "orig"
        )
    }
}
