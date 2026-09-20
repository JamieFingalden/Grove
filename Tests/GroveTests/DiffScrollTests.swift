import SwiftUI
import XCTest
@testable import Grove

/// DiffContentView 的横向宽度现在靠等宽字体估算（一次性算好），
/// 不再逐行测量 —— 那套机制在大 diff 下每帧收集上千个 preference，滚动直接掉帧。
/// 这里锁定估算器的行为契约。
final class DiffWidthEstimatorTests: XCTestCase {
    func testWidthCoversTheLongestLine() {
        let longLine = String(repeating: "very_long_code_", count: 30)
        let files = DiffParser.parse("""
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -0,0 +1,3 @@
        +let short = 1
        +\(longLine)
        +let another = 2
        """)

        let width = DiffContentView.estimatedWidth(for: files)
        let expectedUnits = DiffContentView.displayUnits(longLine)

        // 估算宽度必须容得下最长行，同时不能离谱地超宽。
        XCTAssertGreaterThanOrEqual(width, CGFloat(expectedUnits) * 6.5)
        XCTAssertLessThanOrEqual(width, CGFloat(expectedUnits) * 7 + 200)
    }

    func testWidthIsMonotonicAcrossLineCount() {
        let small = DiffParser.parse("""
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -0,0 +1,2 @@
        +one
        +two
        """)
        let manyShortLines = DiffParser.parse("""
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -0,0 +1,100 @@
        \(Array(repeating: "+line", count: 100).joined(separator: "\n"))
        """)

        // 行数多不应急剧改变宽度：估算只看最长行，这正是去掉逐行测量后
        // 滚动范围不再抖动的原因。
        XCTAssertEqual(
            DiffContentView.estimatedWidth(for: small),
            DiffContentView.estimatedWidth(for: manyShortLines),
            accuracy: 0.5
        )
    }

    func testDisplayUnitsCountsWideCharactersAndTabs() {
        XCTAssertEqual(DiffContentView.displayUnits("hello"), 5)
        XCTAssertEqual(DiffContentView.displayUnits("中文"), 4)          // 全角算 2
        XCTAssertEqual(DiffContentView.displayUnits("\t\tx"), 17)       // tab 按 8 列
        XCTAssertEqual(DiffContentView.displayUnits("func 中文()"), 5 + 4 + 2)
    }
}
