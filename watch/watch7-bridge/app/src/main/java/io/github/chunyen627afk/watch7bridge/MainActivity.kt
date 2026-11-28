package io.github.chunyen627afk.watch7bridge

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import io.github.chunyen627afk.watch7bridge.ancs.Ams
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 狀態與操作畫面：連線狀態、iPhone 電量、媒體控制、配對。 */
class MainActivity : Activity() {

    private lateinit var status: TextView
    private lateinit var info: TextView
    private lateinit var media: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (resources.displayMetrics.density * 28).toInt()
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(pad, pad, pad, pad)
        }
        status = text(col, 16f)
        info = text(col, 13f)
        media = text(col, 13f)

        val row = LinearLayout(this).apply { gravity = Gravity.CENTER }
        button(row, "⏮") { svc()?.link?.mediaCommand(Ams.CMD_PREVIOUS) }
        button(row, "⏯") { svc()?.link?.mediaCommand(Ams.CMD_TOGGLE) }
        button(row, "⏭") { svc()?.link?.mediaCommand(Ams.CMD_NEXT) }
        col.addView(row)

        button(col, "重新連線") { svc()?.link?.kick() }
        button(col, "配對 iPhone") { svc()?.link?.startPairing() }
        button(col, "清除配對") { svc()?.link?.forget() }
        text(col, 11f).text =
            "配對後請在 iPhone「設定→藍牙」點這支手錶旁的資訊鈕，開啟「分享系統通知」。\n" +
            "並把本 App 從手錶電池設定的「休眠中的應用程式」移除。"

        setContentView(ScrollView(this).apply { addView(col) })
    }

    override fun onResume() {
        super.onResume()
        if (BridgeService.hasPermissions(this)) {
            BridgeService.start(this)
        } else {
            requestPermissions(BridgeService.REQUIRED_PERMISSIONS, 1)
        }
        BridgeService.onChanged = { runOnUiThread { refresh() } }
        refresh()
    }

    override fun onPause() {
        BridgeService.onChanged = null
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (BridgeService.hasPermissions(this)) BridgeService.start(this)
        refresh()
    }

    private fun svc() = BridgeService.instance

    private fun refresh() {
        val s = svc()
        if (s == null) {
            status.text = if (BridgeService.hasPermissions(this)) "啟動中" else "需要藍牙與通知權限"
            info.text = ""
            media.text = ""
            return
        }
        status.text = s.stateText
        val last = s.link.lastReadyAt
        info.text = buildString {
            if (s.battery >= 0) append("iPhone 電量 ${s.battery}%\n")
            if (last > 0) append("上次連線 " + SimpleDateFormat("MM/dd HH:mm", Locale.TAIWAN).format(Date(last)))
        }
        media.text = when {
            s.trackTitle.isBlank() -> "沒有正在播放的媒體"
            else -> (if (s.playing) "▶ " else "⏸ ") + s.trackTitle +
                (if (s.trackArtist.isBlank()) "" else "\n" + s.trackArtist)
        }
    }

    private fun text(parent: LinearLayout, size: Float) = TextView(this).apply {
        textSize = size
        gravity = Gravity.CENTER
        setPadding(0, 8, 0, 8)
        parent.addView(this)
    }

    private fun button(parent: LinearLayout, label: String, onClick: () -> Unit) = Button(this).apply {
        text = label
        setOnClickListener { onClick() }
        parent.addView(this)
    }
}
