package com.ambi.gold_paper_trading

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** All UI/headless order claims occur in the single Sona app process. */
object FridayOrderStore {
    private const val PREFS = "FlutterSharedPreferences"
    private const val ORDER = "flutter.oro_friday_order"
    private const val RESULT = "flutter.oro_friday_result"
    private const val CLAIMS = "friday_native_claims_v1"
    @Synchronized fun claim(context: Context): String? {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = p.getString(ORDER, null) ?: return null
        val o = try { JSONObject(raw) } catch (_: Exception) { return null }
        val id = o.optString("id")
        if (id.isBlank()) return null
        val claims = p.getStringSet(CLAIMS, emptySet())!!.toMutableSet()
        if (claims.contains(id)) {
            p.edit().remove(ORDER).commit()
            return null
        }
        claims.add(id)
        // Never prune accepted IDs: an ambiguous/crashed execution must never retry.
        val working = JSONObject().put("id", id).put("status", "working")
            .put("at", System.currentTimeMillis()).toString()
        if (!p.edit().putStringSet(CLAIMS, claims).remove(ORDER)
                .putString(RESULT, working).commit()) throw IllegalStateException("claim storage failed")
        return raw
    }
    @Synchronized fun claimed(context: Context, id: String): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(CLAIMS, emptySet())!!.contains(id)
    fun register(context: Context, messenger: BinaryMessenger, done: (() -> Unit)? = null) {
        MethodChannel(messenger, "oro/friday_claim").setMethodCallHandler { call, result ->
            when (call.method) {
                "claim" -> try { result.success(claim(context)) }
                    catch (_: Exception) { result.error("storage", "Order safety storage unavailable", null) }
                "done" -> { result.success(null); done?.invoke() }
                else -> result.notImplemented()
            }
        }
    }
}
