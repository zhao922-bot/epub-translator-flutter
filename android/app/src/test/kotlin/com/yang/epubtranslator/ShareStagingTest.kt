package com.yang.epubtranslator

import org.junit.Assert.*
import org.junit.Test

class ShareStagingTest {
    @Test fun grantOverflowEvictsOldestFirstAndRevokesUris() {
        val now = System.currentTimeMillis()
        // Fresh grants have no grace exemption once their protection cap overflows.
        val files = (1..25).map { ShareStagingEntry("/s/$it.epub", now - 1000 + it, 1024) }
        val grants = files.associate { it.path to "content://u/${it.path}" }
        val plan = planShareStagingCleanup(files.reversed(), grants, now)
        assertTrue(plan.deleteForAge.isEmpty())
        assertEquals(files.take(5), plan.evictForCap)
        assertEquals(files.take(5).map { grants.getValue(it.path) }, plan.revokeUris)
    }

    @Test fun grantByteOverflowEvictsOldestFirst() {
        val now = System.currentTimeMillis()
        val files = (1..3).map {
            ShareStagingEntry("/s/$it.epub", now - 1000 + it, 100L * 1024 * 1024)
        }
        val grants = files.associate { it.path to "content://u/${it.path}" }
        val plan = planShareStagingCleanup(files.reversed(), grants, now)
        assertEquals(listOf(files.first()), plan.evictForCap)
        assertEquals(listOf(grants.getValue(files.first().path)), plan.revokeUris)
    }

    @Test fun grantsWithinExemptionCapsSurviveQuotaPressure() {
        val now = System.currentTimeMillis()
        val granted = (1..MAX_SHARE_GRANT_EXEMPT_FILES).map {
            ShareStagingEntry(
                "/granted/$it.epub",
                now - 600_000 + it,
                MAX_SHARE_GRANT_EXEMPT_BYTES / MAX_SHARE_GRANT_EXEMPT_FILES,
            )
        }
        val fresh = (1..MAX_SHARE_STAGING_FILES).map {
            ShareStagingEntry("/fresh/$it.epub", now, 1024)
        }
        val grants = granted.associate { it.path to "content://u/${it.path}" }
        val plan = planShareStagingCleanup(granted + fresh, grants, now)
        assertTrue(plan.evictForCap.isEmpty())
        assertTrue(plan.revokeUris.isEmpty())
    }

    @Test fun grantOverflowDoesNotEvictWithoutQuotaPressure() {
        val now = System.currentTimeMillis()
        val files = (1..MAX_SHARE_GRANT_EXEMPT_FILES + 1).map {
            ShareStagingEntry("/s/$it.epub", now - 600_000 + it, 1024)
        }
        val grants = files.associate { it.path to "content://u/${it.path}" }
        val plan = planShareStagingCleanup(files, grants, now)
        assertTrue(plan.evictForCap.isEmpty())
        assertTrue(plan.revokeUris.isEmpty())
    }

    @Test fun activeGrantedSnapshotSurvivesOverflowEviction() {
        val now = System.currentTimeMillis()
        val files = (1..25).map { ShareStagingEntry("/s/$it.epub", now - 1000 + it, 1024) }
        val grants = files.associate { it.path to "content://u/${it.path}" }
        val plan = planShareStagingCleanup(files, grants, now, setOf(files.first().path))
        assertEquals(files.drop(1).take(5), plan.evictForCap)
        assertEquals(files.drop(1).take(5).map { grants.getValue(it.path) }, plan.revokeUris)
    }

    private fun entry(path: String, ageMs: Long, length: Long = 1024) =
        ShareStagingEntry(path, System.currentTimeMillis() - ageMs, length)

    @Test fun grantLedgerRoundTrip() {
        var entries = emptySet<String>()
        entries = recordShareGrant(entries, "content://u/1", "/a/1.epub", 1000)
        entries = recordShareGrant(entries, "content://u/2", "/a/2.epub", 2000)
        val grants = loadShareGrants(entries)
        assertEquals("content://u/1", grants["/a/1.epub"]?.uri)
        assertEquals(1000L, grants["/a/1.epub"]?.grantedAt)
        // Re-sharing the same file replaces the older entry.
        entries = recordShareGrant(entries, "content://u/1b", "/a/1.epub", 3000)
        val reloaded = loadShareGrants(entries)
        assertEquals(2, reloaded.size)
        assertEquals("content://u/1b", reloaded["/a/1.epub"]?.uri)
    }

    @Test fun dropShareGrantAndStale() {
        var entries = emptySet<String>()
        entries = recordShareGrant(entries, "content://u/1", "/a/1.epub", 1000)
        entries = recordShareGrant(entries, "content://u/2", "/a/2.epub", 2000)
        entries = dropShareGrant(entries, "/a/1.epub")
        assertEquals(1, loadShareGrants(entries).size)
        entries = dropStaleShareGrants(entries, setOf("/a/2.epub"))
        assertEquals(1, loadShareGrants(entries).size)
        entries = dropStaleShareGrants(entries, emptySet())
        assertTrue(loadShareGrants(entries).isEmpty())
    }

    @Test fun quotaCountsGracePeriodFiles() {
        val now = System.currentTimeMillis()
        // 25 fresh snapshots inside the grace period: the quota (20) is
        // exceeded, but none may be evicted for cap — they are grace-exempt.
        val files = (1..25).map { entry("/s/$it.epub", ageMs = 60_000) }
        val plan = planShareStagingCleanup(files, emptyMap(), now)
        assertTrue(plan.deleteForAge.isEmpty())
        assertTrue(plan.evictForCap.isEmpty())
    }

    @Test fun capEvictsOldestUngrantedFirst() {
        val now = System.currentTimeMillis()
        val files = (1..25).map { entry("/s/$it.epub", ageMs = 10 * 60_000, length = 1024) }
        val plan = planShareStagingCleanup(files, emptyMap(), now)
        assertEquals(5, plan.evictForCap.size)
        // Oldest first: /s/1.epub has the smallest lastModified.
        assertEquals("/s/1.epub", plan.evictForCap.first().path)
        assertEquals("/s/5.epub", plan.evictForCap.last().path)
    }

    @Test fun liveGrantExemptsFromCapEvictionRegardlessOfAge() {
        val now = System.currentTimeMillis()
        val files = (1..25).map { entry("/s/$it.epub", ageMs = 10 * 60_000, length = 1024) }
        val grants = mapOf("/s/1.epub" to "content://u/1", "/s/2.epub" to "content://u/2")
        val plan = planShareStagingCleanup(files, grants, now)
        assertTrue(plan.evictForCap.none { it.path == "/s/1.epub" })
        assertTrue(plan.evictForCap.none { it.path == "/s/2.epub" })
        // Quota still counts them, so 5 ungranted files are evicted.
        assertEquals(5, plan.evictForCap.size)
        assertEquals("/s/3.epub", plan.evictForCap.first().path)
    }

    @Test fun ageExpiredGrantIsRevokedBeforeDelete() {
        val now = System.currentTimeMillis()
        val files = listOf(
            entry("/s/old.epub", ageMs = 8 * 24 * 60 * 60_000),
            entry("/s/fresh.epub", ageMs = 60_000),
        )
        val grants = mapOf("/s/old.epub" to "content://u/old")
        val plan = planShareStagingCleanup(files, grants, now)
        assertEquals(listOf("/s/old.epub"), plan.deleteForAge.map { it.path })
        assertEquals(listOf("content://u/old"), plan.revokeUris)
        assertTrue(plan.evictForCap.isEmpty())
    }

    @Test fun sizeQuotaCountsAllSnapshots() {
        val now = System.currentTimeMillis()
        // 3 files of 100 MiB each: over the 200 MiB quota even though the
        // two young ones are grace-exempt from eviction.
        val files = listOf(
            entry("/s/a.epub", ageMs = 10 * 60_000, length = 100 * 1024 * 1024),
            entry("/s/b.epub", ageMs = 60_000, length = 100 * 1024 * 1024),
            entry("/s/c.epub", ageMs = 60_000, length = 100 * 1024 * 1024),
        )
        val plan = planShareStagingCleanup(files, emptyMap(), now)
        assertEquals(listOf("/s/a.epub"), plan.evictForCap.map { it.path })
    }

    @Test fun activeShareTargetsExemptFromCapEviction() {
        val now = System.currentTimeMillis()
        // 25 snapshots past the grace period: quota (20) evicts the 5
        // oldest — unless they are in-flight shares.
        val files = (1..25).map { entry("/s/$it.epub", ageMs = 10 * 60_000, length = 1024) }
        val plan = planShareStagingCleanup(
            files,
            emptyMap(),
            now,
            activeSharePaths = setOf("/s/1.epub"),
        )
        assertEquals(5, plan.evictForCap.size)
        assertFalse(plan.evictForCap.any { it.path == "/s/1.epub" })
        // /s/1.epub would have been evicted first; /s/6.epub takes its place.
        assertEquals("/s/2.epub", plan.evictForCap.first().path)
        assertEquals("/s/6.epub", plan.evictForCap.last().path)
    }

    @Test fun activeSharePathsDefaultKeepsOldCallersEvicting() {
        val now = System.currentTimeMillis()
        val files = (1..25).map { entry("/s/$it.epub", ageMs = 10 * 60_000, length = 1024) }
        // No activeSharePaths argument: same behavior as before the param.
        val plan = planShareStagingCleanup(files, emptyMap(), now)
        assertEquals(5, plan.evictForCap.size)
        assertEquals("/s/1.epub", plan.evictForCap.first().path)
    }

    /**
     * B-02: the share-grant ledger's read-modify-write must serialize with
     * cleanupOldShareStaging's read-modify-write. MainActivity runs both on
     * the single ioExecutor thread (the grant is recorded there before the
     * chooser starts); this test pins the invariant that interleaved RMWs
     * submitted to one single-thread executor never lost-update each other.
     *
     * Manual test strategy for the wiring itself (needs Android): share two
     * large EPUBs back-to-back so the second share's cleanup runs while the
     * first share's grant record is in flight; assert both grants survive in
     * SharedPreferences and neither snapshot is swept before its chooser
     * is dismissed.
     */
    @Test fun singleThreadExecutorSerializesLedgerReadModifyWrites() {
        val io = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            var ledger = emptySet<String>()
            fun readLedger(): Set<String> = ledger
            fun writeLedger(next: Set<String>) {
                ledger = next
            }
            val done = java.util.concurrent.CountDownLatch(20)
            repeat(10) { i ->
                // Simulates cleanupOldShareStaging's ledger RMW.
                io.execute {
                    writeLedger(dropShareGrant(readLedger(), "/gone/$i.epub"))
                    done.countDown()
                }
                // Simulates the share path's grant-record RMW.
                io.execute {
                    writeLedger(
                        recordShareGrant(
                            readLedger(),
                            "content://u/$i",
                            "/s/$i.epub",
                            i.toLong(),
                        ),
                    )
                    done.countDown()
                }
            }
            assertTrue(done.await(10, java.util.concurrent.TimeUnit.SECONDS))
            io.shutdown()
            assertTrue(io.awaitTermination(10, java.util.concurrent.TimeUnit.SECONDS))
            // No lost updates: every recorded grant survived every
            // cleanup RMW that ran around it.
            val grants = loadShareGrants(readLedger())
            for (i in 0 until 10) {
                assertEquals("content://u/$i", grants["/s/$i.epub"]?.uri)
            }
        } finally {
            io.shutdownNow()
        }
    }

    @Test fun cleanupDeletesFirstRevokesAfterAndNeverAbortsEarly() {
        // P2-#11: cleanup must delete the files and drop the ledger rows
        // BEFORE revoking URI permissions, and one failed delete must not
        // abort the remaining entries. The stuck file keeps both its data
        // and its grant (revoke is skipped for failed deletes).
        val plan = ShareStagingCleanupPlan(
            deleteForAge = listOf(ShareStagingEntry("/s/old.epub", 1L, 10L)),
            revokeUris = listOf("content://u/old"),
            evictForCap = listOf(
                ShareStagingEntry("/s/stuck.epub", 2L, 10L),
                ShareStagingEntry("/s/quota.epub", 3L, 10L),
            ),
        )
        val grants = setOf(
            "content://u/old|/s/old.epub|1",
            "content://u/stuck|/s/stuck.epub|2",
            "content://u/quota|/s/quota.epub|3",
        )
        val deleted = mutableListOf<String>()
        val revoked = mutableListOf<String>()
        val remaining = executeShareStagingCleanup(
            plan = plan,
            grantUriByPath = mapOf(
                "/s/old.epub" to "content://u/old",
                "/s/stuck.epub" to "content://u/stuck",
                "/s/quota.epub" to "content://u/quota",
            ),
            grants = grants,
            deleteFile = { path ->
                deleted.add(path)
                path != "/s/stuck.epub" // the stuck file fails to delete
            },
            revokeUri = { uri -> revoked.add(uri) },
        )
        // Every entry is attempted despite the mid-sequence failure.
        assertEquals(listOf("/s/old.epub", "/s/stuck.epub", "/s/quota.epub"), deleted)
        // URI permissions are revoked only after their files were deleted;
        // the stuck file's grant survives because its delete failed.
        assertEquals(listOf("content://u/old", "content://u/quota"), revoked)
        // The ledger drops exactly the deleted files.
        assertEquals(setOf("content://u/stuck|/s/stuck.epub|2"), remaining)
    }

    @Test fun cleanupRevokeFailureDoesNotPropagate() {
        // P2-#17: a revoke that throws must not fail the whole cleanup —
        // but its ledger entry is now RESTORED instead of dropped, so the
        // persisted grant is not leaked without a record and a later sweep
        // retries the revoke (see retryOrphanedGrantRevokes).
        val plan = ShareStagingCleanupPlan(
            deleteForAge = listOf(ShareStagingEntry("/s/old.epub", 1L, 10L)),
            revokeUris = listOf("content://u/old"),
            evictForCap = emptyList(),
        )
        val remaining = executeShareStagingCleanup(
            plan = plan,
            grantUriByPath = mapOf("/s/old.epub" to "content://u/old"),
            grants = setOf("content://u/old|/s/old.epub|1"),
            deleteFile = { true },
            revokeUri = { throw RuntimeException("revoke exploded") },
        )
        assertEquals(setOf("content://u/old|/s/old.epub|1"), remaining)
    }

    @Test fun cleanupRevokeFailureThenOrphanRetrySucceeds() {
        // P2-#17: the restored entry is picked up by
        // retryOrphanedGrantRevokes on the next sweep (the file is already
        // gone) and dropped once its revoke finally succeeds.
        val plan = ShareStagingCleanupPlan(
            deleteForAge = listOf(ShareStagingEntry("/s/old.epub", 1L, 10L)),
            revokeUris = listOf("content://u/old"),
            evictForCap = emptyList(),
        )
        val afterFailedRevoke = executeShareStagingCleanup(
            plan = plan,
            grantUriByPath = mapOf("/s/old.epub" to "content://u/old"),
            grants = setOf("content://u/old|/s/old.epub|1"),
            deleteFile = { true },
            revokeUri = { throw RuntimeException("revoke exploded") },
        )
        assertEquals(setOf("content://u/old|/s/old.epub|1"), afterFailedRevoke)
        val revoked = mutableListOf<String>()
        val afterRetry = retryOrphanedGrantRevokes(
            grants = afterFailedRevoke,
            livePaths = emptySet(),
            revokeUri = { revoked.add(it) },
        )
        assertEquals(listOf("content://u/old"), revoked)
        assertTrue(afterRetry.isEmpty())
    }

    @Test fun orphanRetryKeepsEntryWhenRevokeFailsAgain() {
        // P2-#17: an orphan whose revoke keeps failing stays in the ledger
        // for the sweep after that.
        val afterRetry = retryOrphanedGrantRevokes(
            grants = setOf("content://u/old|/s/old.epub|1"),
            livePaths = emptySet(),
            revokeUri = { throw RuntimeException("still failing") },
        )
        assertEquals(setOf("content://u/old|/s/old.epub|1"), afterRetry)
    }

    @Test fun cleanupDeleteThrowIsTreatedAsFailureAndContinues() {
        // P2-#11: a deleteFile that throws counts as a failed delete —
        // the entry is skipped and the rest still run.
        val plan = ShareStagingCleanupPlan(
            deleteForAge = listOf(
                ShareStagingEntry("/s/boom.epub", 1L, 10L),
                ShareStagingEntry("/s/fine.epub", 2L, 10L),
            ),
            revokeUris = listOf("content://u/fine"),
            evictForCap = emptyList(),
        )
        val revoked = mutableListOf<String>()
        val remaining = executeShareStagingCleanup(
            plan = plan,
            grantUriByPath = mapOf(
                "/s/boom.epub" to "content://u/boom",
                "/s/fine.epub" to "content://u/fine",
            ),
            grants = setOf(
                "content://u/boom|/s/boom.epub|1",
                "content://u/fine|/s/fine.epub|2",
            ),
            deleteFile = { path ->
                if (path == "/s/boom.epub") throw RuntimeException("delete exploded")
                true
            },
            revokeUri = { uri -> revoked.add(uri) },
        )
        assertEquals(listOf("content://u/fine"), revoked)
        assertEquals(setOf("content://u/boom|/s/boom.epub|1"), remaining)
    }
}
