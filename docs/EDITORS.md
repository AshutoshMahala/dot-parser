# Using it in an editor

> **Available since 0.5.0.**

Editors and language servers parse a file on almost every keystroke, so most of
the time the file is unfinished. By default a failed parse returns no document
at all. That's the right default for a build tool, but an editor still wants an
outline, highlighting and errors for the part that is done.

This page collects the opt-in features for that:

- [converting byte positions to editor lines and columns](#editor-position-conversion) (unreleased)
- [seeing complete names before their statement is finished](EVENTS.md#outline-while-typing) (unreleased)
- [observing delimiters and completed declaration ranges](EVENTS.md#delimiters-and-completed-declaration-ranges) without a tree (unreleased)
- keeping the finished part of a DOT file, or of markup
- keeping the trees of HTML-like labels, and checking chosen labels later
- keeping comments
- reading files in other encodings

All of them are off by default. Their small fixed costs are listed under
[memory](#memory).

## Editor position conversion

> **Unreleased.** Not in 0.5.0.

Positions in the library are byte offsets into your source. Editors and
language servers usually want a line and a column. `textPosition` converts one
offset when you ask:

```zig
const position = try dot.location.textPosition(source, byte_offset, .{
    .source_encoding = document.source_info.encoding,
    .column_encoding = .utf16,
});
// position.line and position.character are zero-based, like LSP positions.
```

- `line` and `character` count from zero, as in the Language Server Protocol
  (LSP).
- `.source_encoding` is the encoding of `source`; the default is `.utf8`. For a
  document, pass `document.source_info.encoding`.
- `.column_encoding` chooses what a column counts, whatever the source
  encoding: `.utf16` (the default, as in LSP) counts UTF-16 units, `.utf8`
  counts UTF-8 bytes, and `.utf32` counts characters (Unicode scalar values).
  None of them counts what you see on screen: a tab is one, and so is each
  part of a combined character.
- A BOM at the start of `source` is counted like any other character. If your
  editor's text has no BOM, adjust for that yourself.
- Lines end at LF, CRLF or a lone CR, as everywhere else in the library.
- Each broken code unit (a bad byte in UTF-8, a bad 2-byte unit in UTF-16,
  and so on, including an incomplete one at the end) counts as one replacement
  character, U+FFFD. Your source is not changed.

| Error | When |
| --- | --- |
| `error.InvalidOffset` | The offset is past the end of `source`. |
| `error.InvalidBoundary` | The offset is inside a character. This can happen at the end of a one-byte diagnostic on a non-ASCII character. |
| `error.SourceTooLarge` | `source` is larger than 4 GiB. |
| `error.PositionOverflow` | The column doesn't fit in a `u32`. |

To round instead of failing on `InvalidBoundary`, pass `.boundary = .before` for
the start of a range and `.boundary = .after` for its end; both round outwards
to a whole character. The default, `.strict`, returns the error. Stored
positions don't change.

It allocates nothing and keeps no line index, so each call reads the source
from the start up to the offset. It isn't metered and can't be cancelled. For
many lookups, keep your own line index rather than converting every token on
every keystroke. Parsing does no extra work for this. `markup.location` has the
same function.

## Keep the finished part of a DOT file

To show names **before** their statement is finished, use
[early events](EVENTS.md#outline-while-typing) (unreleased) instead of a
document: set `Consumer.observations = dot.events.Observations.early`. Your
consumer then hears about each complete name as soon as it is read, even if
its statement never finishes, and the library builds no tree. To also see a
name that is still being typed, use `dot.events.Observations.previews`, or
`.all` for names, previews and delimiters. [Token previews](EVENTS.md#unfinished-token-previews) report
the unfinished name at the end of the input or when a session pauses, and tell
you when it is finished or rejected. A preview is only raw text; it isn't a
checked name or part of the document.

To keep the finished part as a document, turn on `retention.partial`:

```zig
const Editor = dot.Profile(.{ .policy = .{
    .retention = .{ .partial = true },
} });
var result = Editor.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);
if (result.document) |*document| {
    _ = document.state;           // .complete or .partial
    _ = document.scopeComplete(); // is the DOT itself complete (not: is it valid)
    _ = document.unrepresented(); // the end of the file that wasn't kept, or null
    var gaps = document.skippedRanges();
    while (gaps.next()) |gap| {
        _ = gap.range;            // a part skipped after an error
        _ = gap.scope;            // the scope it was in
    }
    var scopes = document.subgraphs();
    while (scopes.next()) |scope| {
        _ = scope.state();        // each subgraph is complete or partial too
        _ = scope.sourceRange();
    }
}
```

**What you get.** The usual `Document` type, read the usual way. It has the
statements that were finished and every subgraph that was opened; unfinished
subgraphs are marked partial. A statement only appears once it is complete, so
you never see half an edge. If the file fails before a `graph` or `digraph`
header has begun, there is no document.

**Statements after an error** (unreleased). With `on_error = .collect`, the
parser skips the statement that failed, and keeps the finished statements
after it once it has found a safe place to carry on. With `.fail_fast`, it
keeps only the part before the error. Nothing is guessed: an unclosed quote or
comment leaves the rest of the file uncovered, and no closing brace or name is
invented. This setting never changes whether a file is accepted.

**Finding the gaps.**

- `skippedRanges()` (unreleased) lists the parts skipped after errors, in the
  order the parser met them, each with the scope it was in. A gap can still
  contain kept statements: when the edge `{ d } -> ;` fails, its whole text is
  a gap, but the statement `d` inside the braces is kept.
- `unrepresented()` gives the end of the file that wasn't kept, or `null` if
  the kept part reaches the end. Such an end is left when the parse stopped
  early: at a fail-fast error, a cancel, a full limit or buffer, or an
  unclosed quote or comment. When recovery reaches the end of the file, even
  with errors, it is `null`. It never includes the `skippedRanges()` gaps. It
  is **not** a safe place to restart parsing.
- Something missing at the end, such as a final `}`, has no bytes, so no range
  shows it. Look at the diagnostics and the completeness calls as well as the
  ranges.
- `document.root_closed` (unreleased) is `true` once the parser has read the
  graph's closing `}`. That `}` is kept even if the parse is cancelled right
  after it. It doesn't mean the rest of the file was checked:
  `unrepresented()` can still show text after the `}`, such as a trailing
  comment.

**Where it works.** Fixed and growing storage, both scanners, cancellation,
limits, run-time settings and [sessions](EXECUTION.md). A session's document is
readable only once the session has finished, not while it is paused. `measure`
still returns sizes only for a successful parse.

**Cost of `scope.state()`** (unreleased). On a partial document, it reads
through all the statements inside that scope each time you call it. Calling it for every
scope of a deeply nested outline can take time that grows with the square of
the size, so don't do it on every keystroke. On a complete document it is
instant.

**Complete isn't valid.** A complete document can still fail validation, and a
partial document is never `documentValid()`. Validating a partial document
checks only what was kept, and reports that it didn't cover everything: the
validation result's `coverage` is `.incomplete`, with the byte offset of the
first part that wasn't kept. `document.firstUnrepresented()` (unreleased) gives
the same offset. `parseAndValidate`
validates the kept part after a syntax error when collecting errors, but not
after a stop or a fail-fast error.

**Graph kind.** With `validation.graph.treated_as = .auto`, `effectiveKind` is
`null` for a partial graph until a kept edge uses `->`, because the unread part
could still change the answer. A complete graph with no `->` is `.undigraph`.
Graph-kind restrictions only apply once the kind is known.

### If you read the raw arrays

Use the statement and scope views; they always give a safe outline. The raw
arrays can contain things the views hide:

- port references or chain links of a statement that wasn't finished. Its
  attribute pairs are removed (unreleased).
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
- **Markup keeps only the part before the first error**, even when collecting
  errors. Unlike DOT, it doesn't keep anything after the error. So a parse that
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

- For a partial DOT document, choose only names and values that were kept.
- Queue values in source order, without overlaps. A repeat or a step backwards
  returns `error.SelectionOutOfOrder`.
- A bad range or spelling, or running out of memory, leaves the queue as it was.

| Error from `requestMarkup` | Cause |
| --- | --- |
| `error.MarkupRetentionDisabled` | DOT `retention.markup` is off. |
| `error.MarkupNotPassthrough` | `markup` isn't `.passthrough`. |
| `error.DocumentUnavailable` | There is no DOT document. |
| `error.CompositionStopped` | The DOT step can't be continued: it stopped early, a diagnostic wasn't delivered or the bag asked to stop, or it failed with `.fail_fast`. |
| `error.SelectionOutOfOrder` | The value starts before the end of the one queued before it. |
| `error.SelectionClosed` | `processPendingMarkup` was already called. |
| `error.InvalidSpan` | The range is outside the source or, in a partial document, isn't a kept name or value. |
| `error.InvalidIdentifier` | The range isn't exactly one DOT name or value. |
| `error.OutOfMemory` | The queue couldn't grow. |

`processPendingMarkup` returns the first four in the same way, and
`error.SelectionClosed` if it was already called. It can also return the label
checker's configuration and input errors. Running out of memory while keeping
a label's result isn't returned as an error: it is reported as a diagnostic,
and `result.markup.stop` is `.retention_storage`.

**How the labels' state changes.** The DOT side never changes.

| Stage | Labels |
| --- | --- |
| Nothing queued | Not requested; doesn't affect completeness |
| Queued, not checked yet | `.not_processed`; `result.pendingMarkup()` lists them |
| All checked, all trees complete | `.complete`, even if a tree failed validation |
| Any tree missing or partial | `.partial` |
| Stopped before all were checked | The rest stay queued; not complete |

`result.markup.selection` is then `.selected_operands`, so `result.markup.allValid()`
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
always counted in bytes of your source. To turn them into an editor's line and
column, use [textPosition](#editor-position-conversion) (unreleased).

## Memory

- **DOT partial results with growing storage** allocate a small record before
  parsing to track the lists (104 bytes on a 64-bit target). The lists keep
  their spare room rather than being trimmed when parsing ends, which in tests
  kept 26–34% more memory. Exact size hints or fixed buffers avoid that.
  `result.deinit` frees everything.
- **With fixed buffers**, nothing extra is allocated.
- **Keeping the part before a failure** needs no extra scanning or
  allocation: the parser returns what it had already built.
- **Keeping statements after an error** (unreleased) stores them like any
  others. Each skipped part also takes two extra statement slots (16 bytes in
  all, on current targets). Growing storage allocates them as needed; with
  fixed buffers, count them in `statements`. If there is no room, the parse
  stops with a storage failure, rather than losing track of a gap. The
  document, node, edge and subgraph records are no bigger.
- **Partial results make every DOT document 8 bytes larger**, even when they
  are off, and allocator-owned results have one extra pointer. Node, edge and subgraph
  records are unchanged.
- **Keeping label trees** holds all of them at once, instead of one reused set
  of buffers. No list is allocated while it's off, and fixed settings without it
  leave that code out.
- **Checking chosen labels later** uses a queue of 8 bytes per queued label,
  plus room to grow. It is allocated only when you queue something and freed
  once processed; after a stop, it holds the remaining labels until
  `result.deinit`. Fixed settings without it leave that code out.

Speed costs are in [Performance](PERFORMANCE.md#cost-of-opt-in-features).

## Not available yet

- Keeping markup parts after the first error that the parser recovered safely
- Checking labels in small steps, with fixed buffers, or with one budget for
  DOT and its labels
- Resumable sessions for UTF-16 and UTF-32 input

See the [roadmap](ROADMAP.md).

## Examples

- [partial_documents.zig](../examples/partial_documents.zig): a partial DOT
  document, and a complete one with a partial label
- [partial_graph.zig](../examples/partial_graph.zig) (unreleased): the edges
  and colors kept from before and after a broken statement, read through the
  [semantic graph](IR.md#partial-graphs-for-editors)
- [attached_markup.zig](../examples/attached_markup.zig): check chosen labels
  later, in the same result
- [markup_partial.zig](../examples/markup_partial.zig): the finished part of
  markup on its own
- [comments.zig](../examples/comments.zig): keep comments with their positions

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.
