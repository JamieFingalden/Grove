import XCTest
@testable import Grove

/// 超时看门狗的行为测试。
final class ProcessTimeoutTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    /// 卡死的子进程必须被强制结束并报错，而不是永远等下去。
    ///
    /// GUI 里这是唯一的兜底：远端半死不活的 TCP、挂在网络磁盘上的 `.git`、
    /// 写坏的 hook —— 任何一个都能让 git 永不退出。没有看门狗的话，
    /// 用户看到的是一个转不完的圈，而且没有任何办法取消。
    func testHungProcessIsKilledAndReported() async {
        let started = Date()
        do {
            _ = try await ProcessRunner.run(
                executable: shell,
                arguments: ["-c", "sleep 60"],
                timeout: 1
            )
            XCTFail("卡死的进程应该超时")
        } catch let timeout as CommandTimeout {
            XCTAssertEqual(timeout.seconds, 1)
            // 必须在超时后不久就返回，不能真的等满 60 秒。
            XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        } catch {
            XCTFail("抛出了意外的错误类型：\(error)")
        }
    }

    /// 在超时之内正常结束的进程不受影响。
    func testFastProcessIsNotAffected() async throws {
        let result = try await ProcessRunner.run(
            executable: shell,
            arguments: ["-c", "printf ok"],
            timeout: 30
        )
        XCTAssertEqual(result.stdout, "ok")
    }

    /// 忽略 SIGTERM 的进程也要被收拾掉，否则看门狗形同虚设。
    func testProcessIgnoringSIGTERMIsForceKilled() async {
        let started = Date()
        do {
            _ = try await ProcessRunner.run(
                executable: shell,
                arguments: ["-c", "trap '' TERM; sleep 60"],
                timeout: 1
            )
            XCTFail("赖着不退的进程应该被 SIGKILL")
        } catch is CommandTimeout {
            // SIGTERM 后还有 2 秒宽限期，所以这里放宽到 15 秒。
            XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        } catch {
            XCTFail("抛出了意外的错误类型：\(error)")
        }
    }
}
