import SwiftUI

/// 讨论卡片共用原始 diff 上下文，过期意见不能借用最新代码冒充原文。
extension ReviewThread {
    func excerpt(in files: [FileDiff]) -> [DiffLine] {
        guard let filePath else { return [] }
        let hunks: [DiffHunk]
        if let diffHunk, !diffHunk.isEmpty {
            hunks = DiffParser.parse("diff --git a/\(filePath) b/\(filePath)\n--- a/\(filePath)\n+++ b/\(filePath)\n\(diffHunk)\n").flatMap(\.hunks)
        } else if !isOutdated {
            hunks = files.first { $0.newPath == filePath || $0.oldPath == filePath }?.hunks ?? []
        } else { return [] }
        for hunk in hunks {
            if let index = hunk.lines.firstIndex(where: { (isOldSide ? $0.oldNumber : $0.newNumber) == line }) {
                return Array(hunk.lines[max(0, index - 2)...min(hunk.lines.count - 1, index + 2)])
            }
        }
        return []
    }
}

struct ReviewThreadView: View {
    let thread: ReviewThread
    var files: [FileDiff] = []
    var replyLabel = "回复"
    var onReply: ((String) async -> Bool)?
    var onResolve: (() async -> Void)?
    var onLocate: (() -> Void)?
    @State private var showsReply = false
    @State private var replyText = ""
    @State private var isWorking = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let filePath = thread.filePath {
                HStack(spacing: 7) {
                    Button { onLocate?() } label: {
                        Label(filePath + (thread.line.map { ":\($0)" } ?? ""), systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .disabled(onLocate == nil || thread.isOutdated)
                    Spacer(minLength: 0)
                    if thread.isOutdated { Text("已过期").foregroundStyle(.secondary).font(.caption) }
                    if thread.isResolved { Label("已解决", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                }
            }

            if thread.isResolved && !isExpanded {
                Text(AIReviewAutomation.visibleBody(thread.firstNote?.body ?? ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Button("展开讨论（\(thread.notes.count) 条）") { isExpanded = true }
                    .buttonStyle(.borderless).font(.caption)
            } else {
                let excerpt = thread.excerpt(in: files)
                if !excerpt.isEmpty { ReviewCodeExcerpt(lines: excerpt, selectedLine: thread.line, isOldSide: thread.isOldSide) }
                ForEach(thread.notes.filter { !$0.isSystem }) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                            Text(note.authorName).fontWeight(.semibold)
                            Spacer()
                            if let date = note.createdAt { Text(RelativeDate.format(date)).foregroundStyle(.tertiary) }
                        }
                        .font(.system(size: 11))
                        ReviewMarkdownView(text: AIReviewAutomation.visibleBody(note.body))
                    }
                    if note.id != thread.notes.last?.id { Divider() }
                }
                HStack(spacing: 14) {
                    if onReply != nil {
                        Button { showsReply.toggle() } label: { Label(replyLabel, systemImage: "arrowshape.turn.up.left") }
                    }
                    if thread.isResolvable && onResolve != nil {
                        Button { Task { isWorking = true; await onResolve?(); isWorking = false } } label: {
                            Label(thread.isResolved ? "重新打开" : "解决讨论", systemImage: thread.isResolved ? "arrow.uturn.backward" : "checkmark")
                        }
                        .disabled(!thread.canResolve)
                    }
                    if thread.isResolved { Button("收起") { isExpanded = false } }
                    Spacer()
                    if isWorking { ProgressView().controlSize(.mini) }
                }
                .buttonStyle(.borderless).font(.system(size: 11)).disabled(isWorking)
                if showsReply {
                    TextEditor(text: $replyText).font(.system(size: 12)).frame(height: 74)
                        .padding(6).overlay { RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5) }
                        .disabled(isWorking)
                    HStack {
                        Button("取消") { showsReply = false }
                        Spacer()
                        Button("发送回复") {
                            Task {
                                isWorking = true
                                if await onReply?(replyText) == true { replyText = ""; showsReply = false }
                                isWorking = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .disabled(isWorking)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5) }
    }
}

struct ReviewCodeExcerpt: View {
    var lines: [DiffLine]
    var selectedLine: Int?
    var isOldSide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HStack(alignment: .top, spacing: 10) {
                    Text((isOldSide ? line.oldNumber : line.newNumber).map(String.init) ?? "")
                        .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                    Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ")
                    Text(line.text.isEmpty ? " " : line.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(line.kind == .addition ? Color.green.opacity(0.1) : line.kind == .deletion ? Color.red.opacity(0.1) : Color.clear)
                .overlay(alignment: .leading) {
                    if (isOldSide ? line.oldNumber : line.newNumber) == selectedLine {
                        Rectangle().fill(Color.accentColor).frame(width: 3)
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// ponytail: 原生轻量 Markdown 只处理标题、列表、引用和代码围栏；复杂表格仍可在浏览器查看，后续可换完整渲染器。
struct ReviewMarkdownView: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.code {
                    Text(block.text).font(.system(size: 11, design: .monospaced))
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(.init(block.text))
                        .font(.system(size: block.heading ? 15 : 12, weight: block.heading ? .semibold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [(text: String, code: Bool, heading: Bool)] {
        var result: [(String, Bool, Bool)] = []
        var code: [String]? = nil
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if let lines = code { result.append((lines.joined(separator: "\n"), true, false)); code = nil }
                else { code = [] }
            } else if code != nil { code?.append(line) }
            else if line.hasPrefix("#") {
                result.append((String(line.drop(while: { $0 == "#" || $0 == " " })), false, true))
            } else {
                let content = line.hasPrefix("- ") || line.hasPrefix("* ") ? "• " + line.dropFirst(2) : line
                result.append((content.isEmpty ? " " : content, false, false))
            }
        }
        if let code { result.append((code.joined(separator: "\n"), true, false)) }
        return result
    }
}
