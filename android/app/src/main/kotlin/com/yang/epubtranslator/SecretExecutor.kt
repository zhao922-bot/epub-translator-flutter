package com.yang.epubtranslator

import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Process-lifetime KeyStore/secret worker: serializes all secret reads and
 * writes on one background thread across Activity recreations. The old
 * per-Activity executor (shut down in onDestroy) let an old Activity's
 * still-queued op race a new Activity's executor on the same key alias,
 * breaking the serialization guarantee — and the old per-Activity
 * keyStoreLock had the same flaw, since the two Activities locked on
 * different monitors. Never shut down: queued secret ops must survive
 * Activity teardown. Daemon thread, like [ShareRollbackExecutor], so it
 * never keeps the process alive on its own. */
internal object SecretExecutor : Executor {
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "secret-ops").apply { isDaemon = true }
    }

    /** Serializes AndroidKeyStore key creation; concurrent generateKey() on
     * the same alias throws. */
    internal val keyStoreLock = Any()

    override fun execute(command: Runnable) = executor.execute(command)
}
