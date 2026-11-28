package io.github.chunyen627afk.watch7bridge.ancs

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AncsTest {
    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    private fun attr(id: Int, text: String): ByteArray {
        val d = text.toByteArray(Charsets.UTF_8)
        return bytes(id, d.size and 0xFF, d.size shr 8) + d
    }

    private fun response(uid: Int): ByteArray =
        bytes(0, uid, 0, 0, 0) +
            attr(0, "jp.naver.line") + attr(1, "小明") + attr(2, "") +
            attr(3, "晚上吃什麼？") + attr(5, "20261128T183000") +
            attr(6, "") + attr(7, "清除")

    @Test fun parsesEvent() {
        val e = Ancs.parseEvent(bytes(0, 0x18, 1, 1, 0x78, 0x56, 0x34, 0x12))!!
        assertEquals(Ancs.EVENT_ADDED, e.eventId)
        assertEquals(Ancs.CATEGORY_INCOMING_CALL, e.category)
        assertEquals(0x12345678L, e.uid)
        assertTrue(e.hasPositive)
        assertTrue(e.hasNegative)
        assertFalse(e.silent)
        assertFalse(e.preExisting)
    }

    @Test fun rejectsShortEvent() {
        assertNull(Ancs.parseEvent(bytes(0, 0, 0)))
    }

    @Test fun uidAboveSignedIntRange() {
        val e = Ancs.parseEvent(bytes(2, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF))!!
        assertEquals(0xFFFFFFFFL, e.uid)
    }

    @Test fun buildsGetAttributes() {
        val cmd = Ancs.buildGetAttributes(0x01020304L, maxLen = 256)
        assertArrayEquals(
            bytes(0, 4, 3, 2, 1, 0, 1, 0, 1, 2, 0, 1, 3, 0, 1, 5, 6, 7),
            cmd,
        )
    }

    @Test fun buildsPerformAction() {
        assertArrayEquals(bytes(2, 9, 0, 0, 0, 0), Ancs.buildPerformAction(9, positive = true))
        assertArrayEquals(bytes(2, 9, 0, 0, 0, 1), Ancs.buildPerformAction(9, positive = false))
    }

    @Test fun assemblesSinglePacket() {
        val a = AttributeAssembler().feed(response(7))!!
        assertEquals(7L, a.uid)
        assertEquals("jp.naver.line", a.appId)
        assertEquals("小明", a.title)
        assertEquals("晚上吃什麼？", a.message)
        assertEquals("清除", a.negativeLabel)
        assertEquals("", a.positiveLabel)
    }

    @Test fun assemblesAcrossFragmentsEvenInsideMultibyteText() {
        val full = response(7)
        val asm = AttributeAssembler()
        var result: AncsAttributes? = null
        // 每 5 個位元組切一段，一定會切在中文字的中間
        full.toList().chunked(5).forEach { part ->
            assertNull("不應該提早完成", result)
            result = asm.feed(part.toByteArray())
        }
        assertNotNull(result)
        assertEquals("晚上吃什麼？", result!!.message)
    }

    @Test fun handlesTwoResponsesBackToBack() {
        val asm = AttributeAssembler()
        val first = asm.feed(response(1) + response(2).copyOfRange(0, 4))
        assertEquals(1L, first!!.uid)
        val second = asm.feed(response(2).copyOfRange(4, response(2).size))
        assertEquals(2L, second!!.uid)
    }

    @Test fun dropsUnexpectedCommand() {
        val asm = AttributeAssembler()
        assertNull(asm.feed(bytes(1, 0, 0, 0, 0, 0, 0)))
        assertEquals(3L, asm.feed(response(3))!!.uid)
    }

    @Test fun amsRoundTrip() {
        assertArrayEquals(bytes(2, 0, 2), Ams.buildSubscribe(Ams.ENTITY_TRACK, Ams.TRACK_ARTIST, Ams.TRACK_TITLE))
        val u = Ams.parseUpdate(bytes(2, 2, 0) + "歌名".toByteArray())!!
        assertEquals(Ams.ENTITY_TRACK, u.entity)
        assertEquals(Ams.TRACK_TITLE, u.attribute)
        assertEquals("歌名", u.value)
        assertTrue(Ams.isPlaying("1,1.0,12.5"))
        assertFalse(Ams.isPlaying("0,0.0,12.5"))
        assertFalse(Ams.isPlaying(""))
    }
}
