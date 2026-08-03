package com.plaud.template.managers

import com.plaud.template.models.RecordingFile
import com.plaud.template.models.SyncState
import kotlinx.coroutines.flow.StateFlow
import java.io.File

interface SyncManagerProtocol {
    val state: StateFlow<SyncState>
    val files: StateFlow<List<RecordingFile>>

    fun fetchFileList()
    fun startSync()
    fun startWiFiTransfer()
    fun stopSync()
    fun deleteFile(file: RecordingFile)
    fun renameFile(file: RecordingFile, newName: String)
    fun exportAudio(file: RecordingFile, callback: (Result<File>) -> Unit)
}
