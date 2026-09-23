import SwiftUI
import AppKit

/// 轻量代码编辑器：改个参数值、手写冲突的第三种解法，这些小事不值得开一个 IDE。
///
/// 定位是「顺手改两下」，不是替代编辑器：语法着色共享 diff 那套规则，
/// 字号共享 diff 的阅读设置（A−/A+ 调过这里跟着变），输入停顿半秒后重排着色。
struct CodeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 和 diff 面板共用一份字号设置。
    @AppStorage(DiffReading.fontSizeKey) private var fontSize = DiffReading.defaultFontSize

    /// 工作区里的目标文件。
    let url: URL
    /// 展示用（也是语法着色依据）的相对路径。
    let displayPath: String
    /// 保存后刷新状态用；冲突文件的「标记为已解决」也靠它。
    var model: WorktreeModel?
    /// 从冲突区打开时非 nil —— 底栏会提供「保存并标记为已解决」和冲突标记计数。
    var conflictedChange: FileChange?

    @State private var attributed: NSAttributedString = NSAttributedString()
    @State private var originalText: String = ""
    @State private var currentText: String = ""
    @State private var highlightVersion = 0
    @State private var isDirty = false
    @State private var isBinary = false
    @State private var readFailure: String?
    @State private var saveFailure: String?
    @State private var loadedModificationDate: Date?
    @State private var showsOverwriteConfirmation = false
    @State private var showsUnsavedConfirmation = false
    @State private var showsReloadConfirmation = false
    @State private var showsResolveConfirmation = false
    @State private var rehighlightTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if let readFailure {
                    ContentUnavailableView {
                        Label("无法打开这个文件", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(readFailure)
                    }
                } else if isBinary {
                    ContentUnavailableView {
                        Label("二进制文件", systemImage: "doc.badge.gearshape")
                    } description: {
                        Text("二进制内容不适合在文本编辑器里修改，请用专门的工具处理。")
                    }
                } else if let saveFailure {
                    ContentUnavailableView {
                        Label("保存失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(saveFailure)
                    }
                    Button("重试保存") { Task { await save() } }
                } else {
                    SyntaxTextView(
                        attributed: attributed,
                        font: editorFont,
                        version: highlightVersion,
                        onTextChange: handleTextChange(_:)
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            bottomBar
        }
        .frame(minWidth: 620, idealWidth: 840, minHeight: 460, idealHeight: 640)
        .onAppear(perform: load)
        // 有未保存改动时不允许误关：Esc / 点外面都不行，必须走底栏按钮。
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog("文件在磁盘上被改过", isPresented: $showsOverwriteConfirmation) {
            Button("覆盖保存") { Task { await write() } }
            Button("放弃我的修改，重新加载") { load() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("打开之后有别的工具改过「\(url.lastPathComponent)」。覆盖会丢掉那边的新改动；重新加载会丢掉你在这里改的内容。")
        }
        .confirmationDialog("有未保存的修改", isPresented: $showsUnsavedConfirmation) {
            Button("不保存并关闭", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("刚才的改动还没保存。")
        }
        .confirmationDialog("还有冲突标记", isPresented: $showsResolveConfirmation) {
            Button("就这样标记为已解决") { Task { await markResolved() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("文件里还剩 \(remainingMarkerCount) 处 \(conflictMarkerText) 标记。带着标记标记为已解决，容易把「<<<<<<<」提交出去。")
        }
        .confirmationDialog("放弃这里的修改？", isPresented: $showsReloadConfirmation) {
            Button("放弃修改并重新加载", role: .destructive) { load() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重新加载会用磁盘上的内容覆盖你刚才的改动。")
        }
    }

    // MARK: - 头尾

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text((displayPath as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                Text(displayPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(displayPath)
            }

            if isDirty {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                    .help("有未保存的修改")
            }

            Spacer(minLength: 8)

            Text("\(lineCount) 行 · \(currentText.count) 字符")
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            if conflictedChange != nil {
                Text(remainingMarkerCount > 0 ? "剩 \(remainingMarkerCount) 处冲突" : "冲突标记已清空")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(remainingMarkerCount > 0 ? Color.orange : Color.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (remainingMarkerCount > 0 ? Color.orange : Color.green).opacity(0.12),
                        in: Capsule()
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button("重新加载") {
                if isDirty {
                    showsReloadConfirmation = true
                } else {
                    load()
                }
            }
            .disabled(isBinary || readFailure != nil)

            Spacer()

            if conflictedChange != nil {
                Button("保存并标记为已解决…") {
                    Task {
                        guard await save() else { return }
                        if remainingMarkerCount > 0 {
                            showsResolveConfirmation = true
                        } else {
                            await markResolved()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Button("保存") {
                Task { await save() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!isDirty)
            .buttonStyle(.bordered)

            Button("完成") {
                if isDirty {
                    showsUnsavedConfirmation = true
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .labelStyle(.titleAndIcon)
    }

    // MARK: - 逻辑

    private var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    private var lineCount: Int {
        currentText.components(separatedBy: .newlines).count
    }

    private let conflictMarkerText = "<<<<<<<"

    /// 工作区文本里还剩几个冲突块。清零之前不让轻易「标记为已解决」——
    /// 带着标记提交是冲突解决里最常见的事故。
    private var remainingMarkerCount: Int {
        Self.conflictMarkerCount(in: currentText)
    }

    /// 以行首 `<<<<<<<` 的数量计。带前导空白的的伪标记（字符串字面量里
    /// 出现等）不算，避免误拦。
    static func conflictMarkerCount(in text: String) -> Int {
        text.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("<<<<<<<") }
            .count
    }

    private func load() {
        do {
            let data = try Data(contentsOf: url)
            // 和 git 判定二进制同思路：前 8KB 里出现 NUL 就不当文本处理。
            if data.prefix(8192).contains(0) {
                isBinary = true
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                readFailure = "不是 UTF-8 编码的文本文件。为避免改坏内容，Grove 只编辑 UTF-8 文件。"
                return
            }
            originalText = text
            currentText = text
            attributed = Self.highlighted(text, path: displayPath, font: editorFont)
            highlightVersion += 1
            isDirty = false
            loadedModificationDate = modificationDate()
        } catch {
            readFailure = error.localizedDescription
        }
    }

    /// 保存。磁盘版本被外部工具改过时先问一句，返回 false 表示这次没写成。
    @discardableResult
    private func save() async -> Bool {
        guard isDirty else { return true }
        if let loaded = loadedModificationDate,
           let current = modificationDate(),
           current > loaded {
            showsOverwriteConfirmation = true
            return false
        }
        return await write()
    }

    @discardableResult
    private func write() async -> Bool {
        do {
            try currentText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            saveFailure = error.localizedDescription
            return false
        }
        loadedModificationDate = modificationDate()
        originalText = currentText
        isDirty = false
        // 让 diff 和冲突区立刻反映这次编辑；失败不拦用户，状态栏会自己刷新。
        if model != nil {
            await model?.refreshStatus()
            if conflictedChange != nil {
                await model?.reloadConflictContent()
            }
        }
        return true
    }

    private func markResolved() async {
        guard let change = conflictedChange else { return }
        await model?.markConflictResolved(change)
        dismiss()
    }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func handleTextChange(_ new: String) {
        currentText = new
        isDirty = new != originalText

        // 停顿半秒再重排语法颜色：边打边刷会闪，也没必要。
        rehighlightTask?.cancel()
        rehighlightTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // 超大文件编辑期间不重排（开销大、收益小），保存不受影响。
            guard new.utf16.count <= 300_000 else { return }
            attributed = Self.highlighted(new, path: displayPath, font: editorFont)
            highlightVersion += 1
        }
    }

    /// 语法着色（共享 diff 的规则）+ 统一的等宽字体。
    ///
    /// 不能走 `NSAttributedString(AttributedString)` 自动转换：它会直接丢掉
    /// SwiftUI Color 的前景色（实测 attribute 为 NONE），必须逐 run 换成 NSColor。
    private static func highlighted(_ text: String, path: String, font: NSFont) -> NSAttributedString {
        let swift = CodeSyntax.attributed(text, path: path)
        let result = NSMutableAttributedString(string: text)
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        for run in swift.runs {
            guard let color = run.foregroundColor else { continue }
            let nsRange = NSRange(run.range, in: swift)
            result.addAttribute(.foregroundColor, value: NSColor(color), range: nsRange)
        }
        return result
    }
}

// MARK: - NSTextView 包装

/// 直接包 NSTextView：SwiftUI 的 TextEditor 只吃纯文本，上不了语法着色。
private struct SyntaxTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    let font: NSFont
    /// 内容版本号：只有它变了才把 attributed 写回视图，
    /// 避免 SwiftUI 每次刷新状态都重置正在输入的文本。
    let version: Int
    let onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = true
        // 折行，不横滚 —— 和 diff 的流式布局同一个哲学：内容永远不宽过窗口。
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.drawsBackground = true

        let textStorage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer()
        container.widthTracksTextView = true
        container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        textStorage.addLayoutManager(layoutManager)

        let textView = EditorTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // 垂直方向不限长：文本可以一直长，长过可视区滚动条才有意义。
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        applyFont(textView)

        // 代码编辑的卫生设置：不自动替换引号/破折号、不检测链接 ——
        // 这些「智能」行为会悄悄把代码改坏，还很难发现。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        // ⌘F 用系统查找栏。
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        context.coordinator.appliedVersion = version
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        context.coordinator.parent = self
        if font != textView.font {
            applyFont(textView)
        }
        guard version != context.coordinator.appliedVersion else { return }
        context.coordinator.appliedVersion = version
        // 换内容时保住选区和可视位置，别把用户正在看的地方跳走。
        let selected = textView.selectedRanges
        let visible = textView.visibleRect
        textView.textStorage?.setAttributedString(attributed)
        textView.selectedRanges = selected
        textView.scrollToVisible(visible)
        // 重排后的内容高度可能变了（折行重算），让滚动视图重新钉高度。
        scrollView.needsLayout = true
    }

    private func applyFont(_ textView: NSTextView) {
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxTextView
        var appliedVersion: Int = -1

        init(parent: SyntaxTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // 让高度跟住输入（多出来的行撑开滚动范围）。不碰 didChangeText ——
            // 那是本类自身的回调入口，重入就是布局风暴。
            textView.enclosingScrollView?.needsLayout = true
            parent.onTextChange(textView.string)
        }
    }
}

/// 普通的 NSTextView，之后要挂自定义按键行为（比如 Tab 插入缩进）就在这里扩展。
final class EditorTextView: NSTextView {}

/// 会把文本视图宽度钉到可视宽度、高度钉到内容实际高度的滚动视图。
///
/// NSTextView 在滚动视图里「随内容长高」只在用户编辑时自动发生；
/// 程序化设置内容（加载文件、重排语法颜色）不会触发，文本视图会停在
 /// 可视高度 —— 表现为内容看得见但滚不动。
///
/// 高度直接从 layoutManager 的 usedRect 算，**不要用 `didChangeText()`**：
/// 它会派发 textDidChange 委托回调，接到 SwiftUI 的 onTextChange 上就是
/// 「state → 重渲染 → 布局 → didChangeText → state」的布局风暴，
/// 表现为输入停顿后代码抖一下。
final class EditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView,
              let container = textView.textContainer,
              let layoutManager = container.layoutManager else { return }

        let width = contentView.bounds.width
        if textView.frame.width != width {
            textView.frame = CGRect(
                x: 0,
                y: textView.frame.minY,
                width: width,
                height: textView.frame.height
            )
        }
        if abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }

        layoutManager.ensureLayout(for: container)
        let textHeight = layoutManager.usedRect(for: container).height
            + textView.textContainerInset.height * 2
        let needed = max(textHeight, contentView.bounds.height)
        if abs(textView.frame.height - needed) > 0.5 {
            textView.frame.size.height = needed
        }
    }
}
