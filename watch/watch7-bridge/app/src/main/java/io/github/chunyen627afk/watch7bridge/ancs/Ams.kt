package io.github.chunyen627afk.watch7bridge.ancs

/** Apple Media Service：遙控指令與曲目資訊。純 Kotlin。 */
object Ams {
    const val CMD_PLAY = 0
    const val CMD_PAUSE = 1
    const val CMD_TOGGLE = 2
    const val CMD_NEXT = 3
    const val CMD_PREVIOUS = 4
    const val CMD_VOLUME_UP = 5
    const val CMD_VOLUME_DOWN = 6

    const val ENTITY_PLAYER = 0
    const val ENTITY_TRACK = 2

    const val PLAYER_PLAYBACK_INFO = 1
    const val PLAYER_VOLUME = 2
    const val TRACK_ARTIST = 0
    const val TRACK_TITLE = 2

    /** 訂閱某個實體的屬性：第一個位元組是實體，其後是屬性編號。 */
    fun buildSubscribe(entity: Int, vararg attrs: Int): ByteArray =
        ByteArray(1 + attrs.size).also {
            it[0] = entity.toByte()
            attrs.forEachIndexed { i, a -> it[i + 1] = a.toByte() }
        }

    fun parseUpdate(b: ByteArray): AmsUpdate? {
        if (b.size < 3) return null
        return AmsUpdate(
            entity = b[0].toInt() and 0xFF,
            attribute = b[1].toInt() and 0xFF,
            truncated = (b[2].toInt() and 1) != 0,
            value = String(b, 3, b.size - 3, Charsets.UTF_8),
        )
    }

    /** 播放資訊格式為「狀態,速率,已播放秒數」；狀態 1 表示播放中。 */
    fun isPlaying(playbackInfo: String): Boolean =
        playbackInfo.substringBefore(',').trim() == "1"
}

data class AmsUpdate(val entity: Int, val attribute: Int, val truncated: Boolean, val value: String)
