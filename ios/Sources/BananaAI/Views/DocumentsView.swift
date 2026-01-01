//
//  DocumentsView.swift
//  BananaAI
//
//  Manage documents for AI knowledge base
//  Users can upload PDFs, text files, etc. to "train" the AI
//

import SwiftUI
import UniformTypeIdentifiers

struct DocumentsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = DocumentsViewModel()
    @State private var showingFilePicker = false
    @State private var showingProcessingSheet = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.documents.isEmpty {
                    EmptyDocumentsView {
                        showingFilePicker = true
                    }
                } else {
                    documentsList
                }
            }
            .navigationTitle("Knowledge Base")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.pdf, .plainText, .text, .rtf],
                allowsMultipleSelection: true
            ) { result in
                handleFileSelection(result)
            }
            .sheet(isPresented: $showingProcessingSheet) {
                ProcessingView(viewModel: viewModel)
            }
        }
        .onAppear {
            viewModel.knowledgeBase = appState.knowledgeBase
            viewModel.documentProcessor = appState.documentProcessor
            Task { await viewModel.loadDocuments() }
        }
    }

    private var documentsList: some View {
        List {
            Section {
                ForEach(viewModel.documents) { doc in
                    DocumentRow(document: doc)
                }
                .onDelete { indexSet in
                    Task { await viewModel.deleteDocuments(at: indexSet) }
                }
            } header: {
                Text("\(viewModel.documents.count) documents • \(viewModel.totalChunks) knowledge chunks")
            }

            Section {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("The AI uses these documents to answer your questions with specific knowledge.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            showingProcessingSheet = true
            Task {
                await viewModel.processFiles(urls)
                showingProcessingSheet = false
            }
        case .failure(let error):
            print("File selection error: \(error)")
        }
    }
}

@MainActor
class DocumentsViewModel: ObservableObject {
    @Published var documents: [Document] = []
    @Published var totalChunks = 0
    @Published var isProcessing = false
    @Published var processingProgress: Double = 0
    @Published var processingFileName = ""
    @Published var processingStatus = ""

    var knowledgeBase: KnowledgeBase?
    var documentProcessor: DocumentProcessor?

    func loadDocuments() async {
        guard let kb = knowledgeBase else { return }
        documents = await kb.getAllDocuments()
        totalChunks = await kb.getTotalChunks()
    }

    func processFiles(_ urls: [URL]) async {
        guard let processor = documentProcessor else { return }
        isProcessing = true

        for (index, url) in urls.enumerated() {
            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            processingFileName = url.lastPathComponent
            processingProgress = Double(index) / Double(urls.count)

            do {
                processingStatus = "Reading file..."
                let document = try await processor.processFile(url) { status in
                    Task { @MainActor in
                        self.processingStatus = status
                    }
                }
                documents.append(document)

            } catch {
                processingStatus = "Error: \(error.localizedDescription)"
            }
        }

        processingProgress = 1.0
        isProcessing = false
        await loadDocuments()
    }

    func deleteDocuments(at indexSet: IndexSet) async {
        guard let kb = knowledgeBase else { return }
        for index in indexSet {
            let doc = documents[index]
            await kb.deleteDocument(id: doc.id)
        }
        documents.remove(atOffsets: indexSet)
        totalChunks = await kb.getTotalChunks()
    }
}

struct Document: Identifiable {
    let id: String
    let name: String
    let type: String
    let size: Int
    let chunks: Int
    let addedDate: Date
}

struct DocumentRow: View {
    let document: Document

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(.yellow)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(document.name)
                    .font(.headline)
                    .lineLimit(1)

                HStack {
                    Text("\(document.chunks) chunks")
                    Text("•")
                    Text(formattedSize)
                    Text("•")
                    Text(formattedDate)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch document.type {
        case "pdf": return "doc.fill"
        case "txt", "text": return "doc.text.fill"
        default: return "doc.fill"
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(document.size), countStyle: .file)
    }

    private var formattedDate: String {
        document.addedDate.formatted(date: .abbreviated, time: .omitted)
    }
}

struct EmptyDocumentsView: View {
    let addAction: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 70))
                .foregroundStyle(.yellow)

            VStack(spacing: 8) {
                Text("No Documents Yet")
                    .font(.title2.bold())

                Text("Add documents to give the AI specialized knowledge.\nFor example, upload a Tesla service manual to get help with car maintenance.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Button(action: addAction) {
                Label("Add Documents", systemImage: "plus")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)

            VStack(alignment: .leading, spacing: 8) {
                Text("Supported formats:")
                    .font(.caption.bold())

                HStack {
                    Label("PDF", systemImage: "doc.fill")
                    Label("TXT", systemImage: "doc.text.fill")
                    Label("RTF", systemImage: "doc.richtext.fill")
                }
                .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 20)
        }
        .padding()
    }
}

struct ProcessingView: View {
    @ObservedObject var viewModel: DocumentsViewModel

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Processing Documents")
                .font(.headline)

            if !viewModel.processingFileName.isEmpty {
                Text(viewModel.processingFileName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(viewModel.processingStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: viewModel.processingProgress)
                .frame(width: 200)
        }
        .padding(40)
        .presentationDetents([.height(250)])
        .interactiveDismissDisabled()
    }
}

#Preview {
    DocumentsView()
        .environmentObject(AppState())
}
