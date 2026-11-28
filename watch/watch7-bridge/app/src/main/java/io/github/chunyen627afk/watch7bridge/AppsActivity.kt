package io.github.chunyen627afk.watch7bridge

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView

/** 每個 iPhone App 的通知開關。清單來自曾經送過通知的 App。 */
class AppsActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val rules = AppRules(this)
        val pad = (resources.displayMetrics.density * 28).toInt()
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }
        col.addView(TextView(this).apply {
            text = "要在手錶顯示哪些 App 的通知"
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 16)
        })
        val apps = rules.seen()
        if (apps.isEmpty()) {
            col.addView(TextView(this).apply {
                text = "還沒有收過任何通知。收過之後 App 才會出現在這裡。"
                textSize = 12f
                gravity = Gravity.CENTER
            })
        }
        for (id in apps) {
            col.addView(Switch(this).apply {
                text = BridgeService.appLabel(id)
                textSize = 14f
                isChecked = rules.isAllowed(id)
                setPadding(0, 12, 0, 12)
                setOnCheckedChangeListener { _, on -> rules.setAllowed(id, on) }
            })
        }
        setContentView(ScrollView(this).apply { addView(col) })
    }
}
