package com.codepup.workout_timer

import android.app.Activity
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class MediaPickerNavigationTest {
    private lateinit var activity: Activity
    private lateinit var state: MediaBrowserState
    @Before fun setUp() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        activity.getSharedPreferences("media_browser", 0).edit().clear().commit()
        state = MediaBrowserState(activity)
    }

    @Test fun defaultsAreIndependentAndLibraryIsTheInitialSource() {
        assertEquals("name", state.record(true)["sort"])
        assertEquals(true, state.record(true)["ascending"])
        assertEquals(false, state.record(true)["grid"])
        assertEquals("modified", state.record(false)["sort"])
        assertEquals(false, state.record(false)["ascending"])
        assertEquals(true, state.record(false)["grid"])
        assertEquals(true, state.record(false)["showNames"])
        assertEquals(false, state.record(false)["largePreviews"])
        assertEquals(mapOf("source" to "library", "directory" to ""), state.record(false)["location"])
    }

    @Test fun alternatingSelectionsAndViewChangesSurviveOwnerRecreation() {
        val image = mapOf<String, Any?>("source" to "library", "directory" to "external_primary/Pictures/")
        val audio = mapOf<String, Any?>("source" to "folders", "tree" to "tree:a",
            "trail" to listOf(mapOf("id" to "opaque", "name" to "Child")))
        state.remember(false, image, "image", "背景.png")
        state.remember(true, audio, "audio", "声音.mp3")
        state.saveView(false, "size", true, false)
        val restored = MediaBrowserState(activity)
        assertEquals(image, restored.record(false)["location"])
        assertEquals(audio, restored.record(true)["location"])
        assertEquals("image", restored.record(false)["file"])
        assertEquals("size", restored.record(false)["sort"])
        assertEquals(false, restored.record(false)["grid"])
        assertEquals("name", restored.record(true)["sort"])
    }

    @Test fun displayPreferencesPersistWithoutConfirmingAnyFile() {
        val old = state.record(true)["location"]
        state.saveView(true, "modified", false, true)
        assertEquals(old, MediaBrowserState(activity).record(true)["location"])
        assertNull(state.record(true)["file"])
        assertEquals(true, state.record(true)["grid"])
    }

    @Test fun imagePreviewPreferencesSurviveRecreationAndOtherViewChanges() {
        state.saveView(false, "modified", false, true, showNames = false, largePreviews = true)
        state.saveView(false, "name", true, false)
        val restored = MediaBrowserState(activity)
        assertEquals(false, restored.record(false)["showNames"])
        assertEquals(true, restored.record(false)["largePreviews"])
        assertEquals(true, restored.record(true)["showNames"])
        assertEquals(false, restored.record(true)["largePreviews"])
        assertNull(restored.record(false)["file"])
    }

    @Test fun oldRecordsReceivePreviewDefaultsWithoutLosingTheirLocation() {
        activity.getSharedPreferences("media_browser", 0).edit().putString("images",
            """{"location":{"source":"library","directory":"external_primary/Pictures/"},"grid":true,"file":"original"}""").commit()
        assertEquals(true, state.record(false)["showNames"])
        assertEquals(false, state.record(false)["largePreviews"])
        assertEquals("original", state.record(false)["file"])
    }

    @Test fun sharedFolderListIsDurableAndDuplicateAuthorizationDoesNotDuplicateEntries() {
        state.addFolder("tree:a", "One")
        state.addFolder("tree:b", "Two")
        state.addFolder("tree:a", "Renamed")
        val restored = MediaBrowserState(activity)
        assertEquals(2, restored.folders().size)
        assertEquals("Renamed", restored.folders().single { it["tree"] == "tree:a" }["name"])
    }

    @Test fun intentionalRemovalResetsOnlyAffectedLocationsAndPreservesDisplayPreferences() {
        state.addFolder("tree:a", "One")
        state.addFolder("tree:b", "Two")
        val one = mapOf<String, Any?>("source" to "folders", "tree" to "tree:a")
        val two = mapOf<String, Any?>("source" to "folders", "tree" to "tree:b")
        state.remember(true, one, "a", "a.mp3")
        state.remember(false, two, "b", "b.png")
        state.saveView(true, "size", false, true)
        state.removeFolder("tree:a")
        assertEquals(mapOf("source" to "folders", "directory" to ""), state.record(true)["location"])
        assertNull(state.record(true)["file"])
        assertEquals("size", state.record(true)["sort"])
        assertEquals(true, state.record(true)["grid"])
        assertEquals(two, state.record(false)["location"])
        assertEquals("b", state.record(false)["file"])
        assertEquals(1, state.folders().size)
    }

    @Test fun missingPermissionDoesNotEraseRememberedLocationOrOriginalName() {
        val location = mapOf<String, Any?>("source" to "library", "directory" to "external_primary/Pictures/")
        state.remember(false, location, "original", "原图.png")
        state.markAsked(false)
        val restored = MediaBrowserState(activity)
        assertTrue(restored.asked(false))
        assertEquals(location, restored.record(false)["location"])
        assertEquals("原图.png", restored.record(false)["name"])
    }
}
