package com.plaud.template.storage

import android.content.Context
import android.content.SharedPreferences
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.plaud.template.models.RecordingFile
import java.io.File

object RecordingStore {

    private const val PREFS_NAME = "plaud_template_prefs"
    private const val KEY_LAST_CONNECTED_SN = "last_connected_device_sn"
    private const val KEY_PAIRED_SNS = "paired_device_sns"
    private const val KEY_PAIRED_NAMES = "paired_device_names"
    private const val KEY_USER_ID = "user_id"
    private const val KEY_AUTO_SYNC = "is_auto_sync_enabled"
    private const val KEY_FAST_TRANSFER_HIDE = "fast_transfer_never_show"
    private const val RECORDINGS_FILE = "recordings.json"

    private lateinit var appContext: Context
    private lateinit var prefs: SharedPreferences
    private val gson = Gson()
    private val lock = Any()

    fun init(context: Context) {
        appContext = context.applicationContext
        prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    // --- SharedPreferences ---

    /** Active device SN (the one currently selected / to auto-reconnect). */
    var lastConnectedDeviceSN: String?
        get() = prefs.getString(KEY_LAST_CONNECTED_SN, null)
        set(value) = prefs.edit().putString(KEY_LAST_CONNECTED_SN, value).apply()

    // --- Paired devices (multi-device support, mirrors iOS) ---

    /** Serial numbers of all paired devices. */
    val pairedDeviceSNs: List<String>
        get() = prefs.getString(KEY_PAIRED_SNS, null)?.let {
            runCatching { gson.fromJson(it, Array<String>::class.java).toList() }.getOrDefault(emptyList())
        } ?: emptyList()

    private fun savePairedDeviceSNs(value: List<String>) =
        prefs.edit().putString(KEY_PAIRED_SNS, gson.toJson(value)).apply()

    /** [SN: display name] cache for paired devices. */
    private val pairedDeviceNames: Map<String, String>
        get() = prefs.getString(KEY_PAIRED_NAMES, null)?.let {
            val type = object : TypeToken<Map<String, String>>() {}.type
            runCatching { gson.fromJson<Map<String, String>>(it, type) }.getOrNull()
        } ?: emptyMap()

    private fun savePairedDeviceNames(value: Map<String, String>) =
        prefs.edit().putString(KEY_PAIRED_NAMES, gson.toJson(value)).apply()

    /** Add a paired device and make it the active device. */
    fun addPairedDevice(sn: String, name: String) {
        val sns = pairedDeviceSNs.toMutableList()
        if (!sns.contains(sn)) sns.add(sn)
        savePairedDeviceSNs(sns)
        savePairedDeviceNames(pairedDeviceNames.toMutableMap().apply { put(sn, name) })
        lastConnectedDeviceSN = sn
    }

    /** Remove a paired device; if it was active, fall back to the first remaining one. */
    fun removePairedDevice(sn: String) {
        val sns = pairedDeviceSNs.toMutableList().apply { remove(sn) }
        savePairedDeviceSNs(sns)
        savePairedDeviceNames(pairedDeviceNames.toMutableMap().apply { remove(sn) })
        if (lastConnectedDeviceSN == sn) lastConnectedDeviceSN = sns.firstOrNull()
    }

    /** Display name for a paired device SN (falls back to the SN itself). */
    fun deviceName(sn: String): String = pairedDeviceNames[sn] ?: sn

    var userId: String?
        get() = prefs.getString(KEY_USER_ID, null)
        set(value) = prefs.edit().putString(KEY_USER_ID, value).apply()

    /** Runtime-entered User Access Token (Settings → Replace). Overrides the build-time value. */
    var userAccessTokenOverride: String?
        get() = prefs.getString("user_access_token_override", null)
        set(value) = prefs.edit().putString("user_access_token_override", value).apply()

    /** Active token = runtime override (account switch / renewal) ?: build-injected default. */
    val activeUserAccessToken: String
        get() = userAccessTokenOverride ?: com.plaud.template.BuildConfig.USER_ACCESS_TOKEN

    /** Runtime-entered transcription API key (Settings → API Key). Overrides the build-time value. */
    var apiKeyOverride: String?
        get() = prefs.getString("api_key_override", null)
        set(value) = prefs.edit().putString("api_key_override", value).apply()

    /** Active API key = runtime override ?: build-injected default. Read per-request, no restart needed. */
    val activeApiKey: String
        get() = apiKeyOverride ?: com.plaud.template.BuildConfig.PLAUD_API_KEY

    /**
     * X-Client-Id for transcription: derived from the active userAccessToken's JWT `client_id`
     * claim so it always matches the account/environment in use; build-injected value as fallback.
     */
    val activeClientId: String
        get() = com.plaud.template.common.JwtUtils.parse(activeUserAccessToken)?.clientId
            ?.takeIf { it.isNotBlank() }
            ?: com.plaud.template.BuildConfig.PLAUD_CLIENT_ID

    const val PROD_SERVER_DOMAIN = "platform-us.plaud.ai"
    const val PRE_SERVER_DOMAIN = "platform-us-pre.plaud.ai"
    const val TEST_SERVER_DOMAIN = "platform-test.plaud.ai"

    /**
     * Selectable environments in display order — single source for the Settings picker and the
     * card label, so adding an environment never leaves the two out of sync.
     */
    val serverEnvironments: List<Pair<String, String>> = listOf(
        "Production" to PROD_SERVER_DOMAIN,
        "Pre-release" to PRE_SERVER_DOMAIN,
        "Test" to TEST_SERVER_DOMAIN
    )

    /** Display label for a domain ("Custom" if it isn't one of the known environments). */
    fun serverEnvironmentLabel(domain: String): String =
        serverEnvironments.firstOrNull { it.second == domain }?.first ?: "Custom"

    /** Runtime-selected server domain (Settings → Environment). Restart to take effect. */
    var serverDomainOverride: String?
        get() = prefs.getString("server_domain_override", null)
        set(value) = prefs.edit().putString("server_domain_override", value).apply()

    /** Default = prod environment (cloud bind/unbind testing); switch via Settings → Environment. */
    val activeServerDomain: String
        get() = serverDomainOverride ?: PROD_SERVER_DOMAIN

    /** Entered the app from Welcome without pairing a device ("Connect device later"). */
    var hasSkippedOnboarding: Boolean
        get() = prefs.getBoolean("has_skipped_onboarding", false)
        set(value) = prefs.edit().putBoolean("has_skipped_onboarding", value).apply()

    var isAutoSyncEnabled: Boolean
        get() = prefs.getBoolean(KEY_AUTO_SYNC, true)
        set(value) = prefs.edit().putBoolean(KEY_AUTO_SYNC, value).apply()

    /** "Never show again" preference for the WiFi fast-transfer confirmation sheet. */
    var fastTransferNeverShowAgain: Boolean
        get() = prefs.getBoolean(KEY_FAST_TRANSFER_HIDE, false)
        set(value) = prefs.edit().putBoolean(KEY_FAST_TRANSFER_HIDE, value).apply()

    // --- Recording Files (JSON persistence) ---

    val allFiles: List<RecordingFile>
        get() = synchronized(lock) {
            loadFiles().sortedByDescending { it.createdAt }
        }

    fun addFiles(files: List<RecordingFile>) {
        synchronized(lock) {
            val existing = loadFiles().toMutableList()
            val existingSessionIds = existing.map { it.sessionId }.toSet()
            val newFiles = files.filter { it.sessionId !in existingSessionIds }
            existing.addAll(newFiles)
            saveFiles(existing)
        }
    }

    fun deleteFile(file: RecordingFile) {
        synchronized(lock) {
            val files = loadFiles().toMutableList()
            files.removeAll { it.id == file.id }
            saveFiles(files)
        }
        // Delete the local audio file
        file.localPath?.let { path ->
            File(path).takeIf { it.exists() }?.delete()
        }
    }

    fun renameFile(file: RecordingFile, newName: String) {
        synchronized(lock) {
            val files = loadFiles().toMutableList()
            files.find { it.id == file.id }?.name = newName
            saveFiles(files)
        }
    }

    fun replaceAllFiles(files: List<RecordingFile>) {
        synchronized(lock) {
            saveFiles(files)
        }
    }

    /** Backfill a real duration (seconds) for a file whose stored duration is 0. */
    fun updateDuration(id: String, durationSec: Long) {
        synchronized(lock) {
            val files = loadFiles().toMutableList()
            files.find { it.id == id }?.duration = durationSec
            saveFiles(files)
        }
    }

    /** Persist a completed transcription (JSON array, same shape iOS stores) for a file id. */
    fun updateTranscript(id: String, transcriptJSON: String) {
        synchronized(lock) {
            val files = loadFiles().toMutableList()
            files.find { it.id == id }?.transcriptJSON = transcriptJSON
            saveFiles(files)
        }
    }

    fun markAsSynced(sessionId: Long, localPath: String, duration: Long) {
        synchronized(lock) {
            val files = loadFiles().toMutableList()
            files.find { it.sessionId == sessionId }?.apply {
                this.localPath = localPath
                this.syncedAt = System.currentTimeMillis()
                this.duration = duration
            }
            saveFiles(files)
        }
    }

    fun audioFilePath(sessionId: Long): File {
        val dir = File(appContext.filesDir, "audio")
        if (!dir.exists()) dir.mkdirs()
        return File(dir, "${sessionId}.opus")
    }

    val exportDir: File
        get() {
            val dir = File(appContext.cacheDir, "export")
            if (!dir.exists()) dir.mkdirs()
            return dir
        }

    fun clearAll() {
        synchronized(lock) {
            saveFiles(emptyList())
        }
        prefs.edit().clear().apply()
        // Delete the audio directory
        File(appContext.filesDir, "audio").takeIf { it.exists() }?.deleteRecursively()
    }

    // --- Private helpers ---

    private fun recordingsFile(): File = File(appContext.filesDir, RECORDINGS_FILE)

    private fun loadFiles(): List<RecordingFile> {
        val file = recordingsFile()
        if (!file.exists()) return emptyList()
        return try {
            val json = file.readText()
            val type = object : TypeToken<List<RecordingFile>>() {}.type
            gson.fromJson(json, type) ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun saveFiles(files: List<RecordingFile>) {
        val json = gson.toJson(files)
        recordingsFile().writeText(json)
    }
}
