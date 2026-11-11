package com.codepup.workout_timer

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** The only persistent owner of browser preferences; timer media is stored separately. */
internal class MediaBrowserState(context: Context) {
    private val preferences = context.getSharedPreferences("media_browser", Context.MODE_PRIVATE)
    private fun key(audio: Boolean) = if (audio) "audio" else "images"

    fun record(audio: Boolean): Map<String, Any?> {
        val saved = json(preferences.getString(key(audio), null))
        return mapOf(
            "location" to (saved["location"] ?: mapOf("source" to "library", "directory" to "")),
            "file" to saved["file"], "name" to saved["name"],
            "sort" to (saved["sort"] ?: if (audio) "name" else "modified"),
            "ascending" to (saved["ascending"] ?: audio),
            "grid" to (saved["grid"] ?: !audio),
            "showNames" to (saved["showNames"] ?: true),
            "largePreviews" to (saved["largePreviews"] ?: false)
        )
    }

    fun saveView(audio: Boolean, sort: String, ascending: Boolean, grid: Boolean,
        showNames: Boolean = record(audio)["showNames"] as Boolean,
        largePreviews: Boolean = record(audio)["largePreviews"] as Boolean) {
        require(sort in listOf("name", "modified", "size"))
        save(audio, record(audio) + mapOf("sort" to sort, "ascending" to ascending, "grid" to grid,
            "showNames" to showNames, "largePreviews" to largePreviews))
    }

    fun remember(audio: Boolean, location: Map<String, Any?>, file: String, name: String) {
        save(audio, record(audio) + mapOf("location" to location, "file" to file, "name" to name))
    }

    fun folders(): List<Map<String, Any?>> = try {
        val array = JSONArray(preferences.getString("folders", "[]"))
        (0 until array.length()).map { json(array.getJSONObject(it).toString()) }
    } catch (_: Exception) { emptyList() }

    fun addFolder(tree: String, name: String) {
        val folders = folders().filterNot { it["tree"] == tree } + mapOf("tree" to tree, "name" to name)
        preferences.edit().putString("folders", JSONArray(folders).toString()).apply()
    }

    fun removeFolder(tree: String) {
        val edit = preferences.edit().putString("folders",
            JSONArray(folders().filterNot { it["tree"] == tree }).toString())
        for (audio in listOf(true, false)) {
            val saved = record(audio)
            val location = saved["location"] as? Map<*, *>
            if (location?.get("source") == "folders" && location["tree"] == tree) {
                edit.putString(key(audio), JSONObject(saved + mapOf(
                    "location" to mapOf("source" to "folders", "directory" to ""),
                    "file" to null, "name" to null
                )).toString())
            }
        }
        edit.apply()
    }

    fun asked(audio: Boolean) = preferences.getBoolean("asked_${key(audio)}", false)
    fun markAsked(audio: Boolean) { preferences.edit().putBoolean("asked_${key(audio)}", true).apply() }
    private fun save(audio: Boolean, value: Map<String, Any?>) {
        preferences.edit().putString(key(audio), JSONObject(value).toString()).apply()
    }

    companion object {
        private fun json(value: String?): Map<String, Any?> = try {
            val obj = JSONObject(value ?: "{}")
            obj.keys().asSequence().associateWith { convert(obj.get(it)) }
        } catch (_: Exception) { emptyMap() }

        private fun convert(value: Any?): Any? = when (value) {
            JSONObject.NULL -> null
            is JSONObject -> value.keys().asSequence().associateWith { convert(value.get(it)) }
            is JSONArray -> (0 until value.length()).map { convert(value.get(it)) }
            else -> value
        }
    }
}
