//
//  RecordingEditorPresentation.swift
//  lhg-CueRecord
//
//  Ported from nolangz/CueRecord. Modified for lhg-CueRecord.
//

import Foundation

/// Decides whether the post-recording editor should be presented for a take.
nonisolated enum RecordingEditorPresentation {
    /// The editor is keyed to the take it was opened for, not to a global "something is
    /// already showing" flag. A take that is not the one currently open always gets its own
    /// editor — otherwise recording a second take while a stale editor stays open drops the
    /// first one's export UI and leaves the new take as raw, uncomposited assets.
    static func shouldPresent(currentTakeURL: URL?, for takeURL: URL) -> Bool {
        guard let currentTakeURL else { return true }
        return currentTakeURL.standardizedFileURL != takeURL.standardizedFileURL
    }
}
