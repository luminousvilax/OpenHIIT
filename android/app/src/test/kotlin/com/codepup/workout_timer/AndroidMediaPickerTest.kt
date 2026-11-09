package com.codepup.workout_timer

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
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Before
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
@Config(sdk = [28], manifest = Config.NONE)
class AndroidMediaPickerTest {
    companion object {
        const val AUTHORITY = "com.android.externalstorage.documents"
        fun document(id: String): Uri = DocumentsContract.buildDocumentUri(AUTHORITY, id)
    }

    private lateinit var activity: Activity
    private lateinit var provider: TestProvider
    private lateinit var picker: AndroidMediaPicker
    private val audio = document("primary:Music/voice/白刃の剣舞.mp3")
    private val image = document("primary:Pictures/背景.png")

    @Before
    fun setUp() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        // Robolectric's MIME map starts empty instead of loading Android's database.
        val mimeTypes = shadowOf(MimeTypeMap.getSingleton())
        mapOf("mp3" to "audio/mpeg", "wav" to "audio/x-wav",
            "jpg" to "image/jpeg", "jpeg" to "image/jpeg",
            "png" to "image/png", "webp" to "image/webp").forEach { (extension, mime) ->
            mimeTypes.addExtensionMimeTypeMapping(extension, mime)
        }
        activity.getSharedPreferences("media_picker_locations", 0).edit().clear().commit()
        activity.cacheDir.listFiles()?.forEach { it.deleteRecursively() }
        provider = TestProvider()
        provider.attachInfo(activity, ProviderInfo().apply { authority = AUTHORITY })
        ShadowContentResolver.registerProviderInternal(AUTHORITY, provider)
        provider.files[audio] = byteArrayOf(0x49, 0x44, 0x33)
        provider.files[image] = byteArrayOf(1, 2, 3)
        picker = AndroidMediaPicker(activity, Executor { it.run() })
    }

    private fun start(audio: Boolean): CapturedResult {
        val result = CapturedResult()
        picker.pick(audio, result)
        return result
    }

    private fun finish(uri: Uri) {
        picker.onActivityResult(AndroidMediaPicker.REQUEST_CODE, Activity.RESULT_OK,
            Intent().setData(uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION))
    }

    private fun launched(): Intent = shadowOf(activity).nextStartedActivityForResult.intent

    @Test
    fun audioAndImagesKeepIndependentLocationsAcrossPickerRecreation() {
        start(true)
        launched()
        finish(audio)
        start(false)
        launched()
        finish(image)
        picker.close()
        picker = AndroidMediaPicker(activity, Executor { it.run() })
        start(true)
        assertEquals(audio, launched().getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI))
        picker.onActivityResult(AndroidMediaPicker.REQUEST_CODE, Activity.RESULT_CANCELED, null)
        start(false)
        assertEquals(image, launched().getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI))
        assertEquals(2, activity.getSharedPreferences("media_picker_locations", 0).all.size)
    }

    @Test
    fun selectionIsRememberedBeforeCopyFailureAndCancellationPreservesIt() {
        val result = start(true)
        launched()
        provider.unreadable = true
        finish(audio)
        assertEquals("media_pick_failed", result.errorCode)
        assertEquals(audio, PickerLocations(activity).initialUri(true))
        val canceled = start(true)
        launched()
        picker.onActivityResult(AndroidMediaPicker.REQUEST_CODE, Activity.RESULT_CANCELED, null)
        assertTrue(canceled.completed)
        assertNull(canceled.value)
        assertEquals(audio, PickerLocations(activity).initialUri(true))
        assertTrue(activity.cacheDir.listFiles().isNullOrEmpty())
    }

    @Test
    fun missingOrRevokedFileFallsBackToItsDirectory() {
        val locations = PickerLocations(activity)
        locations.remember(true, audio, 0)
        provider.files.remove(audio)
        assertEquals(document("primary:Music/voice"), locations.initialUri(true))
        provider.files[audio] = byteArrayOf(1)
        provider.denyQueries = true
        assertEquals(document("primary:Music/voice"), locations.initialUri(true))
    }

    @Test
    fun storageRootAndRemovableVolumeParentsArePreserved() {
        val locations = PickerLocations(activity)
        locations.remember(true, document("0123-4567:声音.mp3"), 0)
        assertEquals(document("0123-4567:"), locations.initialUri(true))
        locations.remember(false, document("0123-4567:Pictures/背景.webp"), 0)
        assertEquals(document("0123-4567:Pictures"), locations.initialUri(false))
    }

    @Test
    fun opaqueOrCorruptLocationsUseSystemDefaultWithoutGuessingPaths() {
        val locations = PickerLocations(activity)
        locations.remember(true, Uri.parse("content://other.provider/document/opaque-id"), 0)
        assertNull(locations.initialUri(true))
        activity.getSharedPreferences("media_picker_locations", 0).edit()
            .putString("images", "broken json").commit()
        assertNull(locations.initialUri(false))
    }

    @Test
    fun systemIntentKeepsSingleSelectionAndSupportedFormats() {
        start(true)
        val intent = launched()
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, intent.action)
        assertTrue(intent.hasCategory(Intent.CATEGORY_OPENABLE))
        assertFalse(intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
        assertNull(intent.getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI))
        assertEquals(setOf("audio/mpeg", "audio/x-wav"),
            intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES)!!.toSet())
        picker.onActivityResult(AndroidMediaPicker.REQUEST_CODE, Activity.RESULT_CANCELED, null)
        start(false)
        assertEquals(setOf("image/jpeg", "image/png", "image/webp"),
            launched().getStringArrayExtra(Intent.EXTRA_MIME_TYPES)!!.toSet())
    }

    @Test
    fun copiedFilesPreserveNamesAndOriginalBytes() {
        val result = start(true)
        launched()
        finish(audio)
        assertTrue(result.completed)
        val cached = File(result.value as String)
        assertEquals("白刃の剣舞.mp3", cached.name)
        assertArrayEquals(provider.files[audio], cached.readBytes())
        assertArrayEquals(byteArrayOf(0x49, 0x44, 0x33), provider.files[audio])
        assertTrue(cached.canonicalPath.startsWith(activity.cacheDir.canonicalPath + "/"))
    }

    @Test
    fun newestSelectionReplacesOnlyItsOwnRecordAndOldReadGrant() {
        val locations = PickerLocations(activity)
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
        locations.remember(true, audio, flags)
        locations.remember(false, image, flags)
        val replacement = document("primary:Music/other.wav")
        provider.files[replacement] = byteArrayOf(1)
        locations.remember(true, replacement, flags)
        assertEquals(replacement, locations.initialUri(true))
        assertEquals(image, locations.initialUri(false))
        assertEquals(setOf(replacement, image),
            activity.contentResolver.persistedUriPermissions.map { it.uri }.toSet())
        assertTrue(activity.contentResolver.persistedUriPermissions.all { !it.isWritePermission })
    }

    @Test
    fun oversizedCopyFailsWithoutLeavingPartialFilesButRemembersSelection() {
        provider.files[audio] = ByteArray(20 * 1024 * 1024 + 1)
        val result = start(true)
        launched()
        finish(audio)
        assertEquals("media_pick_failed", result.errorCode)
        assertTrue(activity.cacheDir.listFiles().isNullOrEmpty())
        assertEquals(audio, PickerLocations(activity).initialUri(true))
    }

    @Test
    fun concurrentPickIsRejectedAndUnrelatedResultsAreIgnored() {
        val first = start(true)
        launched()
        val second = start(false)
        assertEquals("already_active", second.errorCode)
        assertFalse(picker.onActivityResult(42, Activity.RESULT_CANCELED, null))
        assertFalse(first.completed)
        picker.close()
        assertEquals("picker_closed", first.errorCode)
    }

    class CapturedResult : MethodChannel.Result {
        var completed = false
        var value: Any? = null
        var errorCode: String? = null
        override fun success(result: Any?) { completed = true; value = result }
        override fun error(code: String, message: String?, details: Any?) {
            completed = true
            errorCode = code
        }
        override fun notImplemented() { fail("Unexpected method") }
    }

    class TestProvider : ContentProvider() {
        val files = mutableMapOf<Uri, ByteArray>()
        var unreadable = false
        var denyQueries = false
        override fun onCreate() = true
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
            selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
            if (denyQueries) throw SecurityException("Grant revoked")
            return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply {
                if (files.containsKey(uri)) {
                    addRow(arrayOf(DocumentsContract.getDocumentId(uri).substringAfterLast('/')))
                }
            }
        }
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
            if (unreadable) throw FileNotFoundException("Unavailable source")
            val source = File.createTempFile("provider-", ".tmp", context!!.filesDir)
            source.writeBytes(files[uri] ?: throw FileNotFoundException())
            return ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        override fun getType(uri: Uri): String? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun update(uri: Uri, values: ContentValues?, selection: String?,
            selectionArgs: Array<out String>?) = 0
    }
}
