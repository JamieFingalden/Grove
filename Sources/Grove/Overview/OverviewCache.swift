import Foundation

/// 只缓存业务快照，不存认证凭据。磁盘读写离开主线程。
enum OverviewCache {
    static func url(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grove/Overview", isDirectory: true).appendingPathComponent(name + ".json")
    }
    static func read<T: Decodable & Sendable>(_ name: String, as type: T.Type) async -> T? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url(name)) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }.value
    }
    static func write<T: Encodable & Sendable>(_ value: T, name: String) async -> String? {
        await Task.detached(priority: .utility) {
            do {
                let target = url(name)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(value).write(to: target, options: .atomic)
                return nil
            } catch { return "缓存写入失败：\(error.localizedDescription)" }
        }.value
    }
}
