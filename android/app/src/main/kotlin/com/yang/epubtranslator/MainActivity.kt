package com.yang.epubtranslator

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.OpenableColumns
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "epub_translator_flutter/android_export"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "appDocumentsDirectory" -> result.success(filesDir.absolutePath)
                "pickEpubFile" -> pickEpubFile(result)
                "saveToDownloads" -> saveToDownloads(call, result)
                "shareFile" -> shareFile(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun pickEpubFile(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("PICK_IN_PROGRESS", "An EPUB picker is already open.", null)
            return
        }

        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/epub+zip", "application/octet-stream")
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_PICK_EPUB)
    }

    @Deprecated("Deprecated in Android, still supported by FlutterActivity.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_EPUB) {
            return
        }

        val result = pendingPickResult ?: return
        pendingPickResult = null

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }

        try {
            val uri = data.data!!
            val flags = data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
            try {
                contentResolver.takePersistableUriPermission(uri, flags)
            } catch (_: SecurityException) {
                // Some document providers do not offer persistable permissions.
            }
            val selectedName = queryDisplayName(uri)
            if (!selectedName.endsWith(".epub", ignoreCase = true)) {
                result.error(
                    "INVALID_FILE_TYPE",
                    "Please choose a file with the .epub extension.",
                    null
                )
                return
            }
            result.success(copyUriToAppFile(uri, selectedName))
        } catch (error: Exception) {
            result.error("PICK_FAILED", error.message, null)
        }
    }

    private fun saveToDownloads(call: MethodCall, result: MethodChannel.Result) {
        try {
            val sourcePath = call.argument<String>("sourcePath").orEmpty()
            val displayName = sanitizeFileName(call.argument<String>("displayName").orEmpty())
            val mimeType = call.argument<String>("mimeType") ?: "application/epub+zip"
            result.success(copyFileToDownloads(sourcePath, displayName, mimeType))
        } catch (error: Exception) {
            result.error("SAVE_FAILED", error.message, null)
        }
    }

    private fun shareFile(call: MethodCall, result: MethodChannel.Result) {
        try {
            val sourcePath = call.argument<String>("sourcePath").orEmpty()
            val displayName = sanitizeFileName(call.argument<String>("displayName").orEmpty())
            val mimeType = call.argument<String>("mimeType") ?: "application/epub+zip"
            val source = File(sourcePath)
            require(source.exists()) { "Source file does not exist: $sourcePath" }

            val shareFile = if (displayName.isBlank() || source.name == displayName) {
                source
            } else {
                File(cacheDir, displayName).also { target ->
                    source.copyTo(target, overwrite = true)
                }
            }
            val uri = FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                shareFile
            )
            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(shareIntent, "Share EPUB"))
            result.success(null)
        } catch (error: Exception) {
            result.error("SHARE_FAILED", error.message, null)
        }
    }

    private fun copyUriToAppFile(uri: Uri, displayName: String): String {
        val safeName = sanitizeFileName(displayName)
        val target = File(filesDir, "imports/$safeName")
        target.parentFile?.mkdirs()
        contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Unable to open selected EPUB." }
            FileOutputStream(target).use { output -> input.copyTo(output) }
        }
        return target.absolutePath
    }

    private fun copyFileToDownloads(
        sourcePath: String,
        displayName: String,
        mimeType: String
    ): String {
        val source = File(sourcePath)
        require(source.exists()) { "Source file does not exist: $sourcePath" }
        val safeName = sanitizeFileName(displayName.ifBlank { source.name })

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, safeName)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = requireNotNull(
                contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ) { "Unable to create Downloads entry." }
            try {
                contentResolver.openOutputStream(uri).use { output ->
                    requireNotNull(output) { "Unable to write Downloads entry." }
                    FileInputStream(source).use { input -> input.copyTo(output) }
                }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                return "Downloads/$safeName"
            } catch (error: Exception) {
                contentResolver.delete(uri, null, null)
                throw error
            }
        }

        val downloads = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )
        downloads.mkdirs()
        val target = File(downloads, safeName)
        source.copyTo(target, overwrite = true)
        return target.absolutePath
    }

    private fun queryDisplayName(uri: Uri): String {
        contentResolver.query(uri, null, null, null, null).use { cursor ->
            if (cursor != null && cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    return cursor.getString(index).orEmpty()
                }
            }
        }
        return uri.lastPathSegment.orEmpty()
    }

    private fun sanitizeFileName(name: String): String {
        val sanitized = name.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim()
        return sanitized.ifBlank { "translated.epub" }
    }

    companion object {
        private const val REQUEST_PICK_EPUB = 6001
    }
}
