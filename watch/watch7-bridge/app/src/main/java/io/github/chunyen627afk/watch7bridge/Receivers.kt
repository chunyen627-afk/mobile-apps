package io.github.chunyen627afk.watch7bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** 開機或 App 更新後自動啟動連線服務。 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        BridgeService.start(context)
    }
}

/** 通知上的按鈕與滑掉通知：把動作傳回 iPhone。 */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val uid = intent.getLongExtra(BridgeService.EXTRA_UID, 0)
        val positive = intent.getBooleanExtra(BridgeService.EXTRA_POSITIVE, false)
        BridgeService.instance?.link?.performAction(uid, positive)
    }
}
