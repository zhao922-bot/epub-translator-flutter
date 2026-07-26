# Cross-file footnote anchor repair design

## Context

`Communion ..._translated.epub` retains all 442 internal target addresses, but
an HTML-returning model response moved some source marker text outside its
anchor. Seventeen `footnote_ref_*` anchors were empty, and fourteen
`doc-backlink` anchors incorrectly contained full translated citations.

The source EPUB is valid. The failure shows that accepting model-generated HTML
and repairing it afterwards is not a sufficient structural safety boundary.
Even a structure lock must reason about model-created, deleted, or moved nodes.

## Safety architecture

The source block DOM is the only structure that may be rendered. A
`ProtectedAnchorTextSlots` template splits one root HTML fragment into:

1. a source-owned DOM skeleton, including every source element and attribute;
2. stable, document-ordered prose text slots outside protected footnote anchors
   and raw-text elements such as `script` and `style`.

Protected anchors and their complete marker subtree are never sent to the model
and never appear in the slot list. The protected forms are short marker anchors
using `a#footnote_ref_*`, `role~="doc-backlink"`, `role~="doc-noteref"`,
`epub:type~="noteref"`, or the existing cross-file `footnote_ref` /
`footnote_num` marker classes. Controlled marker forms include numeric,
bracketed, symbolic, single-letter, Roman-numeral, superscript-numeral, and
Chinese-numeral markers. This prevents ordinary prose links from being hidden
from translation.

The model translates only the slot strings. Rendering requires exactly one
plain-text result per slot, clones the source DOM, and assigns each result to the
corresponding source text node. A result such as `<script>`, `<img>`, or `<span>`
is serialized as escaped text; it is never parsed as markup. Source boundary
whitespace is retained so inline slots do not become joined words.
Raw-text element contents remain source-owned rather than becoming slots,
because HTML serializers do not escape text in every raw-text context.

This makes source DOM ownership the primary guarantee. The old post-hoc anchor
lock may remain temporarily for compatibility, but it is not extended by this
component and is not the safety mechanism for the new translation path.

## Data flow

```text
single-root source HTML
        |
        v
source DOM skeleton + translatable slot texts
        |                         |
        |                         v
        |                 model translates text only
        |                         |
        +------------+------------+
                     v
       strict slot-count validation
                     |
                     v
    clone source DOM and set Text.data only
                     |
                     v
          source-structured rendered HTML
```

## Scope

1. Build and unit-test the independent protected-anchor text-slot component.
2. Preserve ordinary prose links as normal translatable slots.
3. Preserve source anchors, marker text, attributes, nested elements, and slot
   boundary whitespace on every render.
4. Reject slot-count mismatches and treat all supplied slot values as text.
5. Document the future pipeline contract: models receive and return text slots,
   not HTML.

The current component task does not integrate with the translation API or alter
`EpubChapterTranslator`; that integration is a separate planned change.

## Acceptance criteria

- Supported short footnote markers do not appear in `slotTexts`.
- Ordinary prose link text remains translatable.
- Slot order is stable and rendering requires the exact same slot count.
- Rendered elements and attributes come only from the source DOM clone.
- Model-looking markup is escaped text and cannot create elements, attributes,
  images, or scripts.
- Source raw-text subtrees are not exposed as translation slots.
- Source markers (`*`, `[1]`, `1`) and boundary whitespace remain unchanged.
- HTML without protected anchors uses the same template and retains its source
  element skeleton.
- Focused unit tests and static analysis pass without a network or API call.

## Non-goals

- No translation API integration in the independent component task.
- No additional post-hoc model-HTML repair logic.
- No full-book retranslation.
- No changes to EPUB navigation, CSS, or chapter ordering.
