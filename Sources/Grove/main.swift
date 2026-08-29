import Foundation

// SwiftUI 的 `@main` 会直接接管进程，没法在它之前插入命令行分支。
// 所以入口放在 main.swift 里，先看参数再决定是开窗口还是跑自查。
//
// `--doctor` 存在的理由见 Doctor.swift：GUI 里最难排查的问题都在 GUI 之外。

let arguments = CommandLine.arguments

if arguments.contains("--doctor") {
    // 参数里第一个不以 `-` 开头的（跳过可执行文件本身）当作仓库路径。
    let path = arguments.dropFirst().first { !$0.hasPrefix("-") }
    await Doctor.run(path: path)
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    Grove —— macOS 上的 git 工作树与 PR 管理工具

    用法：
      Grove                    打开图形界面
      Grove --doctor [路径]    检查环境并打印仓库状态（默认当前目录）
      Grove --help             显示这段说明
    """)
    exit(0)
}

GroveApp.main()
