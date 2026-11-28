package io.github.chunyen627afk.watch7bridge

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import io.github.chunyen627afk.watch7bridge.ancs.Ams
import io.github.chunyen627afk.watch7bridge.ancs.AmsUpdate
import io.github.chunyen627afk.watch7bridge.ancs.Ancs
import io.github.chunyen627afk.watch7bridge.ancs.AncsAttributes
import io.github.chunyen627afk.watch7bridge.ancs.AncsEvent
import io.github.chunyen627afk.watch7bridge.ancs.AttributeAssembler
import java.util.ArrayDeque
import java.util.UUID

enum class LinkState { IDLE, PAIRING, CONNECTING, BONDING, DISCOVERING, READY, WAITING }

interface LinkListener {
    fun onState(state: LinkState, detail: String)
    fun onNotification(event: AncsEvent, attrs: AncsAttributes)
    fun onNotificationRemoved(uid: Long)
    fun onSessionReset()
    fun onBattery(percent: Int)
    fun onMedia(update: AmsUpdate)
}

/**
 * 與 iPhone 的 BLE 連線。
 * 首次配對：手錶廣播（帶 ANCS solicitation），iPhone 從「設定→藍牙」連進來，手錶在同一條連線上當 GATT client 並發起綁定。
 * 之後：手錶主動連回已綁定的 iPhone；直接連線重試數次後改用 autoConnect，並由看門狗定期重來。
 * 所有回呼都轉到主執行緒處理。
 */
@SuppressLint("MissingPermission")
class LinkManager(private val ctx: Context, private val listener: LinkListener) {

    private val main = Handler(Looper.getMainLooper())
    private val btManager = ctx.getSystemService(BluetoothManager::class.java)
    private val adapter: BluetoothAdapter? get() = btManager.adapter
    private val prefs = ctx.getSharedPreferences("link", Context.MODE_PRIVATE)

    var state = LinkState.IDLE
        private set
    private var stateSince = SystemClock.elapsedRealtime()
    var lastReadyAt = 0L
        private set

    private var gatt: BluetoothGatt? = null
    private var server: BluetoothGattServer? = null
    private var advertising = false
    private var directAttempts = 0
    private var discoverRetries = 0
    private var started = false

    private var controlPoint: BluetoothGattCharacteristic? = null
    private var amsRemote: BluetoothGattCharacteristic? = null
    private val assembler = AttributeAssembler()
    private val pendingEvents = HashMap<Long, AncsEvent>()

    private sealed class Op {
        class Notify(val ch: BluetoothGattCharacteristic) : Op()
        class Write(val ch: BluetoothGattCharacteristic, val value: ByteArray) : Op()
        class Read(val ch: BluetoothGattCharacteristic) : Op()
    }

    private val ops = ArrayDeque<Op>()
    private var opBusy = false

    // ---------------------------------------------------------------- 對外

    fun start() {
        if (started) return
        started = true
        ctx.registerReceiver(
            systemReceiver,
            IntentFilter().apply {
                addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
                addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
                addAction(Intent.ACTION_SCREEN_ON)
            },
        )
        main.postDelayed(watchdog, WATCHDOG_INTERVAL_MS)
        reconnect(resetBackoff = true)
    }

    fun stop() {
        if (!started) return
        started = false
        main.removeCallbacksAndMessages(null)
        runCatching { ctx.unregisterReceiver(systemReceiver) }
        stopAdvertising()
        closeGatt()
        setState(LinkState.IDLE, "已停止")
    }

    val bondedAddress: String? get() = prefs.getString(KEY_ADDRESS, null)

    /** 進入配對模式：開始廣播，等 iPhone 從藍牙設定連進來。逾時自動結束。 */
    fun startPairing() {
        val a = adapter ?: return
        if (!a.isEnabled) {
            setState(LinkState.IDLE, "藍牙未開啟")
            return
        }
        closeGatt()
        main.removeCallbacks(reconnectTask)
        if (server == null) server = btManager.openGattServer(ctx, serverCallback)
        val advertiser = a.bluetoothLeAdvertiser
        if (advertiser == null) {
            setState(LinkState.IDLE, "此裝置不支援廣播")
            return
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceSolicitationUuid(ParcelUuid(ANCS_SERVICE))
            .build()
        val scanResponse = AdvertiseData.Builder().setIncludeDeviceName(true).build()
        advertiser.startAdvertising(settings, data, scanResponse, advertiseCallback)
        advertising = true
        setState(LinkState.PAIRING, "請在 iPhone 的藍牙設定點選這支手錶")
        main.removeCallbacks(pairingTimeout)
        main.postDelayed(pairingTimeout, PAIRING_TIMEOUT_MS)
    }

    /** 清除綁定紀錄。系統層的配對要另外在手錶與 iPhone 的藍牙設定移除。 */
    fun forget() {
        prefs.edit().remove(KEY_ADDRESS).apply()
        closeGatt()
        main.removeCallbacks(reconnectTask)
        setState(LinkState.IDLE, "尚未配對")
    }

    /** 手動或由系統事件觸發：立刻重新嘗試連線。 */
    fun kick() {
        if (state == LinkState.READY || state == LinkState.PAIRING) return
        reconnect(resetBackoff = true)
    }

    fun performAction(uid: Long, positive: Boolean) {
        val cp = controlPoint ?: return
        enqueue(Op.Write(cp, Ancs.buildPerformAction(uid, positive)))
    }

    fun mediaCommand(command: Int) {
        val rc = amsRemote ?: return
        enqueue(Op.Write(rc, byteArrayOf(command.toByte())))
    }

    // ---------------------------------------------------------------- 狀態

    private fun setState(s: LinkState, detail: String) {
        if (s != state) stateSince = SystemClock.elapsedRealtime()
        state = s
        if (s == LinkState.READY) lastReadyAt = System.currentTimeMillis()
        Log.i(TAG, "state=$s $detail")
        listener.onState(s, detail)
    }

    private val reconnectTask = Runnable { connectBonded() }

    private fun reconnect(resetBackoff: Boolean) {
        if (!started) return
        if (resetBackoff) directAttempts = 0
        main.removeCallbacks(reconnectTask)
        main.post(reconnectTask)
    }

    private fun scheduleReconnect() {
        if (!started) return
        main.removeCallbacks(reconnectTask)
        if (directAttempts < MAX_DIRECT_ATTEMPTS) {
            val delay = (1000L shl directAttempts).coerceAtMost(60_000L)
            setState(LinkState.WAITING, "${delay / 1000} 秒後重試")
            main.postDelayed(reconnectTask, delay)
        } else {
            main.post(reconnectTask)
        }
    }

    private fun connectBonded() {
        val a = adapter
        val address = bondedAddress
        if (a == null || !a.isEnabled) {
            setState(LinkState.WAITING, "藍牙未開啟")
            return
        }
        if (address == null) {
            setState(LinkState.IDLE, "尚未配對")
            return
        }
        val device = runCatching { a.getRemoteDevice(address) }.getOrNull() ?: return
        if (device.bondState != BluetoothDevice.BOND_BONDED) {
            setState(LinkState.IDLE, "綁定已失效，請重新配對")
            return
        }
        closeGatt()
        val background = directAttempts >= MAX_DIRECT_ATTEMPTS
        directAttempts++
        setState(
            if (background) LinkState.WAITING else LinkState.CONNECTING,
            if (background) "等待 iPhone 回到範圍內" else "連線中（第 $directAttempts 次）",
        )
        gatt = device.connectGatt(ctx, background, gattCallback, BluetoothDevice.TRANSPORT_LE)
        if (!background) {
            main.removeCallbacks(connectTimeout)
            main.postDelayed(connectTimeout, CONNECT_TIMEOUT_MS)
        }
    }

    private val connectTimeout = Runnable {
        if (state == LinkState.CONNECTING) {
            closeGatt()
            scheduleReconnect()
        }
    }

    private val pairingTimeout = Runnable {
        if (state == LinkState.PAIRING) {
            stopAdvertising()
            setState(LinkState.IDLE, "配對逾時")
            if (bondedAddress != null) reconnect(resetBackoff = true)
        }
    }

    /** autoConnect 的背景連線偶爾會卡住不完成；等太久就整個拆掉重來。 */
    private val watchdog = object : Runnable {
        override fun run() {
            val waited = SystemClock.elapsedRealtime() - stateSince
            val stuck = when (state) {
                LinkState.WAITING -> directAttempts >= MAX_DIRECT_ATTEMPTS && waited > WAITING_LIMIT_MS
                LinkState.BONDING, LinkState.DISCOVERING -> waited > SETUP_LIMIT_MS
                else -> false
            }
            if (stuck && bondedAddress != null) {
                Log.w(TAG, "watchdog: $state for ${waited / 1000}s, restarting")
                closeGatt()
                reconnect(resetBackoff = false)
            }
            if (started) main.postDelayed(this, WATCHDOG_INTERVAL_MS)
        }
    }

    private fun closeGatt() {
        main.removeCallbacks(connectTimeout)
        gatt?.let {
            runCatching { it.disconnect() }
            runCatching { it.close() }
        }
        gatt = null
        controlPoint = null
        amsRemote = null
        ops.clear()
        opBusy = false
        assembler.reset()
        pendingEvents.clear()
    }

    private fun stopAdvertising() {
        main.removeCallbacks(pairingTimeout)
        if (advertising) {
            runCatching { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
            advertising = false
        }
    }

    // ---------------------------------------------------------------- 系統事件

    private val systemReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            when (intent.action) {
                BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                    val device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    val bond = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
                    if (device?.address != gatt?.device?.address) return
                    if (bond == BluetoothDevice.BOND_BONDED && state == LinkState.BONDING) {
                        prefs.edit().putString(KEY_ADDRESS, device?.address).apply()
                        beginDiscovery()
                    } else if (bond == BluetoothDevice.BOND_NONE && state == LinkState.BONDING) {
                        closeGatt()
                        setState(LinkState.IDLE, "配對被取消")
                    }
                }
                BluetoothAdapter.ACTION_STATE_CHANGED -> {
                    val s = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.STATE_OFF)
                    if (s == BluetoothAdapter.STATE_ON) reconnect(resetBackoff = true)
                    if (s == BluetoothAdapter.STATE_OFF) {
                        closeGatt()
                        advertising = false
                        server = null
                        setState(LinkState.WAITING, "藍牙未開啟")
                    }
                }
                Intent.ACTION_SCREEN_ON -> if (state == LinkState.WAITING) kick()
            }
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            main.post {
                advertising = false
                setState(LinkState.IDLE, "無法開始廣播（代碼 $errorCode）")
            }
        }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            main.post {
                if (newState == BluetoothProfile.STATE_CONNECTED && state == LinkState.PAIRING) {
                    stopAdvertising()
                    setState(LinkState.CONNECTING, "iPhone 已連入")
                    gatt = device.connectGatt(ctx, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
                }
            }
        }
    }

    // ---------------------------------------------------------------- GATT client

    private fun beginDiscovery() {
        val g = gatt ?: return
        discoverRetries = 0
        setState(LinkState.DISCOVERING, "探索服務")
        if (!g.requestMtu(REQUESTED_MTU)) g.discoverServices()
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (g !== gatt) return@post
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    main.removeCallbacks(connectTimeout)
                    if (g.device.bondState == BluetoothDevice.BOND_BONDED) {
                        prefs.edit().putString(KEY_ADDRESS, g.device.address).apply()
                        beginDiscovery()
                    } else {
                        setState(LinkState.BONDING, "請在兩邊確認配對")
                        if (g.device.bondState == BluetoothDevice.BOND_NONE) g.device.createBond()
                    }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    Log.w(TAG, "disconnected status=$status")
                    val wasReady = state == LinkState.READY
                    closeGatt()
                    if (wasReady) {
                        directAttempts = 0
                        listener.onSessionReset()
                    }
                    scheduleReconnect()
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            main.post { if (g === gatt) g.discoverServices() }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            main.post { if (g === gatt) onDiscovered(g) }
        }

        override fun onServiceChanged(g: BluetoothGatt) {
            main.post { if (g === gatt) g.discoverServices() }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            main.post { if (g === gatt) opDone() }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            main.post { if (g === gatt) opDone() }
        }

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            main.post {
                if (g !== gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) onValue(c.uuid, value)
                opDone()
            }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            main.post { if (g === gatt) onValue(c.uuid, value) }
        }
    }

    private fun onDiscovered(g: BluetoothGatt) {
        val ancs = g.getService(ANCS_SERVICE)
        if (ancs == null) {
            // ANCS 不保證隨時存在；等一下再探索，幾次都沒有就交給看門狗
            if (discoverRetries++ < MAX_DISCOVER_RETRIES) {
                main.postDelayed({ if (g === gatt) g.discoverServices() }, 3000)
            } else {
                setState(LinkState.DISCOVERING, "iPhone 尚未提供通知服務")
            }
            return
        }
        ops.clear()
        opBusy = false
        controlPoint = ancs.getCharacteristic(ANCS_CONTROL_POINT)
        ancs.getCharacteristic(ANCS_DATA_SOURCE)?.let { enqueue(Op.Notify(it)) }
        ancs.getCharacteristic(ANCS_NOTIFICATION_SOURCE)?.let { enqueue(Op.Notify(it)) }

        g.getService(BATTERY_SERVICE)?.getCharacteristic(BATTERY_LEVEL)?.let {
            enqueue(Op.Read(it))
            enqueue(Op.Notify(it))
        }
        g.getService(AMS_SERVICE)?.let { ams ->
            amsRemote = ams.getCharacteristic(AMS_REMOTE_COMMAND)
            ams.getCharacteristic(AMS_ENTITY_UPDATE)?.let { eu ->
                enqueue(Op.Notify(eu))
                enqueue(Op.Write(eu, Ams.buildSubscribe(Ams.ENTITY_TRACK, Ams.TRACK_ARTIST, Ams.TRACK_TITLE)))
                enqueue(Op.Write(eu, Ams.buildSubscribe(Ams.ENTITY_PLAYER, Ams.PLAYER_PLAYBACK_INFO)))
            }
        }
        directAttempts = 0
        setState(LinkState.READY, "已連線")
    }

    private fun onValue(uuid: UUID, value: ByteArray) {
        when (uuid) {
            ANCS_NOTIFICATION_SOURCE -> {
                val e = Ancs.parseEvent(value) ?: return
                if (e.eventId == Ancs.EVENT_REMOVED) {
                    pendingEvents.remove(e.uid)
                    listener.onNotificationRemoved(e.uid)
                } else {
                    val cp = controlPoint ?: return
                    pendingEvents[e.uid] = e
                    enqueue(Op.Write(cp, Ancs.buildGetAttributes(e.uid)))
                }
            }
            ANCS_DATA_SOURCE -> {
                var attrs = assembler.feed(value)
                while (attrs != null) {
                    pendingEvents.remove(attrs.uid)?.let { listener.onNotification(it, attrs!!) }
                    attrs = assembler.feed(ByteArray(0))
                }
            }
            BATTERY_LEVEL -> if (value.isNotEmpty()) listener.onBattery(value[0].toInt() and 0xFF)
            AMS_ENTITY_UPDATE -> Ams.parseUpdate(value)?.let { listener.onMedia(it) }
        }
    }

    // ---------------------------------------------------------------- 操作佇列（GATT 一次只能做一件事）

    private fun enqueue(op: Op) {
        ops.add(op)
        pump()
    }

    private fun opDone() {
        main.removeCallbacks(opTimeout)
        opBusy = false
        pump()
    }

    private val opTimeout = Runnable {
        Log.w(TAG, "gatt operation timed out")
        opBusy = false
        pump()
    }

    private fun pump() {
        val g = gatt ?: return
        while (!opBusy) {
            val op = ops.poll() ?: return
            val ok = when (op) {
                is Op.Notify -> {
                    g.setCharacteristicNotification(op.ch, true)
                    val d = op.ch.getDescriptor(CCCD)
                    d != null && g.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothGatt.GATT_SUCCESS
                }
                is Op.Write -> g.writeCharacteristic(
                    op.ch, op.value, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothGatt.GATT_SUCCESS
                is Op.Read -> g.readCharacteristic(op.ch)
            }
            if (ok) {
                opBusy = true
                main.postDelayed(opTimeout, OP_TIMEOUT_MS)
            }
        }
    }

    companion object {
        private const val TAG = "Watch7Bridge"
        private const val KEY_ADDRESS = "bonded_address"
        private const val MAX_DIRECT_ATTEMPTS = 8
        private const val MAX_DISCOVER_RETRIES = 3
        private const val REQUESTED_MTU = 247
        private const val CONNECT_TIMEOUT_MS = 15_000L
        private const val PAIRING_TIMEOUT_MS = 120_000L
        private const val WATCHDOG_INTERVAL_MS = 60_000L
        private const val WAITING_LIMIT_MS = 120_000L
        private const val SETUP_LIMIT_MS = 90_000L
        private const val OP_TIMEOUT_MS = 5_000L

        val ANCS_SERVICE: UUID = UUID.fromString("7905F431-B5CE-4E99-A40F-4B1E122D00D0")
        val ANCS_NOTIFICATION_SOURCE: UUID = UUID.fromString("9FBF120D-6301-42D9-8C58-25E699A21DBD")
        val ANCS_CONTROL_POINT: UUID = UUID.fromString("69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9")
        val ANCS_DATA_SOURCE: UUID = UUID.fromString("22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB")
        val AMS_SERVICE: UUID = UUID.fromString("89D3502B-0F36-433A-8EF4-C502AD55F8DC")
        val AMS_REMOTE_COMMAND: UUID = UUID.fromString("9B3C81D8-57B1-4A8A-B8DF-0E56F7CA51C2")
        val AMS_ENTITY_UPDATE: UUID = UUID.fromString("2F7CABCE-808D-411F-9A0C-BB92BA96C102")
        val BATTERY_SERVICE: UUID = UUID.fromString("0000180F-0000-1000-8000-00805F9B34FB")
        val BATTERY_LEVEL: UUID = UUID.fromString("00002A19-0000-1000-8000-00805F9B34FB")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
    }
}
