package com.codepup.workout_timer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
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
            val initialUri = locations.initialUri(audio)
            activity.runOnUiThread {
                if (pending !== request) return@runOnUiThread
                val extensions = if (audio) listOf("mp3", "wav")
                    else listOf("jpg", "jpeg", "png", "webp")
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, extensions.mapNotNull {
                        MimeTypeMap.getSingleton().getMimeTypeFromExtension(it)
                    }.distinct().toTypedArray())
                    if (Build.VERSION.SDK_INT >= 26 && initialUri != null) {
                        putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri)
                    }
                }
                try {
                    activity.startActivityForResult(intent, REQUEST_CODE)
                } catch (error: Exception) {
                    pending = null
                    result.error("media_pick_failed", error.message, null)
                }
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

    fun initialUri(audio: Boolean): Uri? {
        val record = read(audio) ?: return null
        val file = Uri.parse(record.getString("file"))
        val exists = try {
            resolver.query(file, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { it.moveToFirst() } == true
        } catch (_: Exception) {
            false
        }
        if (exists) return file
        // The picker can access the parent even when our file grant has expired.
        return record.optString("directory").takeIf { it.isNotEmpty() }?.let(Uri::parse)
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
        parentUri(uri)?.let { record.put("directory", it.toString()) }
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
