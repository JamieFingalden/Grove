import AppKit
import SwiftUI
import XCTest
@testable import Grove

final class GroveSymbolsTests: XCTestCase {
    @MainActor
    func testPullRequestBadgeExposesStatusToAccessibility() throws {
        let request = PullRequest(number: 42, title: "测试请求", state: "OPEN", isDraft: false,
            headRefName: "feature", baseRefName: "main", url: "u", author: nil, updatedAt: Date(),
            additions: 0, deletions: 0, changedFiles: 0, isCrossRepository: false, labels: [])
        let hosting = NSHostingView(rootView: VStack {
            GroveSymbolView(.pullRequest(status: .open)).accessibilityLabel("装饰图标")
            PullRequestBadge(pullRequest: request)
        }.padding(20).environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        func labels(_ element: Any) -> [String] {
            guard let accessible = element as? NSObject else { return [] }
            let labelSelector = NSSelectorFromString("accessibilityLabel")
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            let label = accessible.responds(to: labelSelector)
                ? accessible.perform(labelSelector)?.takeUnretainedValue() as? String : nil
            let children = accessible.responds(to: childrenSelector)
                ? accessible.perform(childrenSelector)?.takeUnretainedValue() as? [Any] : nil
            return [label].compactMap { $0 } + (children ?? []).flatMap { labels($0) }
        }
        let accessibleLabels = labels(hosting)
        XCTAssertFalse(accessibleLabels.contains("装饰图标"), "装饰图标不能重复朗读状态")
        XCTAssertTrue(accessibleLabels.contains { $0.contains("PR #42") && $0.contains(request.status.label) },
                      "屏幕阅读器必须能读取 PR 编号和状态，实际标签：\(accessibleLabels)")
    }

    func testSymbolSizesAndStrokes() {
        XCTAssertEqual(GroveSymbolSize.xs.pointSize, 12)
        XCTAssertEqual(GroveSymbolSize.small.pointSize, 14)
        XCTAssertEqual(GroveSymbolSize.medium.pointSize, 16)
        XCTAssertEqual(GroveSymbolSize.large.pointSize, 20)

        XCTAssertEqual(GroveSymbolSize.xs.strokeWidth, 1.15)
        XCTAssertEqual(GroveSymbolSize.small.strokeWidth, 1.25)
        XCTAssertEqual(GroveSymbolSize.medium.strokeWidth, 1.35)
        XCTAssertEqual(GroveSymbolSize.large.strokeWidth, 1.60)
    }

    func testRebaseOperationDisambiguation() {
        // 核心验证：变基图标必须是 arrow.triangle.swap，不能与 branch 的 arrow.triangle.branch 冲突
        XCTAssertEqual(RepositoryOperation.rebase.systemImage, "arrow.triangle.swap")
        XCTAssertEqual(RepositoryOperation.merge.systemImage, "arrow.triangle.merge")
        XCTAssertNotEqual(RepositoryOperation.rebase.systemImage, "arrow.triangle.branch")
    }

    func testWorktreeGlyphPaths() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)

        let primaryShape = WorktreeGlyphShape(isPrimary: true)
        let primaryPath = primaryShape.path(in: rect)
        XCTAssertFalse(primaryPath.isEmpty, "主工作树矢量路径不应为空")

        let linkedShape = WorktreeGlyphShape(isPrimary: false)
        let linkedPath = linkedShape.path(in: rect)
        XCTAssertFalse(linkedPath.isEmpty, "派生工作树矢量路径不应为空")

        let bareShape = WorktreeGlyphShape(isPrimary: false, isBare: true)
        let barePath = bareShape.path(in: rect)
        XCTAssertFalse(barePath.isEmpty, "Bare 仓库矢量路径不应为空")
    }

    @MainActor
    func testGroveSymbolViewRendersAllCases() {
        let symbols: [GroveSymbol] = [
            .repository,
            .worktree(isPrimary: true, isBare: false),
            .worktree(isPrimary: false, isBare: false),
            .worktree(isPrimary: false, isBare: true),
            .branch,
            .remoteServer,
            .pull,
            .push,
            .fetch,
            .rebase,
            .merge,
            .tag,
            .commit,
            .stage,
            .unstage,
            .pullRequest(status: .open),
            .pullRequest(status: .draft),
            .pullRequest(status: .merged),
            .pullRequest(status: .closed),
            .aiReview,
            .settings,
            .more,
            .copy,
            .external
        ]

        for symbol in symbols {
            let view = GroveSymbolView(symbol, size: .medium, role: .monochrome)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.frame.size.width, 16)
        }
    }

    func testPullPushSymbolsAvailability() {
        // 验证拉取与推送使用配对的 compact 符号，准确表达与本地/远端基准线交互
        let pullImg = NSImage(systemSymbolName: "arrow.down.to.line.compact", accessibilityDescription: nil)
        let pushImg = NSImage(systemSymbolName: "arrow.up.to.line.compact", accessibilityDescription: nil)
        XCTAssertNotNil(pullImg, "arrow.down.to.line.compact 必须在系统中可用")
        XCTAssertNotNil(pushImg, "arrow.up.to.line.compact 必须在系统中可用")
    }
}
