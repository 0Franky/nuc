package com.nexus.continuity.nexus_ui

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.ParcelUuid
import android.provider.Settings
import android.util.Log
import androidx.annotation.NonNull
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val TAG = "NexusBLE"
    private val CHANNEL = "com.nexus.continuity/hardware"
    private val NOTIF_CHANNEL_ID = "nexus_continuity_media"
    private val NEXUS_SERVICE_UUID = UUID.fromString("00002847-0000-1000-8000-00805f9b34fb")

    private var methodChannel: MethodChannel? = null
    private var bleAdvertiser: BluetoothLeAdvertiser? = null
    private var bleScanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var isBleProximityActive = false

    private var localBlePeerId: UUID? = null
    private var bleProximityRequested = false

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        android.system.Os.setenv("NEXUS_CONFIG_DIR", filesDir.resolve("nexus").absolutePath, true)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isBluetoothEnabled" -> {
                    try {
                        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
                        val adapter = bluetoothManager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
                        val isEnabled = adapter != null && adapter.isEnabled
                        result.success(isEnabled)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "openBluetoothSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
                        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "showSystemNotification" -> {
                    try {
                        val title = call.argument<String>("title") ?: "Continua la riproduzione?"
                        val body = call.argument<String>("body") ?: "Vuoi continuare la riproduzione qui?"
                        val url = call.argument<String>("url") ?: ""
                        showNotification(title, body, url)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "showMediaRemoteNotification" -> {
                    try {
                        val title = call.argument<String>("title") ?: "PC Media"
                        val sourceApp = call.argument<String>("source_app") ?: "Browser"
                        val isPlaying = call.argument<Boolean>("is_playing") ?: true
                        val posMs = (call.argument<Number>("position_ms"))?.toLong() ?: 0L
                        val durMs = (call.argument<Number>("duration_ms"))?.toLong() ?: 0L
                        showMediaRemoteNotification(title, sourceApp, isPlaying, posMs, durMs)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "clearMediaRemoteNotification" -> {
                    try {
                        clearMediaRemoteNotification()
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "startBleProximity" -> {
                    val rawId = call.argument<String>("device_id")
                    val id = try { UUID.fromString(rawId) } catch (_: Exception) { null }
                    if (id == null || !id.toString().equals(rawId, ignoreCase = true) ||
                        (id.mostSignificantBits == 0L && id.leastSignificantBits == 0L)) {
                        result.error("invalid_device_id", "A stable Nexus UUID is required", null)
                    } else {
                        if (localBlePeerId != id) stopBleProximityMonitoring()
                        localBlePeerId = id
                        bleProximityRequested = true
                        result.success(startBleProximityMonitoring())
                    }
                }
                "stopBleProximity" -> {
                    try {
                        stopBleProximityMonitoring()
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private val NOTIF_ID_WALKAWAY = 1001
    private val NOTIF_ID_HANDOFF = 1002
    private val NOTIF_ID_RETURN = 1003
    private val NOTIF_ID_MEDIA_REMOTE = 2001

    private val ACTION_MEDIA_PLAY_PAUSE = "com.nexus.continuity.ACTION_MEDIA_PLAY_PAUSE"
    private val ACTION_MEDIA_PREV = "com.nexus.continuity.ACTION_MEDIA_PREV"
    private val ACTION_MEDIA_NEXT = "com.nexus.continuity.ACTION_MEDIA_NEXT"

    private val mediaActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_MEDIA_PLAY_PAUSE -> {
                    Log.d(TAG, "Media action: PLAY_PAUSE received from lockscreen notification")
                    methodChannel?.invokeMethod("onRemoteMediaAction", "TOGGLE_PLAY_PAUSE")
                }
                ACTION_MEDIA_PREV -> {
                    Log.d(TAG, "Media action: PREV received from lockscreen notification")
                    methodChannel?.invokeMethod("onRemoteMediaAction", "PREV")
                }
                ACTION_MEDIA_NEXT -> {
                    Log.d(TAG, "Media action: NEXT received from lockscreen notification")
                    methodChannel?.invokeMethod("onRemoteMediaAction", "NEXT")
                }
            }
        }
    }
    private var isMediaReceiverRegistered = false

    private fun showNotification(title: String, body: String, url: String) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIF_CHANNEL_ID,
                "Nexus Continuity & Proximity",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifiche di prossimità BLE, allontanamento e handoff video"
                enableVibration(true)
                setShowBadge(true)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            }
            notificationManager.createNotificationChannel(channel)
        }

        val intent = if (url.isNotEmpty()) {
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        } else {
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            System.currentTimeMillis().toInt(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        )

        val iconRes = applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.stat_notify_more

        val builder = NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setSmallIcon(iconRes)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)

        if (url.isNotEmpty()) {
            builder.addAction(android.R.drawable.ic_media_play, "Riproduci Ora", pendingIntent)
        }

        val notifId = if (title.contains("Allontanamento", ignoreCase = true)) {
            NOTIF_ID_WALKAWAY
        } else if (title.contains("Bentornato", ignoreCase = true)) {
            NOTIF_ID_RETURN
        } else {
            NOTIF_ID_HANDOFF
        }

        Log.i(TAG, "Dispatched system notification: ID=$notifId, title='$title', url='$url', enabled=${notificationManager.areNotificationsEnabled()}")
        notificationManager.notify(notifId, builder.build())
    }

    private fun showMediaRemoteNotification(
        title: String,
        sourceApp: String,
        isPlaying: Boolean,
        positionMs: Long,
        durationMs: Long
    ) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "nexus_media_remote_v2",
                "Nexus PC Media Remote Control",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Controlli multimediali remoti del PC su schermata di blocco"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            }
            notificationManager.createNotificationChannel(channel)
        }

        if (!isMediaReceiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(ACTION_MEDIA_PLAY_PAUSE)
                addAction(ACTION_MEDIA_PREV)
                addAction(ACTION_MEDIA_NEXT)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(mediaActionReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(mediaActionReceiver, filter)
            }
            isMediaReceiverRegistered = true
        }

        val playPauseIntent = Intent(ACTION_MEDIA_PLAY_PAUSE).apply {
            `package` = packageName
        }
        val playPausePendingIntent = PendingIntent.getBroadcast(
            this,
            101,
            playPauseIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val prevIntent = Intent(ACTION_MEDIA_PREV).apply {
            `package` = packageName
        }
        val prevPendingIntent = PendingIntent.getBroadcast(
            this,
            102,
            prevIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val nextIntent = Intent(ACTION_MEDIA_NEXT).apply {
            `package` = packageName
        }
        val nextPendingIntent = PendingIntent.getBroadcast(
            this,
            103,
            nextIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val contentIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            100,
            contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val playIcon = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val playLabel = if (isPlaying) "Pausa" else "Play"

        val posSec = positionMs / 1000
        val durSec = durationMs / 1000
        val posFormatted = String.format("%02d:%02d", posSec / 60, posSec % 60)
        val durFormatted = if (durSec > 0) String.format("%02d:%02d", durSec / 60, durSec % 60) else "--:--"
        val subtext = "💻 $sourceApp • $posFormatted / $durFormatted"

        val iconRes = applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.stat_notify_more

        val builder = NotificationCompat.Builder(this, "nexus_media_remote_v2")
            .setSmallIcon(iconRes)
            .setContentTitle(title)
            .setContentText(subtext)
            .setSubText("Controllo Remoto PC")
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(isPlaying)
            .setSilent(true)
            .setAutoCancel(false)
            .setContentIntent(contentPendingIntent)
            .addAction(android.R.drawable.ic_media_previous, "Riavvia", prevPendingIntent)
            .addAction(playIcon, playLabel, playPausePendingIntent)
            .addAction(android.R.drawable.ic_media_next, "Prossimo", nextPendingIntent)
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setShowActionsInCompactView(0, 1, 2)
            )

        if (durationMs > 0) {
            builder.setProgress(durationMs.toInt(), positionMs.toInt(), false)
        }

        notificationManager.notify(NOTIF_ID_MEDIA_REMOTE, builder.build())
        Log.d(TAG, "showMediaRemoteNotification: title='$title', isPlaying=$isPlaying, pos=$positionMs/$durationMs")
    }

    private fun clearMediaRemoteNotification() {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(NOTIF_ID_MEDIA_REMOTE)
    }

    // Version 1 service data carries the same UUID used by LAN discovery.
    // Never associate devices by a Bluetooth address, friendly name, or signal strength.
    private fun handleBleScanResult(result: ScanResult) {
        if (!bleProximityRequested || result.rssi !in -127..-1) return
        val record = result.scanRecord ?: return
        val payload = record.getServiceData(ParcelUuid(NEXUS_SERVICE_UUID)) ?: return
        val peerId = BlePeerIdentity.decode(payload) ?: return
        if (peerId == localBlePeerId) return
        runOnUiThread {
            if (bleProximityRequested) {
                methodChannel?.invokeMethod("onBleRssiSample", mapOf(
                    "rssi" to result.rssi,
                    "is_nexus" to true,
                    "peer_id" to peerId.toString()
                ))
            }
        }
    }

    private fun startBleProximityMonitoring(): Boolean {
        if (isBleProximityActive) return true
        val localId = localBlePeerId ?: return false
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = manager?.adapter ?: return false
        val missing = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            missing.addAll(listOf(
                android.Manifest.permission.BLUETOOTH_ADVERTISE,
                android.Manifest.permission.BLUETOOTH_SCAN,
                android.Manifest.permission.BLUETOOTH_CONNECT
            ))
        }
        // Proximity derives physical location, so do not declare neverForLocation.
        missing.add(android.Manifest.permission.ACCESS_FINE_LOCATION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            missing.add(android.Manifest.permission.ACCESS_COARSE_LOCATION)
        }
        missing.removeAll { checkSelfPermission(it) == android.content.pm.PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) {
            requestPermissions(missing.toTypedArray(), 1001)
            return false
        }
        releaseBleResources()
        try {
            if (!adapter.isEnabled) return false
            val serviceId = ParcelUuid(NEXUS_SERVICE_UUID)
            bleAdvertiser = adapter.bluetoothLeAdvertiser
            if (bleAdvertiser != null) {
                val identity = BlePeerIdentity.encode(localId)
                val settings = AdvertiseSettings.Builder()
                    .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                    .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                    .setConnectable(false).setTimeout(0).build()
                // This service is a 16-bit Bluetooth UUID: the legacy payload fits in 31 bytes.
                val data = AdvertiseData.Builder().addServiceUuid(serviceId)
                    .addServiceData(serviceId, identity).setIncludeDeviceName(false).build()
                advertiseCallback = object : AdvertiseCallback() {
                    override fun onStartFailure(errorCode: Int) {
                        Log.w(TAG, "BLE advertiser unavailable: $errorCode")
                    }
                }
                bleAdvertiser?.startAdvertising(settings, data, advertiseCallback)
            }
            bleScanner = adapter.bluetoothLeScanner
            if (bleScanner == null) {
                Log.w(TAG, "BLE scanner unavailable")
                releaseBleResources()
                return false
            }
            scanCallback = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, result: ScanResult?) {
                    if (scanCallback === this) result?.let { handleBleScanResult(it) }
                }
                override fun onBatchScanResults(results: MutableList<ScanResult>?) {
                    if (scanCallback === this) results?.forEach { handleBleScanResult(it) }
                }
                override fun onScanFailed(errorCode: Int) {
                    if (scanCallback !== this) return
                    releaseBleResources()
                    Log.w(TAG, "BLE scanner failed: $errorCode")
                }
            }
            val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .setReportDelay(0).build()
            bleScanner?.startScan(null, settings, scanCallback)
            isBleProximityActive = true
            return true
        } catch (e: Exception) {
            Log.w(TAG, "BLE proximity startup failed", e)
            releaseBleResources()
            return false
        }
    }

    private fun stopBleProximityMonitoring() {
        bleProximityRequested = false
        releaseBleResources()
    }

    private fun releaseBleResources() {
        try { advertiseCallback?.let { bleAdvertiser?.stopAdvertising(it) } }
        catch (e: Exception) { Log.w(TAG, "BLE advertiser stop failed", e) }
        try { scanCallback?.let { bleScanner?.stopScan(it) } }
        catch (e: Exception) { Log.w(TAG, "BLE scanner stop failed", e) }
        isBleProximityActive = false
        advertiseCallback = null
        scanCallback = null
        bleAdvertiser = null
        bleScanner = null
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1001 && bleProximityRequested && grantResults.isNotEmpty() &&
            grantResults.all { it == android.content.pm.PackageManager.PERMISSION_GRANTED }) {
            startBleProximityMonitoring()
        }
    }

    override fun onDestroy() {
        stopBleProximityMonitoring()
        super.onDestroy()
    }
}
