package com.ambi.gold_paper_trading

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import org.json.JSONObject

// Offline bridge for Friday (user project: connect the apps,
// offline-first). Serves the latest REAL snapshot the Dart side wrote to
// SharedPreferences (quote, paper balance, open positions) to Friday on
// the same phone - no network, no account, nothing leaves the device.
// Only Friday may read it: any other caller gets nothing.
//
// Friday paper orders (user ask: buy/sell/close from Friday): Friday hands
// ONE confirmed order to call("fridayTradeSubmit"); it is parked in Sona's
// own preferences and Friday opens Sona. Sona's Dart side executes it with
// its own PIN session through the same openPaper/closePaper path as the
// Buy/Sell/Close buttons (all trade_safety / limits / margin / market-hours
// checks), then writes the result that Friday reads with
// call("fridayTradeResult"). Friday never sees the PIN or backend keys.
// Paper trading only: nothing here reaches a broker.
class OroBridgeProvider : ContentProvider() {

    companion object {
        private const val FRIDAY_PACKAGE = "com.friday.assistant"
        private const val PREFS = "FlutterSharedPreferences"
        private const val ORDER_KEY = "flutter.oro_friday_order"
        private const val RESULT_KEY = "flutter.oro_friday_result"
        private const val MAX_QTY_OZ = 10000.0 // 100 lots
        private const val ORDER_TTL_MS = 60_000L

        /** Pure validation so it can be unit-tested. Null = valid. */
        fun validateOrder(o: JSONObject): String? {
            val id = o.optString("id", "")
            if (id.isEmpty() || id.length > 64) return "bad id"
            when (o.optString("op", "")) {
                "open" -> {
                    val side = o.optString("side", "")
                    if (side != "buy" && side != "sell") return "bad side"
                    val qty = o.optDouble("qty", Double.NaN)
                    if (qty.isNaN() || qty.isInfinite() || qty <= 0 || qty > MAX_QTY_OZ) return "bad qty"
                    for (k in listOf("tp", "sl")) {
                        if (o.has(k) && !o.isNull(k)) {
                            val v = o.optDouble(k, Double.NaN)
                            if (v.isNaN() || v.isInfinite() || v <= 0) return "bad $k"
                        }
                    }
                }
                "close" -> {
                    val ids = o.optJSONArray("ids") ?: return "no ids"
                    if (ids.length() == 0 || ids.length() > 50) return "bad ids"
                    for (i in 0 until ids.length()) {
                        val s = ids.optString(i, "")
                        if (s.isEmpty() || s == "null") return "bad ids"
                    }
                }
                else -> return "bad op"
            }
            return null
        }
    }

    override fun onCreate(): Boolean = true

    private fun callerIsFriday(ctx: Context): Boolean {
        val caller = try {
            ctx.packageManager.getNameForUid(Binder.getCallingUid())
        } catch (e: Exception) {
            null
        }
        return caller == FRIDAY_PACKAGE
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? {
        val ctx = context ?: return null
        if (!callerIsFriday(ctx)) return null
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val json = prefs.getString("flutter.oro_bridge_snapshot", null) ?: return null
        val cursor = MatrixCursor(arrayOf("json"))
        cursor.addRow(arrayOf(json))
        return cursor
    }

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        val ctx = context ?: return null
        if (!callerIsFriday(ctx)) return null
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val out = Bundle()
        when (method) {
            "fridayTradePing" -> out.putBoolean("trade", true)
            "fridayTradeSubmit" -> {
                val order = try { JSONObject(arg ?: "") } catch (e: Exception) { null }
                val error = if (order == null) "bad json" else validateOrder(order)
                if (error != null) {
                    out.putBoolean("accepted", false)
                    out.putString("error", error)
                    return out
                }
                synchronized(OroBridgeProvider::class.java) {
                    val now = System.currentTimeMillis()
                    // One order at a time: refuse while a fresh one is still waiting.
                    val waiting = prefs.getString(ORDER_KEY, null)?.let {
                        try { JSONObject(it) } catch (e: Exception) { null }
                    }
                    if (waiting != null && now - waiting.optLong("receivedAt", 0) < ORDER_TTL_MS) {
                        out.putBoolean("accepted", false)
                        out.putString("error", "busy")
                        return out
                    }
                    order!!.put("receivedAt", now)
                    prefs.edit().putString(ORDER_KEY, order.toString()).commit()
                }
                out.putBoolean("accepted", true)
            }
            "fridayTradeResult" -> {
                val raw = prefs.getString(RESULT_KEY, null)
                val res = raw?.let { try { JSONObject(it) } catch (e: Exception) { null } }
                if (res != null && res.optString("id") == arg) out.putString("json", raw)
            }
            "fridayTradeCancel" -> {
                synchronized(OroBridgeProvider::class.java) {
                    val waiting = prefs.getString(ORDER_KEY, null)?.let {
                        try { JSONObject(it) } catch (e: Exception) { null }
                    }
                    if (waiting != null && waiting.optString("id") == arg) {
                        prefs.edit().remove(ORDER_KEY).commit()
                        out.putBoolean("cancelled", true)
                    }
                }
            }
            else -> return null
        }
        return out
    }

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
