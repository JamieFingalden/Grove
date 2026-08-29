import XCTest
@testable import Grove

/// `ProcessRunner` 的行为测试。这些用例会真的 fork 子进程 ——
/// 管道死锁只在真实的内核缓冲区边界上才会发生，mock 不出来。
final class ProcessRunnerTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    func testCapturesSmallOutput() async throws {
        let result = try await ProcessRunner.run(
            executable: shell,
            arguments: ["-c", "printf 'hello'"]
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stdout, "hello")
    }

    /// 输出超过管道缓冲区（macOS 上 64KB）时不能死锁。
    ///
    /// 这是这一层最容易写错、也最致命的地方：先 `waitUntilExit()` 再读管道的话，
    /// 子进程会阻塞在 write 上等我们读、我们阻塞在 wait 上等它退出，永久互等。
    /// `git diff` 和 `gh pr list --json statusCheckRollup` 动辄几百 KB，
    /// 小仓库上一切正常，换个大仓库整个界面就转圈转到天荒地老。
    func testLargeOutputDoesNotDeadlock() async throws {
        // 2MB，远超任何平台的管道缓冲区。
        let result = try await ProcessRunner.run(
            executable: shell,
            arguments: ["-c", "yes 0123456789012345678901234567890123456789 | head -n 50000"]
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.standardOutput.count, 50_000 * 41)
    }

    /// stdout 和 stderr 同时产生大量输出也不能死锁 ——
    /// 只抽干一个管道的话，另一个填满后子进程照样卡住。
    func testLargeOutputOnBothPipes() async throws {
        let result = try await ProcessRunner.run(
            executable: shell,
            arguments: ["-c", """
            yes aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | head -n 20000 &
            yes bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb | head -n 20000 >&2
            wait
            """]
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.standardOutput.count, 20_000 * 41)
        XCTAssertEqual(result.standardError.count, 20_000 * 41)
    }

    func testNonZeroExitIsReportedNotThrown() async throws {
        let result = try await ProcessRunner.run(
            executable: shell,
            arguments: ["-c", "echo boom >&2; exit 3"]
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "boom")
    }

    func testRunCheckedThrowsWithStderrMessage() async {
        do {
            _ = try await ProcessRunner.runChecked(
                executable: shell,
                arguments: ["-c", "echo 详细错误 >&2; exit 1"]
            )
            XCTFail("非零退出应该抛错")
        } catch let failure as CommandFailure {
            // 错误信息优先用 stderr —— git 的报错都写在那儿，
            // 直接透给用户比包一层「命令失败」有用得多。
            XCTAssertEqual(failure.output, "详细错误")
            XCTAssertEqual(failure.exitCode, 1)
        } catch {
            XCTFail("抛出了意外的错误类型：\(error)")
        }
    }

    func testMissingExecutableThrowsLaunchFailure() async {
        do {
            _ = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/nonexistent/binary"),
                arguments: []
            )
            XCTFail("不存在的可执行文件应该抛错")
        } catch is CommandLaunchFailure {
            // 预期
        } catch {
            XCTFail("抛出了意外的错误类型：\(error)")
        }
    }

    /// 子进程读 stdin 时必须立刻拿到 EOF。
    ///
    /// git 拿不到凭据时会打印 `Username:` 然后等输入。GUI 里没人能回答，
    /// 不接 /dev/null 的话进程就永远挂在那儿 —— 而用户只看到一个转不完的圈。
    func testStdinIsClosedSoChildDoesNotWaitForInput() async throws {
        let result = try await ProcessRunner.run(
            executable: shell,
            arguments: ["-c", "read line; echo \"读到=[$line]\""]
        )
        XCTAssertTrue(result.stdout.contains("读到=[]"))
    }

    /// 大量并发调用不能有任何一条卡住。
    ///
    /// 这一条是有来历的：早先用 `waitUntilExit()` 等进程退出，单条命令永远正常，
    /// 一并发就随机挂死一条 —— 因为它在调用线程上跑 run loop，
    /// 而 Swift 并发的协作线程池不保证线程亲缘性。串行测试根本测不出来。
    func testManyConcurrentProcessesAllComplete() async throws {
        let count = 40
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<count {
                group.addTask {
                    let result = try await ProcessRunner.run(
                        executable: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "printf '%s' \(index)"],
                        timeout: 20
                    )
                    return result.stdout
                }
            }
            var collected: [String] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        XCTAssertEqual(results.count, count)
        XCTAssertEqual(Set(results), Set((0..<count).map(String.init)))
    }

    func testNonUTF8OutputStillDecodesToSomething() async throws {
        // git diff 完全可能吐出非 UTF-8 字节（比如 GBK 编码的源文件）。
        // 解码失败就整条命令报废的话，用户会以为文件坏了。
        let result = try await ProcessRunner.run(
            executable: shell,
            arguments: ["-c", "printf '\\xff\\xfe\\x00abc'"]
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertFalse(result.stdout.isEmpty)
    }

    /// 子进程退出后，孙进程还握着 stdout 管道不放 —— 不能因此卡住。
    ///
    /// 这不是造出来的极端情况：`git commit` / `git fetch` 会顺手 fork 一个
    /// `git gc --auto` 到后台，它继承同一个写端并能活几分钟。等 EOF 的实现
    /// 会在这里彻底卡死，而且超时看门狗也救不了（SIGTERM 打的是子进程，
    /// 孙进程照样握着管道）。
    func testGrandchildHoldingPipeDoesNotBlockCompletion() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(
            executable: shell,
            // sh 立刻打印并退出，但它 fork 的 sleep 会继承 stdout 再活 30 秒。
            arguments: ["-c", "sleep 30 & printf 'done'; exit 0"],
            timeout: 25
        )

        XCTAssertEqual(result.stdout, "done")
        XCTAssertTrue(result.isSuccess)
        // 必须在子进程退出后很快返回，而不是陪着孙进程等满 30 秒。
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// 孙进程的存在不能导致数据被提前截断。
    func testOutputIsNotTruncatedWhenGrandchildExists() async throws {
        let result = try await ProcessRunner.run(
            executable: shell,
            arguments: ["-c", "sleep 30 & yes 0123456789 | head -n 30000; exit 0"],
            timeout: 25
        )
        XCTAssertEqual(result.standardOutput.count, 30_000 * 11)
    }
}
