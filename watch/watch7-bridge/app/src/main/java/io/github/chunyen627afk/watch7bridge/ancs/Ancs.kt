package io.github.chunyen627afk.watch7bridge.ancs

/** Apple Notification Center Service：事件解析與指令組裝。純 Kotlin，可在電腦上測試。 */
object Ancs {
    const val EVENT_ADDED = 0
    const val EVENT_MODIFIED = 1
    const val EVENT_REMOVED = 2

    const val FLAG_SILENT = 1
    const val FLAG_IMPORTANT = 2
    const val FLAG_PREEXISTING = 4
    const val FLAG_POSITIVE_ACTION = 8
    const val FLAG_NEGATIVE_ACTION = 16

    const val CATEGORY_INCOMING_CALL = 1
    const val CATEGORY_MISSED_CALL = 2

    const val ATTR_APP_ID = 0
    const val ATTR_TITLE = 1
    const val ATTR_SUBTITLE = 2
    const val ATTR_MESSAGE = 3
    const val ATTR_DATE = 5
    const val ATTR_POSITIVE_LABEL = 6
    const val ATTR_NEGATIVE_LABEL = 7

    /** 依序要求的屬性；回覆也會照這個順序。 */
    val REQUESTED = intArrayOf(
        ATTR_APP_ID, ATTR_TITLE, ATTR_SUBTITLE, ATTR_MESSAGE,
        ATTR_DATE, ATTR_POSITIVE_LABEL, ATTR_NEGATIVE_LABEL,
    )

    private const val CMD_GET_NOTIFICATION_ATTRIBUTES = 0
    private const val CMD_PERFORM_ACTION = 2

    fun parseEvent(b: ByteArray): AncsEvent? {
        if (b.size < 8) return null
        return AncsEvent(
            eventId = b[0].toInt() and 0xFF,
            flags = b[1].toInt() and 0xFF,
            category = b[2].toInt() and 0xFF,
            categoryCount = b[3].toInt() and 0xFF,
            uid = readUid(b, 4),
        )
    }

    fun buildGetAttributes(uid: Long, maxLen: Int = 512): ByteArray {
        val out = ArrayList<Byte>()
        out.add(CMD_GET_NOTIFICATION_ATTRIBUTES.toByte())
        writeUid(out, uid)
        for (id in REQUESTED) {
            out.add(id.toByte())
            // 標題、副標、內文需要帶最大長度
            if (id == ATTR_TITLE || id == ATTR_SUBTITLE || id == ATTR_MESSAGE) {
                out.add((maxLen and 0xFF).toByte())
                out.add(((maxLen shr 8) and 0xFF).toByte())
            }
        }
        return out.toByteArray()
    }

    fun buildPerformAction(uid: Long, positive: Boolean): ByteArray {
        val out = ArrayList<Byte>()
        out.add(CMD_PERFORM_ACTION.toByte())
        writeUid(out, uid)
        out.add(if (positive) 0 else 1)
        return out.toByteArray()
    }

    internal fun readUid(b: ByteArray, at: Int): Long =
        (b[at].toLong() and 0xFF) or
            ((b[at + 1].toLong() and 0xFF) shl 8) or
            ((b[at + 2].toLong() and 0xFF) shl 16) or
            ((b[at + 3].toLong() and 0xFF) shl 24)

    private fun writeUid(out: MutableList<Byte>, uid: Long) {
        for (i in 0 until 4) out.add(((uid shr (8 * i)) and 0xFF).toByte())
    }
}

data class AncsEvent(
    val eventId: Int,
    val flags: Int,
    val category: Int,
    val categoryCount: Int,
    val uid: Long,
) {
    val silent get() = flags and Ancs.FLAG_SILENT != 0
    val important get() = flags and Ancs.FLAG_IMPORTANT != 0
    val preExisting get() = flags and Ancs.FLAG_PREEXISTING != 0
    val hasPositive get() = flags and Ancs.FLAG_POSITIVE_ACTION != 0
    val hasNegative get() = flags and Ancs.FLAG_NEGATIVE_ACTION != 0
}

data class AncsAttributes(val uid: Long, val values: Map<Int, String>) {
    val appId get() = values[Ancs.ATTR_APP_ID].orEmpty()
    val title get() = values[Ancs.ATTR_TITLE].orEmpty()
    val subtitle get() = values[Ancs.ATTR_SUBTITLE].orEmpty()
    val message get() = values[Ancs.ATTR_MESSAGE].orEmpty()
    val date get() = values[Ancs.ATTR_DATE].orEmpty()
    val positiveLabel get() = values[Ancs.ATTR_POSITIVE_LABEL].orEmpty()
    val negativeLabel get() = values[Ancs.ATTR_NEGATIVE_LABEL].orEmpty()
}

/**
 * Data Source 的回覆會被切成多個封包。把封包依序餵進來，
 * 湊齊一則完整的回覆時回傳結果，否則回傳 null 繼續等。
 */
class AttributeAssembler(private val expectedCount: Int = Ancs.REQUESTED.size) {
    private var buf = ByteArray(0)

    fun reset() {
        buf = ByteArray(0)
    }

    fun feed(chunk: ByteArray): AncsAttributes? {
        buf += chunk
        if (buf.size < 5) return null
        if ((buf[0].toInt() and 0xFF) != 0) {
            // 不是 Get Notification Attributes 的回覆，丟棄避免卡住
            reset()
            return null
        }
        val uid = Ancs.readUid(buf, 1)
        var pos = 5
        val values = HashMap<Int, String>()
        repeat(expectedCount) {
            if (buf.size < pos + 3) return null
            val id = buf[pos].toInt() and 0xFF
            val len = (buf[pos + 1].toInt() and 0xFF) or ((buf[pos + 2].toInt() and 0xFF) shl 8)
            pos += 3
            if (buf.size < pos + len) return null
            values[id] = String(buf, pos, len, Charsets.UTF_8)
            pos += len
        }
        buf = buf.copyOfRange(pos, buf.size)
        return AncsAttributes(uid, values)
    }
}
