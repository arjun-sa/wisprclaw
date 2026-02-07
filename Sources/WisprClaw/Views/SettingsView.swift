import SwiftUI

struct SettingsView: View {
    @AppStorage("gatewayURL") private var gatewayURL = "http://localhost:8001"
    @AppStorage("openclawURL") private var openclawURL = "http://127.0.0.1:18789"
    @AppStorage("openclawToken") private var openclawToken = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            aiAgentTab
                .tabItem {
                    Label("AI Agent", systemImage: "brain")
                }
        }
        .frame(width: 400, height: 350)
    }

    private var generalTab: some View {
        Form {
            Section {
                LabeledContent("Shortcut") {
                    Text("Not configured")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Global Hotkey")
            }

            Section {
                TextField("URL", text: $gatewayURL)
            } header: {
                Text("Transcription Gateway")
            }
        }
        .formStyle(.grouped)
    }

    private var aiAgentTab: some View {
        Form {
            Section {
                TextField("URL", text: $openclawURL)
                SecureField("Auth Token", text: $openclawToken)
            } header: {
                Text("OpenClaw")
            } footer: {
                Text("Uses the Gateway WebSocket protocol. URL and token from ~/.openclaw/openclaw.json (gateway.auth.token).")
            }
        }
        .formStyle(.grouped)
    }
}
