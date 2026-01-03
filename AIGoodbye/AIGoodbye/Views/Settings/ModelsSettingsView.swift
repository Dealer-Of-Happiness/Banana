//
//  ModelsSettingsView.swift
//  AIGoodbye
//
//  Settings view for managing AI models
//

import SwiftUI

struct ModelsSettingsView: View {
    @StateObject private var modelManager = ModelManager.shared
    @State private var showDeleteConfirmation = false
    @State private var modelToDelete: AIModel?

    var body: some View {
        List {
            // Current Model Section
            Section {
                if let currentModel = AIModel.model(withId: modelManager.currentModelId) {
                    CurrentModelRow(model: currentModel)
                }
            } header: {
                Label("Active Model", systemImage: "cpu")
            }

            // Available Models Section
            Section {
                ForEach(AIModel.allModels) { model in
                    ModelRow(
                        model: model,
                        state: modelManager.downloadStates[model.id] ?? .notDownloaded,
                        isSelected: model.id == modelManager.currentModelId,
                        onDownload: { downloadModel(model) },
                        onSelect: { selectModel(model) },
                        onDelete: {
                            modelToDelete = model
                            showDeleteConfirmation = true
                        }
                    )
                }
            } header: {
                Label("Available Models", systemImage: "square.stack.3d.up")
            } footer: {
                Text("Models are stored locally on your device. Total: \(modelManager.formattedTotalSize)")
            }

            // Voice AI Section
            Section {
                NavigationLink {
                    VoiceSettingsView()
                } label: {
                    Label("Voice AI Settings", systemImage: "waveform")
                }
            } header: {
                Label("Voice AI", systemImage: "speaker.wave.3")
            } footer: {
                Text("Configure text-to-speech for AI responses")
            }
        }
        .navigationTitle("AI Models")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete Model",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let model = modelToDelete {
                Button("Delete \(model.name)", role: .destructive) {
                    deleteModel(model)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let model = modelToDelete {
                Text("This will delete \(model.name) (\(model.size)) from your device. You can download it again later.")
            }
        }
    }

    private func downloadModel(_ model: AIModel) {
        Task {
            try? await modelManager.downloadModel(model)
        }
    }

    private func selectModel(_ model: AIModel) {
        modelManager.selectModel(model)
    }

    private func deleteModel(_ model: AIModel) {
        try? modelManager.deleteModel(model)
        modelToDelete = nil
    }
}

// MARK: - Current Model Row

struct CurrentModelRow: View {
    let model: AIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(model.name)
                    .font(.headline)
            }

            Text(model.shortDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Capabilities
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.capabilities, id: \.self) { capability in
                        CapabilityBadge(capability: capability)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Model Row

struct ModelRow: View {
    let model: AIModel
    let state: ModelDownloadState
    let isSelected: Bool
    let onDownload: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.name)
                            .font(.headline)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                    Text(model.size + " • " + model.memoryRequired)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Action Button
                actionButton
            }

            // Description
            Text(model.shortDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Capabilities
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.capabilities, id: \.self) { capability in
                        CapabilityBadge(capability: capability)
                    }
                }
            }

            // Download Progress
            if case .downloading(let progress) = state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))% downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if case .downloaded = state {
                Button {
                    onSelect()
                } label: {
                    Label("Use This Model", systemImage: "checkmark.circle")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .notDownloaded:
            Button {
                onDownload()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)

        case .downloading:
            ProgressView()
                .progressViewStyle(.circular)

        case .downloaded:
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else {
                Button {
                    onSelect()
                } label: {
                    Text("Use")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .failed(let error):
            VStack {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Button("Retry") {
                    onDownload()
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - Capability Badge

struct CapabilityBadge: View {
    let capability: ModelCapability

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: capability.icon)
                .font(.caption2)
            Text(capability.rawValue)
                .font(.caption2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemGray5))
        .clipShape(Capsule())
    }
}

// MARK: - Voice Settings View

struct VoiceSettingsView: View {
    @StateObject private var voiceService = VoiceAIService.shared
    @State private var testText = "Hello! I'm AI goodbye, your personal AI assistant."

    var body: some View {
        List {
            // Enable/Disable
            Section {
                Toggle("Enable Voice AI", isOn: $voiceService.isEnabled)
                    .onChange(of: voiceService.isEnabled) { _, _ in
                        voiceService.savePreferences()
                    }
            } footer: {
                Text("When enabled, AI responses will be read aloud automatically.")
            }

            // Voice Selection
            Section {
                ForEach(voiceService.availableVoices) { voice in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(voice.name)
                            Text(voice.quality.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if voiceService.selectedVoice?.identifier == voice.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        voiceService.selectVoice(voice)
                    }
                }
            } header: {
                Label("Voice", systemImage: "person.wave.2")
            }

            // Speed
            Section {
                VStack(alignment: .leading) {
                    Text("Speech Rate: \(String(format: "%.1fx", voiceService.speechRate * 2))")
                    Slider(value: $voiceService.speechRate, in: 0.25...1.0)
                        .onChange(of: voiceService.speechRate) { _, _ in
                            voiceService.savePreferences()
                        }
                }

                VStack(alignment: .leading) {
                    Text("Pitch: \(String(format: "%.1f", voiceService.speechPitch))")
                    Slider(value: $voiceService.speechPitch, in: 0.5...2.0)
                        .onChange(of: voiceService.speechPitch) { _, _ in
                            voiceService.savePreferences()
                        }
                }
            } header: {
                Label("Adjustments", systemImage: "slider.horizontal.3")
            }

            // Test
            Section {
                Button {
                    if voiceService.isSpeaking {
                        voiceService.stop()
                    } else {
                        voiceService.speak(testText)
                    }
                } label: {
                    HStack {
                        Image(systemName: voiceService.isSpeaking ? "stop.fill" : "play.fill")
                        Text(voiceService.isSpeaking ? "Stop" : "Test Voice")
                    }
                }
            } header: {
                Label("Preview", systemImage: "speaker.wave.2")
            }
        }
        .navigationTitle("Voice AI")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        ModelsSettingsView()
    }
}
