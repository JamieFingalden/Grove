import Foundation
import XCTest
@testable import Grove

final class SafeForcePushTests: XCTestCase {
    func testForcePushUsesLeaseAndNeverBareForce() {
        let arguments = GitClient.pushArguments(
            remote: "origin",
            branch: "feature",
            setUpstream: false,
            forceWithLease: true
        )

        XCTAssertEqual(arguments, ["push", "--force-with-lease", "origin", "feature"])
        XCTAssertFalse(arguments.contains("--force"))
    }

    func testRecognizesUpstreamAsPreviousHeadAfterAmend() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-force-push-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = try await GitClient.resolve()
        _ = try await git.run(["init", "-b", "main"], in: root)
        _ = try await git.run(["config", "user.name", "Grove Tests"], in: root)
        _ = try await git.run(["config", "user.email", "grove@example.invalid"], in: root)

        let file = root.appendingPathComponent("feature.txt")
        try Data("first\n".utf8).write(to: file)
        try await git.stageAll(in: root)
        try await git.commit(message: "first", in: root)

        let remoteCommit = try await git.run(["rev-parse", "HEAD"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await git.run(["remote", "add", "origin", "https://example.invalid/repo.git"], in: root)
        _ = try await git.run(["update-ref", "refs/remotes/origin/main", remoteCommit], in: root)
        _ = try await git.run(["branch", "--set-upstream-to", "origin/main", "main"], in: root)

        try Data("first\n补充\n".utf8).write(to: file)
        try await git.stageAll(in: root)
        try await git.commit(message: "first amended", amend: true, in: root)

        let upstreamOID = try await git.run(["rev-parse", "--verify", "@{upstream}"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previousHeadOID = try await git.run(["rev-parse", "--verify", "HEAD@{1}"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(previousHeadOID, upstreamOID)

        let matchesPreviousHead = await git.upstreamMatchesPreviousHead(in: root)
        XCTAssertTrue(matchesPreviousHead)
    }
}
