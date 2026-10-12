package com.yang.epubtranslator

import java.util.concurrent.atomic.AtomicReference

/** Replace the complete immutable snapshot; readers never observe clear/add gaps. */
internal class ProtectedImportPaths {
    private val paths = AtomicReference<Set<String>>(emptySet())
    fun replace(values: List<String>) {
        paths.set(values.filter { it.isNotBlank() }.toSet())
    }
    operator fun contains(path: String): Boolean = path in paths.get()
}

/** A callback belongs to one attempt, even if completion races a newer pick. */
internal class ImportWatchdog {
    var callback: Runnable? = null
    fun cancel(remove: (Runnable) -> Unit) {
        callback?.let(remove)
        callback = null
    }
}

internal class ImportLifecycle {
    @Volatile var generation = 0
        private set
    @Volatile var destroyed = false
        private set
    fun invalidate() { generation += 1 }
    fun destroy() {
        destroyed = true
        invalidate()
    }
    fun isCurrent(capturedGeneration: Int): Boolean =
        !destroyed && generation == capturedGeneration
}

internal fun confirmedEpubName(safeName: String): String =
    if (safeName.endsWith(".epub", ignoreCase = true)) safeName
    else "$safeName.epub"
