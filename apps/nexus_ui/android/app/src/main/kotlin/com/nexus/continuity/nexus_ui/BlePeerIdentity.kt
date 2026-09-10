package com.nexus.continuity.nexus_ui

import java.nio.ByteBuffer
import java.util.UUID

/** Versioned Nexus service-data identity; independent from Bluetooth MAC addresses. */
internal object BlePeerIdentity {
    fun encode(id: UUID): ByteArray = ByteBuffer.allocate(17).put(1.toByte())
        .putLong(id.mostSignificantBits).putLong(id.leastSignificantBits).array()

    fun decode(payload: ByteArray): UUID? {
        if (payload.size != 17 || payload[0] != 1.toByte()) return null
        val buffer = ByteBuffer.wrap(payload, 1, 16)
        val id = UUID(buffer.long, buffer.long)
        return id.takeUnless { it.mostSignificantBits == 0L && it.leastSignificantBits == 0L }
    }
}
