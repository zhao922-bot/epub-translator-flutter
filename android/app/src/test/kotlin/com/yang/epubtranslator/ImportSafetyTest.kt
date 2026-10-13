package com.yang.epubtranslator

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.nio.file.Files
import java.io.File

class ImportSafetyTest {
    @Test fun knownSizeBoundaryAndUnknownMetadata() {
        val limit = ImportSizeLimit()
        for (size in listOf(-1L, 0L, MAX_IMPORT_BYTES - 1, MAX_IMPORT_BYTES)) {
            limit.checkKnownSize(size)
        }
        assertThrows(IllegalArgumentException::class.java) {
            limit.checkKnownSize(MAX_IMPORT_BYTES + 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            limit.checkKnownSize(Long.MAX_VALUE)
        }
    }

    @Test fun cumulativeBoundaryCannotBeBypassedByUnknownOrUnderreportedSize() {
        for (reported in listOf(-1L, 1L, MAX_IMPORT_BYTES)) {
            val limit = ImportSizeLimit()
            limit.checkKnownSize(reported)
            repeat(4096) { limit.acceptChunk(64 * 1024) }
            limit.acceptChunk(0)
            assertThrows(IllegalArgumentException::class.java) { limit.acceptChunk(1) }
        }
    }

    @Test fun overLimitCopyRemovesPartialAndClaimButPreservesOtherImports() {
        val directory = Files.createTempDirectory("import-limit").toFile()
        try {
            val target = File(directory, "book.epub").apply { createNewFile() }
            val part = File(directory, "book.epub.part")
            val retained = File(directory, "retained.epub").apply { writeText("retained") }
            assertThrows(IllegalArgumentException::class.java) {
                try {
                    part.outputStream().use { output ->
                        val limit = ImportSizeLimit(4)
                        limit.acceptChunk(4)
                        output.write(byteArrayOf(1, 2, 3, 4))
                        limit.acceptChunk(1)
                        output.write(5)
                    }
                } catch (error: Exception) {
                    removeFailedImport(part, target)
                    throw error
                }
            }
            assertFalse(part.exists())
            assertFalse(target.exists())
            assertEquals("retained", retained.readText())
        } finally {
            directory.deleteRecursively()
        }
    }

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

    @Test fun staleGenerationRefusesHolderRegistration() {
        // P2-#9: a copy task that passed the generation check, was parked,
        // and woke up after the watchdog replaced the executor must NOT
        // overwrite the new registration via activeImport.set().
        val lifecycle = ImportLifecycle()
        val staleGeneration = lifecycle.generation
        // The current generation registers fine.
        checkImportRegistration(lifecycle, staleGeneration)
        // The watchdog invalidates (executor replaced, new task registered).
        lifecycle.invalidate()
        checkImportRegistration(lifecycle, lifecycle.generation)
        // The parked task's generation is now stale: refuse.
        assertThrows(ImportStaleException::class.java) {
            checkImportRegistration(lifecycle, staleGeneration)
        }
    }

    @Test fun destroyedLifecycleRefusesHolderRegistration() {
        // P2-#9: same guard at the hasZipMagicBytes probe registration —
        // a destroyed lifecycle never accepts a registration.
        val lifecycle = ImportLifecycle()
        val generation = lifecycle.generation
        lifecycle.destroy()
        assertThrows(ImportStaleException::class.java) {
            checkImportRegistration(lifecycle, generation)
        }
    }
}
