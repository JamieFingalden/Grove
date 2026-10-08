import Foundation
import XCTest
@testable import Grove

/// 标签原语的集成测试。推送用本地裸仓库当远端 —— 走的是真实的 push 代码路径，
/// 但不需要网络。
final class TagTests: XCTestCase {
    private func makeRepository() async throws -> (GitClient, URL, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-tags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let git = try await GitClient.resolve()
        _ = try await git.run(["init", "-b", "main"], in: root)
        _ = try await git.run(["config", "user.name", "Grove Tests"], in: root)
        _ = try await git.run(["config", "user.email", "grove@example.invalid"], in: root)
        try Data("内容\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = try await git.stageAll(in: root)
        _ = try await git.commit(message: "first", in: root)

        let oid = try await git.run(["rev-parse", "HEAD"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (git, root, oid)
    }

    func testAnnotatedTagCarriesMessageAsTagObject() async throws {
        let (git, root, oid) = try await makeRepository()

        try await git.createTag("v1.0.0", message: "发布 1.0", at: oid, in: root)

        // 附注标签指向独立的 tag 对象，说明存在里面，而不是指向提交本身。
        let objectType = try await git.run(["cat-file", "-t", "refs/tags/v1.0.0"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(objectType, "tag")
        let contents = try await git.run(["cat-file", "-p", "refs/tags/v1.0.0"], in: root)
        XCTAssertTrue(contents.contains("发布 1.0"))
        let exists = await git.tagExists("v1.0.0", in: root)
        XCTAssertTrue(exists)
    }

    func testLightweightTagPointsAtCommitDirectly() async throws {
        let (git, root, oid) = try await makeRepository()

        try await git.createTag("wip", message: "", at: oid, in: root)

        // 轻量标签没有独立对象，引用直接落在提交上。
        let pointed = try await git.run(["rev-parse", "refs/tags/wip"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(pointed, oid)
    }

    func testTagExistsDistinguishesTakenNames() async throws {
        let (git, root, oid) = try await makeRepository()
        try await git.createTag("v1.0.0", message: "发布 1.0", at: oid, in: root)

        let taken = await git.tagExists("v1.0.0", in: root)
        let free = await git.tagExists("v2.0.0", in: root)
        XCTAssertTrue(taken)
        XCTAssertFalse(free)
    }

    func testDuplicateTagNameIsRejected() async throws {
        let (git, root, oid) = try await makeRepository()
        try await git.createTag("v1.0.0", message: "第一次", at: oid, in: root)

        do {
            try await git.createTag("v1.0.0", message: "第二次", at: oid, in: root)
            XCTFail("重名标签应该被 git 拒绝")
        } catch {
            XCTAssertTrue("\(error)".contains("already exists"))
        }
    }

    func testPushTagReachesRemoteAndDeleteStaysLocal() async throws {
        let (git, root, oid) = try await makeRepository()

        // 本地裸仓库当远端：push 走真实的代码路径，不碰网络。
        let remoteRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-tags-remote-\(UUID().uuidString)", isDirectory: true)
        _ = try await git.run(["init", "--bare", remoteRoot.path], in: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: remoteRoot) }
        _ = try await git.run(["remote", "add", "origin", remoteRoot.path], in: root)

        try await git.createTag("v1.0.0", message: "发布 1.0", at: oid, in: root)
        try await git.pushTag("v1.0.0", to: "origin", in: root)

        let remoteTags = try await git.run(["tag", "--list"], in: remoteRoot)
        XCTAssertEqual(remoteTags.trimmingCharacters(in: .whitespacesAndNewlines), "v1.0.0")

        // 删本地不影响远端 —— 远端的标签要显式的推送删除，Grove 不偷偷做。
        try await git.deleteTag("v1.0.0", in: root)
        let existsAfterDelete = await git.tagExists("v1.0.0", in: root)
        XCTAssertFalse(existsAfterDelete)
        let remoteAfterDelete = try await git.run(["tag", "--list"], in: remoteRoot)
        XCTAssertEqual(remoteAfterDelete.trimmingCharacters(in: .whitespacesAndNewlines), "v1.0.0")
    }

    func testTagsListNamesForVersionSuggestion() async throws {
        let (git, root, oid) = try await makeRepository()
        try await git.createTag("wip", message: "", at: oid, in: root)
        try await git.createTag("v0.1.1", message: "发布", at: oid, in: root)

        let names = await git.tags(in: root)
        XCTAssertEqual(Set(names), ["wip", "v0.1.1"])
        XCTAssertEqual(VersionTag.suggestedNext(after: names), "v0.1.2")
    }
}

/// 版本号候选的纯逻辑测试：解析和推进不碰仓库。
final class VersionTagTests: XCTestCase {
    func testParsesVersionShapedNames() {
        XCTAssertEqual(VersionTag("v0.1.1")?.rawValue, "v0.1.1")
        XCTAssertEqual(VersionTag("1.2.3")?.rawValue, "1.2.3")
        XCTAssertEqual(VersionTag("v2")?.rawValue, "v2")
    }

    func testRejectsNonVersionNames() {
        for name in ["wip", "release-1", "v1.0.0-beta", "v", "v.1", "1.2.x"] {
            XCTAssertNil(VersionTag(name), "\(name) 不该被当成版本号")
        }
    }

    func testRejectsSignedSegments() {
        // Int() 也认 "+1" / "-1"，但带符号的段不是纯数字 ——
        // 否则 v2.-1 会抢走最高版本的位置，把候选从 v1.2.4 带成 v2.0。
        XCTAssertNil(VersionTag("v2.-1"))
        XCTAssertNil(VersionTag("+1.2"))
        XCTAssertNil(VersionTag("1.+2"))
        XCTAssertEqual(VersionTag.suggestedNext(after: ["v1.2.3", "v2.-1"]), "v1.2.4")
    }

    func testNextBumpsLastSegmentWithoutCarry() {
        XCTAssertEqual(VersionTag("v0.1.1")?.next().rawValue, "v0.1.2")
        XCTAssertEqual(VersionTag("v0.1.9")?.next().rawValue, "v0.1.10")
        XCTAssertEqual(VersionTag("v2")?.next().rawValue, "v3")
        XCTAssertEqual(VersionTag("0.4")?.next().rawValue, "0.5")
    }

    func testSuggestionPicksHighestNumericallyAndKeepsStyle() {
        XCTAssertEqual(
            VersionTag.suggestedNext(after: ["v0.1.0", "v0.1.1", "wip", "v0.0.9"]),
            "v0.1.2"
        )
        // 数值比较而不是字符串比较：1.10.1 比 1.9 新。
        XCTAssertEqual(VersionTag.suggestedNext(after: ["1.9", "1.10.1"]), "1.10.2")
        XCTAssertNil(VersionTag.suggestedNext(after: ["wip", "nightly"]))
        XCTAssertNil(VersionTag.suggestedNext(after: []))
    }
}
