import SwiftUI

/// 添加 / 编辑远程服务器。
///
/// 认证只走 SSH 密钥（ssh-agent、`~/.ssh/config`、默认密钥）：密码提示在
/// GUI 的子进程里没人能回答，BatchMode 会让它立刻失败而不是挂死。
/// 用户在终端里 `ssh 主机` 能免密登录，这里就能连上。
struct RemoteServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// 编辑时传入既有配置；添加时为 nil。
    let server: RemoteServer?

    init(server: RemoteServer? = nil) {
        self.server = server
    }

    @State private var alias = ""
    @State private var host = ""
    @State private var user = ""
    @State private var port = ""

    enum TestState: Equatable {
        case idle
        case testing
        case passed(String)
        case failed(String)
    }

    @State private var testState: TestState = .idle
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fields
                    Divider()
                    testSection
                }
                .padding(18)
            }

            Divider()
            footer
        }
        .frame(width: 520, height: 430)
        .onAppear(perform: populate)
    }

    // MARK: - 区块

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(server == nil ? "连接远程服务器" : "编辑服务器")
                .font(.system(size: 15, weight: .semibold))
            Text("认证走你的 SSH 密钥：终端里能免密登录的机器，这里就能连上；需要密码的连接不支持。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("名称") {
                TextField("开发机", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: alias) { _, _ in resetTestState() }
            }

            LabeledContent("主机") {
                TextField("dev.example.com 或 10.0.0.8", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: host) { _, _ in resetTestState() }
            }

            // 用户名和端口都短，并排一行；「可选」写进占位符，不占标签位。
            LabeledContent("账号") {
                HStack(spacing: 8) {
                    TextField("用户名（可选）", text: $user)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: user) { _, _ in resetTestState() }
                    TextField("22", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onChange(of: port) { _, newValue in
                            let digits = newValue.filter(\.isNumber)
                            let bounded = String(digits.prefix(5))
                            if bounded != newValue { port = bounded }
                            resetTestState()
                        }
                }
            }
        }
    }

    private var testSection: some View {
        HStack(spacing: 10) {
            Button("测试连接") {
                Task { await test() }
            }
            .disabled(!canTest)

            if testState == .testing {
                ProgressView()
                    .controlSize(.small)
            }

            testResult
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle:
            Text("填好主机后先试一下，通过会显示远端 git 版本。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .testing:
            Text("正在连接…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .passed(let version):
            Label(version, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var footer: some View {
        HStack {
            if isSaving {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("取消") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(server == nil ? "添加" : "保存") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(draftServer == nil || isSaving)
        }
        .padding(14)
    }

    // MARK: - 状态

    private var canTest: Bool {
        !trimmedHost.isEmpty && testState != .testing
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespaces)
    }

    /// 表单当前内容对应的配置。主机为空或端口不合法时返回 nil（保存按钮据此禁用）。
    private var draftServer: RemoteServer? {
        guard !trimmedHost.isEmpty else { return nil }
        var portNumber: Int?
        if !port.isEmpty {
            guard let value = Int(port), (1...65535).contains(value) else { return nil }
            portNumber = value
        }
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)

        var value = server ?? RemoteServer()
        value.alias = alias
        value.host = trimmedHost
        value.user = trimmedUser.isEmpty ? nil : trimmedUser
        value.port = portNumber
        return value
    }

    private func populate() {
        guard let server else { return }
        alias = server.alias
        host = server.host
        user = server.user ?? ""
        port = server.port.map(String.init) ?? ""
    }

    private func resetTestState() {
        if testState != .idle { testState = .idle }
    }

    // MARK: - 动作

    private func test() async {
        guard let candidate = draftServer else { return }
        testState = .testing
        // 测试也带着 BatchMode：密钥不可用时立刻失败，错误信息直接给用户。
        guard let transport = model.remoteTransport(for: candidate) else {
            testState = .failed("找不到系统 ssh")
            return
        }
        do {
            testState = .passed(try await transport.probe())
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    private func save() async {
        guard let value = draftServer else { return }
        isSaving = true
        defer { isSaving = false }
        if server == nil {
            model.addRemoteServer(value)
        } else {
            await model.updateRemoteServer(value)
        }
        dismiss()
    }
}

/// 在某台服务器上添加一个项目：输入远端路径，Grove 用远端 git
/// 把它归一化成仓库根目录再保存。
struct AddRemoteProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let server: RemoteServer

    @State private var path = ""
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("服务器") {
                    Label(server.displayName, systemImage: "server.rack")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("路径") {
                    TextField("~/code/project", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { Task { await add() } }
                }

                Text("子目录也行 —— 添加时会用服务器上的 git 定位到仓库根目录。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            footer
        }
        .frame(width: 520, height: 300)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("添加远程项目")
                .font(.system(size: 15, weight: .semibold))
            Text("把 \(server.displayName) 上的一个 git 仓库加进 Grove。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if isAdding {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("取消") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("添加") {
                Task { await add() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
        }
        .padding(14)
    }

    private func add() async {
        guard !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        // 校验失败（不是仓库 / 连不上）时 AppModel 已经报过错，留在表单里让用户改。
        if await model.addRemoteProject(path, on: server) != nil {
            dismiss()
        }
    }
}
