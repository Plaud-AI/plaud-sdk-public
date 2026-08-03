package com.plaud.template.models

import com.google.gson.annotations.SerializedName
import java.util.UUID

data class RecordingFile(
    @SerializedName("id")
    val id: String = UUID.randomUUID().toString(),

    @SerializedName("sessionId")
    val sessionId: Long,

    @SerializedName("deviceSN")
    val deviceSN: String,

    @SerializedName("name")
    var name: String,

    @SerializedName("duration")
    var duration: Long,

    @SerializedName("createdAt")
    val createdAt: Long,

    @SerializedName("syncedAt")
    var syncedAt: Long? = null,

    @SerializedName("localPath")
    var localPath: String? = null,

    @SerializedName("summaryText")
    var summaryText: String? = null,

    @SerializedName("transcriptJSON")
    var transcriptJSON: String? = null
) {
    val isSynced: Boolean
        get() = localPath != null
}
