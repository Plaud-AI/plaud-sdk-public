package com.plaud.template.models

data class SyncProgress(
    val totalFiles: Int,
    val syncedFiles: Int,
    val currentFileName: String? = null,
    val fileProgress: Float = 0f,
    val bytesPerSecond: Long = 0L
) {
    val progressFraction: Float
        get() = if (totalFiles > 0) {
            (syncedFiles.toFloat() + fileProgress) / totalFiles
        } else {
            0f
        }

    val speedText: String
        get() {
            val mbps = bytesPerSecond / (1024f * 1024f)
            return if (mbps >= 1f) {
                String.format("%.1f MB/s", mbps)
            } else {
                val kbps = bytesPerSecond / 1024f
                String.format("%.0f KB/s", kbps)
            }
        }
}
