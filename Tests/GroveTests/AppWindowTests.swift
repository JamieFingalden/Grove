import AppKit
import XCTest
@testable import Grove

@MainActor
final class AppWindowTests: XCTestCase {
    func testDockReopenTargetsMainSceneAndStopsDefaultWindowSelection() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        var opened = 0
        delegate.openMainWindow = { opened += 1 }

        XCTAssertTrue(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true))
        XCTAssertEqual(opened, 0, "已有可见窗口时不应额外打开主窗口")

        XCTAssertFalse(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false),
                       "主动打开主窗口后必须阻止系统再次选择设置等其他窗口")
        XCTAssertEqual(opened, 1, "关闭窗口后从 Dock 重开必须调用主场景入口")

        delegate.showMainWindow()
        XCTAssertEqual(opened, 2, "通知入口必须复用同一个主窗口恢复逻辑")

        delegate.openMainWindow = nil
        XCTAssertTrue(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false),
                      "主场景尚未就绪时交给系统处理，不遍历任意可聚焦窗口")
    }
}
