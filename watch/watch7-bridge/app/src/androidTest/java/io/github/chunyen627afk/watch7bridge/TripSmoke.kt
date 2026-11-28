package io.github.chunyen627afk.watch7bridge

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.view.inspector.WindowInspector
import android.widget.TextView
import org.json.JSONObject
import java.util.UUID

/** 測試 APK 才有此入口，傳送模擬的 iPhone 訊息給正式的解碼與畫面處理。 */
class TripSmoke : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val id = UUID.randomUUID().toString()
        val results = Bundle()
        try {
            targetContext.startForegroundService(Intent(targetContext, BridgeService::class.java))
            repeat(50) { if (BridgeService.instance == null) SystemClock.sleep(100) }
            val service = checkNotNull(BridgeService.instance)
            fun step(state: String, text: String, meters: Int? = null, arrow: String = "") {
                val json = JSONObject().put("t", "navigation").put("trip", id)
                    .put("state", state).put("text", text).put("arrow", arrow).put("meters", meters)
                runOnMainSync { service.onSnapshot(json.toString()) }
                waitForIdleSync()
            }
            fun labels(view: View): List<String> = when (view) {
                is TextView -> listOf(view.text.toString())
                is ViewGroup -> (0 until view.childCount).flatMap { labels(view.getChildAt(it)) }
                else -> emptyList()
            }
            fun displayed(): List<String> {
                var result = emptyList<String>()
                runOnMainSync { result = WindowInspector.getGlobalWindowViews().flatMap { labels(it) } }
                return result
            }
            step("guiding", "右轉", 200, "→")
            check("→  200 公尺" in displayed())
            step("guiding", "右轉", 50, "→")
            check("→  50 公尺" in displayed())
            step("rerouting", "正在重新規劃路線")
            check("正在重新規劃路線" in displayed() && "→  50 公尺" !in displayed())
            step("guiding", "左轉", 80, "←")
            check("←  80 公尺" in displayed())
            step("ended", "導航已結束")
            check("收合" !in displayed())
            results.putString("result", "PASS: open, countdown, reroute, replacement, close")
            finish(Activity.RESULT_OK, results)
        } catch (error: Throwable) {
            runOnMainSync { BridgeService.instance?.tripDisplay?.clear() }
            results.putString("error", error.stackTraceToString())
            finish(Activity.RESULT_CANCELED, results)
        }
    }
}
