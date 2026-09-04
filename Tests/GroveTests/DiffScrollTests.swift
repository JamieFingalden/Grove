import AppKit
import SwiftUI
import XCTest
@testable import Grove

@MainActor
final class DiffScrollTests: XCTestCase {
    func testLongLineExpandsHorizontalScrollRange() throws {
        let longLine = String(repeating: "very_long_code_", count: 30)
        let leadingLines = (1...60).map { "+let leadingValue\($0) = \($0)" }.joined(separator: "\n")
        let trailingLines = (1...120).map { "+let trailingValue\($0) = \($0)" }.joined(separator: "\n")
        let files = DiffParser.parse("""
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -0,0 +1,181 @@
        \(leadingLines)
        +\(longLine)
        \(trailingLines)
        """)
        // 历史页不能让离屏 hunk 的超长行永久撑宽整个文档，否则用户滚到
        // 后面的短行时，横向滚动位置仍在最右侧，当前代码会全部消失。
        let hosting = NSHostingView(rootView: DiffContentView(files: files, showsFileHeaders: true))
        hosting.frame = CGRect(x: 0, y: 0, width: 420, height: 240)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let scrollView = try XCTUnwrap(descendants(of: hosting).compactMap { $0 as? NSScrollView }.first)
        let documentView = try XCTUnwrap(scrollView.documentView)
        let renderedLine = try XCTUnwrap(descendants(of: documentView)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == longLine })
        let renderedLineRightEdge = renderedLine.convert(renderedLine.bounds, to: documentView).maxX
        XCTAssertGreaterThanOrEqual(documentView.frame.width, renderedLineRightEdge + 20)
        XCTAssertLessThanOrEqual(documentView.frame.width, renderedLineRightEdge + 26)

        scrollView.contentView.scroll(to: NSPoint(x: documentView.frame.width, y: documentView.frame.height))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        let trailingLine = try XCTUnwrap(descendants(of: documentView)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "let trailingValue120 = 120" })
        let clipFrame = scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
        let trailingFrame = trailingLine.convert(trailingLine.bounds, to: nil)
        XCTAssertGreaterThan(trailingFrame.maxX, clipFrame.minX, "滚到右下角后当前短代码不能全部消失")
        XCTAssertLessThan(trailingFrame.minX, clipFrame.maxX, "当前短代码必须仍与视口相交")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
