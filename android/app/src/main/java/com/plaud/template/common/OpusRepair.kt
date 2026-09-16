package com.plaud.template.common

import java.io.RandomAccessFile

/**
 * Repairs the malformed OpusTags header the Android SDK's Ogg/Opus exporter writes.
 *
 * SDK bug (byte-level): in the OpusTags packet the `user_comment_list_length` field is written
 * as the remaining BYTE length (e.g. 0x193) instead of the comment COUNT, so parsers read the
 * following bytes ("Tinn"...) as a comment length (1852729684) and crash — both MediaPlayer
 * (error -38) and ExoPlayer (StringIndexOutOfBounds in VorbisUtil) reject the file, while
 * tolerant server-side decoders (ffmpeg) still transcribe it.
 *
 * Repair: zero the comment count in place and rewrite the page CRC. Idempotent and cheap;
 * remove once the SDK exporter is fixed (tracked in sdk-requests-android-parity.md).
 */
object OpusRepair {

    /** Repair the file in place if its OpusTags count is corrupt. Returns true if patched. */
    fun repairIfNeeded(path: String): Boolean = try {
        RandomAccessFile(path, "rw").use { raf ->
            // Read enough to cover the two header pages
            val head = ByteArray(minOf(raf.length(), 8_192L).toInt())
            raf.seek(0)
            raf.readFully(head)

            fun isOggS(off: Int) =
                off + 27 <= head.size && head[off] == 'O'.code.toByte() && head[off + 1] == 'g'.code.toByte() &&
                    head[off + 2] == 'g'.code.toByte() && head[off + 3] == 'S'.code.toByte()

            if (!isOggS(0)) return false
            // Page 1 (OpusHead)
            val segs1 = head[26].toInt() and 0xFF
            var body1 = 0
            for (i in 0 until segs1) body1 += head[27 + i].toInt() and 0xFF
            val page2 = 27 + segs1 + body1
            if (!isOggS(page2)) return false

            // Page 2 (OpusTags)
            val segs2 = head[page2 + 26].toInt() and 0xFF
            var body2 = 0
            for (i in 0 until segs2) body2 += head[page2 + 27 + i].toInt() and 0xFF
            val page2Total = 27 + segs2 + body2
            if (page2 + page2Total > head.size) return false
            val pkt = page2 + 27 + segs2
            val tag = String(head, pkt, 8, Charsets.US_ASCII)
            if (tag != "OpusTags") return false

            fun readLE32(off: Int): Long {
                var v = 0L
                for (b in 3 downTo 0) v = (v shl 8) or (head[off + b].toLong() and 0xFF)
                return v
            }

            val vendorLen = readLE32(pkt + 8).toInt()
            val cntOff = pkt + 12 + vendorLen
            if (cntOff + 4 > page2 + page2Total) return false
            val count = readLE32(cntOff)
            // Sanity: each comment needs ≥4 bytes for its length field; a count larger than the
            // remaining packet could ever hold means the field is corrupt.
            val remaining = (page2 + page2Total - cntOff - 4).toLong()
            if (count * 4 <= remaining) return false // looks valid — leave untouched

            AppLog.w("OpusRepair", "Corrupt OpusTags count=$count in $path — patching to 0")
            // Patch count = 0
            for (i in 0 until 4) head[cntOff + i] = 0
            // Recompute page 2 CRC (Ogg CRC32: poly 0x04C11DB7, init 0, no reflect) with field zeroed
            head[page2 + 22] = 0; head[page2 + 23] = 0; head[page2 + 24] = 0; head[page2 + 25] = 0
            var crc = 0L
            for (i in page2 until page2 + page2Total) {
                crc = crc xor ((head[i].toLong() and 0xFF) shl 24)
                repeat(8) {
                    crc = if (crc and 0x80000000L != 0L) ((crc shl 1) xor 0x04C11DB7L) else (crc shl 1)
                    crc = crc and 0xFFFFFFFFL
                }
            }
            for (i in 0 until 4) head[page2 + 22 + i] = ((crc shr (8 * i)) and 0xFF).toByte()

            raf.seek(0)
            raf.write(head, 0, page2 + page2Total)
            true
        }
    } catch (e: Exception) {
        AppLog.w("OpusRepair", "repair failed for $path", e)
        false
    }
}
