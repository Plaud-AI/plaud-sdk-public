import Foundation

/// File sync progress snapshot
struct SyncProgress {
    let totalFiles: Int
    let syncedFiles: Int
    let currentFileName: String?
    /// Current file download progress 0-100
    var fileProgress: Int = 0
    /// Transfer speed (bytes/sec)
    var bytesPerSecond: Double = 0

    var progressFraction: Float {
        guard totalFiles > 0 else { return 0 }
        // File-level progress + intra-file progress
        let fileFraction = Float(syncedFiles) / Float(totalFiles)
        let inFileFraction = Float(fileProgress) / 100.0 / Float(totalFiles)
        return fileFraction + inFileFraction
    }

    var speedText: String {
        if bytesPerSecond <= 0 { return "" }
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1fMB/s", bytesPerSecond / 1_048_576)
        }
        return String(format: "%.1fKB/s", bytesPerSecond / 1024)
    }
}
