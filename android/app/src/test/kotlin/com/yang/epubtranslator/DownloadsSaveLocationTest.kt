package com.yang.epubtranslator

import org.junit.Assert.assertEquals
import org.junit.Test

class DownloadsSaveLocationTest {
    private val uri = "content://media/external/downloads/42"

    @Test
    fun collisionReportsProviderAssignedName() {
        // book.epub already exists; the inserted URI belongs to book (1).epub.
        assertEquals("Downloads/book (1).epub", DownloadsSaveLocation.resolve(uri) {
            "book (1).epub"
        })
    }

    @Test
    fun unchangedNameIsReported() {
        assertEquals("Downloads/book.epub", DownloadsSaveLocation.resolve(uri) {
            "book.epub"
        })
    }

    @Test
    fun unavailableNameFallsBackToExactUri() {
        for (name in listOf(null, "", " ")) {
            assertEquals(uri, DownloadsSaveLocation.resolve(uri) { name })
        }
        assertEquals(uri, DownloadsSaveLocation.resolve(uri) {
            throw IllegalStateException("Provider query failed")
        })
    }
}
