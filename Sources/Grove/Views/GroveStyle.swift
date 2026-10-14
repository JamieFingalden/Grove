import SwiftUI

/// 共用系统字体和动态颜色，保持原生控件的对比度与明暗模式行为。
enum GroveStyle {
    enum Space {
        static let xs: CGFloat = 4
        static let compact: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let section: CGFloat = 24
        static let empty: CGFloat = 32
    }

    static let title = Font.system(size: 16, weight: .semibold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let metadata = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let micro = Font.system(size: 10, weight: .medium)
    static let emptyTitle = Font.system(size: 15, weight: .semibold)

    static let microRadius: CGFloat = 4
    static let smallRadius: CGFloat = 6
    static let radius: CGFloat = 8
    static let largeRadius: CGFloat = 12

    static let sidebarWidth: CGFloat = 272
    static let toolbarHeight: CGFloat = 40
    static let buttonHeight: CGFloat = 26
    static let toolHitArea: CGFloat = 26
    static let toolIcon = Font.system(size: 13, weight: .regular)
    static let listWidth: CGFloat = 300

    static let content = Color(nsColor: .windowBackgroundColor)
    static let secondarySurface = Color.primary.opacity(0.03)
    static let panelBackground = Color(nsColor: .controlBackgroundColor).opacity(0.45)
    static let subtleBorder = Color.primary.opacity(0.08)
    static let hover = Color.primary.opacity(0.05)
    static let selection = Color.accentColor.opacity(0.12)
    static let inactiveSelection = Color.primary.opacity(0.06)

    // Diff 专用配色：柔和、低饱和、长时阅读不刺眼
    enum Diff {
        static let addedFg = Color(red: 46 / 255, green: 160 / 255, blue: 67 / 255)
        static let addedBg = Color(red: 46 / 255, green: 160 / 255, blue: 67 / 255).opacity(0.10)
        static let addedHighlight = Color(red: 46 / 255, green: 160 / 255, blue: 67 / 255).opacity(0.24)
        static let addedBar = Color(red: 46 / 255, green: 160 / 255, blue: 67 / 255).opacity(0.65)

        static let deletedFg = Color(red: 235 / 255, green: 87 / 255, blue: 87 / 255)
        static let deletedBg = Color(red: 235 / 255, green: 87 / 255, blue: 87 / 255).opacity(0.10)
        static let deletedHighlight = Color(red: 235 / 255, green: 87 / 255, blue: 87 / 255).opacity(0.22)
        static let deletedBar = Color(red: 235 / 255, green: 87 / 255, blue: 87 / 255).opacity(0.65)

        static let hunkHeaderBg = Color.primary.opacity(0.035)
        static let gutterText = Color.secondary.opacity(0.65)
        static let gutterBorder = Color.primary.opacity(0.06)
    }
}

/// 空数据和错误共用尺寸规范；错误明确使用独立标题、原因与重试动作。
struct GroveEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    var isError = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: GroveStyle.Space.xl) {
                VStack(spacing: GroveStyle.Space.md) {
                    Image(systemName: systemImage)
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(spacing: GroveStyle.Space.compact) {
                        Text(title).font(GroveStyle.emptyTitle)
                        Text(description)
                            .font(GroveStyle.metadata)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                actions().controlSize(.regular)
            }
            .frame(maxWidth: 360)
            .padding(GroveStyle.Space.section)
            // 留一点下方呼吸空间；小窗口不额外偏移，不靠绝对坐标定位。
            .padding(.bottom, min(GroveStyle.Space.empty, max(0, geometry.size.height - 360) * 0.1))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension GroveEmptyState where Actions == EmptyView {
    init(title: String, systemImage: String, description: String) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        actions = { EmptyView() }
    }
}

struct GroveLoadingState: View {
    let title: String

    var body: some View {
        VStack(spacing: GroveStyle.Space.md) {
            ProgressView().controlSize(.small)
            Text(title).font(GroveStyle.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// 悬停只改变底色，不改变行高或焦点；键盘焦点仍由系统 Button/List 绘制。
struct GroveRowHover: ViewModifier {
    var isSelected = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(isEnabled && isHovering && !isSelected ? GroveStyle.hover : .clear,
                        in: RoundedRectangle(cornerRadius: GroveStyle.radius))
            .onHover { isHovering = $0 }
    }
}

/// 分隔条只负责分配空间，内容始终挂载在同一位置。
/// 原生 NSSplitView 不可靠地收起带固有尺寸的 SwiftUI 列，因此窄窗口在分栏上层切换内容。
struct GroveAdaptiveSplit<ListContent: View, DetailContent: View>: View {
    let showsDetail: Bool
    @ViewBuilder var list: () -> ListContent
    @ViewBuilder var detail: () -> DetailContent
    @State private var widths: [String: CGFloat] = [:]

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 740
            let listVisible = !compact || !showsDetail
            let detailVisible = !compact || showsDetail
            let listWidth = widths["list"] ?? GroveStyle.listWidth
            let detailWidth = widths["detail"] ?? max(0, geometry.size.width - listWidth)
            HSplitView {
                Color.clear
                    .frame(minWidth: compact ? 0 : 280, idealWidth: GroveStyle.listWidth,
                           maxWidth: compact ? .infinity : min(420, geometry.size.width * 0.45))
                    .background {
                        GeometryReader { pane in
                            Color.clear.preference(key: GrovePaneWidthKey.self, value: ["list": pane.size.width])
                        }
                    }
                Color.clear.frame(minWidth: compact ? 0 : 380, maxWidth: .infinity)
                    .background {
                        GeometryReader { pane in
                            Color.clear.preference(key: GrovePaneWidthKey.self, value: ["detail": pane.size.width])
                        }
                    }
            }
            .opacity(compact ? 0 : 1)
            .disabled(compact)
            .accessibilityHidden(compact)
            .overlay(alignment: .leading) {
                list()
                    .frame(width: compact ? geometry.size.width : listWidth, height: geometry.size.height)
                    .clipped()
                    .opacity(listVisible ? 1 : 0)
                    .allowsHitTesting(listVisible)
                    .disabled(!listVisible)
                    .accessibilityHidden(!listVisible)
            }
            .overlay(alignment: .trailing) {
                detail()
                    .frame(width: compact ? geometry.size.width : detailWidth,
                           height: geometry.size.height)
                    .clipped()
                    .opacity(detailVisible ? 1 : 0)
                    .allowsHitTesting(detailVisible)
                    .disabled(!detailVisible)
                    .accessibilityHidden(!detailVisible)
            }
            .onPreferenceChange(GrovePaneWidthKey.self) { value in
                widths = value
            }
        }
    }
}

private struct GrovePaneWidthKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
