package com.plaud.template.managers

import com.plaud.template.BuildConfig
import com.plaud.template.common.AppLog
import com.plaud.template.storage.RecordingStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/** Transcription state (mirrors iOS TranscriptionState). */
sealed class TranscriptionState {
    object Idle : TranscriptionState()
    data class Uploading(val progress: Float) : TranscriptionState()
    object Submitting : TranscriptionState()
    data class Processing(val status: String) : TranscriptionState()
    /** resultsJson = JSON array of {speaker_id, start, end, text, language} — same shape iOS persists. */
    data class Completed(val resultsJson: String) : TranscriptionState()
    data class Failed(val message: String) : TranscriptionState()
}

/**
 * Transcription manager: upload → submit → poll (mirrors iOS TranscriptionManager).
 *
 * Auth (see PARTNER_API_GUIDE.md):
 * - File upload (S3 multipart 3-step): Bearer userAccessToken
 * - Transcription submit/query: X-Client-Id + X-Client-Api-Key
 */
class TranscriptionManager private constructor() {

    companion object {
        private const val TAG = "Transcription"
        private val BASE_URL get() = "https://${RecordingStore.activeServerDomain}/developer/api"
        private const val DEFAULT_CHUNK = 5 * 1024 * 1024
        private const val POLL_INTERVAL_MS = 5_000L
        /** 240 x 5s = 20 min — the server queue can back up, so leave generous headroom. */
        private const val MAX_POLLS = 240

        @Volatile
        private var instance: TranscriptionManager? = null
        val shared: TranscriptionManager
            get() = instance ?: synchronized(this) {
                instance ?: TranscriptionManager().also { instance = it }
            }
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val json = "application/json".toMediaType()
    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .build()

    private val _state = MutableStateFlow<TranscriptionState>(TranscriptionState.Idle)
    val state: StateFlow<TranscriptionState> = _state.asStateFlow()

    /**
     * Bumped on every transcribe()/reset(); a slow earlier task (e.g. one stuck in PROGRESS while
     * the server queue was backed up) captures its generation at start and is silently dropped once
     * it is no longer current — so it can't overwrite a newer task's completed result.
     */
    private val generation = java.util.concurrent.atomic.AtomicInteger(0)

    /** Emit only if [gen] is still the active generation (drops stale-task updates). */
    private fun emit(gen: Int, state: TranscriptionState) {
        if (gen == generation.get()) _state.value = state
    }

    fun reset() {
        generation.incrementAndGet()
        _state.value = TranscriptionState.Idle
    }

    /** Start the complete transcription flow from a local audio file. */
    fun transcribe(audioPath: String) {
        val gen = generation.incrementAndGet()
        val file = File(audioPath)
        if (!file.exists()) {
            emit(gen, TranscriptionState.Failed("Audio file not found: $audioPath"))
            return
        }
        if (RecordingStore.activeClientId.isBlank() || RecordingStore.activeApiKey.isBlank()) {
            emit(gen, TranscriptionState.Failed("Client ID or API key not configured (local.properties / Settings → API Key)"))
            return
        }
        // The upload API rejects wav (FILE_TYPE_INVALID). New syncs export OPUS; older local
        // files synced as .wav must be deleted and re-synced before they can be transcribed.
        if (file.extension.equals("wav", ignoreCase = true)) {
            emit(gen, TranscriptionState.Failed(
                "WAV is not supported by the transcription service. Delete this recording locally and sync it again (new syncs use MP3)."
            ))
            return
        }
        emit(gen, TranscriptionState.Uploading(0f))
        AppLog.i(TAG, "Starting transcription flow (gen $gen): $audioPath")

        scope.launch {
            try {
                val downloadUrl = uploadFile(file, gen)
                AppLog.i(TAG, "Upload complete, downloadUrl obtained")
                submitAndPoll(downloadUrl, gen)
            } catch (e: Exception) {
                AppLog.e(TAG, "Transcription flow failed", e)
                emit(gen, TranscriptionState.Failed(e.message ?: "Unknown error"))
            }
        }
    }

    // MARK: - Step 1: File upload (S3 multipart 3-step)

    private fun uploadFile(file: File, gen: Int): String {
        val data = file.readBytes()
        val filetype = file.extension.lowercase().ifBlank { "opus" }
        val token = RecordingStore.activeUserAccessToken
        val md5 = data.md5Hex()

        AppLog.i(TAG, "Step 1: generate-presigned-urls (size=${data.size}, type=$filetype)")
        val presigned = postJson(
            url = "$BASE_URL/open/partner/files/upload/generate-presigned-urls",
            body = JSONObject().put("filesize", data.size).put("filetype", filetype),
            headers = mapOf("Authorization" to "Bearer $token")
        )
        val fileId = presigned.getString("FileId")
        val uploadId = presigned.getString("UploadId")
        val chunkSize = presigned.optInt("ChunkSize", DEFAULT_CHUNK)
        val parts = presigned.getJSONArray("Parts")
        AppLog.i(TAG, "Got ${parts.length()} part URLs, fileId=$fileId")

        // Step 2: PUT parts to S3, collect ETags
        val partList = JSONArray()
        for (i in 0 until parts.length()) {
            val part = parts.getJSONObject(i)
            val start = i * chunkSize
            val end = minOf(start + chunkSize, data.size)
            emit(gen, TranscriptionState.Uploading(i.toFloat() / parts.length()))
            AppLog.i(TAG, "Step 2: PUT part ${i + 1}/${parts.length()} (${end - start} bytes)")

            val put = Request.Builder()
                .url(part.getString("PresignedUrl"))
                .put(data.copyOfRange(start, end).toRequestBody())
                .build()
            client.newCall(put).execute().use { resp ->
                if (!resp.isSuccessful) throw IllegalStateException("S3 PUT part ${i + 1} failed: HTTP ${resp.code}")
                val etag = (resp.header("ETag") ?: "").replace("\"", "")
                partList.put(JSONObject()
                    .put("PartNumber", part.getInt("PartNumber"))
                    .put("ETag", etag))
            }
        }

        // Step 3: complete-upload
        emit(gen, TranscriptionState.Uploading(1f))
        AppLog.i(TAG, "Step 3: complete-upload (${parts.length()} parts)")
        val complete = postJson(
            url = "$BASE_URL/open/partner/files/upload/complete-upload",
            body = JSONObject()
                .put("file_id", fileId)
                .put("upload_id", uploadId)
                .put("part_list", partList)
                .put("filetype", filetype)
                .put("file_md5", md5),
            headers = mapOf("Authorization" to "Bearer $token")
        )
        val downloadUrl = complete.optString("DownloadUrl")
        if (downloadUrl.isBlank()) throw IllegalStateException("complete-upload returned no DownloadUrl")
        return downloadUrl
    }

    // MARK: - Step 2: Submit + poll

    private suspend fun submitAndPoll(fileUrl: String, gen: Int) {
        emit(gen, TranscriptionState.Submitting)
        val authHeaders = mapOf(
            "X-Client-Id" to RecordingStore.activeClientId,
            "X-Client-Api-Key" to RecordingStore.activeApiKey
        )

        AppLog.i(TAG, "Submitting transcription task...")
        val submit = postJson(
            url = "$BASE_URL/open/partner/ai/transcriptions/",
            body = JSONObject()
                .put("file_url", fileUrl)
                .put("params", JSONObject()
                    .put("transcribe", JSONObject().put("language", "auto").put("model", "plaud-fast-whisper"))
                    .put("vad", JSONObject().put("decode_silence", false))
                    .put("diarization", JSONObject().put("enabled", false).put("return_embedding", false))),
            headers = authHeaders
        )
        val tid = submit.optString("transcription_id")
            .ifBlank { submit.optJSONObject("data")?.optString("task_id") ?: "" }
        if (tid.isBlank()) {
            val msg = submit.optString("message", submit.optString("status", "unknown error"))
            emit(gen, TranscriptionState.Failed("Transcription submit failed: $msg"))
            return
        }
        AppLog.i(TAG, "Task submitted: transcription_id=$tid")
        emit(gen, TranscriptionState.Processing("PENDING"))

        // Poll every 5s, up to MAX_POLLS
        for (attempt in 1..MAX_POLLS) {
            // Superseded by a newer transcription — stop this poll loop entirely.
            if (gen != generation.get()) return
            delay(POLL_INTERVAL_MS)
            val resp = getJson("$BASE_URL/open/partner/ai/transcriptions/$tid", authHeaders)
            val status = resp.optString("status")
                .ifBlank { resp.optJSONObject("data")?.optString("task_status") ?: "" }
            AppLog.i(TAG, "Poll $attempt/$MAX_POLLS (gen $gen): status=$status")

            when (status.uppercase()) {
                "SUCCESS" -> {
                    val results = resp.optJSONObject("data")?.optJSONArray("results") ?: JSONArray()
                    AppLog.i(TAG, "Transcription complete! resultsCount=${results.length()}")
                    emit(gen, TranscriptionState.Completed(results.toString()))
                    return
                }
                "FAILURE", "REVOKED" -> {
                    emit(gen, TranscriptionState.Failed("Transcription failed: ${resp.optString("message", status)}"))
                    return
                }
                else -> emit(gen, TranscriptionState.Processing(status.ifBlank { "PROCESSING" }))
            }
        }
        emit(gen, TranscriptionState.Failed("Transcription timed out after $MAX_POLLS polls"))
    }

    // MARK: - HTTP helpers

    private fun postJson(url: String, body: JSONObject, headers: Map<String, String>): JSONObject {
        val req = Request.Builder().url(url)
            .post(body.toString().toRequestBody(json))
            .apply { headers.forEach { (k, v) -> header(k, v) } }
            .build()
        return execute(req)
    }

    private fun getJson(url: String, headers: Map<String, String>): JSONObject {
        val req = Request.Builder().url(url)
            .apply { headers.forEach { (k, v) -> header(k, v) } }
            .build()
        return execute(req)
    }

    private fun execute(req: Request): JSONObject {
        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string() ?: ""
            if (!resp.isSuccessful) {
                AppLog.w(TAG, "HTTP ${resp.code} ${req.url.encodedPath}: ${text.take(300)}")
                throw IllegalStateException("HTTP ${resp.code}: ${text.take(200)}")
            }
            return if (text.isBlank()) JSONObject() else JSONObject(text)
        }
    }

    private fun ByteArray.md5Hex(): String =
        MessageDigest.getInstance("MD5").digest(this).joinToString("") { "%02x".format(it) }
}
