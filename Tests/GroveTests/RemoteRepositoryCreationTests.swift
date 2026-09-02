import XCTest
@testable import Grove

final class RemoteRepositoryCreationTests: XCTestCase {
    func testGitHubCreatesFromCurrentRepositoryWithoutImplicitPush() {
        let request = NewRemoteRepository(
            kind: .github,
            path: "team/grove",
            description: "工作树客户端",
            host: "github.example.com",
            visibility: .privateRepository
        )

        XCTAssertEqual(
            GitHubClient.createRepositoryArguments(request),
            [
                "repo", "create", "team/grove", "--private",
                "--source", ".", "--remote", "origin",
                "--description", "工作树客户端"
            ]
        )
    }

    func testGitLabCreatesAndConnectsOriginWithoutEmptyDescription() {
        let request = NewRemoteRepository(
            kind: .gitlab,
            path: "team/grove",
            description: "  ",
            host: "gitlab.example.com",
            visibility: .publicRepository
        )

        XCTAssertEqual(
            GitLabClient.createRepositoryArguments(request),
            ["repo", "create", "team/grove", "--public", "--remoteName", "origin"]
        )
    }
}
