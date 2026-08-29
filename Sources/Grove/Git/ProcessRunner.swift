import Foundation

/// 一次子进程调用的完整结果。stdout/stderr 都留原始 `Data`，
/// 因为 `git diff` 可能吐出非 UTF-8 的内容，解码失败时不该整条命令报废。
struct CommandResult: Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data

    var isSuccess: Bool { exitCode == 0 }

    /// 宽松解码：UTF-8 失败时退回 ISO Latin-1（永不失败），保证任何字节序列都有字符串形态。
    var stdout: String { CommandResult.decode(standardOutput) }
    var stderr: String { CommandResult.decode(standardError) }

    /// 去掉尾部换行的 stdout。git 几乎所有输出都带尾随换行，调用点每次都 trim 太啰嗦。
    var trimmedStdout: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// 子进程以非零状态退出。`message` 优先用 stderr，因为 git 的错误信息都写在那儿。
struct CommandFailure: LocalizedError, Sendable {
    let executable: String
    let arguments: [String]
    let exitCode: Int32
    let output: String

    var errorDescription: String? {
        let command = ([executable] + arguments).joined(separator: " ")
        if output.isEmpty {
            return "命令失败（退出码 \(exitCode)）：\(command)"
        }
        return output
    }

    /// 完整命令行，排查问题时展示给用户。
    var commandLine: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

/// 子进程无法启动（可执行文件不存在、没有执行权限等）。
struct CommandLaunchFailure: LocalizedError, Sendable {
    let executable: String
    let underlying: String

    var errorDescription: String? {
        "无法启动 \(executable)：\(underlying)"
    }
}

/// 子进程超时被强制结束。
struct CommandTimeout: LocalizedError, Sendable {
    let executable: String
    let arguments: [String]
    let seconds: Double

    var errorDescription: String? {
        let command = ([executable] + arguments).joined(separator: " ")
        return "命令超过 \(Int(seconds)) 秒仍未结束，已中止：\(command)"
    }
}

/// 一个可以跨线程读写的布尔标志。
///
/// 看门狗在后台线程上翻转它、主流程在协作线程上读它，需要同步。
/// 用锁而不是 `Mutex`：后者要 macOS 15，而 Grove 的下限是 14。
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// 置位，并返回「这次是不是第一次置位」。
    /// 用来保证 continuation 只被 resume 一次 —— resume 两次会直接崩溃。
    @discardableResult
    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }

    func set() {
        setIfUnset()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum ProcessRunner {
    /// 本地查询的默认超时。`git status` / `git diff` 就算在超大仓库上也是秒级，
    /// 跑到 30 秒必然是卡住了（索引锁、网络文件系统、坏掉的 hook）。
    static let localTimeout: Double = 30
    /// 涉及网络的操作（fetch / push / gh）要宽松得多，慢的远端几十秒很正常。
    static let networkTimeout: Double = 180

    /// 跑一个子进程，等它结束，返回完整输出。
    ///
    /// 三个坑这里都堵上了：
    ///
    /// 1. **管道死锁**。子进程输出超过管道缓冲区（macOS 上 64KB）就会阻塞在 write 上，
    ///    如果我们先 `waitUntilExit()` 再读，双方互等，永久挂死。`git diff`、
    ///    `gh pr list --json statusCheckRollup` 动辄几百 KB，所以这里在进程还活着的
    ///    时候就并发地把两个管道抽干。
    ///
    /// 2. **stdin 交互**。git 拿不到凭据时会弹 `Username:` 提示并等输入；GUI 里没人
    ///    能回答，进程就永远卡着。把 stdin 接到 /dev/null，git 读到 EOF 会立刻失败
    ///    退出，我们能把错误呈现给用户而不是无限转圈。
    ///
    /// 3. **无限期挂起**。前两条堵不住所有情况：远端半死不活的 TCP 连接、卡在
    ///    网络磁盘上的 `.git`、写坏了的 hook，都能让子进程永远不退出。GUI 里这
    ///    表现为一个转不完的进度圈，而且没有任何办法取消。所以给每条命令都套一个
    ///    看门狗，到点强制结束并报出是哪条命令超时了。
    ///
    /// 4. **孙进程握着管道不放**。子进程退出 ≠ 管道到 EOF —— 它 fork 出来的后台
    ///    进程继承了同一个写端。git 就会这么干（`git gc --auto`）。详见 `drain`。
    static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Double = localTimeout,
        standardInput: Data? = nil
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment ?? ProcessInfo.processInfo.environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // 有输入要喂就接管道，否则接 /dev/null（见上面第 2 点：
        // 不接的话 git 会卡在没人能回答的凭据提示上）。
        let inputPipe = standardInput.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CommandLaunchFailure(
                executable: executable.path,
                underlying: error.localizedDescription
            )
        }

        // 写 stdin 必须在读 stdout 之前排好：子进程可能一边读输入一边吐输出，
        // 先写完再读的话，输出超过管道缓冲区就会双向卡死。
        if let inputPipe, let standardInput {
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = inputPipe.fileHandleForWriting
                try? handle.write(contentsOf: standardInput)
                // 必须关掉写端，否则子进程等不到 EOF，会一直读下去。
                try? handle.close()
            }
        }

        let timedOut = AtomicFlag()
        // 进程已经退出、可以停止读管道了。见下面 `drain` 的注释。
        let noMoreWriters = AtomicFlag()

        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut.set()
            process.terminate()

            // SIGTERM 之后再给两秒体面退出的机会。还赖着不走就 SIGKILL ——
            // 到这一步说明它连信号都不响应了，继续等下去毫无意义。
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        defer { watchdog.cancel() }

        // 等进程退出，然后通知 drain「不会再有新数据了」。
        // 这个任务必须跟 drain 并发跑：drain 要在进程存活期间就把管道抽干（见第 1 点），
        // 而进程退出的时刻只有这里知道。
        let exitWatcher = Task {
            await waitForExit(process)
            noMoreWriters.set()
        }

        async let outputData = drain(outputPipe.fileHandleForReading, stopWhen: noMoreWriters)
        async let errorData = drain(errorPipe.fileHandleForReading, stopWhen: noMoreWriters)
        let (collectedOutput, collectedError) = await (outputData, errorData)

        await withTaskCancellationHandler {
            _ = await exitWatcher.value
        } onCancel: {
            process.terminate()
        }

        if timedOut.isSet {
            throw CommandTimeout(
                executable: executable.path,
                arguments: arguments,
                seconds: timeout
            )
        }

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: collectedOutput,
            standardError: collectedError
        )
    }

    /// 跑一个子进程，非零退出直接抛错。绝大多数调用点想要的就是这个语义。
    @discardableResult
    static func runChecked(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Double = localTimeout,
        standardInput: Data? = nil
    ) async throws -> CommandResult {
        let result = try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout,
            standardInput: standardInput
        )
        guard result.isSuccess else {
            // stderr 为空时退回 stdout：有些工具（含 gh 的部分子命令）把错误写在 stdout。
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = result.trimmedStdout
            throw CommandFailure(
                executable: executable.path,
                arguments: arguments,
                exitCode: result.exitCode,
                output: message.isEmpty ? fallback : message
            )
        }
        return result
    }

    /// 在后台线程上把一个管道读干。
    ///
    /// 不能用 `readToEnd()`，因为它等的是 EOF，而 EOF 要等**所有**持有写端的进程
    /// 都关掉它 —— 不只是我们启动的那个子进程，还包括它 fork 出来的孙进程。
    /// git 恰恰会这么干：`git commit` / `git fetch` 之后可能后台跑一个
    /// `git gc --auto`，它继承了同一个 stdout 管道，能活好几分钟。
    /// 于是 git 本身早就退出了，我们还阻塞在 read 上等一个永远不来的 EOF。
    /// （超时看门狗也救不了：它 SIGTERM 的是子进程，孙进程照样握着管道。）
    ///
    /// 所以这里改成非阻塞 + `poll` 轮询：只有在「管道当前没数据」**并且**
    /// 「子进程已经退出」时才收工。既不会漏读缓冲区里的残留数据，
    /// 也不会被赖着不走的孙进程拖住。
    private static func drain(_ handle: FileHandle, stopWhen noMoreWriters: AtomicFlag) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let descriptor = handle.fileDescriptor
                let flags = fcntl(descriptor, F_GETFL, 0)
                _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)

                loop: while true {
                    var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    // 200ms 一轮，好让我们有机会看一眼「进程退出了没」。
                    let ready = poll(&descriptors, 1, 200)

                    if ready > 0 {
                        let count = buffer.withUnsafeMutableBytes { pointer in
                            read(descriptor, pointer.baseAddress, pointer.count)
                        }
                        if count > 0 {
                            collected.append(contentsOf: buffer[0..<count])
                            continue
                        }
                        if count == 0 { break loop }                       // 正常 EOF
                        if errno == EAGAIN || errno == EINTR { continue }  // 没数据/被信号打断，再来
                        break loop                                          // 真的读错了
                    }

                    if ready == 0 {
                        // 这一轮没有数据。子进程已经退出的话，剩下的写端只可能是
                        // 不相干的孙进程，没有再等的必要。
                        if noMoreWriters.isSet { break loop }
                        continue
                    }

                    if errno == EINTR { continue }
                    break loop
                }

                try? handle.close()
                continuation.resume(returning: collected)
            }
        }
    }

    /// 等子进程退出。
    ///
    /// 用 `terminationHandler` 而不是 `waitUntilExit()`。后者会在**调用线程**上起一个
    /// run loop 等通知，而 Foundation 派发终止通知依赖内部的线程亲缘性 ——
    /// 从 Swift 并发的协作线程池上调用时，偶发会永远等不到通知。这个 bug 极其难查：
    /// 单跑一条命令永远正常，并发一多就有一条随机卡死。
    /// `terminationHandler` 由 Foundation 在自己的队列上回调，跟调用方在哪个线程无关。
    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = AtomicFlag()
            // handler 在 Foundation 的队列上跑，所以这个闭包必须是 @Sendable。
            let finish: @Sendable () -> Void = {
                // handler 和下面的 isRunning 检查可能同时命中，只放行第一次 ——
                // continuation resume 两次是直接崩溃，不是报错。
                guard resumed.setIfUnset() else { return }
                continuation.resume()
            }

            process.terminationHandler = { _ in finish() }

            // 设置 handler 之前进程就已经退出的话，handler 永远不会被调用。
            if !process.isRunning { finish() }
        }
    }
}
