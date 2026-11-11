package com.codepup.workout_timer

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Native I/O and permission boundary for the Flutter browser. Never writes source media. */
internal class AndroidMediaPicker(
    private val activity: Activity,
    private val worker: Executor = Executors.newSingleThreadExecutor(),
    private val thumbnails: Executor = ThreadPoolExecutor(2, 2, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue(48))
) {
    companion object {
        const val TREE_REQUEST = 0x4d50
        const val PERMISSION_REQUEST = 0x4d51
        const val MAX_BYTES = 20 * 1024 * 1024
        private const val THUMBNAIL_EDGE = 512
        fun supported(name: String, audio: Boolean): Boolean =
            name.substringAfterLast('.', "").lowercase() in
                if (audio) setOf("mp3", "wav") else setOf("jpg", "jpeg", "png", "webp")
    }

    private val resolver = activity.contentResolver
    private val state = MediaBrowserState(activity)
    private var pendingTree: MethodChannel.Result? = null
    private var pendingPermission: Pair<Boolean, MethodChannel.Result>? = null
    @Volatile private var closed = false
    @Volatile private var thumbnailGeneration = 0
    private val signals = ConcurrentHashMap<CancellationSignal, Boolean>()
    @Volatile private var listingSignal: CancellationSignal? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val audio = call.argument<Boolean>("audio") == true
        when (call.method) {
            "initialize" -> if (!state.asked(audio) && permission(audio) == "denied")
                requestPermission(audio, result) else background(result) { snapshot(audio) }
            "state" -> background(result) { snapshot(audio) }
            "requestPermission" -> requestPermission(audio, result)
            "addFolder" -> addFolder(call.argument<String>("tree"), result)
            "removeFolder" -> background(result) {
                val tree = requireNotNull(call.argument<String>("tree"))
                require(state.folders().any { it["tree"] == tree })
                // Update records first: an intentionally removed location is not a recovery error.
                state.removeFolder(tree)
                try { resolver.releasePersistableUriPermission(Uri.parse(tree), Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                catch (_: SecurityException) { /* Already revoked. */ }
                null
            }
            "saveView" -> background(result) {
                state.saveView(audio, requireNotNull(call.argument<String>("sort")),
                    call.argument<Boolean>("ascending") == true, call.argument<Boolean>("grid") == true,
                    call.argument<Boolean>("showNames") == true, call.argument<Boolean>("largePreviews") == true)
                null
            }
            "list" -> {
                listingSignal?.cancel()
                val signal = CancellationSignal()
                listingSignal = signal
                background(result) { list(audio, location(call), signal) }
            }
            "select" -> background(result) {
                val location = location(call)
                val id = call.argument<String>("id")
                val entry = list(audio, location).singleOrNull { it["id"] == id && it["folder"] == false }
                    ?: throw IOException("This file is no longer available. Refresh the folder.")
                val name = entry["name"] as String
                state.remember(audio, location, id!!, name)
                cacheFile(Uri.parse(id), name).absolutePath
            }
            "thumbnail" -> thumbnail(call, result)
            "cancelThumbnails" -> { cancelThumbnails(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun snapshot(audio: Boolean): Map<String, Any?> = state.record(audio) + mapOf(
        "folders" to state.folders(), "permission" to permission(audio))

    internal fun permission(audio: Boolean): String {
        fun granted(name: String) = activity.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED
        if (Build.VERSION.SDK_INT < 33) return if (granted(Manifest.permission.READ_EXTERNAL_STORAGE)) "full" else "denied"
        if (granted(if (audio) Manifest.permission.READ_MEDIA_AUDIO else Manifest.permission.READ_MEDIA_IMAGES)) return "full"
        if (!audio && Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)) return "partial"
        return "denied"
    }

    private fun requestPermission(audio: Boolean, result: MethodChannel.Result) {
        if (pendingPermission != null) { result.error("already_active", "A permission request is already active.", null); return }
        val primary = if (Build.VERSION.SDK_INT < 33) Manifest.permission.READ_EXTERNAL_STORAGE
            else if (audio) Manifest.permission.READ_MEDIA_AUDIO else Manifest.permission.READ_MEDIA_IMAGES
        if (permission(audio) == "full") { background(result) { snapshot(audio) }; return }
        if (state.asked(audio) && permission(audio) == "denied" && !activity.shouldShowRequestPermissionRationale(primary)) {
            activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", activity.packageName, null)))
            background(result) { snapshot(audio) }
            return
        }
        val permissions = mutableListOf(primary)
        if (!audio && Build.VERSION.SDK_INT >= 34) permissions.add(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        pendingPermission = audio to result
        state.markAsked(audio)
        activity.requestPermissions(permissions.toTypedArray(), PERMISSION_REQUEST)
    }

    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val pending = pendingPermission ?: return true
        pendingPermission = null
        background(pending.second) { snapshot(pending.first) }
        return true
    }

    private fun addFolder(previousTree: String?, result: MethodChannel.Result) {
        if (pendingTree != null) { result.error("already_active", "Folder authorization is already active.", null); return }
        pendingTree = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                if (Build.VERSION.SDK_INT >= 26 && previousTree != null)
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(previousTree))
            }
            activity.startActivityForResult(intent, TREE_REQUEST)
        } catch (error: Exception) {
            pendingTree = null
            result.error("media_browser_failed", "Unable to open folder authorization.", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != TREE_REQUEST) return false
        val result = pendingTree ?: return true
        pendingTree = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        background(result) {
            if (data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION == 0 ||
                data.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION == 0)
                throw IOException("This provider cannot retain folder access. Choose another folder.")
            resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val root = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
            val name = try {
                resolver.query(root, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
                    ?.use { if (it.moveToFirst()) it.getString(0) else null }
            } catch (_: Exception) { null }
                ?: DocumentsContract.getTreeDocumentId(uri).substringAfterLast('/').ifEmpty { "Folder" }
            state.addFolder(uri.toString(), name)
            mapOf("tree" to uri.toString(), "name" to name)
        }
        return true
    }

    @Suppress("UNCHECKED_CAST")
    private fun location(call: MethodCall): Map<String, Any?> =
        requireNotNull(call.argument<Map<String, Any?>>("location"))

    internal fun list(audio: Boolean, location: Map<String, Any?>, signal: CancellationSignal? = null): List<Map<String, Any?>> =
        when (location["source"]) {
            "library" -> {
                if (permission(audio) == "denied") throw SecurityException("Allow media access or add a folder.")
                library(audio, location["directory"] as? String ?: "", signal)
            }
            "folders" -> if (location["tree"] == null) state.folders().map {
                mapOf("id" to it["tree"], "name" to it["name"], "folder" to true, "root" to true)
            } else documents(audio, location, signal)
            else -> throw IllegalArgumentException("Unknown media source")
        }

    /** Query the system index, not the filesystem. Only the current level is returned. */
    private fun library(audio: Boolean, directory: String, signal: CancellationSignal?): List<Map<String, Any?>> {
        val modern = Build.VERSION.SDK_INT >= 29
        val collection = if (audio) MediaStore.Audio.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val columns = mutableListOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED)
        if (modern) { columns.add(MediaStore.MediaColumns.RELATIVE_PATH); columns.add(MediaStore.MediaColumns.VOLUME_NAME) }
        else columns.add(MediaStore.MediaColumns.DATA)
        val entries = mutableListOf<Map<String, Any?>>()
        val folders = linkedMapOf<String, Map<String, Any?>>()
        // Restrict nested browsing in SQL. The root query only reads system-index metadata.
        val selection = if (modern && directory.contains('/')) "${MediaStore.MediaColumns.VOLUME_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? ESCAPE '\\'" else null
        val args = if (selection != null) arrayOf(directory.substringBefore('/'),
            directory.substringAfter('/').replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%") else null
        resolver.query(collection, columns.toTypedArray(), selection, args, null, signal)?.use { cursor ->
            while (cursor.moveToNext()) {
                signal?.throwIfCanceled()
                val name = cursor.getString(1) ?: continue
                if (!supported(name, audio)) continue
                val parent = if (modern) {
                    val volume = cursor.getString(5) ?: "external_primary"
                    "$volume/" + (cursor.getString(4) ?: "")
                } else "external_primary/" + (cursor.getString(4)?.substringBeforeLast('/')
                    ?.removePrefix("/storage/emulated/0/")?.trim('/')?.plus('/') ?: "")
                if (!parent.startsWith(directory)) continue
                val remaining = parent.removePrefix(directory).trimEnd('/')
                if (remaining.isNotEmpty()) {
                    val child = remaining.substringBefore('/')
                    val id = directory + child + "/"
                    folders[id] = mapOf("id" to id, "name" to if (directory.isEmpty() && child == "external_primary") "Internal storage" else child, "folder" to true)
                } else {
                    entries.add(mapOf("id" to ContentUris.withAppendedId(collection, cursor.getLong(0)).toString(),
                        "name" to name, "folder" to false,
                        "size" to if (cursor.isNull(2)) null else cursor.getLong(2),
                        "modified" to if (cursor.isNull(3)) null else cursor.getLong(3) * 1000))
                }
            }
        } ?: throw IOException("Unable to read the media library. Try again.")
        if (directory.isNotEmpty() && entries.isEmpty() && folders.isEmpty())
            throw IOException("This location is empty or no longer accessible. Check access or choose another folder.")
        return folders.values.toList() + entries
    }

    /** Verify each path segment against its parent's immediate children, even for opaque IDs. */
    private fun documentDirectory(location: Map<String, Any?>, signal: CancellationSignal?): Pair<Uri, String> {
        val tree = Uri.parse(location["tree"] as String)
        require(state.folders().any { it["tree"] == tree.toString() }) { "Folder authorization was removed." }
        var id = DocumentsContract.getTreeDocumentId(tree)
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        resolver.query(root, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null, signal)
            ?.use { if (!it.moveToFirst()) throw IOException("This folder is no longer available.") }
            ?: throw IOException("This folder is no longer available.")
        val trail = location["trail"] as? List<*> ?: emptyList<Any>()
        for (part in trail) {
            val next = (part as Map<*, *>)["id"] as String
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            var found = false
            resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null, signal)?.use { cursor ->
                while (cursor.moveToNext()) if (cursor.getString(0) == next &&
                    cursor.getString(1) == DocumentsContract.Document.MIME_TYPE_DIR) { found = true; break }
            }
            require(found) { "This folder is no longer accessible." }
            id = next
        }
        return tree to id
    }

    private fun documents(audio: Boolean, location: Map<String, Any?>, signal: CancellationSignal?): List<Map<String, Any?>> {
        val (tree, id) = documentDirectory(location, signal)
        val entries = mutableListOf<Map<String, Any?>>()
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        resolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(tree, id), columns, null, null, null, signal)
            ?.use { cursor ->
                while (cursor.moveToNext()) {
                    signal?.throwIfCanceled()
                    val name = cursor.getString(1) ?: continue
                    val folder = cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR
                    if (!folder && !supported(name, audio)) continue
                    val docId = cursor.getString(0)
                    entries.add(mapOf("id" to if (folder) docId else
                        DocumentsContract.buildDocumentUriUsingTree(tree, docId).toString(),
                        "name" to name, "folder" to folder,
                        "size" to if (cursor.isNull(3)) null else cursor.getLong(3),
                        "modified" to if (cursor.isNull(4)) null else cursor.getLong(4)))
                }
            } ?: throw IOException("Unable to read this folder. Try again or authorize it again.")
        return entries
    }

    internal fun cacheFile(uri: Uri, name: String): File {
        val safeName = name.replace(Regex("[\\x00-\\x1f\\x7f/\\\\]"), "_")
        require(safeName.isNotEmpty() && safeName != "." && safeName != "..")
        val directory = File.createTempFile("media-pick-", "", activity.cacheDir)
        directory.delete()
        if (!directory.mkdir()) throw IOException("Unable to copy this file.")
        val target = File(directory, safeName)
        try {
            val input = resolver.openInputStream(uri) ?: throw IOException("Unable to read this file.")
            input.use { source -> target.outputStream().use { destination ->
                val buffer = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val count = source.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > MAX_BYTES) throw IOException("Choose a non-empty file no larger than 20 MB.")
                    destination.write(buffer, 0, count)
                }
                if (total == 0) throw IOException("Choose a non-empty file no larger than 20 MB.")
            } }
            return target
        } catch (error: Exception) { target.delete(); directory.delete(); throw error }
    }

    private fun thumbnail(call: MethodCall, result: MethodChannel.Result) {
        val uri = Uri.parse(requireNotNull(call.argument<String>("id")))
        val generation = thumbnailGeneration
        val signal = CancellationSignal()
        signals[signal] = true
        val task = Runnable {
            var bytes: ByteArray? = null
            try {
                if (generation != thumbnailGeneration || closed) signal.cancel()
                signal.throwIfCanceled()
                var bitmap = try {
                    if (Build.VERSION.SDK_INT >= 29) resolver.loadThumbnail(uri, Size(THUMBNAIL_EDGE, THUMBNAIL_EDGE), signal)
                    else DocumentsContract.getDocumentThumbnail(resolver, uri, android.graphics.Point(THUMBNAIL_EDGE, THUMBNAIL_EDGE), signal)
                } catch (_: Exception) { null }
                if (bitmap == null && !signal.isCanceled) {
                    // Bounded fallback for providers without thumbnails. Never decode a full-size bitmap.
                    val encoded = resolver.openInputStream(uri)?.use { input ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(16 * 1024)
                        while (true) {
                            signal.throwIfCanceled()
                            val n = input.read(buffer)
                            if (n < 0) break
                            if (output.size() + n > MAX_BYTES) throw IOException("Image too large")
                            output.write(buffer, 0, n)
                        }
                        output.toByteArray()
                    }
                    if (encoded != null) {
                        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                        BitmapFactory.decodeByteArray(encoded, 0, encoded.size, options)
                        if (options.outWidth > 0 && options.outHeight > 0) {
                            options.inJustDecodeBounds = false
                            options.inSampleSize = 1
                            while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize > THUMBNAIL_EDGE)
                                options.inSampleSize *= 2
                            bitmap = BitmapFactory.decodeByteArray(encoded, 0, encoded.size, options)
                        }
                    }
                }
                bitmap?.let {
                    try { if (!signal.isCanceled) bytes = ByteArrayOutputStream().use { output ->
                        it.compress(Bitmap.CompressFormat.JPEG, 75, output); output.toByteArray()
                    } } finally { it.recycle() }
                }
            } catch (_: Exception) { /* A thumbnail failure never prevents selecting the file. */ }
            finally { signals.remove(signal) }
            activity.runOnUiThread { if (!closed) result.success(if (generation == thumbnailGeneration) bytes else null) }
        }
        try { thumbnails.execute(task) }
        catch (_: RejectedExecutionException) { signals.remove(signal); result.success(null) }
    }

    private fun cancelThumbnails() {
        listingSignal?.cancel()
        thumbnailGeneration++
        signals.keys.forEach { it.cancel() }
    }

    private fun background(result: MethodChannel.Result, task: () -> Any?) {
        worker.execute {
            try {
                val value = task()
                activity.runOnUiThread {
                    if (!closed) result.success(value)
                    else if (value is String && value.startsWith(activity.cacheDir.path + "/media-pick-"))
                        File(value).let { it.delete(); it.parentFile?.delete() }
                }
            } catch (error: Exception) {
                activity.runOnUiThread { if (!closed) result.error("media_browser_failed",
                    if (error is SecurityException) "Access is unavailable. Allow access or authorize the folder again."
                    else error.message ?: "Unable to read media.", null) }
            }
        }
    }

    fun close() {
        closed = true
        pendingTree?.error("picker_closed", "Folder authorization was closed.", null)
        pendingPermission?.second?.error("picker_closed", "Permission request was closed.", null)
        pendingTree = null; pendingPermission = null
        cancelThumbnails()
        (worker as? ExecutorService)?.shutdown()
        (thumbnails as? ExecutorService)?.shutdown()
    }
}
