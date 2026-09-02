import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var localModelID = ""
    @State private var geminiModelID = ""
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()

            Form {
                Section("Local Gemma — primary scoring") {
                    TextField("Hugging Face model ID", text: $localModelID)
                    LabeledContent("Model storage", value: ModelStorage.defaultDirectory.path)
                    LabeledContent("Disk used", value: diskUsage)
                    Text("The model downloads into Application Support on the first score. Scoring stays inside this app and works offline after download.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Apply model ID") { model.updateLocalModelID(localModelID) }
                        Button("Refresh size") { model.refreshModelDiskUsage() }
                    }
                }

                Section("Gemini — optional review and batch scoring") {
                    SecureField(model.isGeminiConfigured ? "API key saved in Keychain" : "Gemini API key", text: $apiKey)
                    TextField("Gemini model ID", text: $geminiModelID)
                    HStack {
                        Button(model.isGeminiConfigured ? "Update settings" : "Save to Keychain") {
                            model.saveGeminiSettings(apiKey: apiKey, geminiModelID: geminiModelID)
                            apiKey = ""
                        }
                        if model.isGeminiConfigured {
                            Button("Remove API key", role: .destructive) { model.removeGeminiAPIKey() }
                        }
                    }
                    Text("Gemini is never used automatically. Deep Review sends one chosen photo immediately. Batch Scoring sends only selected photos through Google’s asynchronous discounted Batch API and stores its score separately from Gemma.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Scoring rubric", value: ScoringPrompt.version)
                    LabeledContent("Primary engine", value: "Gemma via MLX Swift")
                    LabeledContent("Minimum system", value: "macOS 15 · Apple silicon")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 650, height: 600)
        .onAppear {
            localModelID = model.localModelID
            geminiModelID = model.geminiModelID
            model.refreshModelDiskUsage()
        }
    }

    private var diskUsage: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return model.modelDiskUsageBytes == 0 ? "Not downloaded" : formatter.string(fromByteCount: model.modelDiskUsageBytes)
    }
}
