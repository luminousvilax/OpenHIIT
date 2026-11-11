package com.codepup.workout_timer

import android.app.Activity
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import org.json.JSONObject
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
@Config(sdk = [29], manifest = Config.NONE)
@Suppress("DEPRECATION") // The simulated Android versions precede the typed Parcelable APIs.
class MediaPickerNavigationTest {
    companion object {
        private const val STORAGE = "com.android.externalstorage.documents"
        private const val MEDIA = "com.android.providers.media.documents"
        private fun local(id: String) = DocumentsContract.buildDocumentUri(STORAGE, "primary:$id")
    }

    private lateinit var activity: Activity
    private lateinit var picker: AndroidMediaPicker
    private lateinit var mediaProvider: NavigationProvider
    private lateinit var storageDocuments: NavigationProvider
    private lateinit var lastResult: AndroidMediaPickerTest.CapturedResult
    private val audio = local("Music/voice/first.mp3")
    private val nextAudio = local("Music/other/next.mp3")
    private val image = DocumentsContract.buildDocumentUri(MEDIA, "image:42")
    private val mediaAudio = DocumentsContract.buildDocumentUri(MEDIA, "audio:43")
    private val imageFolder = DocumentsContract.buildDocumentUri(MEDIA, "images_bucket:100")
    private val audioFolder = DocumentsContract.buildDocumentUri(MEDIA, "album:901")
    private val photo = local("Pictures/背景/照片.png")
    private val entries = linkedMapOf(
        audio to Entry("first.mp3", "Music/voice/"),
        nextAudio to Entry("next.mp3", "Music/other/"),
        image to Entry("照片.png", "Pictures/背景/"),
        photo to Entry("照片.png", "Pictures/背景/"),
        mediaAudio to Entry("first.mp3", "Music/voice/", parentId = "901"),
    )
    private var lastDirectory: Uri? = null

    @Before
    fun setUp() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        activity.getSharedPreferences("media_picker_locations", 0).edit().clear().commit()
        for (authority in listOf(STORAGE, MEDIA, MediaStore.AUTHORITY)) {
            val provider = NavigationProvider(entries, authority)
            provider.attachInfo(activity, ProviderInfo().apply { this.authority = authority })
            ShadowContentResolver.registerProviderInternal(authority, provider)
            if (authority == MediaStore.AUTHORITY) mediaProvider = provider
            if (authority == STORAGE) storageDocuments = provider
        }
        picker = AndroidMediaPicker(activity, Executor { it.run() })
    }

    private fun open(audio: Boolean): Intent {
        lastResult = AndroidMediaPickerTest.CapturedResult()
        picker.pick(audio, lastResult)
        return shadowOf(activity).nextStartedActivityForResult.intent
    }

    private fun choose(uri: Uri) {
        picker.onActivityResult(AndroidMediaPicker.REQUEST_CODE, Activity.RESULT_OK,
            Intent().setData(uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION))
        lastDirectory = local(entries.getValue(uri).relativePath.removeSuffix("/"))
    }

    private fun cancel() {
        picker.onActivityResult(AndroidMediaPicker.REQUEST_CODE, Activity.RESULT_CANCELED, null)
    }

    // DocumentsUI's LoadDocStackTask needs findDocumentPath; if it fails,
    // picker.ActionHandler restores one shared last location for the calling app.
    // Like the platform MediaDocumentsProvider, the media fixture does not
    // implement findDocumentPath, for either file or directory URIs. A successful
    // activity launch therefore must not be mistaken for successful navigation.
    private fun systemDirectory(intent: Intent): Uri? {
        val initial = intent.getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI)
            ?: return lastDirectory
        if (initial.pathSegments.firstOrNull() == "root") return initial
        return try {
            val path = activity.contentResolver.call(initial, "android:findDocumentPath", null,
                Bundle().apply { putParcelable("uri", initial) })
                ?.getParcelable<DocumentsContract.Path>("result") ?: return lastDirectory
            val directory = if (entries.containsKey(initial)) path.path[path.path.size - 2]
                else path.path.last()
            DocumentsContract.buildDocumentUri(initial.authority!!, directory)
        } catch (_: Exception) {
            lastDirectory
        }
    }

    @Test
    fun replacingAudioDoesNotRedirectImagesSelectedFromMediaCategories() {
        open(true)
        choose(audio)
        open(false)
        choose(image)
        assertEquals(local("Pictures/背景"), systemDirectory(open(false)))
        cancel()
        open(true)
        choose(nextAudio)
        val savedImage = activity.getSharedPreferences("media_picker_locations", 0)
            .getString("images", null)!!
        assertEquals(image.toString(), JSONObject(savedImage).getString("file"))
        assertTrue(activity.contentResolver.query(image, arrayOf(OpenableColumns.DISPLAY_NAME),
            null, null, null)!!.use { it.moveToFirst() })
        assertTrue(activity.contentResolver.persistedUriPermissions.any {
            it.uri == image && it.isReadPermission
        })
        assertEquals(local("Pictures/背景"), systemDirectory(open(false)))
        cancel()
        assertEquals(local("Music/other"), systemDirectory(open(true)))
    }

    @Test
    fun replacingImagesDoesNotRedirectAudioSelectedFromMediaCategories() {
        open(true)
        choose(mediaAudio)
        open(false)
        choose(photo)
        val saved = JSONObject(activity.getSharedPreferences("media_picker_locations", 0)
            .getString("audio", null)!!)
        assertEquals(audioFolder.toString(), saved.getString("directory"))
        assertEquals(audio.toString(), saved.getString("storageFile"))
        assertEquals(local("Music/voice"), systemDirectory(open(true)))
    }

    @Test
    fun existingMediaRecordIsResolvedWithoutReselectingTheFile() {
        activity.getSharedPreferences("media_picker_locations", 0).edit()
            .putString("images", JSONObject().put("file", image.toString()).toString()).commit()
        assertEquals(local("Pictures/背景"),
            open(false).getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI))
    }

    @Test
    fun originalMediaDirectoryIsPreservedWhileStorageIsUsedForNavigation() {
        open(false)
        choose(image)
        val saved = JSONObject(activity.getSharedPreferences("media_picker_locations", 0)
            .getString("images", null)!!)
        assertEquals(imageFolder.toString(), saved.optString("directory"))
        assertEquals(photo.toString(), saved.optString("storageFile"))
        assertEquals(local("Pictures/背景").toString(), saved.optString("storageDirectory"))
        assertEquals(local("Pictures/背景"),
            open(false).getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI))
    }

    @Test
    fun unreadableOriginalUsesPersistedStorageEvenWhenConversionBecomesUnavailable() {
        open(false)
        choose(image)
        mediaProvider.metadataAvailable = false
        entries.remove(image)
        assertEquals(local("Pictures/背景"),
            open(false).getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI))
        val saved = JSONObject(activity.getSharedPreferences("media_picker_locations", 0)
            .getString("images", null)!!)
        assertEquals(photo.toString(), saved.optString("storageFile"))
    }

    @Test
    fun unrestorableMediaDirectoryIsNotLaunchedBeforeItsStorageLocation() {
        open(false)
        choose(image)
        picker.close()
        val rejecting = Robolectric.buildActivity(RejectingOriginalActivity::class.java).setup().get()
        activity = rejecting
        picker = AndroidMediaPicker(activity, Executor { it.run() })
        val intent = open(false)
        assertEquals(0, rejecting.rejectedOriginals)
        assertEquals(local("Pictures/背景"),
            intent.getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI))
    }

    @Test
    fun missingOriginalParentMetadataUsesItsStorageEquivalent() {
        entries[image] = entries.getValue(image).copy(parentId = null)
        open(false)
        choose(image)
        assertEquals(local("Pictures/背景"),
            open(false).getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI))
    }

    @Test
    fun rejectedMediaDirectoryMustNotRestoreTheLastAudioDirectory() {
        open(false)
        choose(image)
        open(true)
        choose(nextAudio)
        val saved = JSONObject(activity.getSharedPreferences("media_picker_locations", 0)
            .getString("images", null)!!)
        assertEquals(image.toString(), saved.getString("file"))
        assertEquals(photo.toString(), saved.getString("storageFile"))
        assertTrue(activity.contentResolver.persistedUriPermissions.any {
            it.uri == image && it.isReadPermission
        })
        val intent = open(false)
        assertEquals(local("Pictures/背景"), systemDirectory(intent))
        assertFalse(lastResult.completed)
    }

    @Test
    fun rememberedStorageFolderSurvivesAStaleFileHint() {
        open(false)
        choose(image)
        open(true)
        choose(nextAudio)
        // A media ID can remain readable after the original filename changes.
        storageDocuments.unavailableDocuments.add(photo)
        assertEquals(local("Pictures/背景"), systemDirectory(open(false)))
    }

    @Test
    fun mediaNavigationDoesNotNeedARejectionCallbackAndCancellationDoesNotReopen() {
        open(false)
        choose(image)
        open(true)
        choose(nextAudio)
        val intent = open(false)
        assertEquals(local("Pictures/背景"),
            intent.getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI))
        assertEquals(local("Pictures/背景"), systemDirectory(intent))
        assertFalse(lastResult.completed)
        cancel()
        assertTrue(lastResult.completed)
        assertNull(lastResult.value)
        assertNull(shadowOf(activity).nextStartedActivityForResult)
    }

    @Test
    fun allLaunchFailuresCompleteTheRequestAndAllowRetry() {
        open(false)
        choose(image)
        picker.close()
        val rejecting = Robolectric.buildActivity(RejectingOriginalActivity::class.java).setup().get()
        rejecting.rejectAll = true
        activity = rejecting
        picker = AndroidMediaPicker(activity, Executor { it.run() })
        val failed = AndroidMediaPickerTest.CapturedResult()
        picker.pick(false, failed)
        assertEquals("media_pick_failed", failed.errorCode)
        rejecting.rejectAll = false
        assertEquals(local("Pictures/背景"),
            open(false).getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI))
    }

    @Test
    fun unavailableMediaMetadataUsesItsCategoryInsteadOfSharedDirectory() {
        mediaProvider.metadataAvailable = false
        open(false)
        choose(image)
        open(true)
        choose(audio)
        assertEquals(DocumentsContract.buildRootUri(MEDIA, "images_root"),
            systemDirectory(open(false)))
        cancel()
        open(true)
        choose(mediaAudio)
        open(false)
        choose(photo)
        assertEquals(DocumentsContract.buildRootUri(MEDIA, "audio_root"),
            systemDirectory(open(true)))
    }

    @Test
    fun temporaryMetadataFailurePreservesKnownMediaDirectory() {
        open(false)
        choose(image)
        mediaProvider.metadataAvailable = false
        open(true)
        choose(audio)
        assertEquals(local("Pictures/背景"), systemDirectory(open(false)))
    }

    @Test
    fun missingMediaFilePreservesItsKnownDirectory() {
        open(false)
        choose(image)
        entries.remove(image)
        open(true)
        choose(audio)
        assertEquals(local("Pictures/背景"), systemDirectory(open(false)))
    }

    @Test
    @Config(sdk = [28])
    fun olderAndroidUsesMediaRootWithoutRequestingStoragePermissions() {
        open(false)
        choose(image)
        open(true)
        choose(audio)
        assertEquals(DocumentsContract.buildRootUri(MEDIA, "images_root"),
            systemDirectory(open(false)))
    }

    data class Entry(val name: String, val relativePath: String,
        val volume: String = MediaStore.VOLUME_EXTERNAL_PRIMARY, val parentId: String? = "100")

    class RejectingOriginalActivity : Activity() {
        var rejectedOriginals = 0
        var rejectAll = false
        override fun startActivityForResult(intent: Intent, requestCode: Int) {
            if (rejectAll) throw IllegalStateException("Picker unavailable")
            val initial = intent.getParcelableExtra<Uri>(DocumentsContract.EXTRA_INITIAL_URI)
            if (initial?.authority == MEDIA) {
                rejectedOriginals++
                throw IllegalArgumentException("Original location rejected")
            }
            super.startActivityForResult(intent, requestCode)
        }
    }

    class NavigationProvider(
        private val entries: Map<Uri, Entry>, private val authority: String
    ) : ContentProvider() {
        var metadataAvailable = true
        val unavailableDocuments = mutableSetOf<Uri>()
        override fun onCreate() = true
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
            selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
            val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME)
            val entry = entries[uri] ?: when (uri.lastPathSegment) {
                "42" -> entries.values.first { it.name == "照片.png" }
                "43" -> entries[DocumentsContract.buildDocumentUri(MEDIA, "audio:43")]
                else -> null
            }
            return MatrixCursor(columns).apply {
                if (entry != null && (authority != MediaStore.AUTHORITY || metadataAvailable))
                    addRow(columns.map {
                        when (it) {
                            OpenableColumns.DISPLAY_NAME -> entry.name
                            MediaStore.MediaColumns.RELATIVE_PATH -> entry.relativePath
                            MediaStore.MediaColumns.VOLUME_NAME -> entry.volume
                            MediaStore.Images.ImageColumns.BUCKET_ID,
                            MediaStore.Audio.AudioColumns.ALBUM_ID -> entry.parentId
                            else -> null
                        }
                    }.toTypedArray())
            }
        }

        override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
            if (method == "get_media_uri" && authority == MediaStore.AUTHORITY) {
                val document = extras!!.getParcelable<Uri>("uri")!!
                val type = if (DocumentsContract.getDocumentId(document).startsWith("image:"))
                    "images" else "audio"
                return Bundle().apply {
                    putParcelable("uri", Uri.parse("content://media/external/$type/media/" +
                        DocumentsContract.getDocumentId(document).substringAfter(':')))
                }
            }
            if (method == "android:findDocumentPath" && authority == STORAGE) {
                val uri = extras!!.getParcelable<Uri>("uri")!!
                if (uri in unavailableDocuments) throw FileNotFoundException(uri.toString())
                val id = DocumentsContract.getDocumentId(uri)
                val parts = id.substringAfter(':').split('/')
                val path = listOf("primary:") + parts.indices.map {
                    "primary:" + parts.take(it + 1).joinToString("/")
                }
                return Bundle().apply { putParcelable("result", DocumentsContract.Path("primary", path)) }
            }
            throw UnsupportedOperationException(method)
        }

        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
            val file = File.createTempFile("navigation-source-", ".tmp", context!!.filesDir)
            file.writeBytes(byteArrayOf(1, 2, 3))
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        override fun getType(uri: Uri): String? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun update(uri: Uri, values: ContentValues?, selection: String?,
            selectionArgs: Array<out String>?) = 0
    }
}
