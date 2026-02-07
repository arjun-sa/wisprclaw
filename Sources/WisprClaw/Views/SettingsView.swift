import SwiftUI

struct SettingsView: View {
    @AppStorage("gatewayURL") private var gatewayURL = "http://localhost:8001"

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
        .frame(width: 400, height: 300)
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
                LabeledContent("API Key") {
                    Text("Not configured")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Model") {
                    Text("Not configured")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Configuration")
            }
        }
        .formStyle(.grouped)
    }
}
