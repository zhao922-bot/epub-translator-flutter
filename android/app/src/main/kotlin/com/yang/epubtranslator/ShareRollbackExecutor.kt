package com.yang.epubtranslator

import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Process-lifetime rollback worker: Activity teardown must not reject cleanup.
 * The daemon thread never needs an Activity-owned shutdown. */
internal object ShareRollbackExecutor : Executor {
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "share-rollback").apply { isDaemon = true }
    }

    /** Serializes grant ledger read-modify-writes across IO and rollback workers. */
    internal val grantLock = Any()

    override fun execute(command: Runnable) = executor.execute(command)
}
