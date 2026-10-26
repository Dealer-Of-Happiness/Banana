//
//  ScreenAwake.swift
//  AIGoodbye
//
//  The one owner of `UIApplication.isIdleTimerDisabled`.
//

import UIKit

/// Keeps the screen from locking while any feature needs it.
///
/// Voice mode, the recorder, the live camera, scene description, translate
/// and a model download each want the screen on, and each used to set the
/// system flag directly: whichever finished first let the phone lock under
/// the others. Every feature now states its own need and the screen stays
/// on while any of them does.
@MainActor
enum ScreenAwake {
    enum Reason: Hashable {
        case liveCamera, voiceMode, translate, sceneDescription, recorder
        /// A model download the user is watching. A locked phone suspends
        /// the app between files, so the download crawled; one tester saw
        /// 30 minutes for a 1 GB model on Wi-Fi.
        case modelDownload
    }

    private(set) static var reasons = Set<Reason>()

    static func set(_ reason: Reason, _ on: Bool) {
        if on {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        let disabled = !reasons.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != disabled {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }
}
