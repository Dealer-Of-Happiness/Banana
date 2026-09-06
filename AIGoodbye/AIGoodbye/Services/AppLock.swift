//
//  AppLock.swift
//  AIGoodbye
//
//  Optional Face ID / Touch ID lock. Conversations are private by design;
//  this keeps them private from someone holding the unlocked phone too.
//

import Foundation
import LocalAuthentication
import Combine

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    /// True when the app is locked and content must be hidden.
    @Published private(set) var isLocked = false
    @Published private(set) var lastError: String?

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { isLocked = false }
        }
    }

    private static let enabledKey = "app_lock_enabled"
    private var authenticating = false
    /// Set when the user dismisses the prompt, so returning to the app
    /// doesn't immediately present it again in a loop.
    private var userDismissed = false

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isLocked = isEnabled
    }

    /// Whether this device can do biometrics or a passcode at all.
    var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Human name for the available biometry, for labels.
    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return L10n.text("Passcode")
        }
    }

    /// Lock when leaving the app so the content is hidden on return.
    func lockIfNeeded() {
        guard isEnabled else { return }
        isLocked = true
        userDismissed = false
    }

    /// Called when the app becomes active: only re-prompts if the user
    /// hasn't just dismissed the prompt themselves.
    func unlockOnForeground() async {
        guard !userDismissed else { return }
        await unlock()
    }

    func unlock() async {
        guard isEnabled, isLocked, !authenticating else { return }

        // If biometrics AND the passcode have become unavailable, the user
        // could never get back in - so release the lock instead of trapping
        // them with their conversations inside.
        guard isAvailable else {
            isEnabled = false
            isLocked = false
            lastError = nil
            return
        }

        authenticating = true
        defer { authenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = L10n.text("Cancel")
        let reason = L10n.text("Unlock your private conversations")

        do {
            // deviceOwnerAuthentication falls back to the passcode.
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok {
                isLocked = false
                lastError = nil
                userDismissed = false
            }
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .systemCancel, .appCancel:
                // Wait for an explicit tap on Unlock.
                userDismissed = true
                lastError = nil
            case .userFallback:
                userDismissed = true
                lastError = nil
            default:
                lastError = L10n.text("Couldn't unlock. Try again.")
            }
        } catch {
            lastError = L10n.text("Couldn't unlock. Try again.")
        }
    }
}
