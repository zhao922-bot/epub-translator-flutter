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

    @Test fun runSecretOpTakesReceiverLambdaNotCapturingClosure() {
        // P-#45: the secret op must be MainActivity.() -> Any? (a Function1
        // with receiver), not () -> Any? (a Function0). A Function0 written
        // as { useKeyStore() } inside the Activity captures `this`, so the
        // process-wide SecretExecutor thread would pin the destroyed
        // Activity. A receiver lambda captures nothing; the Activity is
        // only reached via WeakReference inside the Runnable.
        val candidates = MainActivity::class.java.declaredMethods.filter {
            it.name == "runSecretOp"
        }
        assertFalse(candidates.isEmpty())
        val opParam = candidates
            .mapNotNull { method ->
                method.parameterTypes.getOrNull(2)?.let { method to it }
            }
            .firstOrNull { (_, type) ->
                type == Function1::class.java || type == Function0::class.java
            }
        assertNotNull("runSecretOp must take a function-typed op", opParam)
        assertEquals(
            "P-#45: op must be MainActivity.() -> Any? (Function1), not " +
                "() -> Any? (Function0) which would capture the Activity",
            Function1::class.java,
            opParam!!.second,
        )
    }
}
