import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Grove

@MainActor
final class RetainedPageTests: XCTestCase {
    func testInactivePagesDoNotHandleCommitShortcutOrKeepInputFocus() async throws {
        let state = PageState()
        let hosting = NSHostingView(rootView: Pages(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.orderOut(nil); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        await settle(hosting)
        let editor = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSTextView }
            .first { $0.string == state.drafts[0] })
        XCTAssertTrue(window.makeFirstResponder(editor))
        await settle(hosting)
        XCTAssertTrue(window.firstResponder === editor)
        let shortcut = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(hosting.performKeyEquivalent(with: shortcut))
        XCTAssertEqual(state.commits, [1, 0])

        state.page = 1
        await settle(hosting)
        _ = hosting.performKeyEquivalent(with: shortcut)
        XCTAssertEqual(state.commits, [1, 0], "全局页面不能触发隐藏工作树的提交快捷键")
        XCTAssertFalse(window.firstResponder === editor, "隐藏页面必须释放文本输入焦点")

        state.page = 2
        await settle(hosting)
        XCTAssertTrue(hosting.performKeyEquivalent(with: shortcut))
        XCTAssertEqual(state.commits, [1, 1], "只能提交当前可见的工作树")
        let secondEditor = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSTextView }
            .first { $0.string == state.drafts[1] })
        XCTAssertTrue(window.makeFirstResponder(secondEditor))
        state.history = true
        await settle(hosting)
        XCTAssertTrue(window.firstResponder === secondEditor, "隐藏页面的分栏更新不能抢走当前页面焦点")

        state.page = 0
        state.history = false
        await settle(hosting)
        XCTAssertTrue(window.makeFirstResponder(editor))
        await settle(hosting)
        state.history = true
        await settle(hosting)
        _ = hosting.performKeyEquivalent(with: shortcut)
        XCTAssertEqual(state.commits, [1, 1], "History 后方保留的 Changes 页面也必须禁用")
        XCTAssertFalse(window.firstResponder === editor, "子页面隐藏时也必须释放输入焦点")

        state.history = false
        await settle(hosting)
        XCTAssertTrue(hosting.performKeyEquivalent(with: shortcut))
        XCTAssertEqual(state.commits, [2, 1], "返回 Changes 后快捷键应恢复")
        XCTAssertEqual(state.drafts, ["未提交的草稿", "另一个工作树"], "禁用页面不能清空输入")
        XCTAssertEqual(state.appearances, [1, 1], "切页不能重建已有工作树视图")
    }

    private func settle(_ hosting: NSView) async {
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @Observable fileprivate final class PageState {
        var page = 0
        var history = false
        var drafts = ["未提交的草稿", "另一个工作树"]
        var commits = [0, 0]
        var appearances = [0, 0]
    }

    private struct Pages: View {
        @Bindable var state: PageState

        var body: some View {
            ZStack {
                ZStack {
                    CommitPage(state: state, index: 0).retainedPage(!state.history)
                    Text("History").retainedPage(state.history)
                }
                .retainedPage(state.page == 0)
                Text("Daily / Workspace").retainedPage(state.page == 1)
                CommitPage(state: state, index: 1).retainedPage(state.page == 2)
            }
        }
    }

    private struct CommitPage: View {
        @Bindable var state: PageState
        @FocusState private var focused: Bool
        let index: Int

        var body: some View {
            VStack {
                TextEditor(text: $state.drafts[index])
                    .focused($focused)
                Button("提交") { state.commits[index] += 1 }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .onAppear { state.appearances[index] += 1 }
        }
    }
}
