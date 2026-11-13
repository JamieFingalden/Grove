import CoreServices
import Foundation

/// 系统负责监听目录树；这里只合并通知，不轮询或遍历磁盘。
private final class FileEventStream: @unchecked Sendable {
    struct Event: Sendable {
        let path: String
        let mustRescan: Bool
    }

    private final class Handler {
        let receive: @Sendable ([Event]) -> Void
        init(_ receive: @escaping @Sendable ([Event]) -> Void) { self.receive = receive }
    }

    private let stream: FSEventStreamRef

    init?(paths: [String], receive: @escaping @Sendable ([Event]) -> Void) {
        let handler = Handler(receive)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Handler>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<Handler>.fromOpaque(pointer).release() }
            },
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, context, count, rawPaths, flags, _ in
                guard let context else { return }
                let paths = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
                let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagRootChanged)
                let events = (0..<count).map {
                    Event(path: paths[$0], mustRescan: flags[$0] & rescanFlags != 0)
                }
                Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue().receive(events)
            },
            &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot)
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// 每个仓库共用一个监听器，刷新期间的新事件留到下一批，避免任务堆积。
@MainActor
final class RepositoryFileWatcher {
    struct Batch {
        var paths: Set<String> = []
        var reloadRepository = false
        var refreshAll = false

        var isEmpty: Bool { paths.isEmpty && !reloadRepository && !refreshAll }
    }

    private var stream: FileEventStream?
    private var watchedPaths: Set<String> = []
    private var gitDirectories: [String] = []
    private var pending = Batch()
    private var task: Task<Void, Never>?
    private let delay: Duration
    private let refresh: @MainActor (Batch) async -> Void

    init(delay: Duration = .milliseconds(350), refresh: @escaping @MainActor (Batch) async -> Void) {
        self.delay = delay
        self.refresh = refresh
    }

    func watch(worktrees: [URL], gitDirectories: [URL]) {
        let directories = gitDirectories.map { $0.groveResolved.path }.sorted { $0.count > $1.count }
        let paths = Set(worktrees.map { $0.groveResolved.path } + directories)
        guard paths != watchedPaths || stream == nil else { return }
        self.gitDirectories = directories
        watchedPaths = paths
        stream = nil
        // 父目录已经递归覆盖子目录，无需重复订阅。
        let roots = paths.filter { path in
            !paths.contains { $0 != path && path.hasPrefix($0 + "/") }
        }
        stream = FileEventStream(paths: Array(roots)) { [weak self] events in
            Task { @MainActor [weak self] in
                for event in events { self?.receive(path: event.path, mustRescan: event.mustRescan) }
            }
        }
    }

    func receive(path: String, mustRescan: Bool = false) {
        // FSEvents 返回 /private/var 等物理路径，Foundation 的仓库路径可能是 /var。
        // 统一写法，但不能解析文件自身的符号链接，否则链接变更会被归到仓库外。
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if mustRescan {
            pending.reloadRepository = true
            pending.refreshAll = true
        } else if let directory = gitDirectories.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            let relative = String(path.dropFirst(directory.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let first = relative.split(separator: "/").first.map(String.init) ?? ""
            // 对象库、日志和临时锁不影响界面；尤其不能被只读查询的副作用反复唤醒。
            if relative.hasSuffix(".lock") { return }
            if first == "index" || first.hasPrefix("sharedindex.") {
                pending.refreshAll = true
            } else if ["HEAD", "refs", "packed-refs", "config", "config.worktree", "worktrees",
                       "info", "commondir", "MERGE_HEAD", "MERGE_MSG", "REBASE_HEAD", "ORIG_HEAD",
                       "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"].contains(first)
                        || relative.isEmpty {
                pending.reloadRepository = true
            } else { return }
        } else {
            // 密集构建也只保留有限数量的路径；溢出时用一次状态校准兜底。
            if pending.paths.count < 4096 { pending.paths.insert(path) }
            else { pending.refreshAll = true }
        }
        schedule()
    }

    private func schedule() {
        guard task == nil else { return }
        task = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.drain()
        }
    }

    private func drain() async {
        let batch = pending
        pending = Batch()
        await refresh(batch)
        task = nil
        if !pending.isEmpty { schedule() }
    }

    deinit { task?.cancel() }
}
