package com.plaud.template.common

import android.util.Base64
import org.json.JSONObject

/**
 * Minimal JWT payload reader for the userAccessToken (display + account-switch detection only —
 * no signature verification; the backend remains the source of truth).
 */
object JwtUtils {

    data class TokenInfo(val sub: String, val userId: String, val expSeconds: Long, val clientId: String)

    /** Parse sub / user_id / exp / client_id from a JWT; null if the token is malformed. */
    fun parse(token: String): TokenInfo? = try {
        val parts = token.trim().split(".")
        if (parts.size != 3) null else {
            val payload = String(
                Base64.decode(parts[1], Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP),
                Charsets.UTF_8
            )
            val obj = JSONObject(payload)
            val sub = obj.optString("sub")
            if (sub.isBlank()) null
            else TokenInfo(
                sub = sub,
                userId = obj.optString("user_id", sub),
                expSeconds = obj.optLong("exp", 0L),
                clientId = obj.optString("client_id")
            )
        }
    } catch (e: Exception) {
        null
    }

    /** "eyJhb…Kdxg" style mask for on-screen display. */
    fun mask(token: String): String =
        if (token.length <= 12) token else "${token.take(6)}…${token.takeLast(6)}"
}
