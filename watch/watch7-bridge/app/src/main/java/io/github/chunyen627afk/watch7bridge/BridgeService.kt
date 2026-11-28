package io.github.chunyen627afk.watch7bridge

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.github.chunyen627afk.watch7bridge.ancs.Ams
import io.github.chunyen627afk.watch7bridge.ancs.AmsUpdate
import io.github.chunyen627afk.watch7bridge.ancs.Ancs
import io.github.chunyen627afk.watch7bridge.ancs.AncsAttributes
import io.github.chunyen627afk.watch7bridge.ancs.AncsEvent

/** 維持與 iPhone 連線的前景服務，並把 iPhone 的通知轉成手錶通知。 */
class BridgeService : Service(), LinkListener {

    lateinit var link: LinkManager
        private set
    private lateinit var nm: NotificationManager

    var stateText = "啟動中"
        private set
    var battery = -1
        private set
    var trackTitle = ""
        private set
    var trackArtist = ""
        private set
    var playing = false
        private set

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        nm = getSystemService(NotificationManager::class.java)
        createChannels()
        startForeground(
            ID_LINK,
            linkNotification("啟動中"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
        link = LinkManager(this, this)
        instance = this
        link.start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ANCS -> link.performAction(
                intent.getLongExtra(EXTRA_UID, 0),
                intent.getBooleanExtra(EXTRA_POSITIVE, false),
            )
            ACTION_KICK -> link.kick()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        link.stop()
        instance = null
        super.onDestroy()
    }

    // ---------------------------------------------------------------- LinkListener

    override fun onState(state: LinkState, detail: String) {
        stateText = detail
        nm.notify(ID_LINK, linkNotification(detail))
        onChanged?.invoke()
    }

    override fun onSessionReset() {
        // 斷線後 iPhone 會在重連時重送仍存在的通知，舊的先清掉
        nm.activeNotifications.filter { it.tag == TAG_ANCS }.forEach { nm.cancel(TAG_ANCS, it.id) }
        battery = -1
        onChanged?.invoke()
    }

    override fun onNotificationRemoved(uid: Long) {
        nm.cancel(TAG_ANCS, uid.toInt())
    }

    override fun onNotification(event: AncsEvent, attrs: AncsAttributes) {
        val isCall = event.category == Ancs.CATEGORY_INCOMING_CALL
        // 連線時 iPhone 會把通知中心裡的舊通知全部重送一次；那些不顯示，只顯示連線後新來的
        if (event.preExisting && !isCall) return
        val quiet = event.silent || event.eventId == Ancs.EVENT_MODIFIED
        val channel = when {
            isCall -> CH_CALL
            quiet -> CH_QUIET
            else -> CH_MESSAGE
        }
        val body = listOf(attrs.subtitle, attrs.message).filter { it.isNotBlank() }.joinToString("\n")
        val b = NotificationCompat.Builder(this, channel)
            .setSmallIcon(R.drawable.ic_link)
            .setContentTitle(attrs.title.ifBlank { appLabel(attrs.appId) })
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setSubText(appLabel(attrs.appId))
            .setGroup(attrs.appId)
            .setOnlyAlertOnce(quiet)
            .setAutoCancel(!isCall)
            .setOngoing(isCall)
            .setCategory(if (isCall) NotificationCompat.CATEGORY_CALL else NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(if (isCall) NotificationCompat.PRIORITY_MAX else NotificationCompat.PRIORITY_DEFAULT)

        parseAncsDate(attrs.date)?.let { b.setWhen(it).setShowWhen(true) }

        if (event.hasPositive) {
            b.addAction(0, attrs.positiveLabel.ifBlank { if (isCall) "接聽" else "確定" }, actionIntent(event.uid, true))
        }
        if (event.hasNegative) {
            b.addAction(0, attrs.negativeLabel.ifBlank { if (isCall) "拒接" else "清除" }, actionIntent(event.uid, false))
            // 在手錶上滑掉通知時，同步清掉 iPhone 上的；來電不這樣做，以免誤掛
            if (!isCall) b.setDeleteIntent(actionIntent(event.uid, false))
        }
        nm.notify(TAG_ANCS, event.uid.toInt(), b.build())
    }

    override fun onBattery(percent: Int) {
        battery = percent
        onChanged?.invoke()
    }

    override fun onMedia(update: AmsUpdate) {
        when (update.entity) {
            Ams.ENTITY_TRACK -> when (update.attribute) {
                Ams.TRACK_TITLE -> trackTitle = update.value
                Ams.TRACK_ARTIST -> trackArtist = update.value
            }
            Ams.ENTITY_PLAYER -> if (update.attribute == Ams.PLAYER_PLAYBACK_INFO) playing = Ams.isPlaying(update.value)
        }
        onChanged?.invoke()
    }

    // ---------------------------------------------------------------- 輔助

    private fun actionIntent(uid: Long, positive: Boolean): PendingIntent {
        val i = Intent(this, ActionReceiver::class.java)
            .putExtra(EXTRA_UID, uid)
            .putExtra(EXTRA_POSITIVE, positive)
        val code = (uid.toInt() shl 1) or (if (positive) 1 else 0)
        return PendingIntent.getBroadcast(this, code, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun linkNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CH_LINK)
            .setSmallIcon(R.drawable.ic_link)
            .setContentTitle("iPhone 連線")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .build()
    }

    private fun createChannels() {
        fun ch(id: String, name: String, importance: Int) =
            nm.createNotificationChannel(NotificationChannel(id, name, importance))
        ch(CH_LINK, "連線狀態", NotificationManager.IMPORTANCE_MIN)
        ch(CH_MESSAGE, "iPhone 通知", NotificationManager.IMPORTANCE_DEFAULT)
        ch(CH_QUIET, "iPhone 通知（靜音）", NotificationManager.IMPORTANCE_LOW)
        ch(CH_CALL, "來電", NotificationManager.IMPORTANCE_HIGH)
    }

    companion object {
        const val ACTION_ANCS = "ancs_action"
        const val ACTION_KICK = "kick"
        const val EXTRA_UID = "uid"
        const val EXTRA_POSITIVE = "positive"

        private const val ID_LINK = 1
        private const val TAG_ANCS = "ancs"
        private const val CH_LINK = "link"
        private const val CH_MESSAGE = "message"
        private const val CH_QUIET = "quiet"
        private const val CH_CALL = "call"

        @Volatile
        var instance: BridgeService? = null
            private set

        /** 畫面用來刷新的回呼；只在主執行緒設定與呼叫。 */
        var onChanged: (() -> Unit)? = null

        fun hasPermissions(c: Context): Boolean = REQUIRED_PERMISSIONS.all {
            ContextCompat.checkSelfPermission(c, it) == PackageManager.PERMISSION_GRANTED
        }

        fun start(c: Context) {
            if (hasPermissions(c)) c.startForegroundService(Intent(c, BridgeService::class.java))
        }

        val REQUIRED_PERMISSIONS = arrayOf(
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.POST_NOTIFICATIONS,
        )

        /** 常見 App 的顯示名稱；其餘取識別碼最後一段。 */
        fun appLabel(appId: String): String = when (appId) {
            "jp.naver.line" -> "LINE"
            "com.apple.MobileSMS" -> "訊息"
            "com.apple.mobilephone" -> "電話"
            "com.apple.mobilemail" -> "郵件"
            "com.apple.mobilecal" -> "行事曆"
            "com.google.Maps" -> "Google 地圖"
            "com.google.Gmail" -> "Gmail"
            "net.whatsapp.WhatsApp" -> "WhatsApp"
            "com.facebook.Messenger" -> "Messenger"
            "" -> "iPhone"
            else -> appId.substringAfterLast('.')
        }

        /** ANCS 的日期格式為 yyyyMMdd'T'HHmmss，手機當地時間。 */
        fun parseAncsDate(s: String): Long? = runCatching {
            java.text.SimpleDateFormat("yyyyMMdd'T'HHmmss", java.util.Locale.US).parse(s)?.time
        }.getOrNull()
    }
}
