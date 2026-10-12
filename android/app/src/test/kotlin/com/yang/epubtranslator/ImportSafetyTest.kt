package com.yang.epubtranslator

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class ImportSafetyTest {
    @Test fun confirmedTypesAlwaysHaveDartCompatibleSuffix() {
        for (name in listOf("book.bin", "book.zip", "book", "book.EPUB")) {
            assertTrue(confirmedEpubName(name).endsWith(".epub", ignoreCase = true))
        }
        assertEquals("book.EPUB", confirmedEpubName("book.EPUB"))
    }

    @Test fun replacingProtectionNeverExposesAnEmptyWindow() {
        val paths = ProtectedImportPaths()
        paths.replace(listOf("retained"))
        val missing = AtomicBoolean(false)
        val worker = Thread {
            repeat(100000) { if ("retained" !in paths) missing.set(true) }
        }
        worker.start()
        repeat(100000) { paths.replace(listOf("retained", "new-$it")) }
        worker.join()
        assertFalse(missing.get())
    }

    @Test fun oldCompletionCannotCancelNewWatchdog() {
        val old = ImportWatchdog()
        val newer = ImportWatchdog()
        val oldCallback = Runnable {}
        val newCallback = Runnable {}
        val scheduled = mutableSetOf(oldCallback, newCallback)
        old.callback = oldCallback
        newer.callback = newCallback
        // Old completion is queued on main; a new attempt arms before it runs.
        val queuedCompletion = { old.cancel { scheduled.remove(it) }; Unit }
        queuedCompletion()
        assertEquals(setOf(newCallback), scheduled)
        assertSame(newCallback, newer.callback)
    }

    @Test fun teardownInvalidatesEveryBlockedProviderStage() {
        for (stage in listOf("queryDisplayName", "getType", "probeOpen", "probeRead", "querySize", "openInputStream", "read")) {
            val lifecycle = ImportLifecycle()
            val captured = lifecycle.generation
            val blocked = CountDownLatch(1)
            val release = CountDownLatch(1)
            val copied = AtomicBoolean(false)
            val worker = Thread {
                blocked.countDown()
                release.await()
                if (lifecycle.isCurrent(captured)) copied.set(true)
            }
            worker.start()
            assertTrue(stage, blocked.await(2, TimeUnit.SECONDS))
            lifecycle.destroy()
            release.countDown()
            worker.join()
            assertFalse(stage, copied.get())
            assertTrue(lifecycle.generation > captured)
            assertFalse(lifecycle.isCurrent(lifecycle.generation))
        }
    }
}
