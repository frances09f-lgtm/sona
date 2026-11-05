package com.ambi.gold_paper_trading

import android.content.Context
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class FridayOrderStoreTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val prefs get() = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    @Before fun reset() { prefs.edit().clear().commit() }
    private fun queue(id: String) {
        prefs.edit().putString("flutter.oro_friday_order", JSONObject().put("id", id).put("op", "open").put("side", "buy").put("qty", 1).put("receivedAt", System.currentTimeMillis()).toString()).commit()
    }
    @Test fun concurrentUiAndHeadlessClaimOnlyOnce() {
        queue("concurrent")
        val pool = Executors.newFixedThreadPool(16)
        try {
            val jobs = (1..64).map { Callable { FridayOrderStore.claim(context) } }
            val results = pool.invokeAll(jobs).map { it.get(5, TimeUnit.SECONDS) }
            assertEquals(1, results.count { it != null })
            assertNull(prefs.getString("flutter.oro_friday_order", null))
            assertEquals("working", JSONObject(prefs.getString("flutter.oro_friday_result", "")!!).getString("status"))
        } finally { pool.shutdownNow() }
    }
    @Test fun replayedIdNeverBecomesExecutableAgain() {
        queue("durable")
        assertNotNull(FridayOrderStore.claim(context))
        // Simulates another UI/resume putting the consumed ID back on queue.
        queue("durable")
        assertNull(FridayOrderStore.claim(context))
        assertTrue(FridayOrderStore.claimed(context, "durable"))
        assertNull(prefs.getString("flutter.oro_friday_order", null))
    }
    @Test fun distinctOrderCanBeClaimedAfterPriorConsumption() {
        queue("one"); assertNotNull(FridayOrderStore.claim(context))
        queue("two"); assertNotNull(FridayOrderStore.claim(context))
        assertTrue(FridayOrderStore.claimed(context, "one"))
        assertTrue(FridayOrderStore.claimed(context, "two"))
    }
    @Test fun unrelatedUidIsDenied() {
        assertFalse(FridayCaller.trusted(context, 987654))
        assertFalse(FridayCaller.trusted(context, android.os.Process.myUid()))
    }
}
