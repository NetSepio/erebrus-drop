package com.erebrus.drop

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private val channelName = "com.erebrus.drop/network"
    private val pickUploadFileRequest = 7317
    private val pickHostFolderRequest = 7318
    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingHostFolderResult: MethodChannel.Result? = null
    private var nsdManager: NsdManager? = null
    private var nsdRegistrationListener: NsdManager.RegistrationListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    private data class HostDocument(
        val uri: Uri,
        val documentId: String,
        val name: String,
        val mimeType: String?,
        val sizeBytes: Long,
        val modifiedAtMillis: Long
    ) {
        val isDirectory: Boolean
            get() = mimeType == Document.MIME_TYPE_DIR
    }

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
                "listHostFolder" -> listHostFolder(call, result)
                "copyFileIntoHostFolder" -> copyFileIntoHostFolder(call, result)
                "createHostFolder" -> createHostFolder(call, result)
                "copyHostFileToCache" -> copyHostFileToCache(call, result)
                "openHostFile" -> openHostFile(call, result)
                "openLocalFile" -> openLocalFile(call, result)
                "publishMdnsService" -> publishMdnsService(call, result)
                "stopMdnsService" -> {
                    stopMdnsService()
                    result.success(mapOf("stopped" to true))
                }
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
                "setRoomKeepAwake" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(mapOf("enabled" to enabled))
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
            .filter { runCatching { it.isUp && !it.isLoopback }.getOrDefault(false) }
            .sortedWith(compareBy<NetworkInterface> { interfacePriority(it.name) }.thenBy { it.name })
            .flatMap { it.inetAddresses.toList() }
            .filter {
                !it.isLoopbackAddress &&
                    !it.isLinkLocalAddress &&
                    it.hostAddress?.contains(":") == false
            }
            .mapNotNull { it.hostAddress }
    }

    private fun interfacePriority(name: String): Int {
        return when {
            name.startsWith("wlan", ignoreCase = true) -> 0
            name.startsWith("wifi", ignoreCase = true) -> 0
            name.startsWith("ap", ignoreCase = true) -> 1
            name.startsWith("eth", ignoreCase = true) -> 2
            name.startsWith("rmnet", ignoreCase = true) -> 8
            name.startsWith("ccmni", ignoreCase = true) -> 8
            name.startsWith("tun", ignoreCase = true) -> 9
            name.startsWith("utun", ignoreCase = true) -> 9
            else -> 5
        }
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

    private fun listHostFolder(call: MethodCall, result: MethodChannel.Result) {
        try {
            val rootUri = call.argument<String>("rootUri") ?: throw IllegalArgumentException("Missing rootUri")
            val path = call.argument<String>("path") ?: "/"
            val root = Uri.parse(rootUri)
            val folder = findHostDocument(root, path)
                ?: throw IllegalArgumentException("Folder not found: $path")
            if (!folder.isDirectory) {
                throw IllegalArgumentException("Path is not a folder: $path")
            }
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(root, folder.documentId)
            val rows = mutableListOf<Map<String, Any?>>()
            queryDocuments(childrenUri).use { cursor ->
                while (cursor.moveToNext()) {
                    val child = cursorHostDocument(root, cursor)
                    if (child.name.startsWith(".")) continue
                    rows.add(hostDocumentMap(child, joinHostPath(path, child.name)))
                }
            }
            result.success(
                rows.sortedWith(
                    compareBy<Map<String, Any?>> { if (it["type"] == "folder") 0 else 1 }
                        .thenBy { it["name"]?.toString()?.lowercase() ?: "" }
                )
            )
        } catch (error: Exception) {
            result.error("HOST_FOLDER_LIST_FAILED", error.message, null)
        }
    }

    private fun createHostFolder(call: MethodCall, result: MethodChannel.Result) {
        try {
            val rootUri = call.argument<String>("rootUri") ?: throw IllegalArgumentException("Missing rootUri")
            val path = call.argument<String>("path") ?: "/"
            ensureHostFolder(Uri.parse(rootUri), path)
            result.success(mapOf("ok" to true))
        } catch (error: Exception) {
            result.error("HOST_FOLDER_CREATE_FAILED", error.message, null)
        }
    }

    private fun copyFileIntoHostFolder(call: MethodCall, result: MethodChannel.Result) {
        try {
            val rootUri = call.argument<String>("rootUri") ?: throw IllegalArgumentException("Missing rootUri")
            val folderPath = call.argument<String>("folderPath") ?: "/"
            val sourcePath = call.argument<String>("sourcePath") ?: throw IllegalArgumentException("Missing sourcePath")
            val requestedName = safeName(call.argument<String>("name") ?: File(sourcePath).name)
            val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
            val root = Uri.parse(rootUri)
            val parent = ensureHostFolder(root, folderPath)
            val name = uniqueHostName(root, parent.documentId, requestedName)
            val documentUri = DocumentsContract.createDocument(
                contentResolver,
                parent.uri,
                mimeType.ifBlank { "application/octet-stream" },
                name
            ) ?: throw IllegalStateException("Could not create $name")

            FileInputStream(File(sourcePath)).use { input ->
                contentResolver.openOutputStream(documentUri, "w").use { output ->
                    if (output == null) throw IllegalStateException("Could not open host folder output stream.")
                    input.copyTo(output)
                }
            }

            val document = queryDocument(root, DocumentsContract.getDocumentId(documentUri))
                ?: HostDocument(
                    uri = documentUri,
                    documentId = DocumentsContract.getDocumentId(documentUri),
                    name = name,
                    mimeType = mimeType,
                    sizeBytes = File(sourcePath).length(),
                    modifiedAtMillis = System.currentTimeMillis()
                )
            result.success(hostDocumentMap(document, joinHostPath(folderPath, document.name)))
        } catch (error: Exception) {
            result.error("HOST_FOLDER_COPY_FAILED", error.message, null)
        }
    }

    private fun copyHostFileToCache(call: MethodCall, result: MethodChannel.Result) {
        try {
            val rootUri = call.argument<String>("rootUri") ?: throw IllegalArgumentException("Missing rootUri")
            val path = call.argument<String>("path") ?: throw IllegalArgumentException("Missing path")
            val document = findHostDocument(Uri.parse(rootUri), path)
                ?: throw IllegalArgumentException("File not found: $path")
            if (document.isDirectory) throw IllegalArgumentException("Folders cannot be streamed as files.")
            val targetDirectory = File(cacheDir, "host_folder_cache").apply { mkdirs() }
            val target = uniqueFile(targetDirectory, safeName(document.name))
            contentResolver.openInputStream(document.uri).use { input ->
                if (input == null) throw IllegalStateException("Could not open selected file.")
                FileOutputStream(target).use { output -> input.copyTo(output) }
            }
            result.success(
                mapOf(
                    "path" to target.absolutePath,
                    "name" to document.name,
                    "mimeType" to (document.mimeType ?: "application/octet-stream")
                )
            )
        } catch (error: Exception) {
            result.error("HOST_FOLDER_CACHE_FAILED", error.message, null)
        }
    }

    private fun openHostFile(call: MethodCall, result: MethodChannel.Result) {
        try {
            val rootUri = call.argument<String>("rootUri") ?: throw IllegalArgumentException("Missing rootUri")
            val path = call.argument<String>("path") ?: throw IllegalArgumentException("Missing path")
            val document = findHostDocument(Uri.parse(rootUri), path)
                ?: throw IllegalArgumentException("File not found: $path")
            if (document.isDirectory) throw IllegalArgumentException("Open a folder by browsing into it.")
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(document.uri, document.mimeType ?: "*/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Open ${document.name}"))
            result.success(mapOf("opened" to true))
        } catch (error: ActivityNotFoundException) {
            result.error("OPEN_FILE_UNAVAILABLE", "No app can open this file type.", null)
        } catch (error: Exception) {
            result.error("OPEN_FILE_FAILED", error.message, null)
        }
    }

    private fun openLocalFile(call: MethodCall, result: MethodChannel.Result) {
        try {
            val path = call.argument<String>("path") ?: throw IllegalArgumentException("Missing path")
            val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
            val file = File(path)
            if (!file.exists() || !file.isFile) {
                throw IllegalArgumentException("File not found: $path")
            }
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Open ${file.name}"))
            result.success(mapOf("opened" to true))
        } catch (error: ActivityNotFoundException) {
            result.error("OPEN_FILE_UNAVAILABLE", "No app can open this file type.", null)
        } catch (error: Exception) {
            result.error("OPEN_FILE_FAILED", error.message, null)
        }
    }

    private fun findHostDocument(rootUri: Uri, path: String): HostDocument? {
        var current = rootHostDocument(rootUri)
        for (segment in hostPathSegments(path)) {
            val child = findChildByName(rootUri, current.documentId, segment) ?: return null
            current = child
        }
        return current
    }

    private fun ensureHostFolder(rootUri: Uri, path: String): HostDocument {
        var current = rootHostDocument(rootUri)
        for (segment in hostPathSegments(path)) {
            val existing = findChildByName(rootUri, current.documentId, segment)
            current = when {
                existing == null -> {
                    val created = DocumentsContract.createDocument(
                        contentResolver,
                        current.uri,
                        Document.MIME_TYPE_DIR,
                        segment
                    ) ?: throw IllegalStateException("Could not create folder $segment")
                    queryDocument(rootUri, DocumentsContract.getDocumentId(created))
                        ?: HostDocument(
                            uri = created,
                            documentId = DocumentsContract.getDocumentId(created),
                            name = segment,
                            mimeType = Document.MIME_TYPE_DIR,
                            sizeBytes = 0,
                            modifiedAtMillis = System.currentTimeMillis()
                        )
                }
                existing.isDirectory -> existing
                else -> throw IllegalArgumentException("$segment exists and is not a folder")
            }
        }
        return current
    }

    private fun rootHostDocument(rootUri: Uri): HostDocument {
        val documentId = DocumentsContract.getTreeDocumentId(rootUri)
        return queryDocument(rootUri, documentId)
            ?: HostDocument(
                uri = DocumentsContract.buildDocumentUriUsingTree(rootUri, documentId),
                documentId = documentId,
                name = folderDisplayName(rootUri),
                mimeType = Document.MIME_TYPE_DIR,
                sizeBytes = 0,
                modifiedAtMillis = 0
            )
    }

    private fun queryDocument(rootUri: Uri, documentId: String): HostDocument? {
        val uri = DocumentsContract.buildDocumentUriUsingTree(rootUri, documentId)
        return queryDocuments(uri).use { cursor ->
            if (cursor.moveToFirst()) cursorHostDocument(rootUri, cursor) else null
        }
    }

    private fun findChildByName(rootUri: Uri, parentDocumentId: String, name: String): HostDocument? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, parentDocumentId)
        return queryDocuments(childrenUri).use { cursor ->
            var found: HostDocument? = null
            while (cursor.moveToNext() && found == null) {
                val child = cursorHostDocument(rootUri, cursor)
                if (child.name == name) found = child
            }
            found
        }
    }

    private fun queryDocuments(uri: Uri): Cursor {
        return contentResolver.query(
            uri,
            arrayOf(
                Document.COLUMN_DOCUMENT_ID,
                Document.COLUMN_DISPLAY_NAME,
                Document.COLUMN_MIME_TYPE,
                Document.COLUMN_SIZE,
                Document.COLUMN_LAST_MODIFIED
            ),
            null,
            null,
            null
        ) ?: throw IllegalStateException("Could not read selected folder.")
    }

    private fun cursorHostDocument(rootUri: Uri, cursor: Cursor): HostDocument {
        val documentId = cursor.getString(cursor.getColumnIndexOrThrow(Document.COLUMN_DOCUMENT_ID))
        val name = cursor.getString(cursor.getColumnIndexOrThrow(Document.COLUMN_DISPLAY_NAME)) ?: "Item"
        val mimeType = cursor.getString(cursor.getColumnIndexOrThrow(Document.COLUMN_MIME_TYPE))
        val sizeIndex = cursor.getColumnIndex(Document.COLUMN_SIZE)
        val modifiedIndex = cursor.getColumnIndex(Document.COLUMN_LAST_MODIFIED)
        val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else 0L
        val modified = if (modifiedIndex >= 0 && !cursor.isNull(modifiedIndex)) {
            cursor.getLong(modifiedIndex)
        } else {
            0L
        }
        return HostDocument(
            uri = DocumentsContract.buildDocumentUriUsingTree(rootUri, documentId),
            documentId = documentId,
            name = name,
            mimeType = mimeType,
            sizeBytes = size,
            modifiedAtMillis = modified
        )
    }

    private fun hostDocumentMap(document: HostDocument, path: String): Map<String, Any?> {
        return mapOf(
            "name" to document.name,
            "path" to normalizeHostPath(path),
            "type" to if (document.isDirectory) "folder" else "file",
            "sizeBytes" to if (document.isDirectory) 0L else document.sizeBytes,
            "modifiedAtMillis" to document.modifiedAtMillis,
            "mimeType" to document.mimeType
        )
    }

    private fun uniqueHostName(rootUri: Uri, parentDocumentId: String, requestedName: String): String {
        val existing = mutableSetOf<String>()
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, parentDocumentId)
        queryDocuments(childrenUri).use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(cursor.getColumnIndexOrThrow(Document.COLUMN_DISPLAY_NAME))
                if (name != null) existing.add(name)
            }
        }
        if (!existing.contains(requestedName)) return requestedName
        val base = requestedName.substringBeforeLast('.', requestedName)
        val extension = requestedName.substringAfterLast('.', "")
        var index = 1
        while (true) {
            val candidate = if (extension.isEmpty()) "$base-$index" else "$base-$index.$extension"
            if (!existing.contains(candidate)) return candidate
            index++
        }
    }

    private fun hostPathSegments(path: String): List<String> {
        return normalizeHostPath(path)
            .split("/")
            .filter { it.isNotBlank() }
            .map { safeName(it) }
            .filter { it.isNotBlank() }
    }

    private fun joinHostPath(parent: String, name: String): String {
        val normalizedParent = normalizeHostPath(parent)
        val safe = safeName(name)
        return if (normalizedParent == "/") "/$safe" else "$normalizedParent/$safe"
    }

    private fun normalizeHostPath(path: String): String {
        val parts = path
            .split("/")
            .filter { it.isNotBlank() && it != "." && it != ".." }
            .map { safeName(it) }
            .filter { it.isNotBlank() }
        return if (parts.isEmpty()) "/" else "/" + parts.joinToString("/")
    }

    private fun publishMdnsService(call: MethodCall, result: MethodChannel.Result) {
        val serviceName = call.argument<String>("serviceName") ?: "Erebrus Drop"
        val serviceType = call.argument<String>("serviceType") ?: "_erebrusdrop._tcp."
        val port = call.argument<Int>("port") ?: 0
        if (port <= 0) {
            result.error("MDNS_INVALID_PORT", "A valid TCP port is required.", null)
            return
        }
        stopMdnsService()
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifiManager.createMulticastLock("erebrus-drop-mdns").apply {
                setReferenceCounted(false)
                acquire()
            }
            val manager = getSystemService(Context.NSD_SERVICE) as NsdManager
            nsdManager = manager
            val info = NsdServiceInfo().apply {
                this.serviceName = serviceName
                this.serviceType = if (serviceType.endsWith(".")) serviceType else "$serviceType."
                this.port = port
                val txt = call.argument<Map<String, Any?>>("txt") ?: emptyMap()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    txt.forEach { (key, value) ->
                        setAttribute(key, value?.toString() ?: "")
                    }
                }
            }
            val listener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(serviceInfo: NsdServiceInfo) = Unit
                override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    if (nsdRegistrationListener === this) {
                        stopMdnsService()
                    }
                }
                override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit
                override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
            }
            nsdRegistrationListener = listener
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            result.success(mapOf("published" to true))
        } catch (error: Exception) {
            stopMdnsService()
            result.error("MDNS_PUBLISH_FAILED", error.message, null)
        }
    }

    private fun stopMdnsService() {
        val manager = nsdManager
        val listener = nsdRegistrationListener
        if (manager != null && listener != null) {
            runCatching { manager.unregisterService(listener) }
        }
        nsdRegistrationListener = null
        nsdManager = null
        multicastLock?.let { lock ->
            if (lock.isHeld) {
                runCatching { lock.release() }
            }
        }
        multicastLock = null
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
