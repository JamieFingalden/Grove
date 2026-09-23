import SwiftUI

/// 轻量语法着色：把一行代码变成带颜色的 `AttributedString`。
///
/// 不引 tree-sitter / Highlightr 这种重依赖 —— 我们只对**可视区域**的行着色
/// （LazyVStack），一个按优先级顺序跑正则的小着色器足够把 Python/Swift/JS
/// 的关键字、字符串、注释、数字、函数名点亮，而这正是 review 时眼睛要抓的东西。
/// 以后要换真解析器，入口不变，只换实现。
enum CodeSyntax {
    // MARK: - 语言

    enum Language: String, CaseIterable {
        case python, swift, javascript, typescript, json, shell, yaml, go, cLike

        /// 按扩展名猜语言。认不出的返回 nil，界面退回纯文本 —— 没有着色
        /// 比错误的着色好。
        static func forPath(_ path: String) -> Language? {
            let ext = (path as NSString).pathExtension.lowercased()
            switch ext {
            case "py", "pyw", "pyi": return .python
            case "swift": return .swift
            case "js", "mjs", "cjs", "jsx": return .javascript
            case "ts", "tsx": return .typescript
            case "json": return .json
            case "sh", "bash", "zsh": return .shell
            case "yaml", "yml": return .yaml
            case "go": return .go
            case "c", "h", "cpp", "hpp", "cc", "java", "rs", "kt", "css": return .cLike
            default: return nil
            }
        }
    }

    // MARK: - 词法种类

    /// 着色优先级从高到低：注释里出现引号不能再按字符串处理，
    /// 字符串里的数字不能按数字处理。先匹配到的范围把字符「占住」，
    /// 后面的规则跳过已占用的区间。
    enum Kind {
        case comment
        case string
        case number
        case keyword
        case attribute
        case definition
    }

    // MARK: - 着色

    /// 一行文本 → 着色 + 词级高亮区间的最终展示属性。
    ///
    /// `highlights` 是词级 diff 算出的「这一行里真正变化的片段」，
    /// `highlight` 是叠加的强调底色（由调用方按行的增/删属性给色）；
    /// nil 时不高亮。review 时先看片段，再看整行。
    static func attributed(
        _ text: String,
        path: String?,
        highlights: [Range<String.Index>] = [],
        highlight: Color? = nil
    ) -> AttributedString {
        var result = AttributedString()
        guard !text.isEmpty else { return result }

        let tokens = (path.flatMap(Language.forPath(_:)).map { tokens(for: text, language: $0) }) ?? []
        // 所有样式边界点：语法 token 边界 + 词级高亮边界，按位置排序去重。
        var boundaries: Set<String.Index> = [text.startIndex, text.endIndex]
        for token in tokens {
            boundaries.insert(token.range.lowerBound)
            boundaries.insert(token.range.upperBound)
        }
        for range in highlights {
            boundaries.insert(range.lowerBound)
            boundaries.insert(range.upperBound)
        }
        let cuts = boundaries.sorted()

        for pair in zip(cuts, cuts.dropFirst()) {
            let segment = pair.0..<pair.1
            guard !segment.isEmpty else { continue }
            var piece = AttributedString(String(text[segment]))
            // 区间内任意一点落在哪个 token 里就算哪种（段不跨 token 边界，取下界即可）。
            if let kind = tokens.first(where: { $0.range.contains(segment.lowerBound) })?.kind {
                piece.foregroundColor = color(for: kind)
            }
            if let highlight, highlights.contains(where: { $0.overlaps(segment) }) {
                piece.backgroundColor = highlight
            }
            result += piece
        }
        return result
    }

    private static func color(for kind: Kind) -> Color {
        switch kind {
        // 语义色比自定义色更耐看，且自动适配深色模式。
        case .comment: .secondary
        case .string: Color(nsColor: .systemTeal)
        case .number: .orange
        case .keyword: Color(nsColor: .systemPurple)
        case .attribute: .pink
        case .definition: .blue
        }
    }

    // MARK: - 规则

    struct Token {
        var range: Range<String.Index>
        var kind: Kind
    }

    private static func tokens(for text: String, language: Language) -> [Token] {
        var claimed: [Range<String.Index>] = []
        var result: [Token] = []

        func match(_ pattern: String, kind: Kind, captureGroup: Int = 0) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: ns) {
                let group = match.range(at: captureGroup)
                guard group.location != NSNotFound else { continue }
                guard let range = Range(group, in: text) else { continue }
                // 已被更高优先级规则占住的区间不重复着色。
                guard !claimed.contains(where: { $0.overlaps(range) }) else { continue }
                claimed.append(range)
                result.append(Token(range: range, kind: kind))
            }
        }

        let rules = rules(for: language)
        // 先跑定义类规则（带捕获组只染名字），再跑普通规则。
        for rule in rules where rule.captureGroup > 0 {
            match(rule.pattern, kind: rule.kind, captureGroup: rule.captureGroup)
        }
        for rule in rules where rule.captureGroup == 0 {
            match(rule.pattern, kind: rule.kind)
        }
        return result
    }

    private struct Rule {
        var pattern: String
        var kind: Kind
        /// > 0 表示只给第 N 个捕获组着色（定义名），而不是整个匹配。
        var captureGroup: Int = 0
    }

    private static func rules(for language: Language) -> [Rule] {
        let identifier = "[A-Za-z_][A-Za-z0-9_]*"

        switch language {
        case .python:
            return [
                Rule(pattern: "#.*$", kind: .comment),
                Rule(pattern: "[rfbu]?\"\"\"[^\"\"\"]*\"\"\"", kind: .string),
                Rule(pattern: "[rfbu]?'''[^']*'''", kind: .string),
                Rule(pattern: "[rfbu]?\"(?:\\\\.|[^\"\\\\])*\"", kind: .string),
                Rule(pattern: "[rfbu]?'(?:\\\\.|[^'\\\\])*'", kind: .string),
                Rule(pattern: "@\(identifier)", kind: .attribute),
                Rule(pattern: "\\b(?:def|class)\\s+(\(identifier))", kind: .definition, captureGroup: 1),
                Rule(pattern: "\\b(?:False|None|True|and|as|assert|async|await|break|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield|match|case)\\b", kind: .keyword),
                Rule(pattern: "\\b(?:print|len|range|enumerate|zip|list|dict|set|tuple|str|int|float|bool|open|isinstance|super|self)\\b", kind: .keyword),
                Rule(pattern: "\\b\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b|\\b0[xX][0-9a-fA-F_]+\\b", kind: .number),
            ]
        case .swift:
            return [
                Rule(pattern: "//.*$", kind: .comment),
                Rule(pattern: "/\\*.*\\*/", kind: .comment),
                Rule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", kind: .string),
                Rule(pattern: "@\\w+", kind: .attribute),
                Rule(pattern: "\\b(?:func|class|struct|enum|protocol|extension|var|let|init)\\s+(\(identifier))", kind: .definition, captureGroup: 1),
                Rule(pattern: "\\b(?:actor|as|async|await|break|case|catch|continue|default|defer|deinit|do|else|enum|extension|fallthrough|for|func|guard|if|import|in|infix|init|inout|internal|is|lazy|let|mutating|nil|nonisolated|open|operator|optional|override|postfix|precedencegroup|prefix|private|public|repeat|required|rethrows|return|self|Self|static|struct|subscript|super|switch|throw|throws|try|typealias|unowned|var|where|while|some|any)\\b", kind: .keyword),
                Rule(pattern: "\\b\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b|\\b0[xX][0-9a-fA-F_]+\\b", kind: .number),
            ]
        case .javascript, .typescript:
            return [
                Rule(pattern: "//.*$", kind: .comment),
                Rule(pattern: "/\\*.*\\*/", kind: .comment),
                Rule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", kind: .string),
                Rule(pattern: "'(?:\\\\.|[^'\\\\])*'", kind: .string),
                Rule(pattern: "`(?:\\\\.|[^`\\\\])*`", kind: .string),
                Rule(pattern: "\\b(?:function|class)\\s+(\(identifier))", kind: .definition, captureGroup: 1),
                Rule(pattern: "\\b(?:abstract|any|as|async|await|break|case|catch|class|const|continue|debugger|declare|default|delete|do|else|enum|export|extends|false|finally|for|from|function|if|implements|import|in|instanceof|interface|is|keyof|let|module|namespace|new|null|of|private|protected|public|readonly|return|satisfies|static|super|switch|this|throw|true|try|type|typeof|undefined|unique|unknown|var|void|while|yield)\\b", kind: .keyword),
                Rule(pattern: "\\b\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b|\\b0[xX][0-9a-fA-F_]+\\b", kind: .number),
            ]
        case .json:
            return [
                Rule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"(?=\\s*:)", kind: .keyword),
                Rule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", kind: .string),
                Rule(pattern: "\\b(?:true|false|null)\\b", kind: .keyword),
                Rule(pattern: "-?\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", kind: .number),
            ]
        case .shell:
            return [
                Rule(pattern: "#.*$", kind: .comment),
                Rule(pattern: "\"(?:\\\\.|[^\"\\\\$])*\"|'(?:[^'])*'", kind: .string),
                Rule(pattern: "\\b(?:if|then|else|elif|fi|for|while|do|done|case|esac|function|in|return|local|export|source)\\b", kind: .keyword),
                Rule(pattern: "\\$\\{?\\w+\\}?", kind: .attribute),
            ]
        case .yaml:
            return [
                Rule(pattern: "#.*$", kind: .comment),
                Rule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'[^']*'", kind: .string),
                Rule(pattern: "^\\s*[\\w.-]+(?=\\s*:)", kind: .keyword),
                Rule(pattern: "\\b(?:true|false|null)\\b", kind: .keyword),
            ]
        case .go:
            return [
                Rule(pattern: "//.*$", kind: .comment),
                Rule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|`[^`]*`", kind: .string),
                Rule(pattern: "\\b(?:func|type|struct|interface|package)\\s+(\(identifier))", kind: .definition, captureGroup: 1),
                Rule(pattern: "\\b(?:break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var|nil|true|false)\\b", kind: .keyword),
                Rule(pattern: "\\b\\d[\\d_]*(?:\\.\\d+)?\\b", kind: .number),
            ]
        case .cLike:
            return [
                Rule(pattern: "//.*$", kind: .comment),
                Rule(pattern: "/\\*.*\\*/", kind: .comment),
                Rule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", kind: .string),
                Rule(pattern: "\\b(?:\\d[A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*)\\b(?=\\s*\\()", kind: .definition),
                Rule(pattern: "\\b(?:alignas|auto|bool|break|case|catch|char|class|const|constexpr|continue|default|delete|do|double|else|enum|explicit|export|extern|false|final|float|for|friend|goto|if|inline|int|long|mutable|namespace|new|noexcept|nullptr|operator|override|private|protected|public|register|return|short|signed|sizeof|static|struct|switch|template|this|throw|throws|true|try|typedef|typename|union|unsigned|using|virtual|void|volatile|while|func|impl|dyn|move|mut|pub|ref|use|where|fun|val|var|when|object|companion|suspend|data|sealed|internal|lateinit|package|import|interface|super|abstract|open)\\b", kind: .keyword),
                Rule(pattern: "\\b\\d[\\d_]*(?:\\.\\d+)?[fFuUlL]*\\b|\\b0[xX][0-9a-fA-F_]+\\b", kind: .number),
            ]
        }
    }
}
