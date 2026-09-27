package com.yang.epubtranslator

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.KeyStore
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingSaveCall: MethodCall? = null
    private var pendingSaveResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    /** Native-side backstop for pickEpubFile: cleared when the picker
     * returns, the activity is destroyed, or the picker can't open. */
    private var pickTimeoutCallback: Runnable? = null

    /**
     * Absolute paths of import targets that have been claimed (via
     * claimUniqueImportTarget) but whose copy hasn't finished yet. They are
     * legitimately zero bytes until the first chunk lands, so
     * cleanupZeroByteImports() must not touch them.
     */
    private val activeImportTargets: MutableSet<String> =
        Collections.synchronizedSet(mutableSetOf<String>())

    /**
     * Same idea as activeImportTargets, but for share staging claims: a
     * freshly claimed staging file is legitimately zero bytes until the
     * copy lands, so cleanupOldShareStaging() must not sweep it.
     */
    private val activeShareTargets: MutableSet<String> =
        Collections.synchronizedSet(mutableSetOf<String>())

    /**
     * Guards the Downloads save path against double-taps on Android 10+,
     * where no permission round-trip serializes the calls (the Android
     * 6-9 branch has its own pendingSaveResult guard). Set before the IO
     * work is queued, cleared when it finishes.
     */
    private val saveInFlight = AtomicBoolean(false)

    /** Serializes AndroidKeyStore key creation; concurrent generateKey() on
     * the same alias throws. */
    private val keyStoreLock = Any()

    /** Runs KeyStore/secret ops off the UI thread on a single background
     * thread: avoids unbounded thread creation and serializes reads and
     * writes of the same secret. Shut down in onDestroy. */
    private val secretExecutor = Executors.newSingleThreadExecutor()

    /** Runs file IO (import copy, Downloads save, share staging) on a
     * single background thread: avoids unbounded thread creation and
     * keeps IO serialized. Shut down in onDestroy. */
    private val ioExecutor = Executors.newSingleThreadExecutor()

    /**
     * Posts a MethodChannel reply on the UI thread. Background work must never
     * hold the Activity: it is posted via the main looper instead, and the
     * reply is dropped quietly if the engine is already gone (e.g. the
     * activity was destroyed while a large file was copying).
     */
    private fun replyOnUiThread(result: MethodChannel.Result, reply: () -> Unit) {
        mainHandler.post {
            try {
                reply()
            } catch (error: Exception) {
                Log.w(TAG, "Dropped platform reply after teardown: ${error.message}")
            }
        }
    }

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
                "startTranslationService" -> startTranslationService(call, result)
                "updateTranslationNotification" -> updateTranslationNotification(call, result)
                "stopTranslationService" -> stopTranslationService(result)
                "openAppSettings" -> openAppSettings(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun pickEpubFile(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("PICK_IN_PROGRESS", "An EPUB picker is already open.", null)
            return
        }

        // Drop zero-byte leftovers from imports that died mid-copy (e.g. the
        // app was killed). A valid EPUB is never empty, so this is safe.
        cleanupZeroByteImports()

        pendingPickResult = result
        // Native-side backstop for the Dart 5-minute timeout: if the user
        // only picks a file after the Dart side has already given up, the
        // copy must not run — its result would be dropped and the copied
        // file left behind as an orphan.
        val timeout = Runnable {
            val pending = pendingPickResult
            if (pending != null) {
                pendingPickResult = null
                pickTimeoutCallback = null
                pending.error(
                    "PICK_TIMEOUT",
                    "The file picker timed out after 5 minutes.",
                    null
                )
            }
        }
        pickTimeoutCallback = timeout
        mainHandler.postDelayed(timeout, PICK_TIMEOUT_MS)
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/epub+zip", "application/octet-stream")
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_EPUB)
        } catch (error: Exception) {
            // No app can handle the picker (e.g. stripped-down ROMs without
            // DocumentsUI). Clear the pending slot, otherwise every later
            // import would wrongly report PICK_IN_PROGRESS until the
            // process dies.
            cancelPickTimeout()
            pendingPickResult = null
            result.error(
                "PICK_NO_PICKER",
                "No app available to pick EPUB files: ${error.message}",
                null
            )
        }
    }

    private fun cancelPickTimeout() {
        pickTimeoutCallback?.let {
            mainHandler.removeCallbacks(it)
            pickTimeoutCallback = null
        }
    }

    @Deprecated("Deprecated in Android, still supported by FlutterActivity.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_EPUB) {
            return
        }
        cancelPickTimeout()

        val result = pendingPickResult ?: return
        pendingPickResult = null

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }

        val uri = data.data!!

        // Copying an EPUB can take a while for large books; keep it off the
        // UI thread so the app never hits an ANR while importing. The
        // display-name query runs here too: a slow document provider can
        // block inside contentResolver.query().
        //
        // Only the intent's one-shot read grant is used: the file is copied
        // immediately, so no persistable URI permission is taken (and none
        // needs releasing afterwards).
        ioExecutor.execute {
            try {
                val selectedName = queryDisplayName(uri)
                // Some document providers don't report a display name (or any
                // extension); fall back to the provider-declared MIME type,
                // then to the file's magic bytes, so a valid EPUB isn't
                // rejected just because the URI has no suffix.
                val mimeType = contentResolver.getType(uri)
                val looksLikeEpub = selectedName.endsWith(".epub", ignoreCase = true) ||
                    mimeType.equals("application/epub+zip", ignoreCase = true) ||
                    (selectedName.isBlank() && mimeType == null && hasZipMagicBytes(uri))
                if (!looksLikeEpub) {
                    replyOnUiThread(result) {
                        result.error(
                            "INVALID_FILE_TYPE",
                            "Please choose a file with the .epub extension.",
                            null
                        )
                    }
                    return@execute
                }
                val path = copyUriToAppFile(uri, selectedName)
                replyOnUiThread(result) { result.success(path) }
            } catch (error: Exception) {
                replyOnUiThread(result) { result.error("PICK_FAILED", error.message, null) }
            }
        }
    }

    /** Deletes zero-byte files left in imports/ by imports that died mid-copy.
     * Skips targets claimed by copies that are still running: they are
     * legitimately zero bytes until the first chunk lands.
     *
     * The remaining race — cleanup listing a file in the instant between
     * createNewFile() and the claim being registered — is harmless: the
     * copy thread opens FileOutputStream on the target right after, which
     * recreates a deleted file before writing a single byte. */
    private fun cleanupZeroByteImports() {
        try {
            File(filesDir, "imports").listFiles()?.forEach { file ->
                if (file.isFile && file.length() == 0L &&
                    file.absolutePath !in activeImportTargets
                ) {
                    file.delete()
                }
            }
        } catch (_: Exception) {
            // Best effort only; a failed cleanup must not block importing.
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
            try {
                requestPermissions(
                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    REQUEST_WRITE_DOWNLOADS
                )
            } catch (error: Exception) {
                // The activity may be in a state where no permission dialog
                // can be shown; don't leak the pending result (the Dart side
                // also has a timeout as a backstop).
                pendingSaveCall = null
                pendingSaveResult = null
                result.error(
                    "SAVE_FAILED",
                    "Unable to request storage permission: ${error.message}",
                    null
                )
            }
            return
        }

        performSaveToDownloads(call, result)
    }

    private fun performSaveToDownloads(call: MethodCall, result: MethodChannel.Result) {
        // Double-taps on the save button would otherwise queue two identical
        // saves (the Android 6-9 permission round-trip serializes them, but
        // Android 10+ reaches straight for the IO thread).
        if (!saveInFlight.compareAndSet(false, true)) {
            result.error(
                "SAVE_IN_PROGRESS",
                "A Downloads save is already in progress.",
                null
            )
            return
        }
        // Writing to Downloads can take a while for large books; keep it off
        // the UI thread so the app never hits an ANR while exporting.
        ioExecutor.execute {
            try {
                val sourcePath = call.argument<String>("sourcePath").orEmpty()
                val displayName = sanitizeFileName(call.argument<String>("displayName").orEmpty())
                val mimeType = call.argument<String>("mimeType") ?: "application/epub+zip"
                val savedPath = copyFileToDownloads(sourcePath, displayName, mimeType)
                replyOnUiThread(result) { result.success(savedPath) }
            } catch (error: Exception) {
                replyOnUiThread(result) { result.error("SAVE_FAILED", error.message, null) }
            } finally {
                saveInFlight.set(false)
            }
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
            if (!shouldShowRequestPermissionRationale(Manifest.permission.WRITE_EXTERNAL_STORAGE)) {
                // The user picked "Don't ask again": another request would be
                // silently denied, so point the Dart side at the system
                // settings page (openAppSettings) instead of retrying.
                result.error(
                    "PERMISSION_PERMANENTLY_DENIED",
                    "Storage permission was permanently denied. " +
                        "Grant it in the app settings to save to Downloads.",
                    null
                )
            } else {
                result.error(
                    "SAVE_PERMISSION_DENIED",
                    "Storage permission is required to save to Downloads on this Android version.",
                    null
                )
            }
            return
        }

        performSaveToDownloads(call, result)
    }

    override fun onDestroy() {
        // If the activity is destroyed while a picker/permission dialog is
        // open ("Don't keep activities", extreme memory pressure), the
        // recreated activity has no reference to the pending Dart call and
        // it would hang forever. Reply with an error so the Dart side can
        // move on (it also has a timeout as a backstop). Teardown-time
        // reply failures are swallowed: the engine may already be gone.
        // A pending picker timeout must not fire after teardown: the reply
        // would go nowhere and the runnable would leak with the looper.
        cancelPickTimeout()
        pendingPickResult?.let { pending ->
            pendingPickResult = null
            try {
                pending.error(
                    "ACTIVITY_DESTROYED",
                    "The activity was destroyed before the picker returned.",
                    null
                )
            } catch (_: Exception) {
            }
        }
        pendingSaveResult?.let { pending ->
            pendingSaveResult = null
            pendingSaveCall = null
            try {
                pending.error(
                    "ACTIVITY_DESTROYED",
                    "The activity was destroyed before the permission result returned.",
                    null
                )
            } catch (_: Exception) {
            }
        }
        secretExecutor.shutdown()
        // Queued IO finishes; only new submissions are rejected.
        ioExecutor.shutdown()
        super.onDestroy()
    }

    private fun shareFile(call: MethodCall, result: MethodChannel.Result) {
        // Capture the application context up front: the worker thread must
        // not hold the Activity, which may be destroyed while a large book
        // is being staged.
        val appContext = applicationContext
        val chooserTitle = call.argument<String>("chooserTitle")
            ?.takeIf { it.isNotBlank() } ?: "Share EPUB"
        // Staging the share copy can take a while for large books; keep it
        // off the UI thread so the app never hits an ANR while sharing.
        ioExecutor.execute {
            try {
                val sourcePath = call.argument<String>("sourcePath").orEmpty()
                val displayName = sanitizeFileName(call.argument<String>("displayName").orEmpty())
                val mimeType = call.argument<String>("mimeType") ?: "application/epub+zip"
                val source = File(sourcePath)
                require(source.exists()) { "Source file does not exist: $sourcePath" }

                // Stage copies in a dedicated subdir (covered by the
                // FileProvider <cache-path>) and sweep stale copies so they
                // don't accumulate forever.
                val stagingDir = File(appContext.cacheDir, "share_staging").apply { mkdirs() }
                cleanupOldShareStaging(stagingDir)
                val shareFile = if (displayName.isBlank() || source.name == displayName) {
                    source
                } else {
                    // Claim a uniquely-named staging file per share. The
                    // chooser stays open after this worker thread finishes
                    // and the target app reads the file asynchronously
                    // afterwards; a later share of the same display name
                    // claims a different name, so it can never overwrite
                    // this file mid-read. createNewFile() is atomic
                    // (O_CREAT|O_EXCL), so two racing shares can never
                    // claim the same path.
                    val target = claimUniqueImportTarget(stagingDir, displayName)
                    // Mark the claim as in-flight: it is legitimately zero
                    // bytes until the first chunk lands, and the sweep above
                    // must not mistake it for an orphan.
                    activeShareTargets.add(target.absolutePath)
                    try {
                        source.copyTo(target, overwrite = true)
                    } catch (error: Exception) {
                        // Don't leave a truncated staging file behind.
                        target.delete()
                        throw error
                    } finally {
                        activeShareTargets.remove(target.absolutePath)
                    }
                    target
                }
                mainHandler.post {
                    try {
                        val uri = FileProvider.getUriForFile(
                            appContext,
                            "${appContext.packageName}.fileprovider",
                            shareFile
                        )
                        val shareIntent = Intent(Intent.ACTION_SEND).apply {
                            type = mimeType
                            putExtra(Intent.EXTRA_STREAM, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        appContext.startActivity(
                            Intent.createChooser(shareIntent, chooserTitle).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                        )
                        result.success(null)
                    } catch (error: Exception) {
                        try {
                            result.error("SHARE_FAILED", error.message, null)
                        } catch (_: Exception) {
                            Log.w(TAG, "Dropped share reply after teardown.")
                        }
                    }
                }
            } catch (error: Exception) {
                replyOnUiThread(result) { result.error("SHARE_FAILED", error.message, null) }
            }
        }
    }

    /**
     * Deletes share staging copies older than 7 days, then enforces a
     * count/size cap (newest files win, oldest evicted first) so rapid
     * shares can't pile up unbounded inside the 7-day window. Best effort
     * only: a failed cleanup must not block sharing.
     */
    private fun cleanupOldShareStaging(stagingDir: File) {
        try {
            val now = System.currentTimeMillis()
            // Drop zero-byte orphans: a claim whose copy died mid-flight
            // (e.g. the process was killed) leaves an empty file that
            // would otherwise squat the original name — and force a "(2)"
            // suffix on the next same-name share — until the 7-day sweep.
            // Skip files younger than the grace period: an in-flight
            // share's claim is legitimately zero bytes until the first
            // chunk lands. Also skip claims registered in
            // activeShareTargets: same-millisecond clock granularity must
            // never let the sweep win over a live claim.
            stagingDir.listFiles()?.forEach { file ->
                if (file.isFile && file.length() == 0L &&
                    file.absolutePath !in activeShareTargets &&
                    now - file.lastModified() >= SHARE_STAGING_CAP_GRACE_MS
                ) {
                    file.delete()
                }
            }
            val files = stagingDir.listFiles()?.filter { it.isFile }?.toMutableList()
                ?: return
            files.filter { it.lastModified() < now - SHARE_STAGING_MAX_AGE_MS }
                .forEach { it.delete() }
            // Files younger than the grace period may still have their
            // chooser open (the target app reads asynchronously), so only
            // cap-evict files old enough to be safely dead.
            val evictable = files
                .filter { it.exists() && now - it.lastModified() >= SHARE_STAGING_CAP_GRACE_MS }
                .sortedBy { it.lastModified() }
            var totalBytes = evictable.sumOf { it.length() }
            var count = evictable.size
            for (file in evictable) {
                if (count <= MAX_SHARE_STAGING_FILES && totalBytes <= MAX_SHARE_STAGING_BYTES) {
                    break
                }
                val size = file.length()
                if (!file.delete()) {
                    break
                }
                totalBytes -= size
                count -= 1
            }
        } catch (_: Exception) {
            // A failed cleanup must not block sharing.
        }
    }

    private fun copyUriToAppFile(uri: Uri, displayName: String): String {
        var safeName = sanitizeFileName(displayName)
        if (!safeName.contains('.')) {
            // Some document providers report no display name, leaving only a
            // bare document id with no extension. The picker was opened for
            // EPUBs, so assume .epub instead of producing a file the app
            // would later reject for missing its suffix.
            safeName += ".epub"
        }
        val importsDir = File(filesDir, "imports").apply { mkdirs() }
        // Atomically claim a unique target: createNewFile() only succeeds for
        // the thread that wins the race, so two concurrent imports of the
        // same file name can never end up writing to the same path.
        val target = claimUniqueImportTarget(importsDir, safeName)
        // Mark the claim as in-flight so a second import's
        // cleanupZeroByteImports() doesn't mistake it for a leftover.
        activeImportTargets.add(target.absolutePath)
        try {
            contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "Unable to open selected EPUB." }
                FileOutputStream(target).use { output -> input.copyTo(output) }
            }
        } catch (error: Exception) {
            // Don't leave a zero-byte claim behind on failure.
            target.delete()
            throw error
        } finally {
            activeImportTargets.remove(target.absolutePath)
        }
        return target.absolutePath
    }

    private fun claimUniqueImportTarget(directory: File, fileName: String): File {
        val dotIndex = fileName.lastIndexOf('.')
        val baseName = if (dotIndex > 0) fileName.substring(0, dotIndex) else fileName
        val extension = if (dotIndex > 0) fileName.substring(dotIndex) else ""
        var counter = 1
        while (true) {
            val candidate = if (counter <= 1) {
                File(directory, fileName)
            } else {
                File(directory, "$baseName ($counter)$extension")
            }
            // createNewFile() is atomic (O_CREAT|O_EXCL): exactly one racing
            // thread gets `true`. An IOException (e.g. unwritable dir)
            // propagates to the caller instead of looping forever.
            if (candidate.createNewFile()) {
                return candidate
            }
            counter += 1
        }
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
            // Best-effort sweep of this app's own orphaned IS_PENDING=1
            // entries (e.g. the process died between writing the file and
            // flipping the flag). They are invisible and can never be
            // completed or removed by hand. Never blocks the save.
            cleanupStalePendingDownloads()
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
                try {
                    contentResolver.delete(uri, null, null)
                } catch (_: Exception) {
                    // Deleting the half-written entry is best effort; the
                    // original failure is what must surface.
                }
                throw error
            }
        }

        val downloads = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )
        downloads.mkdirs()
        // Never silently overwrite an existing file in Downloads; claim a
        // unique name atomically, same as the imports/ flow above.
        val target = claimUniqueImportTarget(downloads, safeName)
        try {
            source.copyTo(target, overwrite = true)
        } catch (error: Exception) {
            // Don't leave a truncated file in Downloads.
            target.delete()
            throw error
        }
        return target.absolutePath
    }

    /**
     * Deletes this app's own MediaStore Downloads entries that are stuck at
     * IS_PENDING=1 and older than STALE_PENDING_DOWNLOADS_MS — orphans left
     * behind when the process died between writing the file and clearing
     * the pending flag. Such entries are invisible to the user and can
     * never be completed. Best effort only.
     */
    private fun cleanupStalePendingDownloads() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return
        }
        try {
            val cutoffSec = (System.currentTimeMillis() - STALE_PENDING_DOWNLOADS_MS) / 1000
            contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.DATE_ADDED),
                "${MediaStore.Downloads.IS_PENDING} = 1 AND " +
                    "${MediaStore.Downloads.OWNER_PACKAGE_NAME} = ?",
                arrayOf(packageName),
                null
            )?.use { cursor ->
                val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Downloads._ID)
                val dateIndex = cursor.getColumnIndex(MediaStore.Downloads.DATE_ADDED)
                val staleIds = mutableListOf<Long>()
                while (cursor.moveToNext()) {
                    val dateAddedSec = if (dateIndex >= 0) cursor.getLong(dateIndex) else 0L
                    // dateAddedSec <= 0 means the provider didn't report a
                    // date; don't assume such entries are stale.
                    if (dateAddedSec > 0 && dateAddedSec < cutoffSec) {
                        staleIds.add(cursor.getLong(idIndex))
                    }
                }
                for (id in staleIds) {
                    try {
                        contentResolver.delete(
                            ContentUris.withAppendedId(
                                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                                id
                            ),
                            null,
                            null
                        )
                    } catch (_: Exception) {
                        // One bad entry must not stop the sweep.
                    }
                }
            }
        } catch (_: Exception) {
            // A failed sweep must not block saving.
        }
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

    /**
     * Last-resort EPUB check for document providers that report neither a
     * display name nor a MIME type: an EPUB is a ZIP archive, so its first
     * four bytes are PK\x03\x04.
     */
    private fun hasZipMagicBytes(uri: Uri): Boolean {
        return try {
            contentResolver.openInputStream(uri).use { input ->
                if (input == null) {
                    return@use false
                }
                val header = ByteArray(4)
                var read = 0
                while (read < 4) {
                    val n = input.read(header, read, 4 - read)
                    if (n <= 0) {
                        break
                    }
                    read += n
                }
                read == 4 &&
                    header[0] == 0x50.toByte() &&
                    header[1] == 0x4B.toByte() &&
                    header[2] == 0x03.toByte() &&
                    header[3] == 0x04.toByte()
            }
        } catch (_: Exception) {
            false
        }
    }

    /** Runs a KeyStore/secret op off the UI thread and replies on it. */
    private fun runSecretOp(
        result: MethodChannel.Result,
        errorCode: String,
        op: () -> Any?,
    ) {
        secretExecutor.execute {
            try {
                val value = op()
                replyOnUiThread(result) { result.success(value) }
            } catch (error: Exception) {
                replyOnUiThread(result) { result.error(errorCode, error.message, null) }
            }
        }
    }

    private fun readSecret(call: MethodCall, result: MethodChannel.Result) {
        // KeyStore unlock + AES-GCM can block (first unlock may prompt the
        // keystore daemon); never do it on the platform thread.
        runSecretOp(result, "SECRET_READ_FAILED") {
            val name = sanitizeSecretName(call.argument<String>("name").orEmpty())
            val prefs = getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
            val iv = prefs.getString("${name}_iv", null)
            val encrypted = prefs.getString("${name}_value", null)
            if (iv.isNullOrBlank() || encrypted.isNullOrBlank()) {
                return@runSecretOp null
            }
            val cipher = Cipher.getInstance(SECRET_TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateSecretKey(),
                GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP))
            )
            val decrypted = cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP))
            String(decrypted, Charsets.UTF_8)
        }
    }

    private fun writeSecret(call: MethodCall, result: MethodChannel.Result) {
        runSecretOp(result, "SECRET_WRITE_FAILED") {
            val name = sanitizeSecretName(call.argument<String>("name").orEmpty())
            val value = call.argument<String>("value").orEmpty()
            if (value.isBlank()) {
                deleteSecretValues(name)
                return@runSecretOp null
            }
            val cipher = Cipher.getInstance(SECRET_TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
            val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString("${name}_iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .putString("${name}_value", Base64.encodeToString(encrypted, Base64.NO_WRAP))
                .apply()
            null
        }
    }

    private fun deleteSecret(call: MethodCall, result: MethodChannel.Result) {
        runSecretOp(result, "SECRET_DELETE_FAILED") {
            val name = sanitizeSecretName(call.argument<String>("name").orEmpty())
            deleteSecretValues(name)
            null
        }
    }

    private fun deleteSecretValues(name: String) {
        getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove("${name}_iv")
            .remove("${name}_value")
            .apply()
    }

    /** Opens the app's system settings page, so the user can grant a
     * permanently-denied permission by hand. */
    private fun openAppSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null)
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error(
                "OPEN_SETTINGS_FAILED",
                "Unable to open app settings: ${error.message}",
                null
            )
        }
    }

    /**
     * Starts the translation foreground service so long translations
     * survive the app going to the background (Doze / process trimming).
     * On Android 13+ the notification permission is requested first, but
     * the service starts regardless: the translation itself must never be
     * blocked on that permission.
     */
    private fun startTranslationService(call: MethodCall, result: MethodChannel.Result) {
        val title = call.argument<String>("title")?.takeIf { it.isNotBlank() }
            ?: "EPUB Translator"
        val text = call.argument<String>("text").orEmpty()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            try {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    REQUEST_POST_NOTIFICATIONS
                )
            } catch (_: Exception) {
                // A failed request must not block the service start below.
            }
        }
        try {
            val intent = Intent(this, TranslationForegroundService::class.java).apply {
                putExtra(TranslationForegroundService.EXTRA_TITLE, title)
                putExtra(TranslationForegroundService.EXTRA_TEXT, text)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            result.success(null)
        } catch (error: Exception) {
            result.error(
                "START_SERVICE_FAILED",
                "Unable to start translation service: ${error.message}",
                null
            )
        }
    }

    /** Forwards a progress update to the foreground service's notification.
     * Safe to call when the service isn't running: the values are stashed
     * and applied on the next start. */
    private fun updateTranslationNotification(call: MethodCall, result: MethodChannel.Result) {
        val progress = (call.argument<Int>("progress") ?: 0).coerceIn(0, 100)
        val text = call.argument<String>("text").orEmpty()
        TranslationForegroundService.updateNotification(progress, text)
        result.success(null)
    }

    private fun stopTranslationService(result: MethodChannel.Result) {
        try {
            stopService(Intent(this, TranslationForegroundService::class.java))
            result.success(null)
        } catch (error: Exception) {
            result.error(
                "STOP_SERVICE_FAILED",
                "Unable to stop translation service: ${error.message}",
                null
            )
        }
    }

    private fun getOrCreateSecretKey(): SecretKey = synchronized(keyStoreLock) {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keyStore.getEntry(SECRET_KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        if (existing != null) {
            return@synchronized existing.secretKey
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
        return@synchronized keyGenerator.generateKey()
    }

    private fun sanitizeSecretName(name: String): String {
        val sanitized = name.replace(Regex("[^A-Za-z0-9_.-]"), "_").trim('_', '.', '-')
        return sanitized.ifBlank { "secret" }
    }

    private fun sanitizeFileName(name: String): String {
        val sanitized = name.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim()
        // "." and ".." survive the character filter but are directory
        // references, not file names; fall back to the default instead of
        // resolving against the staging/downloads directory.
        if (sanitized.isBlank() || sanitized == "." || sanitized == "..") {
            return "translated.epub"
        }
        return truncateFileNameBytes(sanitized)
    }

    /**
     * Truncates a file name to MAX_FILE_NAME_BYTES UTF-8 bytes: a single
     * path component is capped at 255 bytes on ext4, and an overlong name
     * would otherwise fail deep inside MediaStore with PICK_FAILED. The
     * cut never splits a multi-byte character (it backs off to the last
     * complete character), and the extension is preserved when it is short
     * enough to be worth keeping.
     */
    private fun truncateFileNameBytes(name: String): String {
        val bytes = name.toByteArray(Charsets.UTF_8)
        if (bytes.size <= MAX_FILE_NAME_BYTES) {
            return name
        }
        val dot = name.lastIndexOf('.')
        val suffix = if (dot > 0) name.substring(dot) else ""
        val suffixBytes = suffix.toByteArray(Charsets.UTF_8).size
        if (suffixBytes > MAX_FILE_NAME_BYTES / 2) {
            // Pathological "extension": not worth preserving, just cut.
            return cutUtf8Bytes(bytes, MAX_FILE_NAME_BYTES)
        }
        val baseBudget = (MAX_FILE_NAME_BYTES - suffixBytes).coerceAtLeast(1)
        return cutUtf8Bytes(bytes, baseBudget) + suffix
    }

    /** Cuts a UTF-8 byte array to at most [maxBytes] bytes, backing off to
     * the last complete character so no multi-byte sequence is split. */
    private fun cutUtf8Bytes(bytes: ByteArray, maxBytes: Int): String {
        var cut = maxBytes.coerceAtMost(bytes.size)
        // 0x80..0xBF are UTF-8 continuation bytes: a cut ending on one
        // would split a character, so walk back to the leading byte.
        while (cut > 0 && (bytes[cut - 1].toInt() and 0xC0) == 0x80) {
            cut--
        }
        if (cut <= 0) {
            cut = 1
        }
        return String(bytes, 0, cut, Charsets.UTF_8)
    }

    private fun requiresLegacyDownloadsWritePermission(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
    }

    companion object {
        private const val TAG = "EpubTranslator"
        private const val REQUEST_PICK_EPUB = 6001
        private const val REQUEST_WRITE_DOWNLOADS = 6002
        private const val REQUEST_POST_NOTIFICATIONS = 6003
        /** Native-side backstop matching the Dart 5-minute picker timeout. */
        private const val PICK_TIMEOUT_MS = 5L * 60 * 1000
        /** File names are truncated to this many UTF-8 bytes (ext4 caps a
         * single path component at 255). */
        private const val MAX_FILE_NAME_BYTES = 200
        private const val SECURE_PREFS_NAME = "secure_secrets"
        private const val SECRET_KEY_ALIAS = "epub_translator_secure_settings"
        private const val SECRET_TRANSFORMATION = "AES/GCM/NoPadding"
        /** Share staging files older than this are swept unconditionally. */
        private const val SHARE_STAGING_MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000
        /** Cap for share_staging/: newest files win, oldest evicted first. */
        private const val MAX_SHARE_STAGING_FILES = 20
        private const val MAX_SHARE_STAGING_BYTES = 200L * 1024 * 1024
        /** Staging files younger than this are exempt from the count/size
         * cap: their chooser may still be open and the target app may not
         * have read the file yet. */
        private const val SHARE_STAGING_CAP_GRACE_MS = 5L * 60 * 1000
        /** MediaStore Downloads entries stuck at IS_PENDING=1 older than
         * this are treated as orphans of a killed save and deleted. */
        private const val STALE_PENDING_DOWNLOADS_MS = 60L * 60 * 1000
    }
}
