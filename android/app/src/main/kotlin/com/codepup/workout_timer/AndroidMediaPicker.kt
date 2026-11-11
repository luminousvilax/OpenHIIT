package com.codepup.workout_timer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Opens the system picker while keeping audio and image navigation independent. */
internal class AndroidMediaPicker(
    private val activity: Activity,
    private val worker: Executor = Executors.newSingleThreadExecutor()
) {
    companion object {
        const val REQUEST_CODE = 0x4d50
        private const val MAX_BYTES = 20 * 1024 * 1024
    }

    private class Request(val audio: Boolean, val result: MethodChannel.Result)
    private val locations = PickerLocations(activity)
    private var pending: Request? = null

    fun pick(audio: Boolean, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("already_active", "File picker is already active.", null)
            return
        }
        val request = Request(audio, result)
        pending = request
        worker.execute {
            val initialUris = locations.initialUris(audio)
            activity.runOnUiThread {
                if (pending !== request) return@runOnUiThread
                val extensions = if (audio) listOf("mp3", "wav")
                    else listOf("jpg", "jpeg", "png", "webp")
                val template = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, extensions.mapNotNull {
                        MimeTypeMap.getSingleton().getMimeTypeFromExtension(it)
                    }.distinct().toTypedArray())
                }
                var launchError: Exception? = null
                for (initialUri in initialUris) {
                    val intent = Intent(template)
                    if (Build.VERSION.SDK_INT >= 26 && initialUri != null) {
                        intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri)
                    }
                    try {
                        activity.startActivityForResult(intent, REQUEST_CODE)
                        return@runOnUiThread
                    } catch (error: Exception) {
                        launchError = error
                    }
                }
                pending = null
                result.error("media_pick_failed", launchError?.message, null)
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val request = pending ?: return true
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending = null
            request.result.success(null)
            return true
        }
        worker.execute {
            // Navigation is remembered before copying, validation or image cropping.
            locations.remember(request.audio, uri, data.flags)
            try {
                val cached = cacheFile(uri)
                val path = cached.absolutePath
                activity.runOnUiThread {
                    if (pending === request) {
                        pending = null
                        request.result.success(path)
                    } else {
                        cached.delete()
                        cached.parentFile?.delete()
                    }
                }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    if (pending === request) {
                        pending = null
                        request.result.error("media_pick_failed", error.message, null)
                    }
                }
            }
        }
        return true
    }

    private fun cacheFile(uri: Uri): File {
        val resolver = activity.contentResolver
        val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
            ?: throw IOException("Unable to read this file. Choose a local file.")
        // Preserve the extension for the existing validators without trusting a provider's path.
        val safeName = name.replace(Regex("[\\x00-\\x1f\\x7f/\\\\]"), "_")
        if (safeName.isEmpty() || safeName == "." || safeName == "..") {
            throw IOException("Unable to read this file. Choose a local file.")
        }
        val directory = File.createTempFile("media-pick-", "", activity.cacheDir)
        directory.delete()
        if (!directory.mkdir()) throw IOException("Unable to copy this file.")
        val target = File(directory, safeName)
        try {
            val input = resolver.openInputStream(uri)
                ?: throw IOException("Unable to read this file. Choose a local file.")
            input.use { source ->
                target.outputStream().use { destination ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_BYTES) {
                            throw IOException("Choose a non-empty file no larger than 20 MB.")
                        }
                        destination.write(buffer, 0, count)
                    }
                }
            }
            return target
        } catch (error: Exception) {
            target.delete()
            directory.delete()
            throw error
        }
    }

    fun close() {
        pending?.result?.error("picker_closed", "File picker was closed.", null)
        pending = null
        (worker as? ExecutorService)?.shutdownNow()
    }
}

/** Two navigation records, separate from saved timer media and picker cache files. */
internal class PickerLocations(private val context: Context) {
    private val preferences = context.getSharedPreferences("media_picker_locations", Context.MODE_PRIVATE)
    private val resolver = context.contentResolver
    private fun key(audio: Boolean) = if (audio) "audio" else "images"

    fun initialUri(audio: Boolean): Uri? = initialUris(audio).firstOrNull()

    fun initialUris(audio: Boolean): List<Uri?> {
        val record = read(audio) ?: return listOf(null)
        val file = Uri.parse(record.getString("file"))
        val exists = try {
            resolver.query(file, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { it.moveToFirst() } == true
        } catch (_: Exception) {
            false
        }
        val media = mediaRoot(file) != null
        val savedDirectory = storedUri(record, "directory")
        val originalDirectory = savedDirectory?.takeIf {
            it.authority == file.authority && it.pathSegments.firstOrNull() != "root"
        }
        val savedStorageFile = storedUri(record, "storageFile")
        // Old records are resolved without rewriting them when a picker is canceled.
        val resolved = if (exists && media && savedStorageFile == null) resolveMediaLocation(file)
            else null
        val storageFile = savedStorageFile ?: resolved?.storageFile
            ?: file.takeIf { it.authority == "com.android.externalstorage.documents" }
        val storageDirectory = storedUri(record, "storageDirectory")
            ?: storageFile?.let(::parentUri)
            ?: savedDirectory?.takeIf { it.authority == "com.android.externalstorage.documents" }

        val candidates = mutableListOf<Uri?>()
        // MediaDocumentsProvider cannot restore a document stack. DocumentsUI
        // accepts the launch, then silently resumes its shared last directory.
        // Use the cached storage folder up front, also avoiding a stale filename
        // when the media ID still exists after a rename.
        if (media) storageDirectory?.let(candidates::add)
        if (exists) {
            if (!media) candidates.add(file)
            storageFile?.let(candidates::add)
        }
        if (!media) originalDirectory?.let(candidates::add)
        // A cached physical directory remains useful if the source grant or
        // MediaStore lookup becomes unavailable. Do not replace it with a new lookup.
        storageDirectory?.let(candidates::add)
        mediaRoot(file)?.let(candidates::add)
        return candidates.distinct().ifEmpty { listOf(null) }
    }

    fun remember(audio: Boolean, uri: Uri, flags: Int) {
        val previous = read(audio)?.optString("file")
        try {
            if (flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0 &&
                flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0) {
                resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } catch (_: Exception) {
            // Some providers do not support durable grants. Directory memory still works.
        }
        val record = JSONObject().put("file", uri.toString())
        val media = mediaRoot(uri) != null
        val resolved = if (media) resolveMediaLocation(uri) else null
        val directory = if (media) resolved?.directory else parentUri(uri)
        directory?.let { record.put("directory", it.toString()) }
        val storageFile = resolved?.storageFile
            ?: uri.takeIf { it.authority == "com.android.externalstorage.documents" }
        storageFile?.let {
            record.put("storageFile", it.toString())
            parentUri(it)?.let { parent -> record.put("storageDirectory", parent.toString()) }
        }
        preferences.edit().putString(key(audio), record.toString()).apply()
        if (previous != null && previous != uri.toString() &&
            read(!audio)?.optString("file") != previous) {
            try {
                resolver.releasePersistableUriPermission(
                    Uri.parse(previous), Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {
                // The old grant may already have been revoked.
            }
        }
    }

    private fun read(audio: Boolean): JSONObject? = try {
        preferences.getString(key(audio), null)?.let(::JSONObject)
            ?.takeIf { it.optString("file").isNotEmpty() }
    } catch (_: Exception) {
        null
    }

    private fun storedUri(record: JSONObject, key: String): Uri? =
        record.optString(key).takeIf { it.isNotEmpty() }?.let(Uri::parse)

    private fun mediaRoot(uri: Uri): Uri? {
        if (uri.authority != "com.android.providers.media.documents") return null
        val root = when (DocumentsContract.getDocumentId(uri).substringBefore(':')) {
            "image" -> "images_root"
            "audio" -> "audio_root"
            else -> return null
        }
        return DocumentsContract.buildRootUri(uri.authority!!, root)
    }

    private data class MediaLocation(val directory: Uri?, val storageFile: Uri?)

    private fun resolveMediaLocation(uri: Uri): MediaLocation? {
        // Preserve both source metadata and the storage location. Navigation
        // uses the storage URI because media-directory hints can be ignored.
        if (Build.VERSION.SDK_INT < 29) return null
        return try {
            val media = MediaStore.getMediaUri(context, uri) ?: return null
            val image = DocumentsContract.getDocumentId(uri).startsWith("image:")
            val parentColumn = if (image) MediaStore.Images.ImageColumns.BUCKET_ID
                else MediaStore.Audio.AudioColumns.ALBUM_ID
            val projection = arrayOf(MediaStore.MediaColumns.RELATIVE_PATH,
                MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.VOLUME_NAME,
                parentColumn)
            resolver.query(media, projection, null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) return null
                val parentId = cursor.getString(3)?.takeIf { it.toLongOrNull() != null }
                val directory = parentId?.let {
                    val kind = if (image) "images_bucket" else "album"
                    DocumentsContract.buildDocumentUri(uri.authority!!, "$kind:$it")
                }
                MediaLocation(directory,
                    asStorageFile(cursor.getString(0), cursor.getString(1), cursor.getString(2)))
            }
        } catch (_: Exception) {
            // Keep the original grant for imports; navigation may still use the
            // saved directory or media-category root without broader permissions.
            null
        }
    }

    private fun asStorageFile(relative: String?, name: String?, volume: String?): Uri? {
        if (relative == null || name == null || volume == null ||
            relative.startsWith('/') || relative.split('/').any { it == ".." || it == "." } ||
            name.isEmpty() || name.contains('/')) return null
        val root = if (volume == MediaStore.VOLUME_EXTERNAL_PRIMARY) "primary" else {
            context.getSystemService(StorageManager::class.java)?.storageVolumes
                ?.firstOrNull { it.uuid?.equals(volume, ignoreCase = true) == true }
                ?.uuid ?: return null
        }
        val path = if (relative.isEmpty()) name else relative.trimEnd('/') + "/" + name
        return DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "$root:$path")
    }

    private fun parentUri(uri: Uri): Uri? = try {
        when {
            Build.VERSION.SDK_INT >= 26 && DocumentsContract.isTreeUri(uri) -> {
                val path = DocumentsContract.findDocumentPath(resolver, uri)?.path
                path?.takeIf { it.size > 1 }?.let {
                    DocumentsContract.buildDocumentUriUsingTree(uri, it[it.size - 2])
                }
            }
            uri.authority == "com.android.externalstorage.documents" -> {
                // Only this provider defines IDs as root:path/to/file. Other IDs are opaque.
                val id = DocumentsContract.getDocumentId(uri)
                val colon = id.indexOf(':')
                if (colon < 1) null else {
                    val slash = id.lastIndexOf('/')
                    val parent = if (slash > colon) id.substring(0, slash)
                        else id.substring(0, colon + 1)
                    DocumentsContract.buildDocumentUri(uri.authority!!, parent)
                }
            }
            else -> null
        }
    } catch (_: Exception) {
        null
    }
}
