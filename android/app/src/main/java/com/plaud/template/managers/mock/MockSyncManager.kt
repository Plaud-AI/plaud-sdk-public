package com.plaud.template.managers.mock

import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import com.plaud.template.managers.SyncManagerProtocol
import com.plaud.template.models.*
import java.io.File
import java.util.UUID

/**
 * Mock sync manager for use while developing the Files / Settings UI
 */
class MockSyncManager : SyncManagerProtocol {

    companion object {
        private const val TAG = "MockSyncManager"
    }

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private val _state = MutableStateFlow<SyncState>(SyncState.Idle)
    override val state: StateFlow<SyncState> = _state.asStateFlow()

    private val _files = MutableStateFlow(makeMockFiles())
    override val files: StateFlow<List<RecordingFile>> = _files.asStateFlow()

    override fun fetchFileList() {
        Log.d(TAG, "fetchFileList (no-op)")
    }

    override fun startSync() {
        Log.d(TAG, "startSync (mock)")
        _state.value = SyncState.Syncing(
            SyncProgress(totalFiles = 3, syncedFiles = 0, currentFileName = "Untitled Recording")
        )
        scope.launch {
            delay(2000)
            _state.value = SyncState.Completed
        }
    }

    override fun startWiFiTransfer() {
        Log.d(TAG, "startWiFiTransfer (no-op)")
    }

    override fun stopSync() {
        _state.value = SyncState.Idle
    }

    override fun deleteFile(file: RecordingFile) {
        val current = _files.value.toMutableList()
        current.removeAll { it.id == file.id }
        _files.value = current
    }

    override fun renameFile(file: RecordingFile, name: String) {
        val current = _files.value.toMutableList()
        val idx = current.indexOfFirst { it.id == file.id }
        if (idx >= 0) {
            current[idx] = current[idx].copy(name = name)
            _files.value = current
        }
    }

    override fun exportAudio(file: RecordingFile, completion: (Result<File>) -> Unit) {
        val tmpDir = System.getProperty("java.io.tmpdir") ?: "/tmp"
        val mockFile = File(tmpDir, "${file.sessionId}.wav")
        completion(Result.success(mockFile))
    }

    // MARK: - Mock data

    private fun makeMockFiles(): List<RecordingFile> {
        val now = System.currentTimeMillis()
        return listOf(
            RecordingFile(
                id = "mock-1",
                sessionId = (now / 1000) - 86400L,
                deviceSN = "MOCK-SN-001",
                name = "Team Standup",
                duration = 1823L,   // ~30 minutes
                createdAt = now - 86_400_000L,
                syncedAt = now - 86_300_000L,
                localPath = "/mock/path/1.wav",
                summaryText = "Today's standup covered the Q2 goals and the iteration plan.",
                transcriptJSON = null
            ),
            RecordingFile(
                id = "mock-2",
                sessionId = (now / 1000) - 172800L,
                deviceSN = "MOCK-SN-001",
                name = "Product Review",
                duration = 3612L,   // ~60 minutes
                createdAt = now - 172_800_000L,
                syncedAt = now - 172_700_000L,
                localPath = "/mock/path/2.wav",
                summaryText = null,
                transcriptJSON = null
            ),
            RecordingFile(
                id = "mock-3",
                sessionId = (now / 1000) - 3600L,
                deviceSN = "MOCK-SN-001",
                name = "Untitled Recording",
                duration = 900L,    // 15 minutes
                createdAt = now - 3_600_000L,
                syncedAt = null,
                localPath = null,
                summaryText = null,
                transcriptJSON = null
            )
        )
    }
}
