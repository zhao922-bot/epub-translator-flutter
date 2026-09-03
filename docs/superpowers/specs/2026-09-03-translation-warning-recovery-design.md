# Translation warning recovery design

## Context

The translator currently keeps an EPUB run alive after exhausted API connection or receive timeouts by retaining source text for the affected blocks. The generated EPUB is useful, but the final job is still marked `completed`, so users cannot distinguish a fully translated book from a partial result. Degraded block tracking also lives on the long-lived translator instance and uses chapter-local string IDs, which can suppress cache writes for unrelated blocks in later chapters or runs.

Two adjacent reliability issues belong in the same repair batch:

- a hard-coded diagnostic path can write source text, model output, and errors outside the application's normal storage boundary;
- a secure-store read error is collapsed into “key missing”, so saving an unrelated setting can delete a key that may still exist.

## Goals

- Represent a usable but incomplete EPUB as `completedWithWarnings` rather than `completed`.
- Keep partial EPUB output exportable and make its warning state visible in the translation overview and job history.
- Let users retry a warning result while reusing successfully cached blocks.
- Prevent degraded-block state from leaking across chapters or translation runs.
- Prevent unrelated settings saves from modifying secrets whose read state is unknown.
- Remove the production hard-coded diagnostic write path.
- Preserve backward compatibility with existing job-history JSON.

## Non-goals

- Building a dedicated per-block repair editor or warning-details page.
- Persisting every degraded block identifier in job history.
- Changing retry counts, timeout durations, batching policy, prompts, or translation-quality heuristics.
- Deleting any diagnostic file that already exists on a user's machine.
- Refactoring the complete translation pipeline or settings architecture.

## Job status and persisted data

Add `completedWithWarnings` to `TranslationJobStatus` and add a non-negative `degradedBlockCount` field to `TranslationJob`.

Terminal status is selected after the translated EPUB has been repacked:

- zero degraded blocks: `completed`;
- at least one degraded block, but fewer than the selected run's total translatable blocks: `completedWithWarnings`;
- every selected translatable block degraded: `failed`.

The all-degraded case must not be presented as an exportable success. If an output file was already created before the all-degraded condition is finalized, it is not exposed through `hasExportableEpub`.

`hasExportableEpub` returns true for translation-phase jobs in either `completed` or `completedWithWarnings` when the output path ends in `.epub`. `canResumeTranslation` returns true for `completedWithWarnings` as well as resumable failed and cancelled jobs. Job-list retry capability follows the same rule so warning jobs expose a retry action.

`degradedBlockCount` is serialized as an integer. Missing, malformed, or negative values in legacy history load as zero. Existing `completed` entries remain `completed`; no history migration rewrites them.

## Degraded-block tracking

Replace the translator-wide `Set<String>` used for operational decisions with a run-scoped tracker keyed by the actual extracted block object. The tracker is cleared at the start of every public translation run. Test-only translation entry points also start with isolated tracking state.

Object-level tracking prevents identical chapter-local IDs such as `p-0` from colliding. The same extracted block instance flows through translation, footnote batching, and cache-write decisions, so degraded blocks remain excluded from cache while unrelated blocks are cached normally.

User-visible reporting stores only the total count. Runtime logs may include a bounded sample of block IDs for diagnosis, followed by the total count; they must not contain source text, translated text, API keys, or complete model responses.

Successfully translated blocks keep their existing cache entries. Degraded blocks are not cached. Retrying a warning job therefore performs the existing cache-restoration scan, reuses good blocks, and sends only cache misses—including degraded blocks—back through translation.

## Translation result flow

The EPUB translation pipeline continues after an individual exhausted timeout by retaining that block's last usable content and marking the block degraded. Progress can reach 100 percent because processing is finished, but terminal state communicates output quality:

1. Start a run with an empty degraded tracker.
2. Translate selected blocks and mark fallback blocks as degraded.
3. Skip cache writes only for the exact degraded block objects.
4. Repack the EPUB when at least one selected block produced a non-degraded translation, or when the selected run contains no translatable blocks.
5. Set `completed`, `completedWithWarnings`, or `failed` from the rules above.
6. Persist the terminal job and its `degradedBlockCount` in history.

A selected run with zero translatable blocks keeps the existing successful behavior and is not treated as all-degraded.

## User interface

The application adds localized labels for `completedWithWarnings`, using “完成但有警告” in Chinese and “Completed with warnings” in English.

The translation overview uses warning-container colors and an alert icon for this state. It shows a concise localized message containing the degraded block count and retains the normal EPUB open/share/save controls. The completed state continues to use the success treatment.

The jobs page shows the warning status, keeps output opening enabled, and enables retry/resume. Existing retry plumbing is extended to accept `completedWithWarnings`; retry uses the same input, output, selection, and cache-restoration flow as failed or cancelled translation jobs.

No modal confirmation is required to open a partial EPUB because the warning remains visible next to the output action.

## Secure-store tri-state handling

Secret reads must distinguish:

- `value`: the secure store returned a non-empty key;
- `missing`: the secure store completed successfully with no key;
- `readFailure`: the secure store threw and the current value is unknown.

`SettingsStore` retains the read state independently for the legacy, DeepSeek, and custom provider secrets. Saving ordinary configuration writes the JSON settings file but skips secret mutation for any slot in `readFailure` state. This prevents a theme, language, timeout, or provider-setting save from deleting an unreadable key.

An explicit API-key edit carries the affected secret slot as an explicit mutation. A non-empty value writes the trimmed key; an empty value deletes it. A successful explicit mutation replaces `readFailure` with the corresponding known state. Provider preset changes are not considered explicit key edits unless they supply a new key value.

Legacy file-to-secure-store migration only deletes the legacy plaintext key from serialized settings after all required secure writes succeed. A secure read or write failure leaves the in-memory configuration usable for the current session and must not trigger an implicit secret deletion.

## Diagnostic privacy

Remove the hard-coded `_p13_failure_diag.log` production write and its payload construction. Existing structured application logs remain, subject to their current sanitization. This change does not locate, read, truncate, or delete diagnostic files already present on disk.

## Error handling and compatibility

- `completedWithWarnings` is a terminal, non-active state.
- Warning jobs are exportable and resumable; completed jobs remain exportable but not resumable.
- Failed all-degraded jobs retain a sanitized explanation and are resumable when progress or cache data exists.
- Unknown future status strings continue to fall back through the existing defensive history parser.
- UI status switches must handle the new enum exhaustively.
- The change does not expose model response bodies or book text in logs or persisted history.

## Test strategy

Implementation follows test-driven development. Tests are added or changed before production code for these behaviors:

1. A run with one degraded block and at least one successful block finishes as `completedWithWarnings`, records the count, and exposes an exportable EPUB.
2. A run with no degraded blocks remains `completed` with count zero.
3. A run where every translatable block degrades finishes as `failed` and is not exportable.
4. Warning jobs round-trip through history JSON and legacy entries default the count to zero.
5. Warning jobs appear as non-active, openable, retryable, and resumable in job summaries.
6. The translation overview renders localized warning status, count, warning styling, and output actions.
7. Repeated chapter-local block IDs do not interfere with each other's cache writes.
8. A second run on the same repository instance begins with no degraded state from the first run.
9. Retrying a warning job reuses cached successful blocks and retranslates prior degraded cache misses.
10. A secure-store read failure followed by an unrelated settings update performs no write or delete for the affected secret.
11. Explicitly replacing or clearing a key after a read failure performs the requested secure mutation.
12. Source inspection or a focused regression test proves that the hard-coded diagnostic path and sensitive diagnostic payload are absent.

After focused tests pass, run the full Flutter test suite and static analysis. Existing live tests that require external credentials may remain skipped under their documented guards.

## Delivery boundary

This repair is complete when the new status is persisted and visible, partial output remains usable, retry targets uncached degraded blocks, degradation cannot leak between blocks or runs, secure-store read failures cannot cause implicit deletion, the hard-coded diagnostic writer is removed, and focused plus full regression verification passes.
