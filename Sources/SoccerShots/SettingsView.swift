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
                    if model.availableGeminiModels.isEmpty {
                        TextField("Preferred Gemini model ID", text: $geminiModelID)
                    } else {
                        Picker("Preferred review model", selection: $geminiModelID) {
                            if !model.availableGeminiModels.contains(where: { $0.id == geminiModelID }) {
                                Text(geminiModelID).tag(geminiModelID)
                            }
                            ForEach(model.availableGeminiModels) { option in
                                Text(option.displayName ?? option.id).tag(option.id)
                            }
                        }
                        .onChange(of: geminiModelID) { _, value in model.selectGeminiModel(value) }
                    }
                    HStack {
                        Button(model.isGeminiConfigured ? "Update settings" : "Save to Keychain") {
                            model.saveGeminiSettings(apiKey: apiKey, geminiModelID: geminiModelID)
                            apiKey = ""
                        }
                        if model.isGeminiConfigured {
                            Button("Remove API key", role: .destructive) { model.removeGeminiAPIKey() }
                        }
                        Button(model.isRefreshingGeminiModels ? "Refreshing…" : "Refresh Models") {
                            model.refreshGeminiModels()
                        }
                        .disabled(model.isRefreshingGeminiModels || !model.isGeminiConfigured)
                    }
                    if let status = model.geminiModelStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Deep Review uses Google’s current Interactions API with the preferred model. Batch Scoring sends only selected photos through Google’s discounted asynchronous Batch API and automatically chooses a compatible current model when the preferred model is unavailable. Neither result replaces Gemma’s local primary score.")
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
            if model.isGeminiConfigured { model.refreshGeminiModels() }
        }
        .onReceive(model.$geminiModelID) { geminiModelID = $0 }
    }

    private var diskUsage: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return model.modelDiskUsageBytes == 0 ? "Not downloaded" : formatter.string(fromByteCount: model.modelDiskUsageBytes)
    }
}
