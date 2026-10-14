import AppKit
import SwiftUI

// MARK: - Grove Symbols: Soft Precision
//
// 统一图标系统规范：
// 1. 严格区分「仓库（folder）」、「工作树（Worktree 几何面板）」、「分支（arrow.triangle.branch）」与「变基（arrow.triangle.swap）」，消除语义重叠。
// 2. 统一尺寸分级：xs (12pt), small (14pt), medium (16pt), large (20pt)。
// 3. 统一笔画粗细：在 14-16pt 下保持 1.25-1.35pt 笔画与 round caps/joins，与 SF Symbols Regular 字重取得光学平衡。
// 4. 纯原生 Swift/SwiftUI 实现，零外部依赖，完整支持 Light/Dark 模式与系统强调色。

/// 图标尺寸等级
enum GroveSymbolSize: CGFloat, Sendable, CaseIterable {
    /// 12pt：极小角标、行内次级状态、紧凑指示符
    case xs = 12
    /// 14pt：高密度列表项、小尺寸按钮图标、辅助工具栏
    case small = 14
    /// 16pt：默认侧边栏、主操作行、标准工具栏
    case medium = 16
    /// 20pt：空状态标题、重要头部入口
    case large = 20

    var pointSize: CGFloat { rawValue }

    /// 自定义几何图形的匹配描边宽度
    var strokeWidth: CGFloat {
        switch self {
        case .xs: return 1.15
        case .small: return 1.25
        case .medium: return 1.35
        case .large: return 1.60
        }
    }

    /// 对应的 SF Symbols 字体配置
    var font: Font {
        .system(size: pointSize, weight: .regular)
    }
}

/// 图标语义角色与色彩
enum GroveSymbolRole: Sendable, Equatable {
    case primary
    case secondary
    case tertiary
    case accent
    case success
    case warning
    case danger
    case custom(Color)
    /// 不主动设置前景色，继承上层环境的 foregroundStyle
    case monochrome

    var color: Color? {
        switch self {
        case .primary: return Color.primary
        case .secondary: return Color.secondary
        case .tertiary: return Color.secondary.opacity(0.65)
        case .accent: return Color.accentColor
        case .success: return Color.green
        case .warning: return Color.orange
        case .danger: return Color.red
        case .custom(let color): return color
        case .monochrome: return nil
        }
    }
}

/// 语义图标定义
enum GroveSymbol: Sendable, Equatable {
    // MARK: - 基础实体
    case repository
    case worktree(isPrimary: Bool, isBare: Bool)
    case branch
    case remoteServer
    case detachedHead

    // MARK: - Git 动作与状态
    case pull
    case push
    case fetch
    case rebase
    case merge
    case tag
    case commit
    case stage
    case unstage
    case discard
    case refresh
    case conflict
    case lock
    case prunable

    // MARK: - 评审与自动化
    case pullRequest(status: PullRequest.Status)
    case aiReview
    case codeReview(state: PullRequest.ReviewState)
    case ciPipeline(status: CIStatus)

    // MARK: - 界面导航与操作
    case search
    case filter
    case settings
    case more
    case copy
    case external
    case terminal
    case editor
    case expand
    case collapse
    case checkmark
}

// MARK: - 自定义工作树矢量图形 (Linked Workspace Panel - Form 1)

/// 工作树（Worktree）专属矢量图标。
///
/// 视觉隐喻：
/// - 底部的锚点圆环表示 Git 根提交/存储库基准。
/// - 主工作树（Primary）：中央直出主干，承载主工作区面板（代表根签出目录）。
/// - 附加工作树（Linked）：从根部优雅向右侧分叉向上，承载独立的派生工作区面板。
/// - 空仓库（Bare）：无工作区文件目录，用纯虚框或归档形态呈现。
struct WorktreeGlyphShape: Shape {
    var isPrimary: Bool
    var isBare: Bool

    init(isPrimary: Bool, isBare: Bool = false) {
        self.isPrimary = isPrimary
        self.isBare = isBare
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sx = rect.width / 20.0
        let sy = rect.height / 20.0

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        if isBare {
            // Bare 仓库：只有 git 结构，没有工作区面板，用带有虚框感的扁平抽屉
            let box = CGRect(x: rect.minX + 3.5 * sx, y: rect.minY + 5.0 * sy, width: 13.0 * sx, height: 9.0 * sy)
            path.addRoundedRect(in: box, cornerSize: CGSize(width: 2.0 * sx, height: 2.0 * sy))
            path.move(to: pt(3.5, 9.5))
            path.addLine(to: pt(16.5, 9.5))
            path.move(to: pt(8.5, 12.0))
            path.addLine(to: pt(11.5, 12.0))
            return path
        }

        if isPrimary {
            // 主工作树：居中工作区面板 + 垂直连接干 + 基准锚点
            let box = CGRect(x: rect.minX + 3.5 * sx, y: rect.minY + 2.5 * sy, width: 13.0 * sx, height: 9.5 * sy)
            path.addRoundedRect(in: box, cornerSize: CGSize(width: 2.2 * sx, height: 2.2 * sy))
            // 标题栏分割线
            path.move(to: pt(3.5, 5.8))
            path.addLine(to: pt(16.5, 5.8))
            // 直连干
            path.move(to: pt(10.0, 12.0))
            path.addLine(to: pt(10.0, 14.5))
            // 根节点锚环
            path.addEllipse(in: CGRect(x: rect.minX + 8.2 * sx, y: rect.minY + 14.5 * sy, width: 3.6 * sx, height: 3.6 * sy))
        } else {
            // 附加工作树：右侧派生工作区面板 + 左下弯曲分支干 + 基准锚点
            let box = CGRect(x: rect.minX + 8.5 * sx, y: rect.minY + 2.5 * sy, width: 10.0 * sx, height: 9.5 * sy)
            path.addRoundedRect(in: box, cornerSize: CGSize(width: 2.0 * sx, height: 2.0 * sy))
            // 标题栏分割线
            path.move(to: pt(8.5, 5.8))
            path.addLine(to: pt(18.5, 5.8))
            // 弯曲分支干
            path.move(to: pt(4.5, 14.5))
            path.addCurve(to: pt(8.5, 8.5), control1: pt(4.5, 9.5), control2: pt(6.5, 8.5))
            // 根节点锚环
            path.addEllipse(in: CGRect(x: rect.minX + 2.7 * sx, y: rect.minY + 14.2 * sy, width: 3.6 * sx, height: 3.6 * sy))
        }

        return path
    }
}

// MARK: - 图标视图渲染组件

struct GroveSymbolView: View {
    let symbol: GroveSymbol
    let size: GroveSymbolSize
    let role: GroveSymbolRole
    let isDecorative: Bool

    init(_ symbol: GroveSymbol, size: GroveSymbolSize = .medium, role: GroveSymbolRole = .monochrome,
         isDecorative: Bool = true) {
        self.symbol = symbol
        self.size = size
        self.role = role
        self.isDecorative = isDecorative
    }

    var body: some View {
        Group {
            switch symbol {
            case .worktree(let isPrimary, let isBare):
                WorktreeGlyphShape(isPrimary: isPrimary, isBare: isBare)
                    .stroke(
                        role.color ?? Color.primary,
                        style: StrokeStyle(lineWidth: size.strokeWidth, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: size.pointSize, height: size.pointSize)

            case .pullRequest(let status):
                if let image = Self.bundledPullRequestImage(for: status) {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(role.color ?? statusTintColor(status))
                        .frame(width: size.pointSize, height: size.pointSize)
                } else {
                    Image(systemName: "arrow.triangle.pull")
                        .font(size.font)
                        .foregroundStyle(role.color ?? statusTintColor(status))
                        .frame(width: size.pointSize, height: size.pointSize)
                }

            default:
                if let systemName = systemSymbolName(for: symbol) {
                    Image(systemName: systemName)
                        .font(size.font)
                        .ifLet(role.color) { view, color in
                            view.foregroundStyle(color)
                        }
                        .frame(width: size.pointSize, height: size.pointSize)
                }
            }
        }
        .accessibilityHidden(isDecorative)
    }

    private func systemSymbolName(for symbol: GroveSymbol) -> String? {
        switch symbol {
        case .repository: return "folder"
        case .branch: return "arrow.triangle.branch"
        case .remoteServer: return "server.rack"
        case .detachedHead: return "number"
        case .pull: return "arrow.down.to.line.compact"
        case .push: return "arrow.up.to.line.compact"
        case .fetch: return "arrow.clockwise"
        case .rebase: return "arrow.triangle.swap"
        case .merge: return "arrow.triangle.merge"
        case .tag: return "tag"
        case .commit: return "circle.circle"
        case .stage: return "plus"
        case .unstage: return "minus"
        case .discard: return "arrow.uturn.backward"
        case .refresh: return "arrow.clockwise"
        case .conflict: return "exclamationmark.triangle.fill"
        case .lock: return "lock.fill"
        case .prunable: return "exclamationmark.triangle.fill"
        case .aiReview: return "sparkles"
        case .codeReview(let state): return state.systemImage
        case .ciPipeline(let status): return status.systemImage
        case .search: return "magnifyingglass"
        case .filter: return "line.3.horizontal.decrease.circle"
        case .settings: return "gearshape"
        case .more: return "ellipsis"
        case .copy: return "doc.on.doc"
        case .external: return "arrow.up.forward.square"
        case .terminal: return "terminal"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .expand: return "chevron.right"
        case .collapse: return "chevron.down"
        case .checkmark: return "checkmark"
        case .worktree, .pullRequest: return nil
        }
    }

    private func statusTintColor(_ status: PullRequest.Status) -> Color {
        switch status {
        case .open: return .green
        case .draft: return .gray
        case .merged: return Color(red: 146 / 255, green: 79 / 255, blue: 247 / 255)
        case .closed: return .orange
        }
    }

    private static let iconBundle = Bundle.main.url(forResource: "Grove_Grove", withExtension: "bundle")
        .flatMap { Bundle(url: $0) } ?? Bundle.module

    private static func bundledPullRequestImage(for status: PullRequest.Status) -> NSImage? {
        let name: String
        switch status {
        case .open: name = "pull-request-open"
        case .draft: name = "pull-request-draft"
        case .merged: name = "pull-request-merged"
        case .closed: name = "pull-request-closed"
        }
        return iconBundle.url(forResource: name, withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
    }
}

private extension View {
    @ViewBuilder
    func ifLet<V, T>(_ value: T?, transform: (Self, T) -> V) -> some View where V: View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - Label 便捷扩展

@MainActor
extension Label where Title == Text, Icon == GroveSymbolView {
    init(_ titleKey: LocalizedStringKey, symbol: GroveSymbol, size: GroveSymbolSize = .small, role: GroveSymbolRole = .monochrome) {
        self.init {
            Text(titleKey)
        } icon: {
            GroveSymbolView(symbol, size: size, role: role)
        }
    }

    init<S>(_ title: S, symbol: GroveSymbol, size: GroveSymbolSize = .small, role: GroveSymbolRole = .monochrome) where S: StringProtocol {
        self.init {
            Text(title)
        } icon: {
            GroveSymbolView(symbol, size: size, role: role)
        }
    }
}
