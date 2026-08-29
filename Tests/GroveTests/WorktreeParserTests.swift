import XCTest
@testable import Grove

final class WorktreeParserTests: XCTestCase {
    func testParsesMultipleWorktrees() {
        let output = """
        worktree /Users/me/proj
        HEAD 8ed3be38fdf01cc1431c7b2c00971214a729e5c8
        branch refs/heads/main

        worktree /Users/me/proj-worktrees/feature-login
        HEAD a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0
        branch refs/heads/feature/login

        """

        let worktrees = WorktreeParser.parse(output)

        XCTAssertEqual(worktrees.count, 2)
        XCTAssertEqual(worktrees[0].path.path, "/Users/me/proj")
        XCTAssertEqual(worktrees[0].branch, "main")
        // git 保证第一条是主工作树，界面上靠这个标记禁掉「删除」。
        XCTAssertTrue(worktrees[0].isPrimary)
        XCTAssertFalse(worktrees[1].isPrimary)
        // 带斜杠的分支名只能剥掉 refs/heads/ 前缀，不能按最后一段切。
        XCTAssertEqual(worktrees[1].branch, "feature/login")
    }

    func testParsesDetachedLockedAndPrunable() {
        let output = """
        worktree /Users/me/proj
        HEAD aaa111
        branch refs/heads/main

        worktree /Volumes/External/wt
        HEAD bbb222
        detached
        locked 放在移动硬盘上

        worktree /Users/me/gone
        HEAD ccc333
        branch refs/heads/dead
        prunable gitdir file points to non-existent location

        """

        let worktrees = WorktreeParser.parse(output)

        XCTAssertEqual(worktrees.count, 3)
        XCTAssertTrue(worktrees[1].isDetached)
        XCTAssertEqual(worktrees[1].lockReason, "放在移动硬盘上")
        XCTAssertTrue(worktrees[1].isLocked)
        XCTAssertTrue(worktrees[2].isPrunable)
        XCTAssertFalse(worktrees[2].isLocked)
    }

    func testLockedWithoutReasonStillCountsAsLocked() {
        // `locked` 后面的原因是可选的。存 nil 会让它被误判成「没锁」，
        // 于是界面允许删除一个被锁的工作树，git 再把操作打回来。
        let output = """
        worktree /Users/me/proj
        HEAD aaa111
        branch refs/heads/main
        locked

        """

        let worktrees = WorktreeParser.parse(output)
        XCTAssertTrue(worktrees[0].isLocked)
        XCTAssertEqual(worktrees[0].lockReason, "")
    }

    func testHandlesMissingTrailingBlankLine() {
        let output = """
        worktree /Users/me/proj
        HEAD aaa111
        branch refs/heads/main
        """

        XCTAssertEqual(WorktreeParser.parse(output).count, 1)
    }

    func testBareRepositoryHasNoHead() {
        let output = """
        worktree /Users/me/proj.git
        bare

        """

        let worktrees = WorktreeParser.parse(output)
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertTrue(worktrees[0].isBare)
        XCTAssertNil(worktrees[0].head)
        XCTAssertEqual(worktrees[0].checkoutLabel, "空仓库")
    }
}
