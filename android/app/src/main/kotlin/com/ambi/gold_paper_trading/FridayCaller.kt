package com.ambi.gold_paper_trading

import android.content.pm.PackageManager
import android.os.Build
import java.security.MessageDigest

object FridayCaller {
    fun trusted(context: android.content.Context, uid: Int): Boolean {
        val packageManager = context.packageManager
        val packages = packageManager.getPackagesForUid(uid) ?: return false
        if (packages.size != 1 || packages[0] != "com.friday.assistant") return false
        return try {
            val info = if (Build.VERSION.SDK_INT >= 28)
                packageManager.getPackageInfo(packages[0], PackageManager.GET_SIGNING_CERTIFICATES)
            else @Suppress("DEPRECATION") packageManager.getPackageInfo(packages[0], PackageManager.GET_SIGNATURES)
            val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners
                else @Suppress("DEPRECATION") info.signatures
            signatures?.any { sig ->
                MessageDigest.getInstance("SHA-256").digest(sig.toByteArray())
                    .joinToString("") { "%02x".format(it) } ==
                    "9ca9b3638f3580bfff9d01883515dbaaf44b8e74617fd4e6119228f54785e2fc"
            } == true
        } catch (_: Exception) { false }
    }
}
