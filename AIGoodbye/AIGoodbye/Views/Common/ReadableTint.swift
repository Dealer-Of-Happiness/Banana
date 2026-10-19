//
//  ReadableTint.swift
//  AIGoodbye
//
//  Text colors for the app's tinted buttons: a color at 10-15% behind text
//  in the same color ("Start chatting", "Start recording", "Hands-free
//  conversation"). Plain systemBlue and systemRed on their own tint measure
//  about 3.5:1 in light mode, under the 4.5:1 that text needs. These keep
//  the hue but go darker in light mode (about 6:1 and 5.7:1), darker still
//  with Increase Contrast. Dark mode keeps the system color, which already
//  reads well on a dark tint.
//

import SwiftUI
import UIKit

extension Color {
    static let tintedBlue = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark { return .systemBlue }
        return traits.accessibilityContrast == .high
            ? UIColor(red: 0.0, green: 0.22, blue: 0.62, alpha: 1)
            : UIColor(red: 0.0, green: 0.32, blue: 0.80, alpha: 1)
    })

    static let tintedRed = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark { return .systemRed }
        return traits.accessibilityContrast == .high
            ? UIColor(red: 0.58, green: 0.05, blue: 0.03, alpha: 1)
            : UIColor(red: 0.70, green: 0.08, blue: 0.05, alpha: 1)
    })

    /// A deep red for a solid button with white text, in both appearances:
    /// systemRed is a light coral in Dark Mode (and lighter still with
    /// Increase Contrast), where white text on it measured under 3:1.
    static let solidRed = Color(uiColor: UIColor { traits in
        traits.accessibilityContrast == .high
            ? UIColor(red: 0.58, green: 0.05, blue: 0.03, alpha: 1)
            : UIColor(red: 0.70, green: 0.08, blue: 0.05, alpha: 1)
    })
}
