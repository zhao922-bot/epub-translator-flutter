package com.yang.epubtranslator

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingSaveCall: MethodCall? = null
    private var pendingSaveResult: MethodChannel.Result? = null

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
                "readSecret" -> readSecret(call, result)
                "writeSecret" -> writeSecret(call, result)
                "deleteSecret" -> deleteSecret(call, result)
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
        if (
            requiresLegacyDownloadsWritePermission() &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            if (pendingSaveResult != null) {
                result.error("SAVE_IN_PROGRESS", "A Downloads save is already pending.", null)
                return
            }
            pendingSaveCall = call
            pendingSaveResult = result
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                REQUEST_WRITE_DOWNLOADS
            )
            return
        }

        performSaveToDownloads(call, result)
    }

    private fun performSaveToDownloads(call: MethodCall, result: MethodChannel.Result) {
        try {
            val sourcePath = call.argument<String>("sourcePath").orEmpty()
            val displayName = sanitizeFileName(call.argument<String>("displayName").orEmpty())
            val mimeType = call.argument<String>("mimeType") ?: "application/epub+zip"
            result.success(copyFileToDownloads(sourcePath, displayName, mimeType))
        } catch (error: Exception) {
            result.error("SAVE_FAILED", error.message, null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_WRITE_DOWNLOADS) {
            return
        }

        val result = pendingSaveResult ?: return
        val call = pendingSaveCall
        pendingSaveCall = null
        pendingSaveResult = null

        if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED || call == null) {
            result.error(
                "SAVE_PERMISSION_DENIED",
                "Storage permission is required to save to Downloads on this Android version.",
                null
            )
            return
        }

        performSaveToDownloads(call, result)
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

    private fun readSecret(call: MethodCall, result: MethodChannel.Result) {
        try {
            val name = sanitizeSecretName(call.argument<String>("name").orEmpty())
            val prefs = getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
            val iv = prefs.getString("${name}_iv", null)
            val encrypted = prefs.getString("${name}_value", null)
            if (iv.isNullOrBlank() || encrypted.isNullOrBlank()) {
                result.success(null)
                return
            }
            val cipher = Cipher.getInstance(SECRET_TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateSecretKey(),
                GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP))
            )
            val decrypted = cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP))
            result.success(String(decrypted, Charsets.UTF_8))
        } catch (error: Exception) {
            result.error("SECRET_READ_FAILED", error.message, null)
        }
    }

    private fun writeSecret(call: MethodCall, result: MethodChannel.Result) {
        try {
            val name = sanitizeSecretName(call.argument<String>("name").orEmpty())
            val value = call.argument<String>("value").orEmpty()
            if (value.isBlank()) {
                deleteSecret(call, result)
                return
            }
            val cipher = Cipher.getInstance(SECRET_TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
            val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString("${name}_iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .putString("${name}_value", Base64.encodeToString(encrypted, Base64.NO_WRAP))
                .apply()
            result.success(null)
        } catch (error: Exception) {
            result.error("SECRET_WRITE_FAILED", error.message, null)
        }
    }

    private fun deleteSecret(call: MethodCall, result: MethodChannel.Result) {
        try {
            val name = sanitizeSecretName(call.argument<String>("name").orEmpty())
            getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .remove("${name}_iv")
                .remove("${name}_value")
                .apply()
            result.success(null)
        } catch (error: Exception) {
            result.error("SECRET_DELETE_FAILED", error.message, null)
        }
    }

    private fun getOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keyStore.getEntry(SECRET_KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        if (existing != null) {
            return existing.secretKey
        }

        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore"
        )
        val keySpec = KeyGenParameterSpec.Builder(
            SECRET_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build()
        keyGenerator.init(keySpec)
        return keyGenerator.generateKey()
    }

    private fun sanitizeSecretName(name: String): String {
        val sanitized = name.replace(Regex("[^A-Za-z0-9_.-]"), "_").trim('_', '.', '-')
        return sanitized.ifBlank { "secret" }
    }

    private fun sanitizeFileName(name: String): String {
        val sanitized = name.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim()
        return sanitized.ifBlank { "translated.epub" }
    }

    private fun requiresLegacyDownloadsWritePermission(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
    }

    companion object {
        private const val REQUEST_PICK_EPUB = 6001
        private const val REQUEST_WRITE_DOWNLOADS = 6002
        private const val SECURE_PREFS_NAME = "secure_secrets"
        private const val SECRET_KEY_ALIAS = "epub_translator_secure_settings"
        private const val SECRET_TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
