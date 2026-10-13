package com.yang.epubtranslator

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class SecretExecutorTest {
    @Test fun executorAndLockAreProcessWideSingletons() {
        // P2-#10: KeyStore ops must stay serialized across Activity
        // recreations, so the executor and the key-creation lock live on
        // this application-scoped singleton — never on an Activity instance.
        // An `object` guarantees one instance per process; these assertions
        // pin that property so a future refactor cannot silently reintroduce
        // per-Activity state.
        assertSame(SecretExecutor, SecretExecutor)
        assertSame(SecretExecutor.keyStoreLock, SecretExecutor.keyStoreLock)
    }

    @Test fun submittedOpsRunInSubmissionOrder() {
        // P2-#10: the singleton is a single daemon thread, so ops from a
        // destroyed Activity and its replacement still serialize FIFO.
        val order = mutableListOf<Int>()
        val latch = CountDownLatch(3)
        repeat(3) { i ->
            SecretExecutor.execute {
                // Mirrors MainActivity.runSecretOp: the whole op runs under
                // the shared keyStoreLock.
                synchronized(SecretExecutor.keyStoreLock) {
                    order.add(i)
                }
                latch.countDown()
            }
        }
        assertTrue(latch.await(10, TimeUnit.SECONDS))
        assertEquals(listOf(0, 1, 2), order)
    }
}
