# Using it in an editor

> **Available since 0.5.0.**

Editors and language servers parse a file on almost every keystroke, so most of
the time the file is unfinished. By default a failed parse returns no document
at all. That's the right default for a build tool, but an editor still wants an
outline, highlighting and errors for the part that is done.

This page collects the opt-in features for that:

- [observing complete names before statements finish](EVENTS.md#outline-while-typing) (Unreleased)
- keeping the finished part of a DOT file, or of markup
- keeping the trees of HTML-like labels, and checking chosen labels later
- keeping comments
- reading files in other encodings

All of them are off by default. Their small fixed costs are listed under
[memory](#memory).

## Editor position conversion

> **Unreleased.**

Stored spans always count original bytes. Both `dot.location` and
`markup.location` can derive editor coordinates on request:

```zig
const position = try dot.location.textPosition(source, byte_offset, .{
    .source_encoding = document.source_info.encoding,
    .column_encoding = .utf16,
});
// position.line and position.character are zero-based, like LSP positions.
```

Source encoding defaults to UTF-8. Column encoding defaults to `.utf16`;
`.utf8` counts UTF-8 bytes and `.utf32` counts Unicode scalars, irrespective of
the source encoding. These are not grapheme or display-cell columns. A tab
counts as one, and a leading BOM counts as a scalar if present in `source`.
Match the text your editor holds: if it strips the BOM, account for that at
the integration boundary.

LF, CRLF and standalone CR follow the ordinary physical-line policy. Malformed
code units, including an incomplete final unit, count as one U+FFFD replacement
each for positions only; source bytes are unchanged. Queries inside a scalar or
code unit return `InvalidBoundary`; out-of-range offsets return `InvalidOffset`.
This can also happen at the end of a one-byte diagnostic on a valid non-ASCII
character. Use `.boundary = .before` for a range's start and `.boundary = .after`
for its end to round outward to scalar boundaries. The default `.strict` keeps
the boundary error; ordinary byte locations and stored spans are unchanged.
Sources beyond the u32 domain return `SourceTooLarge`; a converted column that
cannot fit in u32 returns `PositionOverflow` instead of wrapping.

This helper allocates nothing, stores no line index, and scans O(offset) per
call. It is not work-metered or cancellable. Many arbitrary queries may warrant
an editor-owned line index; don't recompute every token's location on each
keystroke. Ordinary parsing, byte spans and byte columns incur no added work.

## Keep the finished part of a DOT file

For an outline **before a statement finishes**, use the Unreleased
[early event observations](EVENTS.md#outline-while-typing) with
`Consumer.observations = dot.events.Observations.early`. Complete names can be exposed even when
their statement never commits, without retaining the library's tree. This is
separate from the partial-document option below. For raw unfinished names,
select `dot.events.Observations.previews` (or `.all` for both): [token previews](EVENTS.md#unfinished-token-previews)
cover actual EOF and metered pauses, with separately charged callbacks and
explicit retirement. Their raw spans are not trusted identifiers or tree nodes.

Turn on `retention.partial`:

```zig
const Editor = dot.Profile(.{ .policy = .{
    .retention = .{ .partial = true },
} });
var result = Editor.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);
if (result.document) |*document| {
    _ = document.state;           // .complete or .partial
    _ = document.scopeComplete(); // is the DOT itself complete (not: is it valid)
    _ = document.unrepresented(); // unfinished suffix, or null
    var gaps = document.skippedRanges();
    while (gaps.next()) |gap| {
        _ = gap.range;            // failed/skipped statement or region
        _ = gap.scope;            // containing DOT scope
    }
    var scopes = document.subgraphs();
    while (scopes.next()) |scope| {
        _ = scope.state();        // each subgraph is complete or partial too
        _ = scope.sourceRange();
    }
}
```

**What you get.** The usual `Document` type, read the usual way. It has retained
completed statements and every subgraph that was opened;
unfinished subgraphs are marked partial. A statement only appears once it is
complete, so you never see half an edge.

**Unreleased: later recovered statements are kept too.** With
`on_error = .collect`, a failed statement is abandoned and later completed
statements are retained after a safe synchronization boundary. With
`.fail_fast`, only the safe prefix is kept. Partial retention remains off by
default and does not change acceptance. Nothing is guessed: an unclosed quote
or comment leaves the rest uncovered; no closing brace or name is invented.

`skippedRanges()` gives internal recovery gaps in encounter order. A failed
outer edge's range may contain independently retained endpoint-body statements;
it does not mean every byte within the range lacks a representation.
`unrepresented()` gives only the unfinished suffix, not those gaps. It is
**not** a safe place to restart parsing, and is null if recovery reached the
end despite errors. A missing token at EOF has no corresponding source bytes;
consult diagnostics and completeness as well as the ranges.
The root closing brace is retained once consumed, even if cancellation happens
before the final EOF check. Its presence does not claim that trailing input was checked.
If the file fails before a `graph` or `digraph` header has begun, there is no
document.

**Where it works.** Fixed and growing storage, both scanners, cancellation,
limits, run-time settings and [sessions](EXECUTION.md). A session's document is
readable only once the session has finished, not while it is paused. `measure`
still returns sizes only for a successful parse.

`scope.state()` currently scans that scope's statement interval on partial
documents. Querying every nested scope can be quadratic in deep outlines;
complete-document checks are constant-time. Avoid repeated queries on every
keystroke until a cached outline-state pass is available.

**Complete isn't valid.** A complete document can still fail validation, and a
partial document is never `documentValid()`. Validating a partial document
checks only what was kept, and reports that it didn't cover everything
(`coverage.incomplete` names the earliest gap or unfinished suffix, also
available through `document.firstUnrepresented()`). `parseAndValidate`
validates the kept part after a syntax error when collecting errors, but not
after a stop or a fail-fast error.

**Graph kind.** With `validation.graph.treated_as = .auto`, `effectiveKind` is
`null` for a partial graph until a kept edge uses `->`, because the unread part
could still change the answer. A complete graph with no `->` is `.undigraph`.
Graph-kind restrictions only apply once the kind is known.

### If you read the raw arrays

Use the statement and scope views; they always give a safe outline. The raw
arrays can contain things the views hide:

- port references or chain links of a statement that wasn't finished;
  unattached attribute pairs are discarded on abort
- order entries for statements still being built. `statement(id)` returns
  `null` for those, and iterators and counts skip them.
- a subgraph at the start of a statement only becomes a standalone statement
  once the parser knows it isn't the start of an edge
- an edge's `complete()` stays false until its attributes are attached
- an unfinished subgraph record has `subtree_end == 0`. The views turn that
  into safe bounds for you.

## Keep the finished part of markup

The markup parser has the same option:

```zig
const Editor = markup.Profile(.{ .policy = .{
    .mode = .structural,
    .retention = .{ .partial = true },
} });
var parsed = Editor.parseBorrowed(allocator, "<root><done/><child x='unfinished", bag.sink(), .{});
defer parsed.deinit();
if (parsed.document) |document| {
    _ = document.state; // .partial here
    var roots = document.roots();
    while (roots.next()) |node| {
        _ = node.state();           // .partial for the unfinished <root>
        _ = node.children();        // <done/> is there inside <root>
        _ = node.attributes();      // finished attributes are there too
        _ = node.subtreeComplete(); // false: this element isn't complete
        _ = node.headerComplete();  // true for <root>; null for text, comments, CDATA
    }
    _ = document.unrepresented(); // the source the tree doesn't cover
}
```

- `subtreeComplete()` says whether an element and everything inside it is
  complete. `scopeComplete()` checks just that element. Today they always
  agree, because an unfinished child also leaves its parents unfinished.
  Neither says the markup is valid. The `.not_processed` state is reserved and
  isn't returned yet.
- **Markup keeps only the part before the first error**. Unlike DOT collection,
  it does not retain later recovered statements. So a parse that
  reached the end (`parsed.completion == .complete`) can still have a partial
  document, for example when only a closing tag is missing. Missing quotes,
  comments and closing tags are never filled in.
  [Closing-tag typo recovery](MARKUP.md#closing-tag-typo-recovery) only affects
  which later errors are reported, not the kept part.
- `unrepresented()` gives the rest of the source, possibly including some
  whitespace already read. It isn't a restart point, and it is empty when only
  a closing tag is missing at the end.
- It works with both scanners, fixed and growing storage, sessions, workspaces
  and run-time settings. A cancel, unsupported input, or a full limit or buffer
  can also leave a partial document. A stop before parsing starts leaves none.
- Outcomes and diagnostics don't change. Both presets turn this setting off.
- Validation works as for DOT: `validate` checks the kept tree and reports what
  it couldn't cover, and `documentValid()` is false for a partial document.
- If you read the raw records, see
  [building a document yourself](MARKUP.md#building-a-document-yourself).

## Keep the label trees from a DOT file

When you [check every label while parsing](LABELS.md#check-every-label-while-parsing),
each label's tree is normally checked and then thrown away. To keep them:

```zig
const Editor = dot.Profile(.{
    .policy = .{ .retention = .{ .partial = true, .markup = true } },
    .processors = .{ .markup = markup.Profile(.{ .policy = .{
        .retention = .{ .partial = true },
    } }) },
});
var bag = Editor.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var result = try Editor.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator); // frees the DOT document and every label tree
for (result.markupResults() orelse &.{}) |child| {
    _ = child.envelope; // the whole <...> value, in DOT file positions
    _ = child.input;    // the label's inner bytes and where they start in the file
    _ = child.result.parse.document; // the label's tree; may be partial or null
    _ = child.result.validation;
}
```

Three separate settings:

| Setting | Controls |
| --- | --- |
| DOT `retention.partial` | Keep the finished part of the DOT file after an error |
| DOT `retention.markup` | Keep each checked label's result |
| Label checker `retention.partial` | Keep the finished part of a label after an error |

- All three are off by default, and each can be changed per call when its
  profile has run-time settings.
- Keeping trees never turns checking on. With `markup = .passthrough`, you can
  still [check chosen labels later](#check-chosen-labels-later-in-the-same-result);
  with `.none` you can't. A label checker must be bound.
- `markupResults()` is `null` when keeping is off. Otherwise it is a list in
  source order, possibly empty. Each `<...>` part of a joined value like
  `<a> + <b>` gets its own entry.
- Entries stay valid even if the DOT parse fails later, so match them to the DOT
  document by source position, not by statement.
- A label tree's positions are relative to its own bytes (`child.input.bytes`).
  Add `child.input.origin` to get file positions. Diagnostics already use file
  positions.
- Don't free entries yourself: `result.deinit` frees everything.

**Is it complete?**

| Call | Answers |
| --- | --- |
| `result.scopeComplete()` | Is the DOT itself complete? |
| `result.subtreeComplete()` | Is the DOT complete, and every requested label too? |
| `result.state()` | `.complete`, `.partial`, `.not_processed` (labels requested but not checked yet), or `.empty` (no DOT document at all) |
| `result.markup.representation` | The labels alone. Check `result.markup.requested` first. |

A complete but empty graph, `graph {}`, is `.complete`, not `.empty`. To learn
why a parse failed, look at the DOT outcome. Complete and valid are separate:

- A label that fails to parse leaves the DOT complete but the whole partial.
- A repeated attribute makes a complete tree invalid, but not partial.
- Labels you didn't ask to check don't affect completeness.

**Memory and limits.** Each kept tree has its own buffers, so memory grows with
all the kept trees, instead of one reused set. The source is never copied. This
still uses an allocator, runs to completion, and has no shared work budget or
fixed-buffer version yet.

**Your own label checker** can take part if it returns
[owned results](CUSTOM_PROCESSORS.md#optional-owned-results). One that doesn't
still works with keeping off. Asking it to keep trees is rejected before
parsing: `error.MarkupRetentionUnsupported` for run-time settings, or a compile
error for compiled ones.

[partial_documents.zig](../examples/partial_documents.zig) shows a complete DOT
file with a partial label, and an unfinished DOT subgraph.

## Check chosen labels later, in the same result

Sometimes you want to check only some labels, but still have them belong to the
DOT result and count towards its completeness. Leave automatic checking off,
keep results on, then queue the labels you want:

```zig
const Editor = dot.Profile(.{
    .policy = .{ .markup = .passthrough, .retention = .{ .markup = true } },
    .processors = .{ .markup = markup.Profile(.{ .policy = .{
        .retention = .{ .partial = true },
    } }) },
});
var bag = Editor.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var result = try Editor.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);
if (result.dot.document) |document| {
    for (document.attributes) |attribute| {
        if (std.mem.eql(u8, document.text(attribute.key), "label"))
            try result.requestMarkup(allocator, attribute.value);
    }
}
// The chosen labels are queued; none has been checked yet.
try Editor.processPendingMarkup(allocator, &result, bag.sink(), .{});
// Read the results with result.markupResults().
```

**Queueing.** `requestMarkup` takes one whole value, including its `<...>`. It
checks the range and spelling, queues each `<...>` part of a joined value, and
ignores other parts. It doesn't decode or copy anything, and it can't prove a
range you built yourself came from the document, so use ranges from the
document.

- For a partial DOT document, choose only values inside the kept part.
- Queue values in source order, without overlaps. A repeat or a step backwards
  returns `error.SelectionOutOfOrder`.
- A bad range or spelling, or running out of memory, leaves the queue as it was.

**How the labels' state changes.** The DOT side never changes.

| Stage | Labels |
| --- | --- |
| Nothing queued | Not requested; doesn't affect completeness |
| Queued, not checked yet | `.not_processed`; `result.pendingMarkup()` lists them |
| All checked, all trees complete | `.complete`, even if a tree failed validation |
| Any tree missing or partial | `.partial` |
| Stopped before all were checked | The rest stay queued; not complete |

`result.markup.selection` is then `.selected_operands`, so `markup.allValid()`
covers only the labels you chose, not every `<...>` in the file. The `visited`,
`valid`, `rejected` and `unprocessed` counts cover the labels that were checked;
any still queued are in `pendingMarkup()`. Queued labels keep
`documentValid()` and `subtreeComplete()` false. A partial DOT document stays
partial even if all its labels are fine.

**One batch.** Calling `processPendingMarkup` closes the queue. Queueing more,
or processing again, returns `error.SelectionClosed`, with no repeated
diagnostics. An empty queue does nothing.

- The DOT parse's `on_error` setting carries over to the labels.
- The label checker's run-time settings and cancel check are passed fresh, as
  `.markup` options to `processPendingMarkup`; its resources go in
  `.markup_resources`. They are checked before any label is processed.
- If the DOT parse stopped early or failed with fail-fast, this call can't
  continue past that.

**One exception: too little validation scratch.** If DOT validation reported
`.insufficient_scratch`, a scratch array you passed was too small, so nothing
is actually wrong with the parse. With `.collect`, label checking can still go
ahead, as long as every diagnostic was delivered and the bag didn't ask to
stop. With `.fail_fast` it can't. Checking labels never reruns DOT validation,
so `result.dot.documentValid()` and `result.documentValid()` stay `false`. They
mean "proven valid", nothing more. `result.dot.validation.?.outcome` gives the
required and provided sizes; validate again with enough scratch if you need to.
`result.scopeComplete()` stays `true` for the complete DOT.

**Stops during the batch.** A fail-fast error, a stop inside a label checker, or
the bag asking to stop leaves the remaining labels queued. When collecting,
ordinary label errors don't stop the batch. What happened is in
`result.markup.stop` and each label's result; the DOT outcome isn't changed.
`result.markup.diagnostic_delivery` and `diagnostic_stop` record how the bag
responded during this stage, including a failure to store a result.

**Good to know.** Use the same allocator for parsing, queueing, processing and
freeing. Keep the source alive and unchanged. The queue is allocated only when
you queue something and freed once processed, and each label has its own
buffers. This isn't resumable and has no shared work budget. Diagnostics arrive
in order: DOT's first, then the chosen labels in source order.

[attached_markup.zig](../examples/attached_markup.zig) is the complete example.

## Keep comments

To show or keep comments, turn on [comment retention](READING_DOCUMENTS.md#comments).
With partial results on too, the comments in the kept part are available after
an error.

## Files in other encodings

Some editors and Windows tools save files as UTF-16. To parse them without
converting, see [source encodings](ENCODINGS.md). Positions and columns are
always counted in bytes of your source; converting them to an editor's line
and column is optional through [textPosition](#editor-position-conversion).

## Memory

- **DOT partial results with growing storage** allocate a small record before
  parsing to track the lists (104 bytes on a 64-bit target). The lists keep
  their spare room rather than being trimmed when parsing ends, which in tests
  kept 26–34% more memory. Exact size hints or fixed buffers avoid that.
  `result.deinit` frees everything.
- **With fixed buffers**, nothing extra is allocated.
- **Terminal salvage** needs no extra scanning or allocation. Continuing DOT
  recovery retains later syntax normally and stores two compact order slots
  (16 bytes on current targets) per skipped region. Growing order storage may
  allocate; fixed-buffer callers must reserve these slots. Exhaustion stops
  recovery honestly rather than silently losing gaps. Document, node, edge and
  subgraph record sizes are unchanged by this extension.
- **DOT documents are 8 bytes larger** even with partial results off, and
  allocator-owned results have one extra pointer. Node, edge and subgraph
  records are unchanged.
- **Keeping label trees** holds all of them at once, instead of one reused set
  of buffers. No list is allocated while it's off, and fixed settings without it
  leave that code out.
- **Checking chosen labels later** uses a queue of 8 bytes per queued label,
  plus room to grow. It is allocated only when you queue something and freed
  once processed; after a stop, it holds the remaining labels until
  `result.deinit`. Fixed settings without it leave that code out.

Speed costs are in [Performance](PERFORMANCE.md#cost-of-opt-in-features).

## Examples

- [partial_documents.zig](../examples/partial_documents.zig): a partial DOT
  document, and a complete one with a partial label
- [attached_markup.zig](../examples/attached_markup.zig): check chosen labels
  later, in the same result
- [markup_partial.zig](../examples/markup_partial.zig): the finished part of
  markup on its own
- [comments.zig](../examples/comments.zig): keep comments with their positions

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.

## Not available yet

- Keeping markup parts after the first error that the parser recovered safely
- Checking labels in small steps, with fixed buffers, or with one budget for
  DOT and its labels
- Resumable sessions for UTF-16 and UTF-32 input

See the [roadmap](ROADMAP.md).
