package com.erebrus.drop

import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private val channelName = "com.erebrus.drop/network"
    private val pickUploadFileRequest = 7317
    private val pickHostFolderRequest = 7318
    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingHostFolderResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler {
            call,
            result ->
            when (call.method) {
                "getDeviceName" -> result.success(deviceName())
                "getLocalIpAddresses" -> result.success(getLocalIpAddresses())
                "getStorageStats" -> result.success(getStorageStats())
                "isLocalOnlyHotspotSupported" -> result.success(
                    mapOf(
                        "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O),
                        "reason" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            "Android can attempt a local-only hotspot. OEM policy may still deny it."
                        } else {
                            "Android 8.0 or newer is required for app-created local-only hotspots."
                        }
                    )
                )
                "startLocalOnlyHotspot" -> startLocalOnlyHotspot(result)
                "stopLocalOnlyHotspot" -> {
                    hotspotReservation?.close()
                    hotspotReservation = null
                    result.success(mapOf("stopped" to true))
                }
                "pickFileForUpload" -> pickFileForUpload(result)
                "pickFilesForUpload" -> pickFileForUpload(result)
                "selectHostFolder" -> selectHostFolder(result)
                "startRoomForegroundService" -> {
                    startRoomForegroundService(
                        call.argument<String>("roomName") ?: "Drop Room",
                        call.argument<String>("baseUrl") ?: "Local network"
                    )
                    result.success(mapOf("started" to true))
                }
                "stopRoomForegroundService" -> {
                    stopService(Intent(this, DropRoomForegroundService::class.java))
                    result.success(mapOf("stopped" to true))
                }
                "moveAppToBackground" -> {
                    moveTaskToBack(true)
                    result.success(mapOf("backgrounded" to true))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == pickHostFolderRequest) {
            handleHostFolderResult(resultCode, data)
            return
        }
        if (requestCode != pickUploadFileRequest) return

        val result = pendingPickResult
        pendingPickResult = null
        if (result == null) return

        if (resultCode != RESULT_OK || data == null) {
            result.success(null)
            return
        }

        try {
            val uris = mutableListOf<Uri>()
            val clipData = data.clipData
            if (clipData != null) {
                for (index in 0 until clipData.itemCount) {
                    uris.add(clipData.getItemAt(index).uri)
                }
            } else {
                data.data?.let { uris.add(it) }
            }
            if (uris.isEmpty()) {
                result.success(null)
                return
            }
            result.success(uris.map { copyPickedFile(it) })
        } catch (error: Exception) {
            result.error("PICK_FILE_FAILED", error.message, null)
        }
    }

    private fun getLocalIpAddresses(): List<String> {
        return NetworkInterface.getNetworkInterfaces().toList()
            .flatMap { it.inetAddresses.toList() }
            .filter { !it.isLoopbackAddress && it.hostAddress?.contains(":") == false }
            .mapNotNull { it.hostAddress }
    }

    private fun deviceName(): String {
        val manufacturer = Build.MANUFACTURER.orEmpty().trim()
        val model = Build.MODEL.orEmpty().trim()
        if (model.isNotEmpty() && manufacturer.isNotEmpty()) {
            return if (model.startsWith(manufacturer, ignoreCase = true)) {
                model
            } else {
                "$manufacturer $model"
            }
        }
        if (model.isNotEmpty()) return model
        if (manufacturer.isNotEmpty()) return manufacturer
        return Build.DEVICE.orEmpty().ifEmpty { "Android device" }
    }

    private fun getStorageStats(): Map<String, Long> {
        val stat = StatFs(Environment.getDataDirectory().path)
        return mapOf(
            "availableBytes" to stat.availableBytes,
            "totalBytes" to stat.totalBytes
        )
    }

    private fun pickFileForUpload(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("PICK_IN_PROGRESS", "A file picker is already open.", null)
            return
        }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        try {
            startActivityForResult(intent, pickUploadFileRequest)
        } catch (error: Exception) {
            pendingPickResult = null
            result.error("PICK_FILE_UNAVAILABLE", error.message, null)
        }
    }

    private fun selectHostFolder(result: MethodChannel.Result) {
        if (pendingHostFolderResult != null) {
            result.error("PICK_IN_PROGRESS", "A folder picker is already open.", null)
            return
        }
        pendingHostFolderResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, pickHostFolderRequest)
        } catch (error: Exception) {
            pendingHostFolderResult = null
            result.error("PICK_FOLDER_UNAVAILABLE", error.message, null)
        }
    }

    private fun startRoomForegroundService(roomName: String, baseUrl: String) {
        val intent = Intent(this, DropRoomForegroundService::class.java).apply {
            putExtra("roomName", roomName)
            putExtra("baseUrl", baseUrl)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun handleHostFolderResult(resultCode: Int, data: Intent?) {
        val result = pendingHostFolderResult
        pendingHostFolderResult = null
        if (result == null) return
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val flags = data.flags and (
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            contentResolver.takePersistableUriPermission(uri, flags)
            result.success(
                mapOf(
                    "uri" to uri.toString(),
                    "name" to folderDisplayName(uri),
                    "platform" to "Android SAF"
                )
            )
        } catch (error: Exception) {
            result.error("PICK_FOLDER_FAILED", error.message, null)
        }
    }

    private fun copyPickedFile(uri: Uri): Map<String, Any?> {
        val name = displayName(uri)
        val targetDirectory = File(cacheDir, "picked_uploads").apply { mkdirs() }
        val target = uniqueFile(targetDirectory, safeName(name))
        contentResolver.openInputStream(uri).use { input ->
            if (input == null) throw IllegalStateException("Could not open selected file.")
            FileOutputStream(target).use { output -> input.copyTo(output) }
        }
        return mapOf(
            "path" to target.absolutePath,
            "name" to name,
            "sizeBytes" to target.length()
        )
    }

    private fun displayName(uri: Uri): String {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(uri, null, null, null, null)
            val nameIndex = cursor?.getColumnIndex(OpenableColumns.DISPLAY_NAME) ?: -1
            if (cursor != null && cursor.moveToFirst() && nameIndex >= 0) {
                cursor.getString(nameIndex) ?: "upload"
            } else {
                uri.lastPathSegment ?: "upload"
            }
        } finally {
            cursor?.close()
        }
    }

    private fun folderDisplayName(uri: Uri): String {
        val lastSegment = uri.lastPathSegment ?: return "Selected folder"
        return lastSegment.substringAfterLast(":").ifEmpty { "Selected folder" }
    }

    private fun safeName(name: String): String {
        return name.replace(Regex("[\\\\/:*?\"<>|]"), "-").trim().ifEmpty { "upload" }
    }

    private fun uniqueFile(directory: File, name: String): File {
        val base = name.substringBeforeLast('.', name)
        val extension = name.substringAfterLast('.', "")
        var candidate = File(directory, name)
        var index = 1
        while (candidate.exists()) {
            val nextName = if (extension.isEmpty()) {
                "$base-$index"
            } else {
                "$base-$index.$extension"
            }
            candidate = File(directory, nextName)
            index++
        }
        return candidate
    }

    private fun startLocalOnlyHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(
                mapOf(
                    "supported" to false,
                    "started" to false,
                    "reason" to "Android 8.0 or newer is required for app-created local-only hotspots."
                )
            )
            return
        }

        val existing = hotspotReservation
        if (existing != null) {
            result.success(hotspotResult(existing))
            return
        }

        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        try {
            wifiManager.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        hotspotReservation = reservation
                        result.success(hotspotResult(reservation))
                    }

                    override fun onStopped() {
                        hotspotReservation = null
                    }

                    override fun onFailed(reason: Int) {
                        hotspotReservation = null
                        result.success(
                            mapOf(
                                "supported" to true,
                                "started" to false,
                                "reason" to hotspotFailureReason(reason)
                            )
                        )
                    }
                },
                Handler(Looper.getMainLooper())
            )
        } catch (error: SecurityException) {
            result.success(
                mapOf(
                    "supported" to true,
                    "started" to false,
                    "reason" to "Android denied hotspot control. Check Nearby Wi-Fi/location permissions and OEM restrictions."
                )
            )
        } catch (error: Exception) {
            result.success(
                mapOf(
                    "supported" to true,
                    "started" to false,
                    "reason" to (error.message ?: "This device did not allow local-only hotspot creation.")
                )
            )
        }
    }

    private fun hotspotResult(reservation: WifiManager.LocalOnlyHotspotReservation): Map<String, Any?> {
        val config = reservation.wifiConfiguration
        return mapOf(
            "supported" to true,
            "started" to true,
            "ssid" to config?.SSID?.trim('"'),
            "passphrase" to config?.preSharedKey?.trim('"'),
            "gatewayIp" to "192.168.43.1"
        )
    }

    private fun hotspotFailureReason(reason: Int): String {
        return when (reason) {
            WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL ->
                "Android could not find an available Wi-Fi channel for the hotspot."
            WifiManager.LocalOnlyHotspotCallback.ERROR_GENERIC ->
                "Android or the device OEM refused to create a local-only hotspot."
            WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE ->
                "The device is in a Wi-Fi mode that cannot create a local-only hotspot right now."
            WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED ->
                "Tethering/local hotspot is disabled by device policy or carrier/OEM settings."
            else -> "Android refused to create a local-only hotspot. Reason code: $reason"
        }
    }
}
