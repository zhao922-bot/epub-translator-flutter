package com.yang.epubtranslator

import java.util.concurrent.atomic.AtomicReference
import java.io.File

internal const val MAX_IMPORT_BYTES = 256L * 1024 * 1024

/** Thrown when the selected EPUB exceeds the import size limit (B-2). */
internal class ImportTooLargeException :
    IllegalArgumentException("Selected EPUB exceeds the 256 MiB import limit.")

internal class ImportSizeLimit(private val maximum: Long = MAX_IMPORT_BYTES) {
    private var copied = 0L
    fun checkKnownSize(size: Long) {
        if (size > maximum) throw ImportTooLargeException()
    }
    fun acceptChunk(size: Int) {
        require(size >= 0)
        if (size.toLong() > maximum - copied) {
            throw ImportTooLargeException()
        }
        copied += size
    }
}

/** Keep cleanup shared with the native copy's failure path. */
internal fun removeFailedImport(partFile: File, target: File) {
    partFile.delete()
    target.delete()
}

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
    /**
     * Guards the generation check-and-register sequence (P2-#16): the
     * watchdog's executor replacement and a task's holder registration must
     * not interleave, or a stale task could slip between the generation
     * re-check and the set() and overwrite a newer import's holder.
     */
    val registrationLock = Any()
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

/** Thrown when an import task observes a newer executor generation: the
 * watchdog already replaced the executor, so this pick's result was (or
 * will be) answered with PICK_TIMEOUT and anything the task does now would
 * only corrupt a newer pick's state. */
internal class ImportStaleException :
    Exception("Import attempt superseded by executor replacement.")

/**
 * Registration gate for the active-import holder slot (P2-#9): re-checks
 * the task's captured generation immediately before registering. A task
 * suspended across a blocking provider call must not overwrite a newer
 * import's registration after the watchdog replaced the executor — on a
 * stale generation this throws [ImportStaleException] instead of
 * registering, so the newer holder (and its watchdog un-wedging) survives.
 *
 * P2-#16: prefer [MainActivity.registerImportHolder], which runs this
 * check and the set() atomically under [ImportLifecycle.registrationLock].
 * Check-then-set without the lock lets a watchdog executor replacement
 * land between the two and still overwrite the newer holder.
 */
internal fun checkImportRegistration(
    lifecycle: ImportLifecycle,
    taskGeneration: Int,
) {
    if (!lifecycle.isCurrent(taskGeneration)) throw ImportStaleException()
}

internal fun confirmedEpubName(safeName: String): String =
    if (safeName.endsWith(".epub", ignoreCase = true)) safeName
    else "$safeName.epub"
