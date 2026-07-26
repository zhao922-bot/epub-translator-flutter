# Cross-file footnote anchor repair design

## Context

`Communion ..._translated.epub` retains all 442 internal target addresses,
but some source marker text was moved outside its anchor during HTML fallback.
Seventeen `footnote_ref_*` anchors are empty, and fourteen `doc-backlink`
anchors incorrectly contain the full translated citation.

The source EPUB is valid. The existing structure lock protects local fragment
links and standard `doc-noteref` markup, but does not recognise this EPUB's
cross-file footnote conventions:

- a body marker in `a#footnote_ref_* > span.footnote_ref`;
- a footnote return marker in `a[role="doc-backlink"] > span.footnote_num`;
- an `href` that points to another XHTML file plus a fragment.

## Scope

1. Treat those three forms as protected marker containers in the translator's
   HTML structure lock. If an API response empties, translates, or moves a
   protected marker, rebuild against the source HTML skeleton instead of
   accepting the malformed response.
2. Preserve legitimate ordinary hyperlinks and translatable footnote body text.
3. Repair the existing translated Communion EPUB locally, without an API call:
   restore body-marker text from the source, and restrict each return anchor to
   its source marker while leaving translated citation prose outside the link.
4. Write the repaired EPUB next to the current file using a distinct suffix;
   never overwrite the source or the existing translated file.

## Acceptance criteria

- A model response that moves a cross-file `footnote_ref` marker outside the
  link is rebuilt so the marker remains inside the original anchor.
- A response that places citation prose inside a `doc-backlink` marker restores
  the original marker-only link structure.
- Existing tests still show ordinary external links and footnote prose remain
  translatable.
- The repaired Communion EPUB has no empty `footnote_ref_*` markers and no
  expanded `doc-backlink` anchors; every internal anchor target resolves.
- Automated unit tests, static analysis, and a post-repair archive audit pass.

## Non-goals

- No full-book retranslations.
- No API requests for the repair operation.
- No changes to the EPUB's navigation document, CSS, or chapter ordering.
