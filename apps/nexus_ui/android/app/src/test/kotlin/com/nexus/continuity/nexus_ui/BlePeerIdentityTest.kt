package com.nexus.continuity.nexus_ui

import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class BlePeerIdentityTest {
    private val id = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")
    private val wire = byteArrayOf(1, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
        0x77, 0x88.toByte(), 0x99.toByte(), 0xaa.toByte(), 0xbb.toByte(),
        0xcc.toByte(), 0xdd.toByte(), 0xee.toByte(), 0xff.toByte())

    @Test fun preservesNetworkByteOrder() {
        assertArrayEquals(wire, BlePeerIdentity.encode(id))
        assertEquals(id, BlePeerIdentity.decode(wire))
    }

    @Test fun rejectsTruncatedAndTrailingData() {
        for (length in 0..16) assertNull(BlePeerIdentity.decode(wire.copyOf(length)))
        assertNull(BlePeerIdentity.decode(wire + byteArrayOf(0)))
    }

    @Test fun rejectsUnknownVersionsAndNilIdentity() {
        assertNull(BlePeerIdentity.decode(wire.copyOf().also { it[0] = 2 }))
        assertNull(BlePeerIdentity.decode(ByteArray(17).also { it[0] = 1 }))
    }
}
