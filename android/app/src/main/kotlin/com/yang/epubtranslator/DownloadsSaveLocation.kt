package com.yang.epubtranslator

/** Reports the provider-owned name; the exact URI is a safe query fallback. */
internal object DownloadsSaveLocation {
    fun resolve(uri: String, queryDisplayName: () -> String?): String {
        val actualName = try {
            queryDisplayName()
        } catch (_: Exception) {
            null
        }
        return if (actualName.isNullOrBlank()) uri else "Downloads/$actualName"
    }
}
