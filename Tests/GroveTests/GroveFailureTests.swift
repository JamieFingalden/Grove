import XCTest
@testable import Grove

final class GroveFailureTests: XCTestCase {
    func testDivergingPullGetsActionableMessage() {
        let failure = GroveFailure(
            title: "拉取失败",
            error: commandFailure("fatal: Not possible to fast-forward, aborting.")
        )

        XCTAssertTrue(failure.detail.contains("变基"))
        XCTAssertFalse(failure.detail.contains("fatal:"))
        XCTAssertTrue(failure.technicalDetail?.contains("Not possible to fast-forward") == true)
    }

    func testRejectedPushExplainsThatRemoteIsAhead() {
        let failure = GroveFailure(
            title: "推送失败",
            error: commandFailure("! [rejected] main -> main (non-fast-forward)")
        )

        XCTAssertTrue(failure.detail.contains("远端"))
        XCTAssertTrue(failure.detail.contains("拉取"))
    }

    func testUnknownGitFailureKeepsRawOutputBehindTechnicalDetails() {
        let failure = GroveFailure(title: "操作失败", error: commandFailure("unexpected failure"))

        XCTAssertFalse(failure.detail.contains("unexpected failure"))
        XCTAssertTrue(failure.technicalDetail?.contains("unexpected failure") == true)
    }

    private func commandFailure(_ output: String) -> CommandFailure {
        CommandFailure(
            executable: "/usr/bin/git",
            arguments: ["pull", "--ff-only"],
            exitCode: 1,
            output: output
        )
    }
}
