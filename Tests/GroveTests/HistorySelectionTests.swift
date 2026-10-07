import XCTest
@testable import Grove

/// 故意忽略取消，验证传输迟到的成功与失败都不能覆盖当前选中的提交。
private actor HistoryDiffTransport: CommandTransport {
    nonisolated let label = "受控历史请求"
    private var pending: [String: CheckedContinuation<CommandResult, Never>] = [:]

    func runGit(_ arguments: [String], worktreePath: String, timeout: Double,
                standardInput: Data?) async throws -> CommandResult {
        let oid = arguments.last!
        return await withCheckedContinuation { pending[oid] = $0 }
    }

    func hasRequest(_ oid: String) -> Bool { pending[oid] != nil }

    func finish(_ oid: String, fails: Bool = false) {
        let diff = """
            diff --git a/\(oid).txt b/\(oid).txt
            new file mode 100644
            --- /dev/null
            +++ b/\(oid).txt
            @@ -0,0 +1 @@
            +\(oid)

            """
        pending.removeValue(forKey: oid)!.resume(returning: CommandResult(
            exitCode: fails ? 1 : 0,
            standardOutput: fails ? Data() : Data(diff.utf8),
            standardError: fails ? Data("读取失败".utf8) : Data()
        ))
    }

    func fileExists(atPath path: String) async -> Bool { false }
    func directoryExists(atPath path: String) async -> Bool { false }
    func readData(atPath path: String) async -> Data? { nil }
    func writeData(_ data: Data, toPath path: String, atomic: Bool) async throws {}
    func modificationDate(atPath path: String) async -> Date? { nil }
    func createDirectory(atPath path: String) async throws {}
}

@MainActor
final class HistorySelectionTests: XCTestCase {
    private func model(_ transport: HistoryDiffTransport) -> WorktreeModel {
        WorktreeModel(
            worktree: Worktree(path: URL(fileURLWithPath: "/tmp/grove-history"), head: "B",
                               branch: "main", isBare: false, isDetached: false,
                               lockReason: nil, prunableReason: nil),
            repository: nil, git: GitClient(transport: transport), app: nil
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("历史请求未在预期时间内完成")
    }

    func testLateSuccessAndFailureKeepTheNewerCommitDiff() async throws {
        for oldFails in [false, true] {
            let transport = HistoryDiffTransport()
            let model = model(transport)
            model.selectedCommit = "A"
            try await waitUntil { await transport.hasRequest("A") }
            model.selectedCommit = "B"
            try await waitUntil { await transport.hasRequest("B") }
            await transport.finish("B")
            try await waitUntil { model.commitDiff?.first?.newPath == "B.txt" }
            await transport.finish("A", fails: oldFails)
            // 让迟到响应完成；旧错误路径不能把新 diff 清为空数组。
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(model.selectedCommit, "B")
            XCTAssertEqual(model.commitDiff?.first?.newPath, "B.txt")
        }
    }

    func testClearingSelectionKeepsDiffEmptyWhenPendingRequestReturns() async throws {
        let transport = HistoryDiffTransport()
        let model = model(transport)
        model.selectedCommit = "A"
        try await waitUntil { await transport.hasRequest("A") }
        model.selectedCommit = nil
        await transport.finish("A")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(model.commitDiff)
    }
}
