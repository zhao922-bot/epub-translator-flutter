package com.yang.epubtranslator

/** Share staging files older than this are swept unconditionally. */
internal const val SHARE_STAGING_MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000
/** Cap for share_staging/: newest files win, oldest evicted first. */
internal const val MAX_SHARE_STAGING_FILES = 20
internal const val MAX_SHARE_STAGING_BYTES = 200L * 1024 * 1024
/** Staging files younger than this are exempt from the count/size cap when
 * they carry no share grant: their chooser may still be open and the target
 * app may not have read the file yet. Files WITH a live grant are exempt
 * regardless of age (a fixed grace period cannot guarantee the receiver
 * has read the file). */
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
 * revoke first so a grant never outlives its file. */
internal data class ShareStagingCleanupPlan(
    /** Files past the max age: deleted unconditionally. */
    val deleteForAge: List<ShareStagingEntry>,
    /** Grant URIs to revoke before deleting [deleteForAge]. */
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
 *   their URI grants (if any) are revoked first so a grant never outlives
 *   its file — cleanup follows the grant's lifetime, not a fixed grace.
 * - The count/size quota counts ALL surviving snapshots: a burst of shares
 *   inside the grace period must not let the quota be exceeded silently.
 * - Eviction only takes the oldest grace-expired files WITHOUT a live
 *   grant; a live grant exempts its snapshot regardless of age.
 */
internal fun planShareStagingCleanup(
    entries: List<ShareStagingEntry>,
    grantUriByPath: Map<String, String>,
    now: Long,
): ShareStagingCleanupPlan {
    val (expired, survivors) = entries.partition { entry ->
        now - entry.lastModified >= SHARE_STAGING_MAX_AGE_MS
    }
    val revokeUris = expired.mapNotNull { grantUriByPath[it.path] }
    var totalBytes = survivors.sumOf { it.length }
    var count = survivors.size
    val evictForCap = mutableListOf<ShareStagingEntry>()
    for (file in survivors.sortedBy { it.lastModified }) {
        if (count <= MAX_SHARE_STAGING_FILES && totalBytes <= MAX_SHARE_STAGING_BYTES) {
            break
        }
        // A live share grant outlives any fixed grace period: never evict
        // its snapshot for quota.
        if (file.path in grantUriByPath) {
            continue
        }
        if (now - file.lastModified < SHARE_STAGING_CAP_GRACE_MS) {
            continue
        }
        evictForCap.add(file)
        totalBytes -= file.length
        count -= 1
    }
    return ShareStagingCleanupPlan(
        deleteForAge = expired,
        revokeUris = revokeUris,
        evictForCap = evictForCap,
    )
}
