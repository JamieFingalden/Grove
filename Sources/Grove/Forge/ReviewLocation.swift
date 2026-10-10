import Foundation

/// 绑定 diff 中的真实行，保留重命名前后路径和上下文行的双侧行号。
struct ReviewLocation: Equatable, Sendable {
    var oldPath: String
    var newPath: String
    var oldLine: Int?
    var newLine: Int?
    var isOldSide: Bool

    var path: String { isOldSide ? oldPath : newPath }
    var line: Int { (isOldSide ? oldLine : newLine) ?? 0 }

    init?(file: FileDiff, line: DiffLine, isOldSide: Bool) {
        guard line.kind != .noNewline,
              let number = isOldSide ? line.oldNumber : line.newNumber,
              number > 0 else { return nil }
        oldPath = file.oldPath ?? file.newPath ?? file.displayPath
        newPath = file.newPath ?? file.oldPath ?? file.displayPath
        oldLine = line.oldNumber
        newLine = line.newNumber
        self.isOldSide = isOldSide
    }
}

enum ReviewDiscussionError: LocalizedError {
    case changedHead
    case unavailable
    case emptyBody

    var errorDescription: String? {
        switch self {
        case .changedHead: "请求的代码已更新，请刷新代码变更后重新添加讨论。"
        case .unavailable: "无法读取讨论或执行此操作，请检查平台权限后重试。"
        case .emptyBody: "讨论内容不能为空。"
        }
    }
}
