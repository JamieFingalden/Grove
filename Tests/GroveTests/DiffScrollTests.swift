import AppKit
import SwiftUI
import XCTest
@testable import Grove

@MainActor
final class DiffScrollTests: XCTestCase {
    func testLongLineExpandsHorizontalScrollRange() throws {
        let longLine = String(repeating: "very_long_code_", count: 30)
        let shortLines = (1...120).map { "+let value\($0) = \($0)" }.joined(separator: "\n")
        let files = DiffParser.parse("""
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -0,0 +1,121 @@
        \(shortLines)
        +\(longLine)
        """)
        let hosting = NSHostingView(rootView: DiffContentView(files: files))
        hosting.frame = CGRect(x: 0, y: 0, width: 420, height: 240)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let scrollView = try XCTUnwrap(descendants(of: hosting).compactMap { $0 as? NSScrollView }.first)
        let documentWidth = try XCTUnwrap(scrollView.documentView).frame.width
        let expectedCodeWidth = ceil((longLine as NSString).size(
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)]
        ).width)
        XCTAssertGreaterThanOrEqual(
            documentWidth,
            expectedCodeWidth + 132,
            "横向范围必须覆盖视口外的最长代码行、行号栏和右侧留白"
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
