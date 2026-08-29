import XCTest
@testable import Grove

/// 历史筛选。跑真 git —— `--grep` / `--author` 的匹配语义（正则还是字面量、
/// 区不区分大小写、author 匹不匹配邮箱）光看文档很容易记岔。
final class LogQueryTests: XCTestCase {
    private var root: URL!
    private var git: GitClient!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git = try await GitClient.resolve()
        try await git.run(["init", "-q", "-b", "main"], in: root)

        try await commit(author: "张三", email: "zhang@example.com", message: "加上登录页", file: "login.swift")
        try await commit(author: "李四", email: "li@example.com", message: "修复崩溃 foo(bar)", file: "crash.swift")
        try await commit(author: "张三", email: "zhang@example.com", message: "重构 API", file: "api.swift")
        try await commit(author: "Wang Wu", email: "wang@example.com", message: "Update README", file: "README.md")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func commit(author: String, email: String, message: String, file: String) async throws {
        try "内容 \(file)\n".write(
            to: root.appendingPathComponent(file), atomically: true, encoding: .utf8
        )
        try await git.run(["add", "-A"], in: root)
        try await git.run(
            ["-c", "user.name=\(author)", "-c", "user.email=\(email)",
             "commit", "-qm", message],
            in: root
        )
    }

    private func subjects(_ query: LogQuery) async throws -> [String] {
        try await git.log(in: root, query: query).map(\.subject)
    }

    // MARK: -

    func testNoFilterReturnsEverything() async throws {
        let all = try await subjects(LogQuery())
        XCTAssertEqual(all.count, 4)
    }

    func testFiltersByAuthorName() async throws {
        var query = LogQuery()
        query.authors = ["张三"]
        let found = try await subjects(query)
        XCTAssertEqual(found.sorted(), ["加上登录页", "重构 API"].sorted())
    }

    func testAuthorAlsoMatchesEmail() async throws {
        // git 的 --author 同时匹配姓名和邮箱。界面上只列姓名，但用户手敲邮箱
        // 也该能用 —— 这条确认这个行为确实成立。
        var query = LogQuery()
        query.authors = ["li@example.com"]
        let found = try await subjects(query)
        XCTAssertEqual(found, ["修复崩溃 foo(bar)"])
    }

    func testFiltersByMessageText() async throws {
        var query = LogQuery()
        query.text = "登录"
        let found = try await subjects(query)
        XCTAssertEqual(found, ["加上登录页"])
    }

    /// 搜索词按**字面量**匹配，不是正则。
    ///
    /// 不加 `--fixed-strings` 的话，`foo(bar)` 会被 git 当成正则里的分组，
    /// 结果是匹配到 `foobar` 而匹配不到用户真正想找的 `foo(bar)` ——
    /// 而且不报错，静默给出错误结果。搜代码符号时这种词太常见了。
    func testSearchIsLiteralNotRegex() async throws {
        var query = LogQuery()
        query.text = "foo(bar)"
        let literal = try await subjects(query)
        XCTAssertEqual(literal, ["修复崩溃 foo(bar)"])

        // 正则元字符不该匹配到任意字符。
        query.text = "修复.崩溃"
        let regexish = try await subjects(query)
        XCTAssertTrue(regexish.isEmpty)
    }

    func testSearchIsCaseInsensitive() async throws {
        var query = LogQuery()
        query.text = "readme"
        let found = try await subjects(query)
        XCTAssertEqual(found, ["Update README"])
    }

    func testFiltersByPath() async throws {
        var query = LogQuery()
        query.path = "login.swift"
        let found = try await subjects(query)
        XCTAssertEqual(found, ["加上登录页"])
    }

    func testCombinedFiltersAreAnded() async throws {
        var query = LogQuery()
        query.authors = ["张三"]
        query.text = "重构"
        // 两个条件是「与」不是「或」—— 是「或」的话这里会返回 3 条。
        let found = try await subjects(query)
        XCTAssertEqual(found, ["重构 API"])
    }

    /// 多选提交人是「或」：同一个人用两个身份提交时，两边的提交都要看得到。
    ///
    /// 这是真实需求 —— 本地 git 配的是英文名，公司 GitLab 上是中文名，
    /// 只能选一个的话永远看不全自己的提交。
    func testMultipleAuthorsAreOred() async throws {
        var query = LogQuery()
        query.authors = ["zhang@example.com", "li@example.com"]
        let found = try await subjects(query)
        XCTAssertEqual(Set(found), ["加上登录页", "重构 API", "修复崩溃 foo(bar)"])
    }

    /// 同一个邮箱换过显示名时，按邮箱筛能一次把两种名字的提交都捞出来。
    func testFilteringByEmailCatchesBothDisplayNames() async throws {
        try await commit(author: "范高健", email: "jamie@example.com", message: "中文名提交", file: "a.txt")
        try await commit(author: "jamie", email: "jamie@example.com", message: "英文名提交", file: "b.txt")

        var query = LogQuery()
        query.authors = ["jamie@example.com"]
        let found = try await subjects(query)
        XCTAssertEqual(Set(found), ["中文名提交", "英文名提交"])
    }

    func testNoMatchReturnsEmptyRatherThanFailing() async throws {
        var query = LogQuery()
        query.authors = ["根本不存在的人"]
        // 筛不到东西是正常结果，不是错误 —— 抛异常会让界面弹一个没必要的报错。
        let found = try await subjects(query)
        XCTAssertTrue(found.isEmpty)
    }

    func testLimitIsRespected() async throws {
        var query = LogQuery()
        query.limit = 2
        let found = try await subjects(query)
        XCTAssertEqual(found.count, 2)
    }

    func testAuthorsListIsSortedByFrequency() async throws {
        let authors = await git.authors(in: root)
        // 张三提交了两次，排最前面 —— 下拉框里最常打交道的人该在最上面。
        XCTAssertEqual(authors.first?.name, "张三")
        XCTAssertEqual(authors.first?.email, "zhang@example.com")
        XCTAssertEqual(authors.first?.count, 2)
        XCTAssertEqual(Set(authors.map(\.name)), ["张三", "李四", "Wang Wu"])
        // 筛选用邮箱而不是姓名：更能唯一定位一个身份。
        XCTAssertEqual(authors.first?.filterToken, "zhang@example.com")
    }

    func testSummaryDescribesActiveFilters() {
        var query = LogQuery()
        XCTAssertNil(query.summary)
        XCTAssertFalse(query.isActive)

        query.authors = ["张三"]
        query.text = "登录"
        XCTAssertTrue(query.isActive)
        XCTAssertEqual(query.summary, "提交人 张三 · 包含「登录」")
    }
}
