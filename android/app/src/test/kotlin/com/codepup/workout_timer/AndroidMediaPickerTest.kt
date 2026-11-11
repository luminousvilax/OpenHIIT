package com.codepup.workout_timer

import android.Manifest
import android.app.Activity
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.Executor

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class AndroidMediaPickerTest {
    private lateinit var activity: Activity
    private lateinit var provider: TestProvider
    private lateinit var picker: AndroidMediaPicker
    private lateinit var state: MediaBrowserState
    private val tree = DocumentsContract.buildTreeDocumentUri("browser.test", "root").toString()
    private val folder get() = mapOf<String, Any?>("source" to "folders", "tree" to tree)
    private val audioUri get() = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(tree), "audio").toString()

    @Before fun setUp() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        activity.getSharedPreferences("media_browser", 0).edit().clear().commit()
        activity.cacheDir.listFiles()?.forEach { it.deleteRecursively() }
        state = MediaBrowserState(activity)
        state.addFolder(tree, "Fixtures")
        provider = TestProvider()
        provider.attachInfo(activity, ProviderInfo().apply { authority = "browser.test" })
        ShadowContentResolver.registerProviderInternal("browser.test", provider)
        ShadowContentResolver.registerProviderInternal(MediaStore.AUTHORITY, provider)
        picker = AndroidMediaPicker(activity, Executor { it.run() }, Executor { it.run() })
    }
    @After fun tearDown() { picker.close() }

    private fun call(method: String, args: Map<String, Any?> = emptyMap()): CapturedResult =
        CapturedResult().also { picker.handle(MethodCall(method, args), it) }

    @Test fun folderListingFiltersFilesButKeepsImmediateSubfolders() {
        val entries = picker.list(true, folder)
        assertEquals(setOf("Nested", "声音.mp3"), entries.map { it["name"] }.toSet())
        assertEquals(setOf("Nested", "背景.png"), picker.list(false, folder).map { it["name"] }.toSet())
        assertFalse(state.record(true)["location"] == folder)
    }

    @Test fun opaqueChildIdsWorkAndCannotEscapeTheAuthorizedRoot() {
        val child = folder + mapOf("trail" to listOf(mapOf("id" to "opaque-child", "name" to "Nested")))
        assertEquals("nested.wav", picker.list(true, child).single()["name"])
        val forged = folder + mapOf("trail" to listOf(mapOf("id" to "outside", "name" to "Forged")))
        val result = call("list", mapOf("audio" to true, "location" to forged))
        assertEquals("media_browser_failed", result.errorCode)
        assertFalse(provider.queriedOutside)
    }

    @Test fun fileSelectionRemembersBeforeCopyAndPreservesUnicodeAndOriginalBytes() {
        val result = call("select", mapOf("audio" to true, "location" to folder, "id" to audioUri))
        assertNull(result.errorCode)
        val cached = File(result.value as String)
        assertEquals("声音.mp3", cached.name)
        assertArrayEquals(provider.audio, cached.readBytes())
        assertArrayEquals(byteArrayOf(0x49, 0x44, 0x33, 1), provider.audio)
        assertEquals(audioUri, state.record(true)["file"])
        assertNull(state.record(false)["file"])
    }

    @Test fun failedCopyKeepsSelectionAndRemovesPartialCache() {
        provider.audio = ByteArray(AndroidMediaPicker.MAX_BYTES + 1)
        val result = call("select", mapOf("audio" to true, "location" to folder, "id" to audioUri))
        assertEquals("media_browser_failed", result.errorCode)
        assertEquals(audioUri, state.record(true)["file"])
        assertTrue(activity.cacheDir.listFiles().isNullOrEmpty())
    }

    @Test fun emptyFilesFailWithoutCacheAndUnknownFilesCannotBeSelected() {
        provider.audio = byteArrayOf()
        assertNotNull(call("select", mapOf("audio" to true, "location" to folder, "id" to audioUri)).errorCode)
        assertTrue(activity.cacheDir.listFiles().isNullOrEmpty())
        val forged = call("select", mapOf("audio" to true, "location" to folder, "id" to "content://outside/file"))
        assertNotNull(forged.errorCode)
    }

    @Test fun cancelingFolderAuthorizationKeepsListAndNavigation() {
        val before = state.record(true)
        val result = call("addFolder")
        val intent = shadowOf(activity).nextStartedActivityForResult.intent
        assertEquals(Intent.ACTION_OPEN_DOCUMENT_TREE, intent.action)
        assertEquals(0, intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        picker.onActivityResult(AndroidMediaPicker.TREE_REQUEST, Activity.RESULT_CANCELED, null)
        assertTrue(result.completed)
        assertNull(result.value)
        assertEquals(1, state.folders().size)
        assertEquals(before, state.record(true))
    }

    @Test fun successfulFolderAuthorizationRetainsOnlyReadAccessAndSurvivesCancellationOfFileSelection() {
        call("addFolder")
        picker.onActivityResult(AndroidMediaPicker.TREE_REQUEST, Activity.RESULT_OK,
            Intent().setData(Uri.parse(tree)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION))
        assertEquals(1, state.folders().size)
        assertTrue(activity.contentResolver.persistedUriPermissions.any { it.uri.toString() == tree && it.isReadPermission && !it.isWritePermission })
        assertNull(state.record(true)["file"])
    }

    @Test fun removingSharedRootClearsBothLocationsButDoesNotTouchSourceFiles() {
        state.remember(true, folder, audioUri, "声音.mp3")
        state.remember(false, folder, "image", "背景.png")
        val result = call("removeFolder", mapOf("tree" to tree))
        assertNull(result.errorCode)
        assertTrue(state.folders().isEmpty())
        assertNull(state.record(true)["file"])
        assertNull(state.record(false)["file"])
        assertEquals(4, provider.audio.size)
        assertNotNull(call("list", mapOf("audio" to true, "location" to folder)).errorCode)
    }

    @Test fun revokedFolderAccessIsReportedWithoutErasingRecord() {
        state.remember(true, folder, audioUri, "声音.mp3")
        provider.deny = true
        assertNotNull(call("list", mapOf("audio" to true, "location" to folder)).errorCode)
        assertEquals(audioUri, state.record(true)["file"])
        assertEquals(1, state.folders().size)
    }

    @Test fun initialPermissionRequestIsTypedAndDenialIsNotAutomaticallyRepeated() {
        call("initialize", mapOf("audio" to true))
        val request = shadowOf(activity).lastRequestedPermission
        assertArrayEquals(arrayOf(Manifest.permission.READ_MEDIA_AUDIO), request.requestedPermissions)
        picker.onRequestPermissionsResult(AndroidMediaPicker.PERMISSION_REQUEST)
        assertTrue(state.asked(true))
        assertFalse(state.asked(false))
        val repeated = call("initialize", mapOf("audio" to true))
        assertTrue(repeated.completed)
        assertEquals("denied", (repeated.value as Map<*, *>)["permission"])
    }

    @Test fun partialImagePermissionIsUsableWithoutGrantingAudioOrVideo() {
        shadowOf(activity.application).grantPermissions(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        assertEquals("partial", picker.permission(false))
        assertEquals("denied", picker.permission(true))
        val result = call("initialize", mapOf("audio" to false))
        assertTrue(result.completed)
        assertEquals("partial", (result.value as Map<*, *>)["permission"])
    }

    @Test fun mediaLibraryReturnsOnlyCurrentLevelAndNeverMixesAudioAndImages() {
        shadowOf(activity.application).grantPermissions(Manifest.permission.READ_MEDIA_AUDIO, Manifest.permission.READ_MEDIA_IMAGES)
        val home = mapOf<String, Any?>("source" to "library", "directory" to "")
        assertEquals("Internal storage", picker.list(true, home).single()["name"])
        val root = home + mapOf("directory" to "external_primary/")
        assertEquals(setOf("Music"), picker.list(true, root).map { it["name"] }.toSet())
        assertEquals(setOf("Pictures"), picker.list(false, root).map { it["name"] }.toSet())
        val leaf = home + mapOf("directory" to "external_primary/Music/")
        assertEquals("声音.mp3", picker.list(true, leaf).single()["name"])
        assertTrue(picker.list(true, leaf).none { it["name"] == "nested.wav" })
    }

    @Test fun missingMediaDirectoryReportsErrorAndPreservesNavigation() {
        shadowOf(activity.application).grantPermissions(Manifest.permission.READ_MEDIA_IMAGES)
        val location = mapOf<String, Any?>("source" to "library", "directory" to "external_primary/Gone/")
        state.remember(false, location, "old", "old.png")
        assertNotNull(call("list", mapOf("location" to location)).errorCode)
        assertEquals(location, state.record(false)["location"])
    }

    @Test fun obsoleteQueuedThumbnailsCompleteWithoutReadingOriginals() {
        picker.close()
        val queued = mutableListOf<Runnable>()
        picker = AndroidMediaPicker(activity, Executor { it.run() }, Executor { queued.add(it) })
        val result = call("thumbnail", mapOf("id" to audioUri))
        assertFalse(result.completed)
        call("cancelThumbnails")
        provider.deny = true
        queued.single().run()
        assertTrue(result.completed)
        assertNull(result.value)
    }

    class CapturedResult : MethodChannel.Result {
        var completed = false
        var value: Any? = null
        var errorCode: String? = null
        override fun success(result: Any?) { completed = true; value = result }
        override fun error(code: String, message: String?, details: Any?) { completed = true; errorCode = code }
        override fun notImplemented() { fail("Unexpected method") }
    }

    class TestProvider : ContentProvider() {
        var audio = byteArrayOf(0x49, 0x44, 0x33, 1)
        var deny = false
        var queriedOutside = false
        override fun onCreate() = true
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor {
            if (deny) throw SecurityException("Access revoked")
            val columns = projection!!
            val rows: List<Map<String, Any?>>
            if (uri.authority == MediaStore.AUTHORITY) {
                val image = uri.path!!.contains("images")
                val name = if (image) "背景.png" else "声音.mp3"
                rows = listOf(mapOf(MediaStore.MediaColumns._ID to 1L,
                    MediaStore.MediaColumns.DISPLAY_NAME to name, MediaStore.MediaColumns.SIZE to 4L,
                    MediaStore.MediaColumns.DATE_MODIFIED to 12L,
                    MediaStore.MediaColumns.RELATIVE_PATH to if (image) "Pictures/" else "Music/",
                    MediaStore.MediaColumns.VOLUME_NAME to "external_primary"))
            } else {
                val id = DocumentsContract.getDocumentId(uri)
                if (id == "outside") queriedOutside = true
                val children = uri.lastPathSegment == "children"
                fun row(doc: String, name: String, mime: String, size: Long? = null) = mapOf<String, Any?>(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID to doc,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME to name,
                    DocumentsContract.Document.COLUMN_MIME_TYPE to mime,
                    DocumentsContract.Document.COLUMN_SIZE to size)
                rows = if (!children) listOf(row(id, "Fixtures", DocumentsContract.Document.MIME_TYPE_DIR))
                    else if (id == "root") listOf(row("opaque-child", "Nested", DocumentsContract.Document.MIME_TYPE_DIR),
                        row("audio", "声音.mp3", "audio/mpeg", audio.size.toLong()),
                        row("image", "背景.png", "image/png"), row("other", "notes.txt", "text/plain"))
                    else if (id == "opaque-child") listOf(row("nested", "nested.wav", "audio/wav")) else emptyList()
            }
            return MatrixCursor(columns).apply { rows.forEach { row -> addRow(columns.map { row[it] }.toTypedArray()) } }
        }
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
            if (deny) throw FileNotFoundException()
            val file = File(context!!.filesDir, "fixture")
            file.writeBytes(audio)
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        override fun getType(uri: Uri): String? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = error("Originals must never be deleted")
        override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = error("Originals must never be changed")
    }
}
