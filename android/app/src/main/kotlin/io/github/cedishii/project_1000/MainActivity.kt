package io.github.cedishii.project_1000

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * Adds one small native feature: "Save to device…", which lets the user
 * choose where a backup .zip or a Life Album PDF goes (Downloads, an SD
 * card, Google Drive, …) using Android's own save dialog. The file is
 * copied as a stream, so large files never need to fit in memory, and no
 * storage permission is required.
 */
class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingSource: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "saveAs") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingResult != null) {
                    result.error("busy", "A save is already in progress", null)
                    return@setMethodCallHandler
                }
                val source = call.argument<String>("source")
                val name = call.argument<String>("name")
                val mime = call.argument<String>("mime") ?: "application/zip"
                if (source == null || name == null) {
                    result.error("args", "source and name are required", null)
                    return@setMethodCallHandler
                }
                pendingResult = result
                pendingSource = source
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                startActivityForResult(intent, REQUEST_SAVE)
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_SAVE) return
        val result = pendingResult ?: return
        val source = pendingSource
        pendingResult = null
        pendingSource = null

        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || source == null) {
            result.success(false) // cancelled
            return
        }
        Thread {
            try {
                contentResolver.openOutputStream(uri, "w").use { out ->
                    requireNotNull(out) { "Could not open destination" }
                    FileInputStream(File(source)).use { input -> input.copyTo(out) }
                }
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread { result.error("io", e.message, null) }
            }
        }.start()
    }

    companion object {
        private const val CHANNEL = "project_1000/backup_file"
        private const val REQUEST_SAVE = 4100
    }
}
