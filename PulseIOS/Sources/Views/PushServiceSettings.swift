import SwiftUI

struct PushServiceSettings: View {
    let client: IPhonePushBridgeClient
    @State private var endpoint = ""
    @State private var bearer = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        Form {
            if !client.isConfigurable {
                Section {
                    Text("此环境为验收演示，禁止配置远程服务，不会读取钥匙串或发送网络请求。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("私人行情更新服务") {
                TextField("HTTPS 服务根地址", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("仅在本机配置的服务访问凭据", text: $bearer).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("凭据只写入这个App自己的钥匙串，不要发送到聊天。首次连接前请确认这是你部署的服务；切换服务需先撤销旧注册。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("保存本机配置") {
                    do { try client.saveConfiguration(endpoint: endpoint, bearer: bearer); bearer = ""; error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(busy || !client.isConfigurable)
                Button("检查真实服务状态") {
                    busy = true
                    Task { await client.checkStatus(); busy = false }
                }.disabled(busy || !client.isConfigured)
            }
            Section("实际状态") {
                Text(client.statusText)
                if let error { Text(error).foregroundStyle(.orange) }
                Text("配置完整不等于APNs已到达。自动启动还需要对应签名权限、有效活动令牌、常在线服务和真机验收；免费续签不是后台推送权限。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("撤销远程活动注册", role: .destructive) {
                    busy = true
                    Task { await client.revoke(); busy = false }
                }.disabled(busy || !client.isConfigured)
            }
        }
        .navigationTitle("后台更新服务")
        .onAppear { endpoint = client.endpointText }
    }
}
