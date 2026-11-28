package io.github.chunyen627afk.watch7bridge.ancs

/**
 * 與 iPhone 端 App 之間的訊息分段。每個封包第一個位元組是旗標：bit0 表示第一段，bit1 表示最後一段。
 * 必須與 apps/watch-link-ios 的 Framing.swift 一致。
 */
object Framing {
    const val FLAG_START = 1
    const val FLAG_END = 2

    fun split(message: ByteArray, maxChunk: Int): List<ByteArray> {
        val size = maxOf(1, maxChunk - 1)
        if (message.isEmpty()) return listOf(byteArrayOf((FLAG_START or FLAG_END).toByte()))
        val out = ArrayList<ByteArray>()
        var offset = 0
        while (offset < message.size) {
            val end = minOf(offset + size, message.size)
            var flags = 0
            if (offset == 0) flags = flags or FLAG_START
            if (end == message.size) flags = flags or FLAG_END
            out.add(byteArrayOf(flags.toByte()) + message.copyOfRange(offset, end))
            offset = end
        }
        return out
    }
}

class Reassembler {
    private var buffer = ByteArray(0)
    private var active = false

    fun reset() {
        buffer = ByteArray(0)
        active = false
    }

    fun feed(chunk: ByteArray): ByteArray? {
        if (chunk.isEmpty()) return null
        val flags = chunk[0].toInt() and 0xFF
        if (flags and Framing.FLAG_START != 0) {
            buffer = ByteArray(0)
            active = true
        }
        if (!active) return null
        buffer += chunk.copyOfRange(1, chunk.size)
        if (flags and Framing.FLAG_END != 0) {
            active = false
            val message = buffer
            buffer = ByteArray(0)
            return message
        }
        return null
    }
}
