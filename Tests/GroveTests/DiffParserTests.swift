import XCTest
@testable import Grove

final class DiffParserTests: XCTestCase {
    func testParsesSimpleHunk() {
        let diff = """
        diff --git a/src/app.swift b/src/app.swift
        index 1234567..89abcde 100644
        --- a/src/app.swift
        +++ b/src/app.swift
        @@ -10,4 +10,5 @@ func greet() {
             print("hello")
        -    print("old")
        +    print("new")
        +    print("extra")
             return
        """

        let files = DiffParser.parse(diff)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].newPath, "src/app.swift")
        XCTAssertEqual(files[0].additions, 2)
        XCTAssertEqual(files[0].deletions, 1)

        let lines = files[0].hunks[0].lines
        // 行号必须两边独立推进：上下文行两侧都 +1，新增只推新侧，删除只推旧侧。
        XCTAssertEqual(lines[0].oldNumber, 10)
        XCTAssertEqual(lines[0].newNumber, 10)
        XCTAssertEqual(lines[1].kind, .deletion)
        XCTAssertEqual(lines[1].oldNumber, 11)
        XCTAssertNil(lines[1].newNumber)
        XCTAssertEqual(lines[2].kind, .addition)
        XCTAssertNil(lines[2].oldNumber)
        XCTAssertEqual(lines[2].newNumber, 11)
        XCTAssertEqual(lines[4].oldNumber, 12)
        XCTAssertEqual(lines[4].newNumber, 13)
    }

    func testHunkHeaderWithoutCountDefaultsToOne() {
        // `@@ -5 +5,2 @@` 里省略的计数按规范默认是 1。当成 0 会让行号推导错位。
        let header = DiffParser.parseHunkHeader("@@ -5 +5,2 @@")
        XCTAssertEqual(header?.oldStart, 5)
        XCTAssertEqual(header?.oldCount, 1)
        XCTAssertEqual(header?.newStart, 5)
        XCTAssertEqual(header?.newCount, 2)
        XCTAssertEqual(header?.prefixWidth, 1)
    }

    func testCombinedDiffHasWiderPrefix() {
        // 合并冲突期间 git 输出的是 combined diff：`@@@` 三个 @、每行两列前缀。
        // 按普通 diff 解析的话每一行都会被当成上下文，看起来「什么都没改」。
        let header = DiffParser.parseHunkHeader("@@@ -1,2 -1,2 +1,3 @@@")
        XCTAssertEqual(header?.prefixWidth, 2)
        XCTAssertEqual(header?.newStart, 1)
        XCTAssertEqual(header?.newCount, 3)

        let diff = """
        diff --cc merged.txt
        index aaa,bbb..ccc
        @@@ -1,2 -1,2 +1,3 @@@
          shared context
        ++added by merge
         - removed from theirs
        """

        let files = DiffParser.parse(diff)
        let lines = files[0].hunks[0].lines
        XCTAssertEqual(lines[0].kind, .context)
        XCTAssertEqual(lines[1].kind, .addition)
        XCTAssertEqual(lines[2].kind, .deletion)
    }

    func testEmptyContextLineIsNotDropped() {
        // 规范里空的上下文行是单个空格，但经过某些工具之后尾部空格会被吃掉。
        // 当成不存在的话，它后面所有行的行号都会错一位。
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         first

        -third
        +THIRD
        """

        let files = DiffParser.parse(diff)
        let lines = files[0].hunks[0].lines
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[1].kind, .context)
        XCTAssertEqual(lines[1].text, "")
        XCTAssertEqual(lines[2].oldNumber, 3)
    }

    func testNoNewlineMarkerDoesNotConsumeLineNumbers() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,1 @@
        -old
        \\ No newline at end of file
        +new
        """

        let files = DiffParser.parse(diff)
        let lines = files[0].hunks[0].lines
        XCTAssertEqual(lines[1].kind, .noNewline)
        XCTAssertNil(lines[1].oldNumber)
        XCTAssertNil(lines[1].newNumber)
        // 标记行不占行号，所以后面的新增行还是第 1 行。
        XCTAssertEqual(lines[2].newNumber, 1)
    }

    func testRenameUsesRenameHeaders() {
        let diff = """
        diff --git a/old/path.swift b/new/path.swift
        similarity index 92%
        rename from old/path.swift
        rename to new/path.swift
        --- a/old/path.swift
        +++ b/new/path.swift
        @@ -1,1 +1,1 @@
        -a
        +b
        """

        let files = DiffParser.parse(diff)
        XCTAssertTrue(files[0].isRename)
        XCTAssertEqual(files[0].oldPath, "old/path.swift")
        XCTAssertEqual(files[0].newPath, "new/path.swift")
    }

    func testPathWithSpacesIsRecoveredFromMidpointSplit() {
        // `diff --git a/my file.txt b/my file.txt` 靠分词切不开。
        // 非重命名时两个路径完全一样，所以可以按正中间的空格切。
        let paths = DiffParser.parseGitHeaderPaths("a/my file.txt b/my file.txt")
        XCTAssertEqual(paths?.old, "my file.txt")
        XCTAssertEqual(paths?.new, "my file.txt")
    }

    func testTrailingTabAfterPathIsStripped() {
        // git 在路径含空格时会往 `---`/`+++` 行末尾补一个裸制表符标记路径边界。
        // 留着它，路径就多一个不可见字符，之后 `git diff -- <路径>` 全部匹配不上 ——
        // 表现是「点了带空格的文件，diff 面板永远空白」。
        XCTAssertEqual(DiffParser.stripPathPrefix("a/my file.txt\t"), "my file.txt")
        XCTAssertEqual(DiffParser.stripPathPrefix("b/plain.txt"), "plain.txt")

        let diff = """
        diff --git a/my file.txt b/my file.txt
        index aaa..bbb 100644
        --- a/my file.txt\t
        +++ b/my file.txt\t
        @@ -1 +1,2 @@
         x
        +y
        """

        let files = DiffParser.parse(diff)
        XCTAssertEqual(files[0].newPath, "my file.txt")
        XCTAssertEqual(files[0].oldPath, "my file.txt")
    }

    func testQuotedPathWithTabCharacterIsUnquoted() {
        // 路径里真的含制表符时 git 会加引号，此时不能按制表符截断。
        let diff = """
        diff --git "a/tab\\there.txt" "b/tab\\there.txt"
        index aaa..bbb 100644
        --- "a/tab\\there.txt"
        +++ "b/tab\\there.txt"
        @@ -1 +1,2 @@
         x
        +y
        """

        let files = DiffParser.parse(diff)
        XCTAssertEqual(files[0].newPath, "tab\there.txt")
    }

    func testNewAndDeletedFilesDetected() {
        let diff = """
        diff --git a/created.txt b/created.txt
        new file mode 100644
        index 0000000..e69de29
        --- /dev/null
        +++ b/created.txt
        @@ -0,0 +1,1 @@
        +hello
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index e69de29..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -bye
        """

        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].isNewFile)
        XCTAssertEqual(files[0].newPath, "created.txt")
        XCTAssertTrue(files[1].isDeletedFile)
        XCTAssertEqual(files[1].oldPath, "gone.txt")
    }

    func testBinaryFileIsFlagged() {
        let diff = """
        diff --git a/logo.png b/logo.png
        index aaa..bbb 100644
        Binary files a/logo.png and b/logo.png differ
        """

        let files = DiffParser.parse(diff)
        XCTAssertTrue(files[0].isBinary)
        XCTAssertTrue(files[0].hunks.isEmpty)
    }

    func testModeOnlyChangeIsFlagged() {
        let diff = """
        diff --git a/script.sh b/script.sh
        old mode 100644
        new mode 100755
        """

        let files = DiffParser.parse(diff)
        XCTAssertTrue(files[0].isModeChangeOnly)
        XCTAssertEqual(files[0].oldMode, "100644")
        XCTAssertEqual(files[0].newMode, "100755")
    }

    func testUnquotesCEscapedPaths() {
        XCTAssertEqual(DiffParser.unquote("\"a/tab\\there.txt\""), "a/tab\there.txt")
        XCTAssertEqual(DiffParser.unquote("plain.txt"), "plain.txt")
        XCTAssertEqual(DiffParser.stripPathPrefix("\"b/quote\\\"name.txt\""), "quote\"name.txt")
    }

    func testTrailingNewlineDoesNotAddPhantomLine() {
        // git 的真实输出永远以换行结尾。按 \n 切之后最后会多一个空串，
        // 当成「空的上下文行」处理的话，每个 diff 末尾都会凭空多出一行、
        // 还占掉一个行号。之前的测试用例都是不带尾随换行的字符串字面量，
        // 所以整整漏掉了这个只在真实数据上才出现的 bug。
        let diff = "diff --git a/a.txt b/a.txt\n"
            + "--- a/a.txt\n"
            + "+++ b/a.txt\n"
            + "@@ -0,0 +1 @@\n"
            + "+hello\n"

        let files = DiffParser.parse(diff)
        let lines = files[0].hunks[0].lines

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, .addition)
        XCTAssertEqual(lines[0].text, "hello")
        XCTAssertEqual(files[0].additions, 1)
    }

    func testRealGitOutputWithMultipleFilesAndTrailingNewline() {
        let diff = "diff --git a/one.txt b/one.txt\n"
            + "--- a/one.txt\n+++ b/one.txt\n@@ -1 +1 @@\n-a\n+b\n"
            + "diff --git a/two.txt b/two.txt\n"
            + "--- a/two.txt\n+++ b/two.txt\n@@ -1 +1 @@\n-c\n+d\n"

        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 2)
        // 每个文件都只有一增一删，不能多出空行。
        XCTAssertEqual(files.map(\.additions), [1, 1])
        XCTAssertEqual(files.map(\.deletions), [1, 1])
        XCTAssertEqual(files[1].hunks[0].lines.count, 2)
    }

    func testGenuineEmptyContextLineIsStillKept() {
        // 只丢**末尾**那一个空串。diff 中间的空行仍然是真的内容行。
        let diff = "diff --git a/a.txt b/a.txt\n"
            + "--- a/a.txt\n+++ b/a.txt\n@@ -1,3 +1,3 @@\n first\n\n-third\n+THIRD\n"

        let files = DiffParser.parse(diff)
        let lines = files[0].hunks[0].lines
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[1].kind, .context)
        XCTAssertEqual(lines[1].text, "")
    }

    func testMultipleFilesAreSeparated() {
        let diff = """
        diff --git a/one.txt b/one.txt
        --- a/one.txt
        +++ b/one.txt
        @@ -1 +1 @@
        -a
        +b
        diff --git a/two.txt b/two.txt
        --- a/two.txt
        +++ b/two.txt
        @@ -1 +1 @@
        -c
        +d
        """

        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.map(\.displayPath), ["one.txt", "two.txt"])
        XCTAssertEqual(files[0].hunks.count, 1)
    }
}
