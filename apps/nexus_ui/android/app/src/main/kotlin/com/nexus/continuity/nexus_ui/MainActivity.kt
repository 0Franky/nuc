package com.nexus.continuity.nexus_ui

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
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
import android.os.Handler
import android.os.Looper
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

    private var targetPeerMac: String = "40:9F:38:A6:80:DE"
    private var targetPeerName: String = "FRANKY"
    private var bluetoothGatt: BluetoothGatt? = null
    private var isDiscoveryReceiverRegistered = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var gattPollRunnable: Runnable? = null
    private var discoveryLoopRunnable: Runnable? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                "setTargetPeerBluetooth" -> {
                    val mac = call.argument<String>("mac")
                    val name = call.argument<String>("name")
                    if (!mac.isNullOrEmpty()) targetPeerMac = mac
                    if (!name.isNullOrEmpty()) targetPeerName = name
                    Log.d(TAG, "Updated target peer Bluetooth: MAC=$targetPeerMac, Name=$targetPeerName")
                    result.success(true)
                }
                "startBleProximity" -> {
                    try {
                        startBleProximityMonitoring()
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "startBleProximity error", e)
                        result.success(false)
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

    private val discoveryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (BluetoothDevice.ACTION_FOUND == intent?.action) {
                val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                }
                val rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE).toInt()
                if (device != null && rssi != Short.MIN_VALUE.toInt()) {
                    val addr = device.address ?: ""
                    val name = device.name ?: ""
                    val isTarget = addr.equals(targetPeerMac, ignoreCase = true) ||
                                  name.contains(targetPeerName, ignoreCase = true) ||
                                  name.contains("Nexus", ignoreCase = true)

                    Log.d(TAG, "ACTION_FOUND: addr=$addr, name='$name', rssi=$rssi dBm, isTarget=$isTarget")
                    if (isTarget || (targetPeerMac.isEmpty() && rssi > -80)) {
                        sendRssiSampleToFlutter(rssi, true, name, addr)
                    }
                }
            }
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt?, status: Int, newState: Int) {
            super.onConnectionStateChange(gatt, status, newState)
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                Log.d(TAG, "GATT connected to PC ${gatt?.device?.address}")
                startGattRssiPolling()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                Log.d(TAG, "GATT disconnected from PC")
                stopGattRssiPolling()
            }
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt?, rssi: Int, status: Int) {
            super.onReadRemoteRssi(gatt, rssi, status)
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.d(TAG, "GATT live RSSI sample: $rssi dBm")
                sendRssiSampleToFlutter(rssi, true, gatt?.device?.name ?: targetPeerName, gatt?.device?.address ?: targetPeerMac)
            }
        }
    }

    private fun sendRssiSampleToFlutter(rssi: Int, isNexus: Boolean, name: String, address: String) {
        runOnUiThread {
            methodChannel?.invokeMethod("onBleRssiSample", mapOf(
                "rssi" to rssi,
                "is_nexus" to isNexus,
                "name" to name,
                "address" to address
            ))
        }
    }

    private fun startGattRssiPolling() {
        stopGattRssiPolling()
        gattPollRunnable = object : Runnable {
            override fun run() {
                try {
                    bluetoothGatt?.readRemoteRssi()
                } catch (e: Exception) {
                    Log.e(TAG, "readRemoteRssi exception", e)
                }
                mainHandler.postDelayed(this, 1000)
            }
        }
        mainHandler.post(gattPollRunnable!!)
    }

    private fun stopGattRssiPolling() {
        gattPollRunnable?.let { mainHandler.removeCallbacks(it) }
        gattPollRunnable = null
    }

    private fun startBleProximityMonitoring() {
        if (isBleProximityActive) return
        try {
            val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val adapter = bluetoothManager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
            if (adapter == null || !adapter.isEnabled) {
                Log.w(TAG, "Bluetooth adapter not available or disabled")
                return
            }

            val parcelUuid = ParcelUuid(NEXUS_SERVICE_UUID)

            // 0. Request BLE & Location permissions if needed
            val missingPerms = mutableListOf<String>()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (checkSelfPermission(android.Manifest.permission.BLUETOOTH_ADVERTISE) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    missingPerms.add(android.Manifest.permission.BLUETOOTH_ADVERTISE)
                }
                if (checkSelfPermission(android.Manifest.permission.BLUETOOTH_SCAN) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    missingPerms.add(android.Manifest.permission.BLUETOOTH_SCAN)
                }
                if (checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    missingPerms.add(android.Manifest.permission.BLUETOOTH_CONNECT)
                }
            }
            if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                missingPerms.add(android.Manifest.permission.ACCESS_FINE_LOCATION)
                missingPerms.add(android.Manifest.permission.ACCESS_COARSE_LOCATION)
            }
            if (missingPerms.isNotEmpty()) {
                Log.w(TAG, "Requesting missing runtime permissions: $missingPerms")
                requestPermissions(missingPerms.toTypedArray(), 1001)
            }

            // 1. Start BLE Advertiser (isolated try-catch)
            try {
                val canAdv = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || checkSelfPermission(android.Manifest.permission.BLUETOOTH_ADVERTISE) == android.content.pm.PackageManager.PERMISSION_GRANTED
                if (canAdv) {
                    bleAdvertiser = adapter.bluetoothLeAdvertiser
                    if (bleAdvertiser != null) {
                        val advSettings = AdvertiseSettings.Builder()
                            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                            .setConnectable(false)
                            .setTimeout(0)
                            .build()

                        val advData = AdvertiseData.Builder()
                            .addServiceUuid(parcelUuid)
                            .setIncludeDeviceName(false)
                            .build()

                        advertiseCallback = object : AdvertiseCallback() {
                            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                                super.onStartSuccess(settingsInEffect)
                                Log.d(TAG, "BLE Advertiser started successfully")
                            }
                            override fun onStartFailure(errorCode: Int) {
                                super.onStartFailure(errorCode)
                                Log.w(TAG, "BLE Advertiser failed: $errorCode")
                            }
                        }
                        bleAdvertiser?.startAdvertising(advSettings, advData, advertiseCallback)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "BLE Advertiser startup error (continuing with scanner and discovery): $e")
            }

            // 2. Start BLE Scanner (isolated try-catch)
            try {
                val canScan = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || checkSelfPermission(android.Manifest.permission.BLUETOOTH_SCAN) == android.content.pm.PackageManager.PERMISSION_GRANTED
                if (canScan) {
                    bleScanner = adapter.bluetoothLeScanner
                    if (bleScanner != null) {
                        val scanSettings = ScanSettings.Builder()
                            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                            .setReportDelay(0)
                            .build()

                        scanCallback = object : ScanCallback() {
                            override fun onScanResult(callbackType: Int, result: ScanResult?) {
                                super.onScanResult(callbackType, result)
                                if (result != null) {
                                    val uuids = result.scanRecord?.serviceUuids
                                    val name = result.device?.name ?: ""
                                    val addr = result.device?.address ?: ""
                                    val isTarget = addr.equals(targetPeerMac, ignoreCase = true) ||
                                                  name.contains(targetPeerName, ignoreCase = true) ||
                                                  name.contains("Nexus", ignoreCase = true) ||
                                                  uuids?.contains(parcelUuid) == true

                                    if (isTarget || result.rssi > -80) {
                                        Log.d(TAG, "BLE Scan Result: addr=$addr, name='$name', rssi=${result.rssi}")
                                        sendRssiSampleToFlutter(result.rssi, isTarget, name, addr)
                                    }
                                }
                            }

                            override fun onBatchScanResults(results: MutableList<ScanResult>?) {
                                super.onBatchScanResults(results)
                                val best = results?.maxByOrNull { it.rssi }
                                if (best != null) {
                                    val name = best.device?.name ?: ""
                                    val addr = best.device?.address ?: ""
                                    val isTarget = addr.equals(targetPeerMac, ignoreCase = true) ||
                                                  name.contains(targetPeerName, ignoreCase = true)
                                    sendRssiSampleToFlutter(best.rssi, isTarget, name, addr)
                                }
                            }

                            override fun onScanFailed(errorCode: Int) {
                                super.onScanFailed(errorCode)
                                Log.w(TAG, "BLE Scanner failed: $errorCode")
                            }
                        }

                        bleScanner?.startScan(null, scanSettings, scanCallback)
                        Log.d(TAG, "BLE Scanner started")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "BLE Scanner startup error: $e")
            }

            // 3. Register Classic Discovery for paired PC (Franky)
            try {
                if (!isDiscoveryReceiverRegistered) {
                    val filter = IntentFilter(BluetoothDevice.ACTION_FOUND)
                    registerReceiver(discoveryReceiver, filter)
                    isDiscoveryReceiverRegistered = true
                }

                discoveryLoopRunnable = object : Runnable {
                    override fun run() {
                        try {
                            if (adapter.isDiscovering) {
                                adapter.cancelDiscovery()
                            }
                            adapter.startDiscovery()
                        } catch (e: Exception) {
                            Log.e(TAG, "startDiscovery error", e)
                        }
                        mainHandler.postDelayed(this, 8000)
                    }
                }
                mainHandler.post(discoveryLoopRunnable!!)
            } catch (e: Exception) {
                Log.w(TAG, "Discovery startup error: $e")
            }

            // 4. Connect GATT to Franky (40:9F:38:A6:80:DE) if available
            try {
                val targetDevice = adapter.getRemoteDevice(targetPeerMac)
                Log.d(TAG, "Initiating GATT connection to target device $targetPeerMac...")
                bluetoothGatt = targetDevice.connectGatt(this, false, gattCallback, BluetoothDevice.TRANSPORT_AUTO)
            } catch (e: Exception) {
                Log.e(TAG, "GATT connect exception", e)
            }

            isBleProximityActive = true
            Log.i(TAG, "startBleProximityMonitoring initialized successfully")
        } catch (e: Exception) {
            Log.e(TAG, "startBleProximityMonitoring failed", e)
            isBleProximityActive = false
        }
    }

    private fun stopBleProximityMonitoring() {
        try {
            stopGattRssiPolling()
            discoveryLoopRunnable?.let { mainHandler.removeCallbacks(it) }
            discoveryLoopRunnable = null

            if (isDiscoveryReceiverRegistered) {
                try {
                    unregisterReceiver(discoveryReceiver)
                } catch (_: Exception) {}
                isDiscoveryReceiverRegistered = false
            }

            val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val adapter = bluetoothManager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
            if (adapter?.isDiscovering == true) {
                adapter.cancelDiscovery()
            }

            if (advertiseCallback != null && bleAdvertiser != null) {
                bleAdvertiser?.stopAdvertising(advertiseCallback)
            }
            if (scanCallback != null && bleScanner != null) {
                bleScanner?.stopScan(scanCallback)
            }
            bluetoothGatt?.disconnect()
            bluetoothGatt?.close()
            bluetoothGatt = null
        } catch (_: Exception) {}
        isBleProximityActive = false
        advertiseCallback = null
        scanCallback = null
        Log.i(TAG, "stopBleProximityMonitoring completed")
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1001) {
            Log.d(TAG, "Runtime permissions result received. Restarting BLE proximity monitoring...")
            mainHandler.postDelayed({
                stopBleProximityMonitoring()
                startBleProximityMonitoring()
            }, 600)
        }
    }

    override fun onDestroy() {
        stopBleProximityMonitoring()
        super.onDestroy()
    }
}
