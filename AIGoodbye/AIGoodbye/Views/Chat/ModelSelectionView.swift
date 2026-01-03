//
//  ModelSelectionView.swift
//  AIGoodbye
//
//  Model selection dropdown for new chats
//

import SwiftUI

struct ModelSelectionView: View {
    @StateObject private var modelManager = ModelManager.shared
    @Binding var isPresented: Bool
    @Binding var selectedModelId: String?
    let onStartChat: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.system(size: 40))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text("Select AI Model")
                        .font(.title2.bold())

                    Text("Choose a model for this conversation")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                .padding(.bottom, 16)

                // Model List
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(downloadedModels) { model in
                            ModelSelectionRow(
                                model: model,
                                isSelected: selectedModelId == model.id || (selectedModelId == nil && model.id == modelManager.currentModelId)
                            ) {
                                selectedModelId = model.id
                            }
                        }

                        if downloadedModels.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.largeTitle)
                                    .foregroundStyle(.orange)

                                Text("No Models Downloaded")
                                    .font(.headline)

                                Text("Go to Settings > AI Models to download a model first.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.vertical, 40)
                        }
                    }
                    .padding(.horizontal)
                }

                // Start Chat Button
                Button {
                    let modelId = selectedModelId ?? modelManager.currentModelId
                    if let model = AIModel.model(withId: modelId) {
                        modelManager.selectModel(model)
                    }
                    onStartChat()
                    isPresented = false
                } label: {
                    HStack {
                        Image(systemName: "bubble.left.fill")
                        Text("Start Chat")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloadedModels.isEmpty)
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var downloadedModels: [AIModel] {
        AIModel.allModels.filter { modelManager.isModelDownloaded($0) }
    }
}

// MARK: - Model Selection Row

struct ModelSelectionRow: View {
    let model: AIModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Selection indicator
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.blue : Color(.systemGray4), lineWidth: 2)
                        .frame(width: 24, height: 24)

                    if isSelected {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 14, height: 14)
                    }
                }

                // Model info
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(model.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Capabilities
                    HStack(spacing: 4) {
                        ForEach(model.capabilities.prefix(3), id: \.self) { capability in
                            HStack(spacing: 2) {
                                Image(systemName: capability.icon)
                                Text(capability.rawValue)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                // Size badge
                Text(model.size)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color(.systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick Model Picker (for inline use)

struct QuickModelPicker: View {
    @StateObject private var modelManager = ModelManager.shared
    @State private var showModelSelection = false

    var body: some View {
        Button {
            showModelSelection = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.caption)

                if let model = AIModel.model(withId: modelManager.currentModelId) {
                    Text(model.name)
                        .font(.caption)
                }

                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.systemGray5))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showModelSelection) {
            ModelSelectionView(
                isPresented: $showModelSelection,
                selectedModelId: .constant(nil),
                onStartChat: {}
            )
        }
    }
}

#Preview {
    ModelSelectionView(
        isPresented: .constant(true),
        selectedModelId: .constant(nil),
        onStartChat: {}
    )
}
