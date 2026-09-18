import XCTest
@testable import Grove

/// 冲突标记的解析与回写。纯函数，不碰 git。
final class ConflictParserTests: XCTestCase {
    private let sample = """
    line1
    <<<<<<< HEAD
    MAIN
    =======
    FEATURE
    >>>>>>> feature
    line3

    """

    func testParsesTwoWayBlock() {
        let document = ConflictParser.parse(sample)

        XCTAssertEqual(document.segments.count, 3)
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertTrue(document.endsWithNewline)

        let block = document.blocks[0]
        XCTAssertEqual(block.id, 1)
        XCTAssertEqual(block.oursLabel, "HEAD")
        XCTAssertEqual(block.theirsLabel, "feature")
        XCTAssertEqual(block.ours, ["MAIN"])
        XCTAssertEqual(block.theirs, ["FEATURE"])
        XCTAssertNil(block.baseMarker)

        guard case .text(let head) = document.segments[0], case .text(let tail) = document.segments[2] else {
            XCTFail("首尾应该是普通文本"); return
        }
        XCTAssertEqual(head, ["line1"])
        XCTAssertEqual(tail, ["line3"])
    }

    func testRenderingWithoutChoicesReproducesTheInputExactly() {
        // 没做选择就写盘时，文件必须一个字节都不变 —— 否则「撤销」会留下痕迹。
        let document = ConflictParser.parse(sample)
        XCTAssertEqual(document.rendered(with: [:]), sample)
    }

    func testEachResolutionRendersTheRightLines() {
        let document = ConflictParser.parse(sample)
        let block = document.blocks[0]

        XCTAssertEqual(document.rendered(with: [block.id: .ours]), "line1\nMAIN\nline3\n")
        XCTAssertEqual(document.rendered(with: [block.id: .theirs]), "line1\nFEATURE\nline3\n")
        XCTAssertEqual(document.rendered(with: [block.id: .both]), "line1\nMAIN\nFEATURE\nline3\n")
        XCTAssertEqual(document.rendered(with: [block.id: .bothReversed]), "line1\nFEATURE\nMAIN\nline3\n")
    }

    func testParsesDiff3BaseSection() {
        let text = """
        <<<<<<< HEAD
        ours
        ||||||| d5bbdb3
        base
        =======
        theirs
        >>>>>>> feature

        """
        let document = ConflictParser.parse(text)
        XCTAssertEqual(document.blocks.count, 1)
        let block = document.blocks[0]
        XCTAssertEqual(block.base, ["base"])
        XCTAssertEqual(block.baseLabel, "d5bbdb3")
        // 共同祖先只是参考，任何选择都不该把它写进结果。
        XCTAssertEqual(document.rendered(with: [1: .both]), "ours\ntheirs\n")
        XCTAssertEqual(document.rendered(with: [:]), text)
    }

    func testMultipleBlocksGetSequentialIDs() {
        let text = "<<<<<<< a\n1\n=======\n2\n>>>>>>> b\nmid\n<<<<<<< a\n3\n=======\n4\n>>>>>>> b\n"
        let document = ConflictParser.parse(text)
        XCTAssertEqual(document.blocks.map(\.id), [1, 2])
        XCTAssertEqual(document.rendered(with: [1: .ours, 2: .theirs]), "1\nmid\n4\n")
        // 只解决一个，另一个原样保留。
        XCTAssertEqual(document.rendered(with: [2: .theirs]), "<<<<<<< a\n1\n=======\n2\n>>>>>>> b\nmid\n4\n")
    }

    func testSeparatorOutsideABlockIsPlainText() {
        // Markdown 的 setext 标题下划线正好是一行等号，不在块里就不是分隔线。
        let text = "Title\n=======\nbody\n"
        let document = ConflictParser.parse(text)
        XCTAssertTrue(document.blocks.isEmpty)
        XCTAssertEqual(document.rendered(with: [:]), text)
    }

    func testMarkerLengthMustMatchTheOpeningMarker() {
        // 块里一行 10 个等号：长度跟开头的 7 个 `<` 对不上，是内容不是分隔线。
        let text = "<<<<<<< HEAD\na\n==========\nb\n=======\nc\n>>>>>>> other\n"
        let document = ConflictParser.parse(text)
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].ours, ["a", "==========", "b"])
        XCTAssertEqual(document.blocks[0].theirs, ["c"])
    }

    func testLongerMarkersFromConflictMarkerSizeAttribute() {
        let text = "<<<<<<<<<< HEAD\na\n==========\nb\n>>>>>>>>>> other\n"
        let document = ConflictParser.parse(text)
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].oursLabel, "HEAD")
        XCTAssertEqual(document.rendered(with: [1: .theirs]), "b\n")
    }

    func testUnterminatedBlockFallsBackToPlainText() {
        // 讲冲突的教程、测试样例里常有半截标记；读不完整就当普通文本，别把文件切坏。
        let text = "intro\n<<<<<<< HEAD\nno end here\n"
        let document = ConflictParser.parse(text)
        XCTAssertTrue(document.blocks.isEmpty)
        XCTAssertEqual(document.rendered(with: [:]), text)
    }

    func testNestedOpeningMarkerAbandonsTheOuterBlock() {
        let text = "<<<<<<< HEAD\na\n<<<<<<< inner\nb\n=======\nc\n>>>>>>> inner\n"
        let document = ConflictParser.parse(text)
        // 外层不完整，内层是完整的：只认内层。
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].oursLabel, "inner")
        XCTAssertEqual(document.rendered(with: [:]), text)
    }

    func testPreservesCRLFAndMissingTrailingNewline() {
        // CRLF 文件的 \r 是内容的一部分；文件没有末尾换行也不能被补上。
        let text = "a\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> x\r\nz"
        let document = ConflictParser.parse(text)
        XCTAssertFalse(document.endsWithNewline)
        XCTAssertEqual(document.blocks[0].oursLabel, "HEAD")
        XCTAssertEqual(document.blocks[0].theirsLabel, "x")
        XCTAssertEqual(document.rendered(with: [:]), text)
        XCTAssertEqual(document.rendered(with: [1: .theirs]), "a\r\ntheirs\r\nz")
    }

    func testEmptySideMeansDeletion() {
        // 一侧删掉了这几行时，那一侧在块里是空的；选它就是把这段整个删掉。
        let text = "<<<<<<< HEAD\n=======\nadded\n>>>>>>> x\ntail\n"
        let document = ConflictParser.parse(text)
        XCTAssertEqual(document.blocks[0].ours, [])
        XCTAssertEqual(document.rendered(with: [1: .ours]), "tail\n")
        XCTAssertEqual(document.rendered(with: [1: .theirs]), "added\ntail\n")
    }

    func testMarkerWithoutLabelStillCounts() {
        XCTAssertEqual(ConflictParser.markerSize(of: "<<<<<<<", character: "<"), 7)
        XCTAssertEqual(ConflictParser.markerSize(of: "<<<<<<< HEAD\r", character: "<"), 7)
        XCTAssertNil(ConflictParser.markerSize(of: "<<<<<<<HEAD", character: "<"))
        XCTAssertNil(ConflictParser.markerSize(of: "<<<<<<", character: "<"))
    }

    func testEmptyFile() {
        let document = ConflictParser.parse("")
        XCTAssertTrue(document.segments.isEmpty)
        XCTAssertEqual(document.rendered(with: [:]), "")
    }
}
