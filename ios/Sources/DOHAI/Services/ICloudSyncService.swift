//
//  ICloudSyncService.swift
//  DOH AI
//
//  iCloud sync for conversations and settings
//

import Foundation
import CloudKit
import UIKit
import CoreGraphics

class ICloudSyncService {
    private let settings: SettingsManager
    private var container: CKContainer?
    private var database: CKDatabase?

    init(settings: SettingsManager) {
        self.settings = settings
        // Lazy initialization to avoid crash if iCloud not configured
    }

    private func setupCloudKit() {
        if container == nil {
            container = CKContainer.default()
            database = container?.privateCloudDatabase
        }
    }

    // MARK: - Sync

    func sync() async throws {
        guard settings.iCloudSyncEnabled else { return }

        setupCloudKit()
        guard let container = container else { return }

        // Check iCloud availability
        let status = try await container.accountStatus()
        guard status == .available else {
            throw ICloudError.notAvailable
        }

        // Sync conversations
        try await syncConversations()
    }

    // MARK: - Conversations

    private func syncConversations() async throws {
        guard let database = database else { return }

        // Fetch remote changes
        let query = CKQuery(recordType: "Conversation", predicate: NSPredicate(value: true))
        let records = try await database.records(matching: query)

        // Merge with local data
        for (_, result) in records.matchResults {
            if case .success(let record) = result {
                // Process record
                _ = record
            }
        }
    }

    func uploadConversation(_ conversation: Conversation) async throws {
        guard settings.iCloudSyncEnabled else { return }
        setupCloudKit()
        guard let database = database else { return }

        let record = CKRecord(recordType: "Conversation")
        record["id"] = conversation.id.uuidString
        record["title"] = conversation.title
        record["createdAt"] = conversation.createdAt
        record["updatedAt"] = conversation.updatedAt

        try await database.save(record)
    }

    func deleteConversation(id: UUID) async throws {
        guard settings.iCloudSyncEnabled else { return }
        setupCloudKit()
        guard let database = database else { return }

        let recordID = CKRecord.ID(recordName: id.uuidString)
        try await database.deleteRecord(withID: recordID)
    }

    // MARK: - Export

    func exportConversations(format: ExportFormat) async throws -> URL {
        // Get all conversations from local storage
        let conversations: [Conversation] = [] // Fetch from SwiftData

        let fileName = "DOH_AI_Export_\(Date().ISO8601Format())"
        let tempDir = FileManager.default.temporaryDirectory

        switch format {
        case .txt:
            return try exportAsText(conversations, to: tempDir.appendingPathComponent("\(fileName).txt"))
        case .pdf:
            return try exportAsPDF(conversations, to: tempDir.appendingPathComponent("\(fileName).pdf"))
        case .json:
            return try exportAsJSON(conversations, to: tempDir.appendingPathComponent("\(fileName).json"))
        }
    }

    private func exportAsText(_ conversations: [Conversation], to url: URL) throws -> URL {
        var content = "DOH AI Conversations Export\n"
        content += "Exported: \(Date().formatted())\n"
        content += "=" .padding(toLength: 50, withPad: "=", startingAt: 0) + "\n\n"

        for conversation in conversations {
            content += "## \(conversation.title)\n"
            content += "Created: \(conversation.createdAt.formatted())\n\n"

            for message in conversation.messages {
                let role = message.role == .user ? "You" : "DOH AI"
                content += "\(role): \(message.content)\n\n"
            }

            content += "-".padding(toLength: 50, withPad: "-", startingAt: 0) + "\n\n"
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func exportAsPDF(_ conversations: [Conversation], to url: URL) throws -> URL {
        // Create PDF using UIGraphicsPDFRenderer
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let data = renderer.pdfData { context in
            context.beginPage()

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 24)
            ]

            let bodyAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12)
            ]

            var yOffset: CGFloat = 50

            "DOH AI Conversations".draw(at: CGPoint(x: 50, y: yOffset), withAttributes: titleAttributes)
            yOffset += 40

            for conversation in conversations {
                if yOffset > 700 {
                    context.beginPage()
                    yOffset = 50
                }

                conversation.title.draw(at: CGPoint(x: 50, y: yOffset), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 14)])
                yOffset += 25

                for message in conversation.messages {
                    let role = message.role == .user ? "You: " : "DOH AI: "
                    let text = role + message.content
                    text.draw(in: CGRect(x: 50, y: yOffset, width: 512, height: 100), withAttributes: bodyAttributes)
                    yOffset += 50
                }

                yOffset += 20
            }
        }

        try data.write(to: url)
        return url
    }

    private func exportAsJSON(_ conversations: [Conversation], to url: URL) throws -> URL {
        let exportData = conversations.map { conversation in
            [
                "id": conversation.id.uuidString,
                "title": conversation.title,
                "createdAt": conversation.createdAt.ISO8601Format(),
                "messages": conversation.messages.map { message in
                    [
                        "role": message.role.rawValue,
                        "content": message.content,
                        "timestamp": message.timestamp.ISO8601Format()
                    ]
                }
            ] as [String: Any]
        }

        let json = try JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted)
        try json.write(to: url)
        return url
    }
}

// MARK: - Errors

enum ICloudError: LocalizedError {
    case notAvailable
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "iCloud is not available"
        case .syncFailed(let reason):
            return "Sync failed: \(reason)"
        }
    }
}
