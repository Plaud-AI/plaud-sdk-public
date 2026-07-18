import Foundation

/// Local recording file record
struct RecordingFile: Identifiable, Codable {
    let id: String                    // Local unique ID (UUID)
    let sessionId: Int                // Device-side sessionId (recording start timestamp)
    let deviceSN: String              // Source device SN
    var name: String                  // Display name (default "Untitled Recording")
    var duration: TimeInterval        // Duration in seconds (parsed from audio file, 0 before sync completes)
    let createdAt: Date               // Recording time (derived from sessionId)
    var syncedAt: Date?               // Sync completion time
    var localPath: String?            // Local audio path (available after sync)
    var summaryText: String?          // AI summary
    var transcriptJSON: String?       // Transcription data JSON

    var isSynced: Bool { localPath != nil }
}

extension RecordingFile {
    static let defaultName = "Untitled Recording"
}
