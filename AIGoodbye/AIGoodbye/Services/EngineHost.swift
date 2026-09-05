//
//  EngineHost.swift
//  AIGoodbye
//
//  Owns the settings and the chat engine independently of the SwiftUI view
//  tree, so Siri and Shortcuts work even when the app was never opened in
//  this launch (App Intents can run in a background process where no scene,
//  and therefore no AppState, exists).
//

import Foundation

@MainActor
final class EngineHost {
    static let shared = EngineHost()

    let settings: SettingsManager
    let engine: ChatEngine

    private init() {
        let settings = SettingsManager()
        self.settings = settings
        self.engine = ChatEngine(settings: settings)
    }
}
