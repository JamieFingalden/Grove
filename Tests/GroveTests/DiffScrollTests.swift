import AppKit
import SwiftUI
import XCTest
@testable import Grove

@MainActor
final class DiffScrollTests: XCTestCase {
    func testScrollRangeTracksVisibleCode() throws {
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
        // 同时覆盖历史页的独立面板和合并请求里嵌套在纵向滚动容器中的面板。
        for nested in [false, true] {
            let diff = DiffContentView(files: files, showsFileHeaders: true)
                .frame(width: 420, height: 240)
            let root = nested
                ? AnyView(ScrollView { diff.frame(width: 600, height: 400) })
                : AnyView(diff)
            try checkScrollRange(root: root, longLine: longLine)
        }
    }

    private func checkScrollRange(root: AnyView, longLine: String) throws {
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let scrollView = try XCTUnwrap(descendants(of: hosting)
            .compactMap { $0 as? NSScrollView }.first(where: \.hasHorizontalScroller))
        let documentView = try XCTUnwrap(scrollView.documentView)
        let renderedLine = try XCTUnwrap(descendants(of: documentView)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == longLine })
        let renderedLineRightEdge = renderedLine.convert(renderedLine.bounds, to: documentView).maxX
        XCTAssertEqual(documentView.frame.width, scrollView.contentView.bounds.width, accuracy: 0.5,
                       "离屏长行不能为当前短代码制造多余的横向滚动范围")

        let longLineY = renderedLine.convert(renderedLine.bounds, to: documentView).midY
            - scrollView.contentView.bounds.height / 2
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: longLineY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        // 长行进入视口时，按真实渲染宽度扩展滚动范围，保留少量行尾留白。
        XCTAssertGreaterThanOrEqual(documentView.frame.width, renderedLineRightEdge + 20)
        XCTAssertLessThanOrEqual(documentView.frame.width, renderedLineRightEdge + 26)

        // 范围内的左右和斜向滚动必须保留用户位置，不能在稍后自动回跳。
        for origin in [NSPoint(x: 180, y: longLineY), NSPoint(x: 80, y: longLineY),
                       NSPoint(x: 180, y: longLineY + 15)] {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            XCTAssertEqual(scrollView.contentView.bounds.minX, origin.x, accuracy: 0.5, "横向滚动位置不能自动回跳")
        }

        // 长行进入视口后，必须能看到行尾，轻微上下移动也不能把它拉回左侧。
        let maximumX = documentView.frame.width - scrollView.contentView.bounds.width
        scrollView.contentView.scroll(to: NSPoint(x: maximumX, y: longLineY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        scrollView.contentView.scroll(to: NSPoint(x: maximumX, y: longLineY + 15))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(scrollView.contentView.bounds.minX, maximumX, accuracy: 0.5, "查看长行时必须保持行尾可见")

        scrollView.contentView.scroll(to: NSPoint(
            x: scrollView.contentView.bounds.minX,
            y: documentView.frame.height - scrollView.contentView.bounds.height
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(documentView.frame.width, scrollView.contentView.bounds.width, accuracy: 0.5,
                       "离开长行后必须收回多余的横向滚动范围")
        XCTAssertEqual(scrollView.contentView.bounds.minX, 0, accuracy: 0.5,
                       "回到短行后，原生滚动边界应让代码保持可见")

        let trailingLine = try XCTUnwrap(descendants(of: documentView)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "let trailingValue120 = 120" })
        let clipFrame = scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
        let trailingFrame = trailingLine.convert(trailingLine.bounds, to: nil)
        XCTAssertGreaterThan(trailingFrame.maxX, clipFrame.minX, "滚到右下角后当前短代码不能全部消失")
        XCTAssertLessThan(trailingFrame.minX, clipFrame.maxX, "当前短代码必须仍与视口相交")
        XCTAssertTrue(trailingFrame.intersects(clipFrame), "短代码必须在实际视口内可见")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
