package io.github.chunyen627afk.watch7bridge

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import org.json.JSONObject

/** 只在本機 iPhone 傳來有效導航時顯示，保持系統原本的息屏時間。 */
internal class TripDisplay(private val context: Context) {
    private val windows = context.getSystemService(WindowManager::class.java)
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { clear() }
    private var panel: LinearLayout? = null
    private var distance: TextView? = null
    private var detail: TextView? = null
    private var tripId: String? = null
    private var minimized = false
    private var lastHeading = ""
    private var lastText = ""

    fun showCurrent() {
        if (tripId == null) return
        minimized = false
        showPanel()
    }

    fun receive(msg: JSONObject) {
        val id = msg.optString("trip")
        if (id.isBlank()) return
        val state = msg.optString("state")
        if (state == "ended") {
            if (tripId == id) {
                if (panel != null && power.isInteractive) returnToDial()
                clear()
            }
            return
        }
        if (state !in setOf("routing", "guiding", "rerouting")) return
        val fresh = tripId != id
        if (fresh) { clear(); tripId = id }
        handler.removeCallbacks(timeout)
        handler.postDelayed(timeout, 35_000)
        val meters = msg.optInt("meters", -1)
        val heading = listOf(msg.optString("arrow"), if (meters >= 0 && state == "guiding") "$meters 公尺" else "")
            .filter { it.isNotBlank() }.joinToString("  ")
        val text = msg.optString("text")
        if (fresh || heading != lastHeading || text != lastText) {
            lastHeading = heading
            lastText = text
            val open = PendingIntent.getActivity(context, 3, Intent(context, MainActivity::class.java)
                .putExtra("showTrip", true).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val note = NotificationCompat.Builder(context, "nav")
                .setSmallIcon(R.drawable.ic_link).setOngoing(true).setOnlyAlertOnce(true)
                .setCategory(NotificationCompat.CATEGORY_NAVIGATION)
                .setContentTitle(heading.ifEmpty { "Google 地圖導航" }).setContentText(text).setContentIntent(open)
            notifications.notify("phone-trip", 4, note.build())
        }
        if (!minimized) showPanel()
        distance?.text = lastHeading
        detail?.text = lastText
    }

    private fun showPanel() {
        if (panel != null || !Settings.canDrawOverlays(context)) return
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val pad = (24 * resources.displayMetrics.density).toInt()
            setPadding(pad, 0, pad, 0)
            setBackgroundColor(Color.BLACK)
        }
        fun label(size: Float, color: Int) = TextView(context).apply {
            textSize = size
            setTextColor(color)
            gravity = Gravity.CENTER
            root.addView(this)
        }
        label(12f, Color.LTGRAY).text = "Google 地圖"
        distance = label(30f, Color.WHITE).apply { text = lastHeading }
        detail = label(16f, Color.WHITE).apply { text = lastText; maxLines = 4 }
        root.addView(Button(context).apply {
            text = "收合"
            setOnClickListener { minimized = true; removePanel() }
        })
        val lp = WindowManager.LayoutParams(-1, -1, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE, PixelFormat.OPAQUE)
        lp.setTitle("WatchLink Navigation")
        try {
            windows.addView(root, lp)
            panel = root
        } catch (_: WindowManager.BadTokenException) { removePanel() }
          catch (_: SecurityException) { removePanel() }
    }

    private fun returnToDial() {
        val intent = context.packageManager.getLaunchIntentForPackage("tw.royaloak.viewer") ?: return
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        try { context.startActivity(intent) } catch (_: android.content.ActivityNotFoundException) { }
    }

    private fun removePanel() {
        panel?.let { windows.removeViewImmediate(it) }
        panel = null
        distance = null
        detail = null
    }

    fun clear() {
        handler.removeCallbacks(timeout)
        removePanel()
        notifications.cancel("phone-trip", 4)
        tripId = null
        minimized = false
        lastHeading = ""
        lastText = ""
    }
}
