package io.github.chunyen627afk.watch7bridge

import android.content.Context

/** 記住看過哪些 iPhone App，以及哪些被使用者關掉通知。 */
class AppRules(ctx: Context) {
    private val prefs = ctx.getSharedPreferences("app_rules", Context.MODE_PRIVATE)

    /** 看過的 App 識別碼，依顯示名稱排序。 */
    fun seen(): List<String> =
        prefs.getStringSet(KEY_SEEN, emptySet()).orEmpty()
            .sortedBy { BridgeService.appLabel(it).lowercase() }

    fun remember(appId: String) {
        if (appId.isBlank()) return
        val cur = prefs.getStringSet(KEY_SEEN, emptySet()).orEmpty()
        if (appId !in cur) prefs.edit().putStringSet(KEY_SEEN, cur + appId).apply()
    }

    fun isAllowed(appId: String): Boolean =
        appId !in prefs.getStringSet(KEY_BLOCKED, emptySet()).orEmpty()

    fun setAllowed(appId: String, allowed: Boolean) {
        val cur = prefs.getStringSet(KEY_BLOCKED, emptySet()).orEmpty()
        val next = if (allowed) cur - appId else cur + appId
        prefs.edit().putStringSet(KEY_BLOCKED, next).apply()
    }

    private companion object {
        const val KEY_SEEN = "seen"
        const val KEY_BLOCKED = "blocked"
    }
}
