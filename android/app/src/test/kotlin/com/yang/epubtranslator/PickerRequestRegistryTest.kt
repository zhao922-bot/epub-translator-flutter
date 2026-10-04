package com.yang.epubtranslator

import org.junit.Assert.*
import org.junit.Test

class PickerRequestRegistryTest {
    @Test fun lateResultCannotConsumeTheNextPick() {
        val registry = PickerRequestRegistry<String>()
        val old = registry.register("old")!!
        registry.abandon(old)
        val current = registry.register("current")!!
        assertNotEquals(old, current)
        assertNull(registry.consume(old))
        assertEquals("current", registry.consume(current))
        assertNull(registry.consume(current))
    }

    @Test fun unknownResultDoesNotConsumeCurrentPick() {
        val registry = PickerRequestRegistry<String>()
        val code = registry.register("current")!!
        assertNull(registry.consume(6002))
        assertEquals("current", registry.consume(code))
    }

    @Test fun wraparoundNeverReusesAnOutstandingCode() {
        val registry = PickerRequestRegistry<String>(100, 101)
        val old = registry.register("old")!!
        registry.abandon(old)
        val current = registry.register("current")!!
        assertNull(registry.register("too many"))
        assertNull(registry.consume(old))
        assertEquals(old, registry.register("next"))
        assertEquals("current", registry.consume(current))
        assertEquals("next", registry.consume(old))
    }

    @Test fun recreationDiscardsOldResultsAndReservesTheirCodes() {
        val original = PickerRequestRegistry<String>()
        val old = original.register("old")!!
        val recreated = PickerRequestRegistry<String>()
        recreated.restoreAbandoned(original.outstandingCodes())
        val current = recreated.register("current")!!
        assertNotEquals(old, current)
        assertNull(recreated.consume(old))
        assertEquals("current", recreated.consume(current))
    }
}
