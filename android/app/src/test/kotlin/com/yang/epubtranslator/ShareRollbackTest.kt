package com.yang.epubtranslator

import com.yang.epubtranslator.MainActivity.ShareRollback.rollbackFailedShare
import java.io.File
import org.junit.Assert.*
import org.junit.Test

class ShareRollbackTest {
    @Test fun rollbackRemovesFailedGrantAndSnapshotButKeepsOtherGrants() {
        val snapshot = File.createTempFile("share-rollback-", ".epub")
        try {
            val otherEntries = recordShareGrant(emptySet(), "content://u/other", "/s/other.epub", 1000)
            var ledger = recordShareGrant(otherEntries, "content://u/failed", snapshot.absolutePath, 2000)
            var writes = 0

            assertTrue(rollbackFailedShare({ ledger }, { ledger = it; writes++ }, snapshot))

            assertEquals(otherEntries, ledger)
            assertEquals(1, writes)
            assertFalse(snapshot.exists())
        } finally {
            snapshot.delete()
        }
    }

    @Test fun rollbackWithoutGrantStillWritesLedgerAndDeletesSnapshot() {
        val snapshot = File.createTempFile("share-rollback-", ".epub")
        try {
            val otherEntries = recordShareGrant(emptySet(), "content://u/other", "/s/other.epub", 1000)
            var ledger = otherEntries
            var writes = 0

            assertFalse(rollbackFailedShare({ ledger }, { ledger = it; writes++ }, snapshot))

            assertEquals(otherEntries, ledger)
            assertEquals(1, writes)
            assertFalse(snapshot.exists())
        } finally {
            snapshot.delete()
        }
    }

    @Test fun rollbackIsIdempotent() {
        val snapshot = File.createTempFile("share-rollback-", ".epub")
        try {
            var ledger = recordShareGrant(emptySet(), "content://u/failed", snapshot.absolutePath, 1000)
            var writes = 0
            val readGrants = { ledger }
            val writeGrants: (Set<String>) -> Unit = { ledger = it; writes++ }

            assertTrue(rollbackFailedShare(readGrants, writeGrants, snapshot))
            assertFalse(rollbackFailedShare(readGrants, writeGrants, snapshot))

            assertTrue(ledger.isEmpty())
            assertEquals(2, writes)
            assertFalse(snapshot.exists())
        } finally {
            snapshot.delete()
        }
    }
}
