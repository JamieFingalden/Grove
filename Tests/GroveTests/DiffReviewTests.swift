import SwiftUI
import XCTest
@testable import Grove

/// 「review 级」diff 改造的纯逻辑测试：分栏配对、词级差异、键盘浏览顺序。
@MainActor
final class DiffReviewTests: XCTestCase {
    // MARK: - SplitLayout

    private let clusterSample = """
        diff --git a/a.py b/a.py
        --- a/a.py
        +++ b/a.py
        @@ -1,7 +1,7 @@
         ctx1
        -old1
        -old2
        -old3
        +new1
        +new2
         ctx2
        -gone
         ctx3
        """

    func testSplitPairsAlignDeletionAndAdditionRuns() {
        let files = DiffParser.parse(clusterSample)
        let pairs = SplitLayout.pairs(for: files[0].hunks[0].lines)

        // 改动簇：3 删对 2 增 —— 前 2 行水平对齐，第 3 个删除行右侧留空；
        // 后面还有一个独立的纯删除 -gone。
        let changePairs = pairs.filter(\.isChange)
        XCTAssertEqual(changePairs.count, 4)
        XCTAssertEqual(changePairs[0].left?.text, "old1")
        XCTAssertEqual(changePairs[0].right?.text, "new1")
        XCTAssertEqual(changePairs[1].left?.text, "old2")
        XCTAssertEqual(changePairs[1].right?.text, "new2")
        XCTAssertEqual(changePairs[2].left?.text, "old3")
        XCTAssertNil(changePairs[2].right)

        // 上下文行左右成对且是同一行。
        let contextPairs = pairs.filter { !$0.isChange }
        XCTAssertEqual(contextPairs.map { $0.left?.id }, contextPairs.map { $0.right?.id })

        // 纯删除：左有右无。
        let pureDeletion = changePairs.first { $0.left?.text == "gone" }
        XCTAssertNotNil(pureDeletion?.left)
        XCTAssertNil(pureDeletion?.right)
    }

    func testNoNewlineMarkerLandsOnNewSideWhenAdditionsExist() {
        let sample = """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,2 +1,2 @@
            -old
            +new
            \\ No newline at end of file
             ctx
            """
        let files = DiffParser.parse(sample)
        let pairs = SplitLayout.pairs(for: files[0].hunks[0].lines)
        let changePair = pairs.first { $0.isChange }
        // \\ 标记描述的是新文件末尾，挂到右侧。
        XCTAssertEqual(changePair?.right?.text, "new")
        XCTAssertTrue(changePair?.rightNoNewline ?? false)
        XCTAssertFalse(changePair?.leftNoNewline ?? true)
    }

    func testNoNewlineMarkerLandsOnOldSideForPureDeletion() {
        let sample = """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,2 +1 @@
            -old
            \\ No newline at end of file
             ctx
            """
        let files = DiffParser.parse(sample)
        let pairs = SplitLayout.pairs(for: files[0].hunks[0].lines)
        let changePair = pairs.first { $0.isChange }
        XCTAssertTrue(changePair?.leftNoNewline ?? false)
    }

    // MARK: - 词级差异

    func testWordHighlightOnlyCoversChangedFragment() {
        let sample = """
            diff --git a/a.py b/a.py
            --- a/a.py
            +++ b/a.py
            @@ -1,3 +1,3 @@
             ctx
            -value = old_name(x)
            +value = new_name(x)
             ctx
            """
        let files = DiffParser.parse(sample)
        let highlights = DiffWordHighlight.ranges(for: files[0])
        let oldLine = files[0].hunks[0].lines.first { $0.kind == .deletion }!
        let newLine = files[0].hunks[0].lines.first { $0.kind == .addition }!

        // 两侧只强调真正不同的中段：公共前缀（value = ）和公共后缀（_name(x)）
        // 都不进高亮 —— 连 _name(x) 这种双侧相同的尾巴都能正确剥掉。
        let oldFragment = oldLine.text[highlights[oldLine.id]![0]]
        let newFragment = newLine.text[highlights[newLine.id]![0]]
        XCTAssertEqual(String(oldFragment), "old")
        XCTAssertEqual(String(newFragment), "new")
        // 上下文行没有高亮。
        XCTAssertNil(highlights[files[0].hunks[0].lines[0].id])
    }

    func testPureInsertionLeavesOldSideUnmarked() {
        let sample = """
            diff --git a/a.py b/a.py
            --- a/a.py
            +++ b/a.py
            @@ -1,3 +1,3 @@
             ctx
            -result = compute_value(input)
            +result = compute_new_value(input)
             ctx
            """
        let files = DiffParser.parse(sample)
        let highlights = DiffWordHighlight.ranges(for: files[0])
        let oldLine = files[0].hunks[0].lines.first { $0.kind == .deletion }!
        let newLine = files[0].hunks[0].lines.first { $0.kind == .addition }!

        // 公共前后缀相接时旧行没有任何可强调的中段 —— 高亮只出现在新增侧的 new 上。
        XCTAssertTrue((highlights[oldLine.id] ?? []).isEmpty)
        let fragment = newLine.text[highlights[newLine.id]![0]]
        XCTAssertTrue(String(fragment).contains("new"))
        XCTAssertFalse(String(fragment).contains("input"))
    }

    func testUnpairedLineGetsFullHighlight() {
        let sample = """
            diff --git a/a.py b/a.py
            --- a/a.py
            +++ b/a.py
            @@ -1,2 +1,3 @@
             ctx
            +brand new line
            """
        let files = DiffParser.parse(sample)
        let highlights = DiffWordHighlight.ranges(for: files[0])
        let added = files[0].hunks[0].lines.first { $0.kind == .addition }!
        let range = highlights[added.id]![0]
        XCTAssertEqual(String(added.text[range]), "brand new line")
    }

    func testWhitespaceOnlyChangeIsNotHighlighted() {
        let sample = """
            diff --git a/a.py b/a.py
            --- a/a.py
            +++ b/a.py
            @@ -1,3 +1,3 @@
             ctx
            -x = 1
            +x  = 1
             ctx
            """
        let files = DiffParser.parse(sample)
        let highlights = DiffWordHighlight.ranges(for: files[0])
        // 只多了一个空格：不值得强调，否则每个改缩进的 diff 都是满屏高亮。
        XCTAssertTrue(highlights.values.allSatisfy(\.isEmpty))
    }

    // MARK: - 键盘浏览

    func testOrderedChangeRowsPutConflictsFirstThenStagedThenUnstaged() {
        let status = WorktreeStatus(
            branch: "main", upstream: nil, ahead: 0, behind: 0, oid: nil,
            changes: [
                FileChange(path: "unstaged.swift", originalPath: nil, staged: nil, unstaged: .modified, conflict: nil),
                FileChange(path: "conflict.swift", originalPath: nil, staged: nil, unstaged: .modified, conflict: .bothModified),
                FileChange(path: "staged.swift", originalPath: nil, staged: .modified, unstaged: nil, conflict: nil),
                FileChange(path: "mixed.swift", originalPath: nil, staged: .modified, unstaged: .modified, conflict: nil),
            ],
            operation: nil
        )

        let rows = WorktreeModel.orderedChangeRows(status)
        XCTAssertEqual(rows.map(\.path), ["conflict.swift", "staged.swift", "mixed.swift", "unstaged.swift"])
        // 部分暂存的文件按暂存侧出现在列表里。
        XCTAssertEqual(rows[1].side, .staged)
        XCTAssertEqual(rows[2].side, .staged)
        XCTAssertEqual(rows[3].side, .worktree)
    }

    func testHunkLookupByLineID() {
        let files = DiffParser.parse(clusterSample)
        let target = files[0].hunks[0].lines.first { $0.text == "old2" }!
        XCTAssertEqual(WorktreeModel.hunk(containingLineID: target.id, in: files)?.id, files[0].hunks[0].id)
        XCTAssertNil(WorktreeModel.hunk(containingLineID: 999_999, in: files))
    }

    // MARK: - 折叠区合成

    func testGapHunkSynthesizesNumberedContextLines() {
        let files = DiffParser.parse(clusterSample)
        let hunk = files[0].hunks[0]
        let synthetic = DiffContentView.gapHunk(hollowing: hunk, startLine: 42, texts: ["alpha", "", "gamma"])

        XCTAssertEqual(synthetic.lines.map(\.text), ["alpha", "", "gamma"])
        XCTAssertEqual(synthetic.lines.map(\.oldNumber), [42, 43, 44])
        XCTAssertEqual(synthetic.lines.map(\.newNumber), [42, 43, 44])
        XCTAssertTrue(synthetic.lines.allSatisfy { $0.kind == .context })
        // 负数 id 空间，绝不与解析器的正数 id 撞车。
        XCTAssertTrue(synthetic.lines.allSatisfy { $0.id < 0 })
        XCTAssertFalse(synthetic.lines.isEmpty)
    }

    // MARK: - 语法着色

    func testSyntaxHighlightColorsPythonTokens() {
        let attributed = CodeSyntax.attributed("def compute_value(x):  # 入口", path: "a.py")
        let colored = attributed.runs.filter { $0.foregroundColor != nil }
        // def（关键字）、compute_value（定义名）、注释至少分出两个着色片段。
        XCTAssertGreaterThanOrEqual(colored.count, 2)
        XCTAssertTrue(colored.allSatisfy { $0.backgroundColor == nil })
        // 注释段有自己的颜色。
        let comment = attributed.runs.first { String(attributed[$0.range].characters).contains("#") }
        XCTAssertNotNil(comment?.foregroundColor)
    }

    func testUnknownExtensionFallsBackToPlain() {
        let attributed = CodeSyntax.attributed("def foo(x):", path: "data.xyz")
        XCTAssertTrue(attributed.runs.allSatisfy { $0.foregroundColor == nil })
    }

    func testHighlightOverlaySpansOnlyMarkedRange() {
        let text = "abcdef"
        let middle = text.index(text.startIndex, offsetBy: 2)..<text.index(text.startIndex, offsetBy: 4)
        let attributed = CodeSyntax.attributed(text, path: nil, highlights: [middle], highlight: .yellow)

        let marked = attributed.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(String(attributed.characters), text)
        // 只有中间片段带底色。
        let run = marked.first!
        XCTAssertEqual(String(attributed[run.range].characters), "cd")
    }

// MARK: - 路径拆分

    func testPathPartsSplitFileNameAndDirectory() {
        let sample = """
            diff --git a/src/deep/nested/dir/extractor.py b/src/deep/nested/dir/extractor.py
            --- a/src/deep/nested/dir/extractor.py
            +++ b/src/deep/nested/dir/extractor.py
            @@ -1,1 +1,1 @@
            -a
            +b
            """
        let file = DiffParser.parse(sample)[0]
        XCTAssertEqual(file.fileName, "extractor.py")
        XCTAssertEqual(file.directory, "src/deep/nested/dir")

        // 根目录文件：目录为 nil，文件名即全路径。
        let rootSample = """
            diff --git a/README.md b/README.md
            --- a/README.md
            +++ b/README.md
            @@ -1,1 +1,1 @@
            -a
            +b
            """
        let rootFile = DiffParser.parse(rootSample)[0]
        XCTAssertEqual(rootFile.fileName, "README.md")
        XCTAssertNil(rootFile.directory)
    }

// MARK: - 行号列自适应

    func testHunkNumberColumnsAdaptToPureAdditions() {
        let newFile = """
            diff --git a/new.py b/new.py
            new file mode 100644
            --- /dev/null
            +++ b/new.py
            @@ -0,0 +1,2 @@
            +import os
            +print("hi")
            """
        let hunk = DiffParser.parse(newFile)[0].hunks[0]
        // 新建文件：旧行号列全空 → 不渲染；新行号列保留。
        XCTAssertFalse(hunk.hasOldNumbers)
        XCTAssertTrue(hunk.hasNewNumbers)

        let mixed = DiffParser.parse(clusterSample)[0].hunks[0]
        XCTAssertTrue(mixed.hasOldNumbers)
        XCTAssertTrue(mixed.hasNewNumbers)
    }

    // MARK: - 纯增/纯删 hunk 的单栏判定

    func testDominantSideCollapsesPureAdditions() {
        // 新建文件：全是新增行 → 只看新侧，单栏占满全宽。
        let sample = """
            diff --git a/new.py b/new.py
            new file mode 100644
            --- /dev/null
            +++ b/new.py
            @@ -0,0 +1,3 @@
            +import os
            +
            +print("hi")
            """
        let files = DiffParser.parse(sample)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(
            SplitLayout.dominantSide(for: files[0].hunks[0].lines),
            .new
        )
    }

    func testDominantSideCollapsesPureDeletions() {
        // 删除文件：全是删除行 → 只看旧侧。
        let sample = """
            diff --git a/gone.py b/gone.py
            deleted file mode 100644
            --- a/gone.py
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -import os
            -print("hi")
            """
        let files = DiffParser.parse(sample)
        XCTAssertEqual(
            SplitLayout.dominantSide(for: files[0].hunks[0].lines),
            .old
        )
    }

    func testDominantSideKeepsSplitForMixedAndContextOnly() {
        // 有增有删 → 正常分栏对照。
        let files = DiffParser.parse(clusterSample)
        XCTAssertEqual(SplitLayout.dominantSide(for: files[0].hunks[0].lines), nil)

        // 纯上下文（折叠区展开的合成 hunk）也走单侧，内容不重复两遍。
        let synthetic = DiffContentView.gapHunk(
            hollowing: files[0].hunks[0],
            startLine: 5,
            texts: ["a", "b"]
        )
        XCTAssertEqual(SplitLayout.dominantSide(for: synthetic.lines), .new)
    }

    func testConflictMarkerCountIgnoresIndentedLookalikes() {
        // 编辑器用行首 `<<<<<<<` 数冲突块：字符串字面量里带缩进的伪标记不算，
        // 否则会拦着用户标记已解决。
        let conflicted = "a\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> feature\nc"
        XCTAssertEqual(CodeEditorSheet.conflictMarkerCount(in: conflicted), 1)
        XCTAssertEqual(CodeEditorSheet.conflictMarkerCount(in: "plain text"), 0)
        XCTAssertEqual(CodeEditorSheet.conflictMarkerCount(in: ""), 0)
        XCTAssertEqual(CodeEditorSheet.conflictMarkerCount(in: "  <<<<<<< 缩进的不算"), 0)
        // 多块也能数对
        XCTAssertEqual(
            CodeEditorSheet.conflictMarkerCount(in: "<<<<<<< a\n=======\n>>>>>>> b\n<<<<<<< c\n=======\n>>>>>>> d"),
            2
        )
    }
}

extension CodeSyntax {
    /// 测试用：让着色种类对外可断言。
    static var hasTestableKinds: Bool { true }

}
