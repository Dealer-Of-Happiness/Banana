//
//  AIGoodbyeTests.swift
//  AIGoodbyeTests
//
//  Unit tests for the v3.0 engine logic.
//

import Testing
import Foundation
@testable import AIGoodbye

struct HistoryTrimmingTests {

    @Test func keepsRecentMessagesWithinBudget() {
        let history: [(role: String, content: String)] = (0..<40).map {
            (role: $0 % 2 == 0 ? "user" : "assistant", content: "Message \($0) " + String(repeating: "x", count: 500))
        }
        let trimmed = MLXService.trimHistory(history, tokenBudget: 4096)

        #expect(!trimmed.isEmpty)
        #expect(trimmed.count < history.count)
        // Most recent message must survive.
        #expect(trimmed.last?.content.hasPrefix("Message 39") == true)
        // Order preserved.
        let indices = trimmed.compactMap { entry in
            Int(entry.content.split(separator: " ")[1])
        }
        #expect(indices == indices.sorted())
    }

    @Test func capsOversizedSingleMessages() {
        let huge = String(repeating: "a", count: 20_000)
        let trimmed = MLXService.trimHistory([("user", huge)], tokenBudget: 32_768)
        #expect(trimmed.count == 1)
        #expect(trimmed[0].content.count < 5_000)
        #expect(trimmed[0].content.contains("[Truncated]"))
    }

    @Test func emptyHistoryStaysEmpty() {
        let trimmed = MLXService.trimHistory([], tokenBudget: 8192)
        #expect(trimmed.isEmpty)
    }
}

struct ModelCatalogTests {

    @Test func modelIdsAreUnique() {
        let ids = AIModel.allModels.map(\.id) + [AIModel.appleIntelligence.id]
        #expect(Set(ids).count == ids.count)
    }

    @Test func lookupFindsEveryModel() {
        for model in AIModel.allModels {
            #expect(AIModel.model(withId: model.id)?.id == model.id)
        }
        #expect(AIModel.model(withId: AIModel.appleIntelligence.id)?.backend == .appleIntelligence)
        #expect(AIModel.model(withId: "does-not-exist") == nil)
    }

    @Test func downloadableModelsHaveHuggingFaceIds() {
        for model in AIModel.allModels {
            #expect(model.backend == .mlx)
            #expect(model.huggingFaceId?.isEmpty == false)
            #expect(model.sizeBytes > 0)
        }
    }

    @Test func recommendedModelMatchesDeviceTier() {
        let recommended = AIModel.recommendedDownloadModel
        if DeviceCapability.physicalMemoryGB >= 6 {
            #expect(recommended.id == AIModel.qwen3VL2B.id)
        } else {
            #expect(recommended.id == AIModel.smolVLM2.id)
        }
        #expect(!recommended.isLegacy)
    }
}

struct LegalTextTests {

    @Test func legalCopyIsCompleteAndOffline() {
        #expect(LegalText.sections.count == 6)
        let allText = LegalText.sections.map { $0.title + " " + $0.body }.joined(separator: " ")
        // The one source of truth must reflect the offline reality.
        #expect(!allText.lowercased().contains("api key"))
        #expect(allText.contains("aigoodbye.ai"))
        #expect(allText.contains("marketing@dealerofhappiness.com"))
    }
}
