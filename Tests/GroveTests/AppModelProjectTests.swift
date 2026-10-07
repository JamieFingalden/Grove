import XCTest
@testable import Grove

@MainActor
final class AppModelProjectTests: XCTestCase {
    private let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:])

    func testProjectRetainsIndependentLocalClones() throws {
        let app = AppModel()
        let first = RepositoryModel(root: URL(fileURLWithPath: "/tmp/clone-one"), git: git, app: nil)
        let second = RepositoryModel(root: URL(fileURLWithPath: "/tmp/clone-two"), git: git, app: nil)
        first.origin = GitRemote.parse("https://github.com/example/project.git")
        second.origin = first.origin
        first.worktrees = [worktree(at: first.root)]
        second.worktrees = [worktree(at: second.root)]
        app.repositories = [first, second, first]

        let project = try XCTUnwrap(app.projects.first)
        XCTAssertEqual(app.projects.count, 1)
        XCTAssertEqual(project.locals.map(\.id), [first.id, second.id])
        XCTAssertEqual(project.mergedWorktrees.map(\.id), [first.id, second.id])
    }

    func testSamePathOnDifferentServersHasDistinctRowsAndSheets() {
        let path = URL(fileURLWithPath: "/srv/project")
        let first = RepositoryModel(root: path, git: git, app: nil, server: RemoteServer(host: "dev.example.com"))
        let second = RepositoryModel(root: path, git: git, app: nil, server: RemoteServer(host: "dev.example.com"))
        first.worktrees = [worktree(at: path)]
        second.worktrees = [worktree(at: path)]
        let group = AppModel.ProjectGroup(key: "project", name: "项目", locals: [], remotes: [first, second])

        XCTAssertEqual(group.mergedWorktrees.count, 2)
        XCTAssertNotEqual(group.mergedWorktrees[0].id, group.mergedWorktrees[1].id)
        XCTAssertNotEqual(
            RootView.ActiveSheet.removeWorktree(first, first.worktrees[0]).id,
            RootView.ActiveSheet.removeWorktree(second, second.worktrees[0]).id
        )
        let firstModel = WorktreeModel(worktree: first.worktrees[0], repository: first, git: git, app: nil)
        let secondModel = WorktreeModel(worktree: second.worktrees[0], repository: second, git: git, app: nil)
        XCTAssertNotEqual(firstModel.identityKey, secondModel.identityKey)
        XCTAssertNotEqual(RootView.ActiveSheet.rebase(firstModel).id, RootView.ActiveSheet.rebase(secondModel).id)
    }

    func testIdentityUsesStableServerIDAndOnlyResolvesLocalSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grove-identity-\(UUID().uuidString)")
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }

        var server = RemoteServer(host: "old.example.com")
        let before = RepoID(location: .remote(server), root: link)
        server.host = "new.example.com"
        server.alias = "新名称"
        let after = RepoID(location: .remote(server), root: link)

        XCTAssertEqual(before, after)
        XCTAssertEqual(Set([before, after]).count, 1)
        XCTAssertEqual(before.identityKey, after.identityKey)
        XCTAssertEqual(before.rootPath, link.path)
        XCTAssertNotEqual(before, RepoID(location: .remote(server), root: target))
        XCTAssertEqual(RepoID(location: .local, root: link), RepoID(location: .local, root: target))
    }

    func testClosingOnlineProjectPreservesOfflineRegistrations() throws {
        let suite = "AppModelProjectTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let offline = RemoteServer(host: "offline.example.com")
        let online = RemoteServer(host: "online.example.com")
        let store = RemoteProjectStore(defaults: defaults)
        store.save([
            offline.id.uuidString: ["/srv/offline"],
            online.id.uuidString: ["/srv/closed", "/srv/retained"]
        ])
        let app = AppModel(
            aiGenerationSettings: AIGenerationSettings(defaults: defaults),
            remoteServerStore: RemoteServerStore(defaults: defaults),
            remoteProjectStore: store
        )
        let repository = RepositoryModel(root: URL(fileURLWithPath: "/srv/closed"), git: git, app: nil, server: online)
        app.remoteRepositories = [repository]
        app.closeRemoteProject(repository)

        XCTAssertEqual(store.load()[offline.id.uuidString], ["/srv/offline"])
        XCTAssertEqual(store.load()[online.id.uuidString], ["/srv/retained"])
    }

    func testFailedServerUpdateRetainsRegisteredProjectsUntilExplicitRemoval() async throws {
        let suite = "AppModelProjectTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var server = RemoteServer(host: "old.example.com")
        let store = RemoteProjectStore(defaults: defaults)
        store.save([server.id.uuidString: ["/srv/project"]])
        let app = AppModel(
            aiGenerationSettings: AIGenerationSettings(defaults: defaults),
            remoteServerStore: RemoteServerStore(defaults: defaults),
            remoteProjectStore: store
        )
        app.addRemoteServer(server)
        server.host = "new.example.com"

        // 未启动工具探测，重建会走连接失败分支，不访问真实服务器。
        await app.updateRemoteServer(server)
        XCTAssertFalse(app.failures.isEmpty)
        XCTAssertEqual(store.load()[server.id.uuidString], ["/srv/project"])
        XCTAssertEqual(RemoteServerStore(defaults: defaults).load(), [server])

        app.removeRemoteServer(server)
        XCTAssertNil(store.load()[server.id.uuidString])
    }

    private func worktree(at path: URL) -> Worktree {
        Worktree(path: path, head: nil, branch: "main", isBare: false, isDetached: false,
                 lockReason: nil, prunableReason: nil, isPrimary: true)
    }
}
