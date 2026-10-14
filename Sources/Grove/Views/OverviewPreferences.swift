import SwiftUI

/// 在原生设置表单中复用已有存储，只添加全局视角需要的偏好。
struct OverviewPreferences: View {
    @Environment(AppModel.self) private var app
    @State private var email = ""
    @State private var candidates: [String] = []
    @State private var server: RemoteServer?
    @State private var addsServer = false

    var body: some View {
        @Bindable var preferences = app.navigation
        Section("General") {
            Picker("启动页面", selection: $preferences.startup) {
                ForEach(AppNavigationState.Startup.allCases) { Text($0.label).tag($0) }
            }
            Toggle("自动刷新 Daily / Workspace（每 5 分钟）", isOn: $preferences.autoRefresh)
        }
        Section("Git · Daily 个人身份") {
            Text("仅统计已确认的 Author Email，以 Committer Date 按本地时区分组。不会修改 Git 配置。")
                .font(GroveStyle.caption).foregroundStyle(.secondary)
            ForEach(preferences.authorEmails, id: \.self) { identity in
                HStack {
                    Text(identity)
                    Spacer()
                    Button("移除") { preferences.authorEmails.removeAll { $0 == identity } }
                }
            }
            HStack {
                TextField("Author Email", text: $email).onSubmit(addEmail)
                Button("添加", action: addEmail).disabled(!validEmail)
            }
            ForEach(candidates.filter { !preferences.authorEmails.contains($0) }, id: \.self) { candidate in
                HStack {
                    Text(candidate).foregroundStyle(.secondary)
                    Spacer()
                    Button("确认使用") { preferences.authorEmails.append(candidate) }
                }
            }
            Button("读取 Git 配置候选身份") { Task { await loadCandidates() } }
        }
        Section("Appearance") {
            Picker("外观", selection: $preferences.appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
        }
        Section("Integrations") {
            integration(.github)
            integration(.gitlab)
            Button("重新检测登录状态") { Task { await app.redetectForges() } }
            Text("认证沿用 gh / glab；凭据由 CLI 管理。")
                .font(GroveStyle.caption).foregroundStyle(.secondary)
        }
        Section("Remote") {
            ForEach(app.remoteServers) { host in
                HStack {
                    Text(host.displayName)
                    Spacer()
                    Text(host.destination).foregroundStyle(.secondary)
                    Button("编辑") { server = host }
                }
            }
            Button("添加远程服务器…") { addsServer = true }
                .sheet(isPresented: $addsServer) { RemoteServerSheet().environment(app) }
                .sheet(item: $server) { RemoteServerSheet(server: $0).environment(app) }
        }
    }

    private var validEmail: Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("@") && !value.contains(where: \.isWhitespace)
    }
    private func addEmail() {
        guard validEmail else { return }
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !app.navigation.authorEmails.contains(value) { app.navigation.authorEmails.append(value) }
        email = ""
    }
    private func loadCandidates() async {
        guard let git = app.git else { return }
        var found = Set<String>()
        for repository in app.repositories {
            if let value = try? await git.run(["config", "--get", "user.email"], in: repository.root) {
                let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if candidate.contains("@") { found.insert(candidate) }
            }
        }
        if app.repositories.isEmpty,
           let value = try? await git.run(["config", "--global", "--get", "user.email"], in: FileManager.default.homeDirectoryForCurrentUser) {
            let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if candidate.contains("@") { found.insert(candidate) }
        }
        candidates = found.sorted()
    }
    private func integration(_ kind: ForgeKind) -> some View {
        LabeledContent(kind.displayName) {
            Text(app.availability(of: kind).isReady ? "CLI 已就绪" : app.availability(of: kind).message ?? "不可用")
                .font(GroveStyle.caption).foregroundStyle(.secondary)
        }
    }
}
