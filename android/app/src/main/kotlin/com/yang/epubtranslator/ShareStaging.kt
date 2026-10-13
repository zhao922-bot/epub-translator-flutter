package com.yang.epubtranslator

/** Share staging files older than this are swept unconditionally. */
internal const val SHARE_STAGING_MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000
/** Cap for share_staging/: newest files win, oldest evicted first. */
internal const val MAX_SHARE_STAGING_FILES = 20
internal const val MAX_SHARE_STAGING_BYTES = 200L * 1024 * 1024
/** Under quota pressure, protect only a handful of recent grants / tens of
 * MiB. Dismissed choosers have no result callback to release their grants. */
internal const val MAX_SHARE_GRANT_EXEMPT_FILES = 5
internal const val MAX_SHARE_GRANT_EXEMPT_BYTES = 50L * 1024 * 1024
/** Staging files younger than this are exempt from the count/size cap when
 * they carry no share grant: their chooser may still be open and the target
 * app may not have read the file yet. Live grants are protected within the
 * exemption caps, independent of this grace period. */
internal const val SHARE_STAGING_CAP_GRACE_MS = 5L * 60 * 1000
/** SharedPreferences key holding the share-grant ledger (a string set of
 * `uri|absolutePath|grantedAtMs` entries). */
internal const val SHARE_GRANTS_PREF_KEY = "share_uri_grants"

/** One recorded share: the FileProvider URI whose read grant is alive and
 * the staging snapshot it serves. */
internal data class ShareGrant(
    val uri: String,
    val filePath: String,
    val grantedAt: Long,
)

/** One staging snapshot on disk, for cleanup planning. */
internal data class ShareStagingEntry(
    val path: String,
    val lastModified: Long,
    val length: Long,
)

/** Which staging files the sweep may delete, and which URI grants to
 * revoke after their files are successfully deleted (never before: a grant
 * must not be revoked for a file that survived deletion). */
internal data class ShareStagingCleanupPlan(
    /** Files past the max age: deleted unconditionally. */
    val deleteForAge: List<ShareStagingEntry>,
    /** Grant URIs to revoke after age deletion or quota eviction succeeds. */
    val revokeUris: List<String>,
    /** Files to evict oldest-first until the quota is met (already ordered). */
    val evictForCap: List<ShareStagingEntry>,
)

private const val SHARE_GRANT_SEPARATOR = "|"

/** Parses one ledger entry, or null when malformed. */
private fun parseShareGrant(entry: String): ShareGrant? {
    val parts = entry.split(SHARE_GRANT_SEPARATOR)
    if (parts.size != 3) return null
    val grantedAt = parts[2].toLongOrNull() ?: return null
    return ShareGrant(uri = parts[0], filePath = parts[1], grantedAt = grantedAt)
}

private fun renderShareGrant(grant: ShareGrant): String =
    "${grant.uri}$SHARE_GRANT_SEPARATOR${grant.filePath}$SHARE_GRANT_SEPARATOR${grant.grantedAt}"

/** Records a share grant, replacing any older entry for the same file. Pure
 * set transform so it stays unit-testable without Android stubs. */
internal fun recordShareGrant(
    entries: Set<String>,
    uri: String,
    filePath: String,
    now: Long,
): Set<String> {
    val updated = entries.mapNotNullTo(mutableSetOf()) { entry ->
        val grant = parseShareGrant(entry)
        if (grant != null && grant.filePath != filePath) entry else null
    }
    updated.add(renderShareGrant(ShareGrant(uri, filePath, now)))
    return updated
}

/** Loads the grant ledger keyed by staging file path. */
internal fun loadShareGrants(entries: Set<String>): Map<String, ShareGrant> {
    val result = mutableMapOf<String, ShareGrant>()
    for (entry in entries) {
        val grant = parseShareGrant(entry) ?: continue
        result[grant.filePath] = grant
    }
    return result
}

/** Drops the ledger entry for [filePath], if any. */
internal fun dropShareGrant(entries: Set<String>, filePath: String): Set<String> =
    entries.filterTo(mutableSetOf()) { entry ->
        parseShareGrant(entry)?.filePath != filePath
    }

/** Drops ledger entries whose file no longer exists. */
internal fun dropStaleShareGrants(
    entries: Set<String>,
    existingPaths: Set<String>,
): Set<String> =
    entries.filterTo(mutableSetOf()) { entry ->
        val grant = parseShareGrant(entry)
        grant == null || grant.filePath in existingPaths
    }

/**
 * Plans the share-staging sweep.
 *
 * - Files older than [SHARE_STAGING_MAX_AGE_MS] are deleted unconditionally;
 *   their URI grants (if any) are revoked after successful deletion, so a
 *   grant is never revoked for a file that survived — cleanup follows the
 *   grant's lifetime, not a fixed grace.
 * - The count/size quota counts ALL surviving snapshots: a burst of shares
 *   inside the grace period must not let the quota be exceeded silently.
 * - Evict oldest grace-expired, non-active files WITHOUT grants first.
 * - If still over quota, grant-held snapshots beyond the count/byte
 *   exemption caps become evictable oldest-first (lastModified is the
 *   grant-age proxy), with their URIs revoked after successful deletion.
 *   Grants within the caps and [activeSharePaths] remain quota-protected.
 */
internal fun planShareStagingCleanup(
    entries: List<ShareStagingEntry>,
    grantUriByPath: Map<String, String>,
    now: Long,
    activeSharePaths: Set<String> = emptySet(),
): ShareStagingCleanupPlan {
    val (expired, survivors) = entries.partition { entry ->
        now - entry.lastModified >= SHARE_STAGING_MAX_AGE_MS
    }
    val revokeUris = expired.mapNotNullTo(mutableListOf()) { grantUriByPath[it.path] }
    var totalBytes = survivors.sumOf { it.length }
    var count = survivors.size
    val evictForCap = mutableListOf<ShareStagingEntry>()
    for (file in survivors.sortedBy { it.lastModified }) {
        if (count <= MAX_SHARE_STAGING_FILES && totalBytes <= MAX_SHARE_STAGING_BYTES) {
            break
        }
        // Prefer non-granted snapshots before considering grant overflow.
        if (file.path in grantUriByPath) {
            continue
        }
        // An in-flight share's snapshot: the copy may stall past the grace
        // period while quota pressure exists — never evict it under the
        // chooser's feet.
        if (file.path in activeSharePaths) {
            continue
        }
        if (now - file.lastModified < SHARE_STAGING_CAP_GRACE_MS) {
            continue
        }
        evictForCap.add(file)
        totalBytes -= file.length
        count -= 1
    }
    val granted = survivors.filter { it.path in grantUriByPath }
        .sortedBy { it.lastModified }
    var grantedCount = granted.size
    var grantedBytes = granted.sumOf { it.length }
    for (file in granted) {
        if (count <= MAX_SHARE_STAGING_FILES && totalBytes <= MAX_SHARE_STAGING_BYTES) {
            break
        }
        if (grantedCount <= MAX_SHARE_GRANT_EXEMPT_FILES &&
            grantedBytes <= MAX_SHARE_GRANT_EXEMPT_BYTES
        ) {
            break
        }
        if (file.path in activeSharePaths) continue
        evictForCap.add(file)
        revokeUris.add(grantUriByPath.getValue(file.path))
        totalBytes -= file.length
        count -= 1
        grantedBytes -= file.length
        grantedCount -= 1
    }
    return ShareStagingCleanupPlan(
        deleteForAge = expired,
        revokeUris = revokeUris,
        evictForCap = evictForCap,
    )
}

/**
 * Retries revoking URI grants whose staging files are already gone
 * (P2-#17): a previous sweep may have deleted the file while its revoke
 * failed, or the process may have died between the delete and the revoke.
 * Returns the updated ledger: an entry is dropped only when its revoke
 * succeeds; a failed revoke keeps its entry so a later sweep retries it
 * instead of leaking the persisted grant forever.
 *
 * Pure except for the injected [revokeUri] callback, so the retry stays
 * unit-testable without Android stubs.
 */
internal fun retryOrphanedGrantRevokes(
    grants: Set<String>,
    livePaths: Set<String>,
    revokeUri: (String) -> Unit,
): Set<String> {
    var remaining = grants
    for ((path, grant) in loadShareGrants(grants)) {
        if (path in livePaths) continue
        try {
            revokeUri(grant.uri)
        } catch (_: Exception) {
            // Keep the entry: the next sweep retries the revoke.
            continue
        }
        remaining = dropShareGrant(remaining, path)
    }
    return remaining
}

/**
 * Executes a [ShareStagingCleanupPlan] (P2-#11): deletes the planned files
 * and drops their ledger entries first, then revokes the URI grants of the
 * files actually deleted — never before. Revoking first meant a failed
 * delete (or an aborted loop) left the file on disk with its ledger entry
 * but without the target app's read permission. A single stuck file never
 * blocks the rest: failures are skipped and their ledger entries kept, so a
 * later sweep retries them with the grant still valid.
 *
 * P2-#17: a failed revoke restores its ledger entry instead of dropping
 * it — the persisted URI grant would otherwise leak with no record left
 * to retry it. [retryOrphanedGrantRevokes] picks those entries up on the
 * next sweep even though their files are already gone.
 *
 * Pure except for the injected [deleteFile]/[revokeUri] callbacks, so the
 * ordering stays unit-testable without Android stubs. Returns the updated
 * grant ledger.
 */
internal fun executeShareStagingCleanup(
    plan: ShareStagingCleanupPlan,
    grantUriByPath: Map<String, String>,
    grants: Set<String>,
    deleteFile: (String) -> Boolean,
    revokeUri: (String) -> Unit,
): Set<String> {
    var remaining = grants
    val revokedUris = mutableListOf<Pair<String, String>>()
    for (entry in plan.deleteForAge + plan.evictForCap) {
        val deleted = try {
            deleteFile(entry.path)
        } catch (_: Exception) {
            false
        }
        if (deleted) {
            remaining = dropShareGrant(remaining, entry.path)
            grantUriByPath[entry.path]?.let { revokedUris.add(entry.path to it) }
        }
    }
    val failedRevokes = mutableListOf<String>()
    for ((path, uri) in revokedUris) {
        try {
            revokeUri(uri)
        } catch (_: Exception) {
            // Best effort, but the persisted grant must not leak without a
            // record: remember the path so its ledger entry is restored
            // below and a later sweep retries the revoke.
            failedRevokes.add(path)
        }
    }
    for (path in failedRevokes) {
        grants.firstOrNull { parseShareGrant(it)?.filePath == path }?.let {
            remaining = remaining + it
        }
    }
    return remaining
}
