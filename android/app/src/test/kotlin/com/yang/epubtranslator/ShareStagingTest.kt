package com.yang.epubtranslator

import org.junit.Assert.*
import org.junit.Test

class ShareStagingTest {
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
}
