package com.codepup.workout_timer

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private var mediaPicker: AndroidMediaPicker? = null
    private var mediaPickerChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val picker = AndroidMediaPicker(this)
        mediaPicker = picker
        mediaPickerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "openhiit/media_picker"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "pickFile") {
                    picker.pick(call.argument<Boolean>("audio") == true, result)
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (mediaPicker?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        mediaPickerChannel?.setMethodCallHandler(null)
        mediaPickerChannel = null
        mediaPicker?.close()
        mediaPicker = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
