//
//  LegalText.swift
//  AIGoodbye
//
//  Single source of truth for the legal/about copy shared by onboarding
//  and Settings, so the two screens never drift apart. Resolved through
//  L10n so it follows the in-app language immediately.
//

import Foundation

enum LegalText {

    static let appName = "AiGoodbye"

    static var tagline: String {
        L10n.text("Private, on-device AI. No internet needed, no subscriptions, no data leaving your phone.")
    }

    /// The sections rendered as cards in onboarding and reused anywhere the
    /// app explains itself. Order matters: privacy first, contact last.
    static var sections: [(title: String, body: String, icon: String)] {
        [
            (
                title: L10n.text("100% Private, 100% Offline"),
                body: L10n.text("All AI runs directly on your device, and your conversations never leave your phone. There are no servers, no accounts, no tracking, and no data collection. What you talk about stays yours."),
                icon: "lock.shield.fill"
            ),
            (
                title: L10n.text("Model Downloads"),
                body: L10n.text("AI models are downloaded once from Hugging Face - about 1 to 2 GB, so Wi-Fi is recommended. After the download, everything works fully offline. You can delete models anytime in Settings."),
                icon: "arrow.down.circle.fill"
            ),
            (
                title: L10n.text("Apple Intelligence"),
                body: L10n.text("On supported devices, the app can also use Apple's built-in on-device model. It starts instantly with no download at all. Like everything else in the app, it is fully offline."),
                icon: "sparkles"
            ),
            (
                title: L10n.text("AI Limitations"),
                body: L10n.text("AI answers can be inaccurate or incomplete, so always verify important information. AiGoodbye is not a substitute for professional medical, legal, or financial advice."),
                icon: "exclamationmark.triangle.fill"
            ),
            (
                title: L10n.text("Your Purchase"),
                body: L10n.text("AiGoodbye is a one-time purchase. There are no subscriptions and no hidden fees - pay once and it is yours."),
                icon: "checkmark.seal.fill"
            ),
            (
                title: L10n.text("Contact"),
                body: L10n.text("Questions or ideas? Visit aigoodbye.ai or email marketing@dealerofhappiness.com. We would love to hear from you."),
                icon: "envelope.fill"
            )
        ]
    }
}
