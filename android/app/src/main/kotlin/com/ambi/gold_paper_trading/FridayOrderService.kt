package com.ambi.gold_paper_trading

import android.app.Service
import android.content.Intent
import android.os.*
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.FlutterInjector

/** Bound only while Friday awaits this confirmed order. Never starts an Activity. */
class FridayOrderService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var orderId: String? = null
    private val timeout = Runnable { shutdown() }
    private val messenger = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(msg: Message) {
            if (msg.what != 1 || !FridayCaller.trusted(applicationContext, msg.sendingUid) || engine != null) return
            // Only the provider's validated confirmed order can be consumed.
            val p = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            val raw = p.getString("flutter.oro_friday_order", null) ?: return
            orderId = try { org.json.JSONObject(raw).optString("id") } catch (_: Exception) { return }
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)
                val e = FlutterEngine(applicationContext)
                engine = e
                FridayOrderStore.register(applicationContext, e.dartExecutor.binaryMessenger) { handler.post { shutdown() } }
                e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "fridayOrderMain"))
                handler.postDelayed(timeout, 90_000)
            } catch (_: Exception) { shutdown() }
        }
    })
    override fun onBind(intent: Intent): IBinder = messenger.binder
    private fun shutdown() {
        handler.removeCallbacks(timeout)
        // Withdraw only unclaimed queue state. Claimed status remains unknown on interruption.
        val p = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        synchronized(FridayOrderStore) {
            val raw = p.getString("flutter.oro_friday_order", null)
            val waitingId = try { raw?.let { org.json.JSONObject(it).optString("id") } } catch (_: Exception) { null }
            if (orderId != null && waitingId == orderId) p.edit().remove("flutter.oro_friday_order").commit()
        }
        orderId = null
        engine?.destroy(); engine = null
    }
    override fun onDestroy() { shutdown(); super.onDestroy() }
    override fun onUnbind(intent: Intent): Boolean { shutdown(); return false }
}
