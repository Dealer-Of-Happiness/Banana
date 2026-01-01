//
//  SettingsView.swift
//  BananaAI
//
//  App settings including online/offline mode and model management
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
                // AI Mode Section
                Section {
                    Toggle(isOn: $viewModel.useInternet) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Internet Access")
                                Text("Use online AI services when needed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "wifi")
                        }
                    }

                    if viewModel.useInternet {
                        Picker("Online Provider", selection: $viewModel.onlineProvider) {
                            Text("ChatGPT").tag("openai")
                            Text("Claude").tag("anthropic")
                        }

                        SecureField("API Key", text: $viewModel.apiKey)
                            .textContentType(.password)
                    }
                } header: {
                    Text("AI Mode")
                } footer: {
                    Text(viewModel.useInternet
                         ? "Will use online AI for complex queries when local AI needs help."
                         : "Completely offline. All processing happens on your device.")
                }

                // Local Model Section
                Section {
                    HStack {
                        Text("Current Model")
                        Spacer()
                        Text(viewModel.currentModel)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Model Size")
                        Spacer()
                        Text(viewModel.modelSize)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        ModelSelectionView(selectedModel: $viewModel.currentModel)
                    } label: {
                        Text("Change Model")
                    }
                } header: {
                    Text("Local AI Model")
                }

                // Knowledge Base Section
                Section {
                    HStack {
                        Text("Documents")
                        Spacer()
                        Text("\(viewModel.documentCount)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Knowledge Chunks")
                        Spacer()
                        Text("\(viewModel.chunkCount)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Storage Used")
                        Spacer()
                        Text(viewModel.storageUsed)
                            .foregroundStyle(.secondary)
                    }

                    Button("Clear Knowledge Base", role: .destructive) {
                        viewModel.showClearConfirmation = true
                    }
                } header: {
                    Text("Knowledge Base")
                }

                // About Section
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/your-repo/Banana")!) {
                        HStack {
                            Text("GitHub")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                    }

                    NavigationLink("Privacy Policy") {
                        PrivacyPolicyView()
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Banana AI - Your data stays on your device.")
                }
            }
            .navigationTitle("Settings")
            .alert("Clear Knowledge Base?", isPresented: $viewModel.showClearConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    Task { await viewModel.clearKnowledgeBase() }
                }
            } message: {
                Text("This will remove all uploaded documents. This action cannot be undone.")
            }
        }
        .onAppear {
            viewModel.settings = appState.settings
            viewModel.knowledgeBase = appState.knowledgeBase
            Task { await viewModel.loadStats() }
        }
        .onChange(of: viewModel.useInternet) { _, newValue in
            appState.settings.useInternet = newValue
        }
    }
}

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var useInternet = false
    @Published var onlineProvider = "openai"
    @Published var apiKey = ""
    @Published var currentModel = "Llama 3.2 3B"
    @Published var modelSize = "1.8 GB"
    @Published var documentCount = 0
    @Published var chunkCount = 0
    @Published var storageUsed = "0 MB"
    @Published var showClearConfirmation = false

    var settings: SettingsManager?
    var knowledgeBase: KnowledgeBase?

    func loadStats() async {
        guard let kb = knowledgeBase else { return }
        documentCount = await kb.getAllDocuments().count
        chunkCount = await kb.getTotalChunks()
        storageUsed = await kb.getStorageSize()

        if let settings = settings {
            useInternet = settings.useInternet
            onlineProvider = settings.onlineProvider
            apiKey = settings.apiKey ?? ""
        }
    }

    func clearKnowledgeBase() async {
        await knowledgeBase?.clearAll()
        await loadStats()
    }
}

struct ModelSelectionView: View {
    @Binding var selectedModel: String
    @Environment(\.dismiss) private var dismiss

    let models = [
        ModelOption(name: "Llama 3.2 1B", size: "0.9 GB", description: "Fastest, basic tasks", recommended: false),
        ModelOption(name: "Llama 3.2 3B", size: "1.8 GB", description: "Balanced speed & quality", recommended: true),
        ModelOption(name: "Phi-3 Mini", size: "2.3 GB", description: "Great for coding", recommended: false),
        ModelOption(name: "Gemma 2 2B", size: "1.4 GB", description: "Google's efficient model", recommended: false),
    ]

    var body: some View {
        List(models) { model in
            Button {
                selectedModel = model.name
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.name)
                                .font(.headline)
                            if model.recommended {
                                Text("Recommended")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.yellow)
                                    .foregroundStyle(.black)
                                    .clipShape(Capsule())
                            }
                        }
                        Text("\(model.size) • \(model.description)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if selectedModel == model.name {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.yellow)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .navigationTitle("Select Model")
    }
}

struct ModelOption: Identifiable {
    let id = UUID()
    let name: String
    let size: String
    let description: String
    let recommended: Bool
}

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Privacy Policy")
                    .font(.title.bold())

                Group {
                    Text("Your Privacy Matters")
                        .font(.headline)

                    Text("""
                    Banana AI is designed with privacy as a core principle. Here's what you need to know:

                    **Local Processing**
                    All AI processing happens directly on your iPhone. Your conversations and documents never leave your device unless you explicitly enable internet mode.

                    **Your Documents**
                    Documents you upload are stored locally on your device and are used only to provide you with more relevant AI responses. They are never uploaded to any server.

                    **Internet Mode**
                    When you enable internet mode, your queries may be sent to third-party AI providers (OpenAI or Anthropic) to enhance response quality. You can disable this at any time.

                    **No Tracking**
                    We don't collect analytics, usage data, or any personal information.

                    **Data Deletion**
                    You can delete all your data at any time through the Settings > Knowledge Base > Clear option.
                    """)
                }
            }
            .padding()
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
