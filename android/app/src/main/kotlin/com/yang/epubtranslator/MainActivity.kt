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
import android.os.SystemClock
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
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
import java.io.InputStream
import java.security.KeyStore
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    /**
     * One pickEpubFile import attempt: the watchdog is armed per attempt and
     * always acts on the attempt's identity — never on [pendingPick], which
     * is cleared when the picker returns while the copy keeps running.
     * Without this, a copy wedged in a provider IPC call before registering
     * its stream (queryDisplayName, getType, the magic-bytes probe,
     * querySourceSize, openInputStream) never got its executor replaced,
     * because the old watchdog keyed the replacement off the (already
     * cleared) pending result.
     */
    private class ImportAttempt(
        val id: Int,
        val result: MethodChannel.Result,
    ) {
        /**
         * Set once the result has been answered (success or any error), so
         * a late watchdog and the copy task can never reply twice — a
         * second reply would throw IllegalStateException.
         */
        val done = AtomicBoolean(false)
        var requestCode: Int = -1
    }

    /** The attempt whose picker UI is currently open, if any. Replaces the
     * old pendingPickResult: the result now travels with its attempt. */
    private var pendingPick: ImportAttempt? = null
    private val pickerRequests = PickerRequestRegistry<ImportAttempt>()
    /** Latest import attempt ever started; the watchdog only acts when it
     * is still this attempt (a newer pick supersedes it). */
    private val lastImportAttempt = AtomicReference<ImportAttempt?>(null)
    /** Monotonic id source for [ImportAttempt]; only touched on the UI
     * thread (pickEpubFile), where watchdogs also run. */
    private var importAttemptCounter = 0
    /**
     * Id of the attempt whose copy block is currently executing on
     * [importExecutor], or -1 when none is. Lets the watchdog tell "the
     * copy task will reply by itself" apart from "the task never started
     * (dropped from a replaced executor's queue) and nobody will reply".
     */
    private val runningImportAttemptId = AtomicInteger(-1)
    private var pendingSaveCall: MethodCall? = null
    private var pendingSaveResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    /** Native-side backstop for pickEpubFile: NOT cleared when the picker
     * returns (it doubles as the copy watchdog); cleared when the activity
     * is destroyed or the picker can't open. */
    private var pickTimeoutCallback: Runnable? = null

    /**
     * Elapsed-realtime timestamp (SystemClock.elapsedRealtime()) of the
     * last pickEpubFile channel call. The copy loop in onActivityResult
     * aborts against pickStartElapsed + PICK_TIMEOUT_MS so a copy that
     * outlives the Dart 5-minute timeout never leaves a non-zero orphan
     * in imports/ whose reply Dart already dropped.
     */
    private var pickStartElapsed: Long = 0

    /**
     * A stop action that arrived before configureFlutterEngine ran (cold
     * start straight from the notification). Forwarded once the channel
     * exists.
     */
    private var pendingStopIntent: Intent? = null

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

    /** Runs file IO (Downloads save, share staging) on a single background
     * thread: avoids unbounded thread creation and keeps IO serialized.
     * Shut down in onDestroy. The SAF import copy runs on [importExecutor]
     * instead (see below). */
    private val ioExecutor = Executors.newSingleThreadExecutor()

    /**
     * Runs the SAF/DocumentProvider import copy on its own thread, isolated
     * from [ioExecutor]: reading from a cloud provider (Drive, OneDrive)
     * can block inside InputStream.read() indefinitely when the network
     * stalls, and Dart's 5-minute timeout only drops the reply — the native
     * thread stays wedged. On the shared single thread, that wedged import
     * would starve every later saveToDownloads/shareFile call; isolated
     * here, a stalled import can only delay the next import: the pick
     * watchdog ([pickTimeoutCallback]) closes the wedged stream at the
     * deadline (see [activeImport]), so the executor thread is freed and
     * the next import's copy is never stuck behind it forever.
     *
     * That only covers wedges *after* the stream was registered. The
     * provider IPC calls that run before registration — queryDisplayName(),
     * getType(), the magic-bytes probe, openInputStream() — can wedge the
     * executor's single thread with no stream to close, and shutdownNow()
     * cannot interrupt a thread parked in Binder. So the watchdog
     * additionally replaces the executor outright (see
     * [recreateImportExecutor]) when it fires with no stream registered,
     * and bumps [importGeneration]: newer imports run on the fresh thread
     * while the wedged task aborts via the generation check when its
     * blocking call finally returns. Reassigned only on the UI thread
     * (watchdogs run on [mainHandler]); shut down in onDestroy.
     */
    private var importExecutor = Executors.newSingleThreadExecutor()

    /**
     * Bumped every time the pick watchdog replaces [importExecutor]. Import
     * tasks capture the value at submit time and abort quietly when they
     * observe a newer generation after a blocking provider call returns:
     * their pick already failed with PICK_TIMEOUT, so anything they did now
     * would only corrupt a newer pick's state. Volatile because the bump
     * happens on the UI thread while the checks run on executor threads.
     */
    @Volatile
    private var importGeneration = 0

    /**
     * Absolute paths of import files referenced by job history, synced from
     * Dart ("setProtectedImportPaths"). cleanupStaleImports() never deletes
     * them, so a history entry retried weeks later still finds its source
     * file (bug: the 7-day sweep used to delete it out from under the
     * retry).
     */
    private val protectedImportPaths: MutableSet<String> =
        Collections.synchronizedSet(mutableSetOf<String>())

    /**
     * The import copy currently reading on [importExecutor], if any, with
     * the pick deadline it must respect. A read() wedged inside a stalled
     * cloud provider never reaches the copy loop's deadline check, so the
     * pick watchdog closes this stream when its deadline passes: read()
     * then throws IOException and the executor thread is freed for the
     * next import.
     *
     * Stream and deadline travel in one holder so the watchdog's
     * check-and-close is atomic: it only ever closes the exact holder it
     * inspected, never a newer pick's stream registered in between
     * (compareAndSet fails and the new stream is left alone).
     */
    private data class ActiveImport(
        val stream: InputStream,
        val deadlineElapsed: Long,
    )
    private val activeImport = AtomicReference<ActiveImport?>(null)

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
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "epub_translator_flutter/android_export"
        )
        exportChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "appDocumentsDirectory" -> result.success(filesDir.absolutePath)
                "pickEpubFile" -> pickEpubFile(result)
                "setProtectedImportPaths" -> setProtectedImportPaths(call, result)
                "saveToDownloads" -> saveToDownloads(call, result)
                "shareFile" -> shareFile(call, result)
                "readSecret" -> readSecret(call, result)
                "writeSecret" -> writeSecret(call, result)
                "deleteSecret" -> deleteSecret(call, result)
                "startTranslationService" -> startTranslationService(call, result)
                "updateTranslationNotification" -> updateTranslationNotification(call, result)
                "stopTranslationService" -> stopTranslationService(result)
                "consumePendingForegroundServiceTimeout" ->
                    consumePendingForegroundServiceTimeout(result)
                "openAppSettings" -> openAppSettings(result)
                else -> result.notImplemented()
            }
        }
        // A stop action that arrived via cold start before the channel
        // existed is forwarded now.
        pendingStopIntent?.let {
            pendingStopIntent = null
            forwardStopToDart()
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        savedInstanceState?.getIntArray(PICKER_REQUEST_CODES_STATE)?.let {
            pickerRequests.restoreAbandoned(it)
        }
        super.onCreate(savedInstanceState)
        // Zombie-service sweep: the translation runs in the Dart isolate,
        // which is (re)created together with this activity, so a service
        // still running at this point belongs to a dead Dart incarnation
        // (e.g. the app was swiped away mid-translation and the process
        // survived). Stop it before its frozen notification can lie about
        // progress; a no-op when the service isn't running.
        TranslationForegroundService.stopIfRunning(this)
        // configureFlutterEngine runs inside super.onCreate(), so the
        // channel already exists here on a warm start; on a cold start
        // straight from the notification action it may not, hence the
        // pendingStopIntent deferral above.
        if (intent?.action == TranslationForegroundService.ACTION_STOP_TRANSLATION) {
            intent?.action = null
            if (exportChannel != null) {
                forwardStopToDart()
            } else {
                pendingStopIntent = intent
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == TranslationForegroundService.ACTION_STOP_TRANSLATION) {
            intent.action = null
            forwardStopToDart()
        }
    }

    /**
     * Forwards the notification Stop action to Dart, which cancels the
     * translation run through the same path as the in-app cancel button
     * (and then stops the service in its normal cleanup). Best effort: if
     * no run is active, Dart just logs and ignores it.
     */
    private fun forwardStopToDart() {
        try {
            exportChannel?.invokeMethod("cancelTranslationFromNotification", null)
        } catch (error: Exception) {
            Log.w(TAG, "Failed to forward stop action to Dart: ${error.message}")
        }
    }

    /**
     * Replaces [importExecutor] with a fresh single thread. Called by the
     * pick watchdog when it fires with no stream registered (see
     * [activeImport]): the copy is then wedged in a provider IPC call that
     * runs before openInputStream() — queryDisplayName(), getType(), the
     * magic-bytes probe — and shutdownNow() cannot interrupt a thread
     * parked in Binder, so the wedged thread is abandoned together with the
     * old executor. [importGeneration] is bumped so the abandoned task (and
     * any task submitted before the replacement) aborts quietly when its
     * blocking call returns, instead of copying over a newer pick's file.
     *
     * Tasks queued on the old executor but not yet running are dropped by
     * shutdownNow(): their picks still fail correctly, because each pick's
     * own watchdog fires PICK_TIMEOUT independently of the copy task ever
     * running.
     *
     * Runs on the UI thread: pick watchdogs are the only callers and they
     * always run on [mainHandler], so no extra synchronization is needed
     * around the field reassignment itself.
     */
    private fun recreateImportExecutor() {
        val old = importExecutor
        importExecutor = Executors.newSingleThreadExecutor()
        importGeneration += 1
        old.shutdownNow()
    }

    override fun onSaveInstanceState(outState: android.os.Bundle) {
        outState.putIntArray(PICKER_REQUEST_CODES_STATE, pickerRequests.outstandingCodes())
        super.onSaveInstanceState(outState)
    }

    private fun pickEpubFile(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("PICK_IN_PROGRESS", "An EPUB picker is already open.", null)
            return
        }

        // NOTE: the stale-imports sweep used to run here, on the UI thread.
        // It now runs at the head of the import copy block below (on
        // importExecutor): listFiles() over imports/ can stall on slow
        // storage and must never wedge the platform thread.

        importAttemptCounter += 1
        val attempt = ImportAttempt(id = importAttemptCounter, result = result)
        val requestCode = pickerRequests.register(attempt)
        if (requestCode == null) {
            result.error("PICK_REQUESTS_EXHAUSTED", "Too many outstanding file pickers.", null)
            return
        }
        attempt.requestCode = requestCode
        lastImportAttempt.set(attempt)
        pendingPick = attempt
        // The whole pick operation (picker UI + copy) shares the Dart
        // side's 5-minute budget, measured from the channel call.
        pickStartElapsed = SystemClock.elapsedRealtime()
        // Native-side backstop for the Dart 5-minute timeout. It doubles as
        // the copy watchdog: unlike the old version it is NOT cancelled in
        // onActivityResult, because a copy wedged inside InputStream.read()
        // (stalled cloud provider) never reaches the copy loop's deadline
        // check. The watchdog keys everything off the attempt identity:
        // pendingPick is cleared when the picker returns while the copy
        // keeps running, so keying off it (as the old code did) missed the
        // executor replacement for copies wedged in a provider IPC call
        // before registering their stream.
        //
        // Guards that keep a stale watchdog from harming a newer pick:
        //  - it no-ops unless it is still the latest attempt (a newer pick
        //    supersedes it) and its result hasn't been answered;
        //  - the stream is only closed when the registered holder's own
        //    deadline has passed (compareAndSet fails for a newer pick's
        //    holder and leaves it alone);
        //  - the result is failed only when nobody else will answer it
        //    (picker still open, or the copy task never started); the
        //    running copy task answers its own result via replyToImport(),
        //    whose done-guard makes a double reply impossible.
        // Note this deliberately does NOT clear pickTimeoutCallback: the
        // field belongs to whichever pick registered last, and
        // cancelPickTimeout()/the next pick own it.
        val timeout = Runnable {
            if (lastImportAttempt.get() !== attempt || attempt.done.get()) {
                return@Runnable
            }
            // Free a copy wedged in InputStream.read(): closing the stream
            // makes read() throw IOException, which frees the single
            // importExecutor thread. Without this, every later import's
            // copy would queue behind the wedged one forever.
            var closedStream = false
            val current = activeImport.get()
            if (current != null &&
                SystemClock.elapsedRealtime() >= current.deadlineElapsed
            ) {
                if (activeImport.compareAndSet(current, null)) {
                    closedStream = true
                    try {
                        current.stream.close()
                    } catch (_: Exception) {
                        // Best effort: the copy is already doomed.
                    }
                }
            }
            // No stream registered (and none just closed): the copy — if it
            // started — is wedged in a provider IPC call that runs before
            // openInputStream() (queryDisplayName(), getType(), the
            // magic-bytes probe, querySourceSize()), or the picker never
            // returned. shutdownNow() cannot interrupt a thread parked in
            // Binder, so the wedged thread is abandoned together with the
            // old executor; the wedged task aborts via the generation check
            // when its blocking call returns. Skipped when a stream was just
            // closed above: the close already freed the thread, so replacing
            // would be pointless churn.
            if (!closedStream && activeImport.get() == null) {
                recreateImportExecutor()
            }
            // Fail the result only when nobody else will answer it: the
            // picker still open for this attempt (the copy never started),
            // or the copy task never started because a replacement dropped
            // it from the old executor's queue. Otherwise the running copy
            // task owns the reply and reports PICK_TIMEOUT itself on its
            // deadline check.
            val pickerOpen = pendingPick === attempt
            if (pickerOpen || runningImportAttemptId.get() != attempt.id) {
                if (attempt.done.compareAndSet(false, true)) {
                    if (pickerOpen) {
                        pendingPick = null
                        pickerRequests.abandon(attempt.requestCode)
                    }
                    result.error(
                        "PICK_TIMEOUT",
                        "The file picker timed out after 5 minutes.",
                        null
                    )
                }
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
            startActivityForResult(intent, attempt.requestCode)
        } catch (error: Exception) {
            // No app can handle the picker (e.g. stripped-down ROMs without
            // DocumentsUI). Clear the pending slot, otherwise every later
            // import would wrongly report PICK_IN_PROGRESS until the
            // process dies.
            cancelPickTimeout()
            pickerRequests.consume(attempt.requestCode)
            pendingPick = null
            attempt.done.set(true)
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
        // Consume the attempt attached to this request. A timeout leaves a
        // tombstone: its late result can never consume the new pending pick.
        val attempt = pickerRequests.consume(requestCode) ?: return
        if (pendingPick !== attempt || attempt.done.get()) return
        // NOTE: the pick watchdog is deliberately NOT cancelled here. It
        // doubles as the copy watchdog: a copy wedged in InputStream.read()
        // never reaches the loop's deadline check, so the watchdog must stay
        // armed to close the stream at the deadline (see pickEpubFile). It
        // is a no-op once its attempt is answered, never touches a newer
        // attempt, and only fails the result when nobody else will answer
        // it (see the watchdog in pickEpubFile). The user-cancelled branch
        // below is the exception: with no copy task submitted, it answers
        // via replyToImport(), which drops the watchdog.

        pendingPick = null
        val result = attempt.result

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            // Cancelled by the user (or an empty result): no copy task was
            // submitted on this path, so the watchdog has nothing to guard.
            // Answer through the shared funnel so it is dropped from the
            // main queue (see replyToImport). The RESULT_OK path below must
            // NOT do this: the watchdog doubles as the copy watchdog there.
            replyToImport(attempt) { result.success(null) }
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
        // Capture this pick's deadline NOW (on the UI thread): the executor
        // block below runs later, and a second pick started in between
        // would otherwise overwrite pickStartElapsed and give this copy
        // the wrong deadline — defeating the orphan cleanup at the end.
        val copyDeadlineElapsed = pickStartElapsed + PICK_TIMEOUT_MS
        // Generation guard for the pre-registration wedge (see
        // [recreateImportExecutor]): if the watchdog replaced the executor
        // while this task was blocked in a provider IPC call, this pick is
        // past its deadline — answer PICK_TIMEOUT instead of copying.
        val taskGeneration = importGeneration
        // The import copy runs on importExecutor, isolated from ioExecutor:
        // a stalled cloud-provider stream would wedge the thread inside
        // InputStream.read(), and must never starve save/share calls.
        importExecutor.execute {
            runningImportAttemptId.set(attempt.id)
            try {
                // The watchdog may have failed this attempt while it was
                // still queued (an executor replacement dropped it from the
                // old queue): never copy for an already-answered attempt.
                if (attempt.done.get()) {
                    return@execute
                }
                // The stale-imports sweep runs here, off the UI thread (it
                // used to run in pickEpubFile on the platform thread, where a
                // slow storage listing could wedge it).
                cleanupStaleImports()
                try {
                    val selectedName = queryDisplayName(uri)
                    if (taskGeneration != importGeneration) {
                        // The watchdog replaced the executor while we were
                        // blocked: this pick is past its deadline, so answer
                        // PICK_TIMEOUT (if nobody did) instead of copying.
                        replyImportTimeout(attempt)
                        return@execute
                    }
                // Some document providers don't report a display name (or any
                // extension); fall back to the provider-declared MIME type,
                // then to the file's magic bytes, so a valid EPUB isn't
                // rejected just because the URI has no suffix. Note the
                // magic-bytes check must NOT be gated on a blank name:
                // queryDisplayName() falls back to the URI's last path
                // segment (never blank), which used to make this branch
                // unreachable for exactly the providers it was written for.
                val mimeType = contentResolver.getType(uri)
                val looksLikeEpub = selectedName.endsWith(".epub", ignoreCase = true) ||
                    mimeType.equals("application/epub+zip", ignoreCase = true) ||
                    hasZipMagicBytes(uri)
                if (taskGeneration != importGeneration) {
                    // Same guard after the second round of blocking
                    // provider IPC calls.
                    replyImportTimeout(attempt)
                    return@execute
                }
                if (!looksLikeEpub) {
                    replyToImport(attempt) {
                        result.error(
                            "INVALID_FILE_TYPE",
                            "Please choose a file with the .epub extension.",
                            null
                        )
                    }
                    return@execute
                }
                // The deadline was captured on the UI thread before this
                // block was queued, so a newer pick cannot shift it.
                val path = copyUriToAppFile(
                    uri,
                    selectedName,
                    copyDeadlineElapsed,
                    taskGeneration
                )
                if (taskGeneration != importGeneration) {
                    // The executor was replaced mid-copy (a watchdog fired
                    // while we were blocked): this pick is past its
                    // deadline, so delete the finished file instead of
                    // leaving an orphan nobody references, and answer
                    // PICK_TIMEOUT (if nobody did).
                    File(path).delete()
                    replyImportTimeout(attempt)
                    return@execute
                }
                if (SystemClock.elapsedRealtime() > copyDeadlineElapsed) {
                    // Dart already gave up: delete the finished file instead
                    // of leaving a non-zero orphan nobody references.
                    File(path).delete()
                    replyImportTimeout(attempt)
                } else {
                    replyToImport(attempt) { result.success(path) }
                }
            } catch (error: ImportStaleException) {
                // The watchdog replaced the executor mid-copy (see
                // copyUriToAppFile's generation checks): this pick is
                // past its deadline — answer PICK_TIMEOUT if nobody
                // did. copyUriToAppFile cleaned up its own claim and
                // sidecar on the way out.
                replyImportTimeout(attempt)
            } catch (error: Exception) {
                replyToImport(attempt) {
                    when {
                        error is ImportNoSpaceException ->
                            result.error("PICK_NO_SPACE", error.message, null)
                        SystemClock.elapsedRealtime() > copyDeadlineElapsed ->
                            // Past the deadline — most likely the
                            // watchdog closed our stream, so report the
                            // timeout rather than the raw "stream
                            // closed" IOException.
                            result.error(
                                "PICK_TIMEOUT",
                                "The file picker timed out after 5 minutes.",
                                null
                            )
                        else ->
                            result.error("PICK_FAILED", error.message, null)
                    }
                }
            }
            } finally {
                runningImportAttemptId.compareAndSet(attempt.id, -1)
            }
        }
    }

    /**
     * Answers an import attempt's MethodChannel result at most once. The
     * watchdog may already have failed it with PICK_TIMEOUT (see
     * pickEpubFile), and a second reply would throw IllegalStateException
     * — so every import reply path goes through here.
     */
    private fun replyToImport(attempt: ImportAttempt, reply: () -> Unit) {
        if (attempt.done.compareAndSet(false, true)) {
            // Normal completion (success, user cancel, copy failure): the
            // watchdog is no longer needed — drop it from the main queue
            // instead of letting it linger for the full 5 minutes holding
            // the Activity/Result/ImportAttempt references. Only when it
            // still belongs to this attempt: a newer pick may already have
            // registered its own watchdog (the stale one then no-ops via
            // its lastImportAttempt guard and must be left alone).
            if (lastImportAttempt.get() === attempt) {
                cancelPickTimeout()
            }
            replyOnUiThread(attempt.result, reply)
        }
    }

    /** Timed-out branches answer with the same PICK_TIMEOUT the watchdog
     * sends, guarded so they never double-reply (see [replyToImport]). */
    private fun replyImportTimeout(attempt: ImportAttempt) {
        replyToImport(attempt) {
            attempt.result.error(
                "PICK_TIMEOUT",
                "The file picker timed out after 5 minutes.",
                null
            )
        }
    }

    /**
     * Records the import files referenced by Dart's job history so
     * cleanupStaleImports() never deletes them. Dart syncs the current
     * history's input paths before each pick; a book imported 8 days ago
     * and retried today must still find its source file.
     */
    private fun setProtectedImportPaths(call: MethodCall, result: MethodChannel.Result) {
        val paths = call.argument<List<String>>("paths").orEmpty()
        protectedImportPaths.clear()
        protectedImportPaths.addAll(paths.filter { it.isNotBlank() }.toSet())
        result.success(null)
    }

    /**
     * Sweeps imports/ so it can't grow without bound: every import copies a
     * whole EPUB here, and nothing else ever deletes them.
     *
     * - Zero-byte files: leftovers of imports that died mid-copy (a valid
     *   EPUB is never empty). Skips targets claimed by in-flight copies.
     * - "*.part" sidecars: a killed copy's truncated data (see
     *   copyUriToAppFile). Only swept when older than IMPORT_PART_GRACE_MS
     *   and not belonging to an in-flight claim: same-millisecond clock
     *   granularity must never let the sweep win over a live copy.
     * - Files older than IMPORT_MAX_AGE_MS: deleted unconditionally,
     *   EXCEPT paths in [protectedImportPaths] (job history references:
     *   retrying a weeks-old task must find its source file).
     * - Count/size cap (newest win, oldest evicted first): only files older
     *   than IMPORT_CAP_GRACE_MS are evictable, so a book imported minutes
     *   ago — e.g. one mid-translation, whose source is re-read at repack
     *   time — is never taken by the cap. Protected paths are exempt from
     *   the cap as well.
     *
     * Best effort only: a failed cleanup must not block importing. */
    private fun cleanupStaleImports() {
        try {
            val importsDir = File(filesDir, "imports")
            val now = System.currentTimeMillis()
            importsDir.listFiles()?.forEach { file ->
                if (!file.isFile) {
                    return@forEach
                }
                val age = now - file.lastModified()
                val isPart = file.name.endsWith(IMPORT_PART_SUFFIX)
                val inFlight = file.absolutePath.let { path ->
                    path in activeImportTargets ||
                        (isPart && path.removeSuffix(IMPORT_PART_SUFFIX) in activeImportTargets)
                }
                if (file.length() == 0L && !inFlight) {
                    // Zero-byte leftover of a dead import. The residual race
                    // — the sweep listing a file in the instant between
                    // createNewFile() and the claim being registered — is
                    // harmless: the copy writes to the ".part" sidecar
                    // (created after registration) and renames it onto the
                    // claim on success, so a deleted zero-byte claim is
                    // simply reclaimed by the rename.
                    file.delete()
                    return@forEach
                }
                if (isPart && !inFlight && age >= IMPORT_PART_GRACE_MS) {
                    file.delete()
                    return@forEach
                }
                if (age >= IMPORT_MAX_AGE_MS &&
                    file.absolutePath !in protectedImportPaths
                ) {
                    file.delete()
                }
            }
            // Enforce the cap over evictable files only (see doc comment).
            // Protected paths are never evictable: the cap must not delete
            // a source a history entry may still retry.
            val evictable = importsDir.listFiles()
                ?.filter {
                    it.isFile && it.exists() &&
                        now - it.lastModified() >= IMPORT_CAP_GRACE_MS &&
                        it.absolutePath !in protectedImportPaths
                }
                ?.sortedBy { it.lastModified() }
                ?: return
            var totalBytes = evictable.sumOf { it.length() }
            var count = evictable.size
            for (file in evictable) {
                if (count <= MAX_IMPORT_FILES && totalBytes <= MAX_IMPORT_BYTES) {
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
                replyOnUiThread(result) {
                    if (error is SaveNoSpaceException) {
                        result.error("SAVE_NO_SPACE", error.message, null)
                    } else {
                        result.error("SAVE_FAILED", error.message, null)
                    }
                }
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
        pendingPick?.let { attempt ->
            pendingPick = null
            // The watchdog is cancelled above, so this is the only path
            // that can still answer this attempt: mark it done so a
            // concurrently-firing watchdog can't double-reply.
            if (attempt.done.compareAndSet(false, true)) {
                try {
                    attempt.result.error(
                        "ACTIVITY_DESTROYED",
                        "The activity was destroyed before the picker returned.",
                        null
                    )
                } catch (_: Exception) {
                }
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
        // Un-wedge a copy stuck in InputStream.read() before shutting the
        // executor down: otherwise shutdown() would wait forever on the
        // wedged thread (and the process would keep it alive).
        activeImport.getAndSet(null)?.let { holder ->
            try {
                holder.stream.close()
            } catch (_: Exception) {
            }
        }
        importExecutor.shutdown()
        // The translation itself runs in the Dart isolate, and the engine
        // is destroyed with this activity (shouldDestroyEngineWithHost
        // defaults to true; rotation and friends are handled via
        // configChanges and never reach here). So whenever onDestroy runs,
        // the translation is already dead — but the foreground service is
        // an independent component and would survive as a zombie with a
        // frozen, non-dismissible notification whose Stop button does
        // nothing. Stop it here; a later cold start recreates everything
        // cleanly (and sweeps any leftover via stopIfRunning in onCreate).
        // stopService on a non-running service is a harmless no-op.
        stopService(Intent(this, TranslationForegroundService::class.java))
        super.onDestroy()
    }

    /**
     * Whether [file] sits under one of the roots declared in
     * res/xml/file_paths.xml (<files-path> translated_epubs/ or
     * <cache-path> share_staging/). FileProvider.getUriForFile() throws
     * IllegalArgumentException for anything outside those roots, so
     * shareFile() must stage such files into share_staging/ first instead
     * of sharing them directly.
     */
    private fun isFileProviderExposed(context: Context, file: File): Boolean {
        return try {
            val path = file.canonicalPath
            val translated = File(context.filesDir, "translated_epubs").canonicalPath
            val staging = File(context.cacheDir, "share_staging").canonicalPath
            path == translated || path.startsWith(translated + File.separator) ||
                path == staging || path.startsWith(staging + File.separator)
        } catch (_: Exception) {
            // If the path can't even be resolved, don't hand it to
            // FileProvider: stage a copy instead.
            false
        }
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
                // FileProvider only serves the roots declared in
                // file_paths.xml (files/translated_epubs/ and
                // cache/share_staging/): handing it any other file throws
                // IllegalArgumentException at share time. So a source that
                // needs no rename is shared directly ONLY when it already
                // sits under a served root; anything else goes through a
                // staging copy — even when the display name already
                // matches.
                val needsStaging = (displayName.isNotBlank() && source.name != displayName) ||
                    !isFileProviderExposed(appContext, source)
                val shareFile = if (!needsStaging) {
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
                    // A blank display name falls back to the source's own
                    // name: the staging branch also runs when the source
                    // isn't FileProvider-served even with no rename needed.
                    val target = claimUniqueImportTarget(
                        stagingDir,
                        displayName.ifBlank { source.name }
                    )
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

    private fun copyUriToAppFile(
        uri: Uri,
        displayName: String,
        deadlineElapsed: Long,
        taskGeneration: Int,
    ): String {
        var safeName = sanitizeFileName(displayName)
        if (!safeName.contains('.')) {
            // Some document providers report no display name, leaving only a
            // bare document id with no extension. The picker was opened for
            // EPUBs, so assume .epub instead of producing a file the app
            // would later reject for missing its suffix.
            safeName += ".epub"
        }
        val importsDir = File(filesDir, "imports").apply { mkdirs() }
        // Fail fast when the disk clearly cannot hold the import: without
        // this the copy runs to completion before the first ENOSPC write
        // fails, wasting the user's wait. Size unknown (-1) means "can't
        // tell" — fall through to the copy, whose write errors still
        // surface as PICK_FAILED.
        val sourceSize = querySourceSize(uri)
        if (taskGeneration != importGeneration) {
            // The watchdog replaced the executor while we were blocked in
            // the provider query above: this pick is past its deadline —
            // abort before claiming a target (the caller answers
            // PICK_TIMEOUT).
            throw ImportStaleException()
        }
        if (sourceSize > 0 && importsDir.usableSpace < sourceSize + IMPORT_SPACE_MARGIN_BYTES) {
            throw ImportNoSpaceException(
                "Not enough free space to import this EPUB " +
                    "(needs about ${sourceSize / 1024 / 1024} MB)."
            )
        }
        // Atomically claim a unique target: createNewFile() only succeeds for
        // the thread that wins the race, so two concurrent imports of the
        // same file name can never end up writing to the same path.
        val target = claimUniqueImportTarget(importsDir, safeName)
        // Mark the claim as in-flight so a second import's
        // cleanupStaleImports() doesn't mistake it for a leftover.
        activeImportTargets.add(target.absolutePath)
        // Write to a ".part" sidecar and rename onto the claim on success:
        // if the process is killed mid-copy only the sidecar is left behind
        // (swept by cleanupStaleImports), while the claimed final name is
        // never occupied by a truncated copy — so the next same-name import
        // reuses the original name instead of being forced onto
        // "name (2).epub". renameTo() within one directory is an atomic
        // rename(2) on Linux, replacing the zero-byte claim file.
        val partFile = File(target.absolutePath + IMPORT_PART_SUFFIX)
        try {
            contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "Unable to open selected EPUB." }
                if (taskGeneration != importGeneration) {
                    // The watchdog replaced the executor while openInputStream()
                    // was blocked: abort before registering the stream —
                    // this pick is past its deadline (the caller answers
                    // PICK_TIMEOUT).
                    throw ImportStaleException()
                }
                // Register the stream so the pick watchdog can un-wedge a
                // read() stuck inside a stalled cloud provider: at the
                // deadline it closes exactly this holder (compareAndSet),
                // read() throws IOException, and the single importExecutor
                // thread is freed for the next import.
                val holder = ActiveImport(input, deadlineElapsed)
                activeImport.set(holder)
                try {
                    FileOutputStream(partFile).use { output ->
                        // Chunked (not input.copyTo) so the copy can abort when
                        // it outlives the Dart 5-minute timeout: continuing would
                        // produce an orphan whose reply Dart already dropped.
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            if (SystemClock.elapsedRealtime() > deadlineElapsed) {
                                throw IllegalStateException(
                                    "Pick timed out during copy."
                                )
                            }
                            val n = input.read(buffer)
                            if (n <= 0) {
                                break
                            }
                            output.write(buffer, 0, n)
                        }
                    }
                } finally {
                    activeImport.compareAndSet(holder, null)
                }
            }
            if (!partFile.renameTo(target)) {
                throw IllegalStateException("Unable to finalize imported EPUB.")
            }
        } catch (error: Exception) {
            // Don't leave a truncated sidecar or a zero-byte claim behind.
            partFile.delete()
            target.delete()
            throw error
        } finally {
            activeImportTargets.remove(target.absolutePath)
        }
        return target.absolutePath
    }

    /** Best-effort size of the picked document in bytes, or -1 when the
     * provider doesn't report one. Used for the pre-copy free-space check. */
    private fun querySourceSize(uri: Uri): Long {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (index >= 0) cursor.getLong(index) else -1L
                } else {
                    -1L
                }
            } ?: -1L
        } catch (_: Exception) {
            -1L
        }
    }

    /** Thrown when the pre-copy free-space check fails; mapped to the
     * PICK_NO_SPACE channel error so Dart can show a localized message. */
    private class ImportNoSpaceException(message: String) : Exception(message)

    /** Thrown when the pre-save free-space check fails; mapped to the
     * SAVE_NO_SPACE channel error so Dart can show a localized message
     * instead of the raw English native text. */
    private class SaveNoSpaceException(message: String) : Exception(message)

    /** Thrown when an import task observes a newer [importGeneration] after a
     * blocking provider call: the watchdog replaced the executor, so the
     * task must abort without copying over a newer pick's file. The caller
     * answers PICK_TIMEOUT via [replyImportTimeout] (guarded against a
     * watchdog that may already have failed it). */
    private class ImportStaleException :
        Exception("Import attempt superseded by executor replacement.")

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

    /**
     * Best-effort free space on the volume that hosts Downloads. Android 9
     * and below: the public Downloads directory itself. Android 10+:
     * MediaStore offers no File handle, so the primary shared-storage root
     * (where Downloads lives) is used instead. Returns null when the free
     * space cannot be determined — the save then proceeds and write errors
     * still surface as SAVE_FAILED.
     */
    @Suppress("DEPRECATION")
    private fun downloadsUsableSpace(): Long? {
        return try {
            val root = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Environment.getExternalStorageDirectory()
            } else {
                Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS
                )
            }
            val usable = root.usableSpace
            // usableSpace returns 0 when the path is missing/unmounted;
            // treat that as "unknown", not as "definitely full".
            if (usable <= 0) null else usable
        } catch (_: Exception) {
            null
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

        // Fail fast when the disk clearly cannot hold the save: without
        // this the copy runs until ENOSPC and only then fails, wasting the
        // user's wait (the Q+ branch deletes the half-written entry, but
        // the legacy branch would leave a truncated file without the
        // catch below). Unknown free space (null) falls through to the
        // copy, whose write errors still surface as SAVE_FAILED.
        val sourceSize = source.length()
        if (sourceSize > 0) {
            val usableSpace = downloadsUsableSpace()
            if (usableSpace != null &&
                usableSpace < sourceSize + IMPORT_SPACE_MARGIN_BYTES
            ) {
                throw SaveNoSpaceException(
                    "Not enough free space to save this EPUB to Downloads " +
                        "(needs about ${sourceSize / 1024 / 1024} MB)."
                )
            }
        }

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
     * Last-resort EPUB check when neither the file suffix nor the
     * provider-declared MIME type identifies an EPUB: an EPUB is a ZIP
     * archive, so its first four bytes are PK\x03\x04. A non-EPUB ZIP that
     * slips through is rejected later by the Dart-side structure check.
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
            } catch (error: SecretKeyRotatedException) {
                // Distinct from a generic read failure: the key itself was
                // regenerated (see getOrCreateSecretKey), so Dart must tell
                // the user to re-enter their keys instead of reporting a
                // transient error.
                replyOnUiThread(result) {
                    result.error("SECRET_KEY_ROTATED", error.message, null)
                }
            } catch (error: Exception) {
                replyOnUiThread(result) { result.error(errorCode, error.message, null) }
            }
        }
    }

    /** Thrown when the Android KeyStore key was invalidated (lock-screen
     * credential or biometric enrollment changed) and had to be regenerated:
     * anything encrypted with the old key is unrecoverable, so the stale
     * ciphertext is deleted and Dart is told the key rotated. */
    private class SecretKeyRotatedException : Exception(
        "The device key was invalidated and regenerated; " +
            "previously stored secrets can no longer be decrypted."
    )

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
            val (key, rotated) = getOrCreateSecretKey()
            if (!rotated) {
                try {
                    return@runSecretOp decryptSecret(key, iv, encrypted)
                } catch (error: KeyPermanentlyInvalidatedException) {
                    // Android reported the invalidation at Cipher.init() /
                    // doFinal time instead of getEntry(): drop the dead
                    // entry and regenerate below, then fall through to the
                    // rotation handling.
                    invalidateSecretKeyEntry()
                    getOrCreateSecretKey()
                }
            }
            // The key was invalidated (lock-screen credential or biometric
            // enrollment changed) and regenerated: the stored ciphertext can
            // never be decrypted again. Wipe every stored secret — they are
            // all undecryptable now, and leaving them would make later
            // reads fail with a confusing decrypt error — and report the
            // rotation distinctly so Dart tells the user to re-enter their
            // keys (rather than a generic "read failed", which would invite
            // pointless retries).
            clearAllSecretValues()
            throw SecretKeyRotatedException()
        }
    }

    private fun decryptSecret(key: SecretKey, iv: String, encrypted: String): String {
        val cipher = Cipher.getInstance(SECRET_TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            key,
            GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP))
        )
        val decrypted = cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP))
        return String(decrypted, Charsets.UTF_8)
    }

    private fun writeSecret(call: MethodCall, result: MethodChannel.Result) {
        runSecretOp(result, "SECRET_WRITE_FAILED") {
            val name = sanitizeSecretName(call.argument<String>("name").orEmpty())
            val value = call.argument<String>("value").orEmpty()
            if (value.isBlank()) {
                deleteSecretValues(name)
                return@runSecretOp null
            }
            try {
                putSecretValues(name, value)
            } catch (error: KeyPermanentlyInvalidatedException) {
                // The key died between getEntry() and Cipher.init(): drop
                // the dead entry, wipe the now-undecryptable stale secrets,
                // and retry once with a fresh key. The user's just-entered
                // value is not lost, and no rotation is reported — the
                // write succeeded, so there is nothing to re-enter.
                invalidateSecretKeyEntry()
                clearAllSecretValues()
                putSecretValues(name, value)
            }
            null
        }
    }

    /**
     * Encrypts [value] with the current key and stores it. If the key had
     * to be regenerated (the old one was permanently invalidated), the
     * other stored secrets are wiped first: their ciphertext is
     * unrecoverable with the new key, and leaving it would make their next
     * read fail with a confusing decrypt error instead of cleanly
     * reporting "no stored key".
     */
    private fun putSecretValues(name: String, value: String) {
        val (key, rotated) = getOrCreateSecretKey()
        if (rotated) {
            clearAllSecretValues()
        }
        val cipher = Cipher.getInstance(SECRET_TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString("${name}_iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString("${name}_value", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .apply()
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

    /**
     * Wipes every stored secret. Called when the KeyStore key was
     * permanently invalidated and regenerated: all ciphertext is
     * unrecoverable then. SECURE_PREFS_NAME holds nothing but secrets, so
     * a full clear is safe.
     */
    private fun clearAllSecretValues() {
        getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .apply()
    }

    /**
     * POST_NOTIFICATIONS is requested at most once per install: the
     * translation foreground service is exempt from it, so the service
     * starts regardless of the answer and nagging on every translation
     * would serve nothing.
     */
    private fun hasAskedPostNotifications(): Boolean =
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_ASKED_POST_NOTIFICATIONS, false)

    private fun markAskedPostNotifications() {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ASKED_POST_NOTIFICATIONS, true)
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
        val stopLabel = call.argument<String>("stopLabel")?.takeIf { it.isNotBlank() }
            ?: "Stop"
        val timeoutText = call.argument<String>("timeoutText")?.takeIf { it.isNotBlank() }
            ?: "Background time limit reached — reopen the app to continue."
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED &&
            !hasAskedPostNotifications()
        ) {
            // Ask at most once ever: the foreground service does not need
            // this permission (its notification is exempt), so re-prompting
            // on every translation start would be pure annoyance.
            markAskedPostNotifications()
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
                putExtra(TranslationForegroundService.EXTRA_STOP_LABEL, stopLabel)
                putExtra(TranslationForegroundService.EXTRA_TIMEOUT_TEXT, timeoutText)
                putExtra(
                    TranslationForegroundService.EXTRA_RUN_ID,
                    call.argument<String>("runId").orEmpty(),
                )
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            result.success(null)
        } catch (error: Exception) {
            // Android 12+ throws when a foreground service is started while
            // the app is in the background and no exemption applies
            // (ForegroundServiceStartNotAllowedException, a subclass of
            // IllegalStateException; some OEMs throw SecurityException).
            // Report it distinctly so Dart can warn the user instead of
            // silently losing the keep-alive: the translation itself
            // continues in Dart either way.
            val denied = error is SecurityException ||
                error is IllegalStateException ||
                error.javaClass.simpleName ==
                    "ForegroundServiceStartNotAllowedException"
            result.error(
                if (denied) "START_SERVICE_BACKGROUND_DENIED" else "START_SERVICE_FAILED",
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
        val runId = call.argument<String>("runId").orEmpty()
        TranslationForegroundService.updateNotification(progress, text, runId)
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

    /**
     * Reads and clears the persisted foreground-service timeout notice (see
     * TranslationForegroundService.onTimeout). Returns true when a timeout
     * happened while notifications were disabled: Dart never got to show
     * the system notification, so the next app start surfaces the timeout
     * in-app instead. Clearing on read keeps the notice from showing twice.
     */
    private fun consumePendingForegroundServiceTimeout(result: MethodChannel.Result) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val pending = prefs.getBoolean(
            TranslationForegroundService.KEY_TIMEOUT_PENDING,
            false
        )
        if (pending) {
            prefs.edit()
                .remove(TranslationForegroundService.KEY_TIMEOUT_PENDING)
                .apply()
        }
        result.success(pending)
    }

    /**
     * Returns the secret key plus whether the previous key was found
     * permanently invalidated and had to be regenerated. The rotation flag
     * is op-local (part of the return value), so a rotation triggered by
     * one op can never leak into the next — e.g. a write that regenerated
     * the key must not make the following read delete the just-written
     * ciphertext and report a phantom rotation.
     */
    private data class SecretKeyResult(
        val key: SecretKey,
        val rotated: Boolean,
    )

    private fun getOrCreateSecretKey(): SecretKeyResult = synchronized(keyStoreLock) {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        var rotated = false
        val existing = try {
            keyStore.getEntry(SECRET_KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        } catch (error: KeyPermanentlyInvalidatedException) {
            // The user changed their lock-screen credential or re-enrolled
            // biometrics: Android permanently invalidated the old key, and
            // getEntry() throws instead of returning it. Without this catch
            // the code below would never run (the exception propagates) and
            // every later secret op would fail until the app data was
            // cleared. Delete the dead entry and fall through to generate a
            // fresh key; the stale ciphertext encrypted with the old key is
            // unrecoverable, so readSecret() reports the rotation distinctly
            // (see SecretKeyRotatedException) instead of a generic failure.
            try {
                keyStore.deleteEntry(SECRET_KEY_ALIAS)
            } catch (_: Exception) {
                // Best effort: generateKey() below recreates the alias.
            }
            rotated = true
            null
        }
        if (existing != null) {
            return@synchronized SecretKeyResult(existing.secretKey, false)
        }

        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore"
        )
        val keySpecBuilder = KeyGenParameterSpec.Builder(
            SECRET_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            // Don't tie the key's lifetime to biometric enrollment changes:
            // the stored API keys are never gated on biometrics, so a
            // re-enrolled fingerprint must not nuke them. (API 24+ only.)
            keySpecBuilder.setInvalidatedByBiometricEnrollment(false)
        }
        keyGenerator.init(keySpecBuilder.build())
        return@synchronized SecretKeyResult(keyGenerator.generateKey(), rotated)
    }

    /**
     * Deletes the (possibly dead) key entry so the next
     * [getOrCreateSecretKey] generates a fresh key. Called when a crypto op
     * throws KeyPermanentlyInvalidatedException — Android can report the
     * invalidation at Cipher.init()/doFinal time even when getEntry()
     * succeeded.
     */
    private fun invalidateSecretKeyEntry() = synchronized(keyStoreLock) {
        try {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                .deleteEntry(SECRET_KEY_ALIAS)
        } catch (_: Exception) {
            // Best effort: the next getOrCreateSecretKey() recreates the alias.
        }
    }

    private fun sanitizeSecretName(name: String): String {
        val sanitized = name.replace(Regex("[^A-Za-z0-9_.-]"), "_").trim('_', '.', '-')
        return sanitized.ifBlank { "secret" }
    }

    private fun sanitizeFileName(name: String): String {
        // Beyond the classic illegal characters, also strip C0 controls
        // and DEL: a document provider's display name can legally contain
        // '\n' (it is valid on Linux file systems and in Java strings),
        // and that name flows straight into the foreground-service
        // notification text and log lines, breaking their layout. NUL is
        // rejected by every file system, so it goes too.
        val sanitized = name.replace(Regex("[\\\\/:*?\"<>|\u0000-\u001f\u007f]"), "_").trim()
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
     * the last complete character so no multi-byte sequence is split. A
     * cut landing exactly on a character boundary keeps that character;
     * only a character genuinely split by the cut is dropped. */
    private fun cutUtf8Bytes(bytes: ByteArray, maxBytes: Int): String {
        val limit = maxBytes.coerceAtMost(bytes.size)
        if (limit <= 0) {
            return ""
        }
        // Find the lead byte of the last character at or before the limit.
        var lead = limit - 1
        while (lead > 0 && (bytes[lead].toInt() and 0xC0) == 0x80) {
            lead--
        }
        val expectedLen = when (bytes[lead].toInt() and 0xF0) {
            0xC0, 0xD0 -> 2
            0xE0 -> 3
            0xF0 -> 4
            else -> 1 // ASCII (or a malformed lead, which can't occur here)
        }
        // Keep the character only when it ends at or before the limit.
        // A zero cut is legitimate (no complete character fits in the
        // budget, e.g. maxBytes=1 with a multibyte lead): decoding zero
        // bytes yields "", while forcing at least 1 byte would decode a
        // lone lead byte as U+FFFD.
        val cut = if (lead + expectedLen <= limit) limit else lead
        return String(bytes, 0, cut, Charsets.UTF_8)
    }

    private fun requiresLegacyDownloadsWritePermission(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
    }

    companion object {
        private const val TAG = "EpubTranslator"
        private const val PICKER_REQUEST_CODES_STATE = "epub_picker_request_codes"
        private const val REQUEST_WRITE_DOWNLOADS = 6002
        private const val REQUEST_POST_NOTIFICATIONS = 6003
        /** Native-side backstop matching the Dart 5-minute picker timeout. */
        private const val PICK_TIMEOUT_MS = 5L * 60 * 1000
        /** File names are truncated to this many UTF-8 bytes (ext4 caps a
         * single path component at 255). */
        private const val MAX_FILE_NAME_BYTES = 200
        private const val SECURE_PREFS_NAME = "secure_secrets"
        private const val SECRET_KEY_ALIAS = "epub_translator_secure_settings"
        /** General (non-secret) preferences. */
        private const val PREFS_NAME = "epub_translator_prefs"
        /** Set once POST_NOTIFICATIONS has been requested on Android 13+. */
        private const val KEY_ASKED_POST_NOTIFICATIONS = "asked_post_notifications"
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
        /** imports/ files older than this are deleted unconditionally by
         * cleanupStaleImports. */
        private const val IMPORT_MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000
        /** Cap for imports/: newest files win, oldest evicted first. */
        private const val MAX_IMPORT_FILES = 20
        private const val MAX_IMPORT_BYTES = 1024L * 1024 * 1024
        /** imports/ files younger than this are exempt from the count/size
         * cap: a book imported minutes ago may be mid-translation (its
         * source is re-read at repack time), so the cap must never take it. */
        private const val IMPORT_CAP_GRACE_MS = 24L * 60 * 60 * 1000
        /** "*.part" sidecars younger than this are exempt from the orphan
         * sweep: an in-flight copy's sidecar is legitimately fresh. */
        private const val IMPORT_PART_GRACE_MS = 60L * 60 * 1000
        /** Suffix of the in-progress copy sidecar (see copyUriToAppFile). */
        private const val IMPORT_PART_SUFFIX = ".part"
        /** Headroom added to the reported source size in the pre-copy
         * free-space check. */
        private const val IMPORT_SPACE_MARGIN_BYTES = 10L * 1024 * 1024

        /**
         * Set by configureFlutterEngine; kept static so
         * TranslationForegroundService can reach back into Dart (e.g. the
         * Android 15+ onTimeout callback) without an activity reference.
         */
        @Volatile
        private var exportChannel: MethodChannel? = null

        /**
         * Notifies Dart that the foreground service lost its foreground
         * slot (Android 15+ background time budget exhausted). Dart stops
         * the run through the normal cancel path instead of burning API
         * tokens in a process the system may kill at any moment.
         * Best effort: no-op when the engine is gone.
         */
        fun notifyForegroundServiceTimeout() {
            try {
                exportChannel?.invokeMethod("foregroundServiceTimeout", null)
            } catch (error: Exception) {
                Log.w(TAG, "Failed to forward service timeout to Dart: ${error.message}")
            }
        }
    }
}
