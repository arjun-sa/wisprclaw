import SwiftUI

struct SettingsView: View {
    @AppStorage("gatewayURL") private var gatewayURL = "http://localhost:8001"
    @AppStorage("openclawURL") private var openclawURL = "http://127.0.0.1:18789"
    @AppStorage("openclawToken") private var openclawToken = ""
    @AppStorage("doubleTapCmdEnabled") private var doubleTapCmdEnabled = true
    @AppStorage("llmlinguaEnabled") private var llmlinguaEnabled = false

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
        .frame(width: 400, height: 380)
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle(isOn: $doubleTapCmdEnabled) {
                    HStack {
                        Text("Double-tap")
                        Text("⌘")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)))
                        Text("to record")
                    }
                }
            } header: {
                Text("Activation")
            }

            Section {
                TextField("URL", text: $gatewayURL)
                Toggle("Compress with LLMLingua", isOn: $llmlinguaEnabled)
            } header: {
                Text("Transcription Gateway")
            } footer: {
                Text("LLMLingua reduces input tokens sent to the agent by compressing the transcript. Requires llmlingua installed in the gateway.")
            }
        }
        .formStyle(.grouped)
    }

    private var aiAgentTab: some View {
        Form {
            Section {
                TextField("URL", text: $openclawURL)
            } header: {
                Text("OpenClaw")
            }

            Section {
                TextField("Gateway Token", text: $openclawToken)
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Authentication")
            } footer: {
                Text("Token for the OpenClaw gateway. Also read from GATEWAY_TOKEN in gateway/.env if left empty.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if openclawToken.isEmpty {
                openclawToken = EnvLoader.value(for: "GATEWAY_TOKEN")
                    ?? EnvLoader.value(for: "OPENCLAW_GATEWAY_TOKEN")
                    ?? ""
            }
        }
    }
}
