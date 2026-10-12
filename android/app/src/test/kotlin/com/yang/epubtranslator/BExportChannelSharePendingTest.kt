package com.yang.epubtranslator

import org.junit.Assert.*
import org.junit.Test

class BExportChannelSharePendingTest {
    @Test fun destroyClearsItsBoundChannel() {
        val holder = ExportChannelHolder()
        val channel = Any()
        holder.bind(channel)
        assertSame(channel, holder.current)
        holder.clearIfBound(channel)
        assertNull(holder.current)
    }

    @Test fun oldDestroyCannotClearNewBinding() {
        val holder = ExportChannelHolder()
        val oldChannel = Any()
        val newChannel = Any()
        holder.bind(oldChannel)
        holder.bind(newChannel)
        // Recreation can bind before the old Activity finishes teardown.
        holder.clearIfBound(oldChannel)
        assertSame(newChannel, holder.current)
    }

    @Test fun clearWithoutBindingIsNoOp() {
        val holder = ExportChannelHolder()
        holder.clearIfBound(Any())
        assertNull(holder.current)
    }

    @Test fun clearingUsesIdentityRatherThanValueEquality() {
        val holder = ExportChannelHolder()
        val oldChannel = listOf("equal-channel")
        val newChannel = listOf("equal-channel")
        assertEquals(oldChannel, newChannel)
        assertNotSame(oldChannel, newChannel)
        holder.bind(newChannel)
        // Value equality is insufficient ownership evidence for teardown.
        holder.clearIfBound(oldChannel)
        assertSame(newChannel, holder.current)
    }

    @Test fun zeroRowUpdateRetriesOnceAndPublishes() {
        var calls = 0
        assertTrue(clearPendingFlag({ if (++calls == 1) 0 else 1 }))
        assertEquals(2, calls)
    }

    @Test fun twoZeroRowUpdatesFailPublication() {
        var calls = 0
        // The production caller checks false and throws inside the existing
        // delete/SAVE_FAILED path; an invisible entry must not mean success.
        assertFalse(clearPendingFlag({ calls++; 0 }))
        assertEquals(2, calls)
    }

    @Test fun successfulFirstUpdateDoesNotRetry() {
        var calls = 0
        assertTrue(clearPendingFlag({ calls++; 1 }))
        assertEquals(1, calls)
    }
}
