# Checking HTML-like labels

Graphviz lets you write labels in a small HTML-like language:

```dot
digraph {
    a [label=<<b>Bold</b> and <i>italic</i>>];
}
```

This page shows how to check what is inside those labels while you parse DOT
files. To parse HTML-like markup without DOT, see
[Parsing markup on its own](MARKUP.md).

> **Available since 0.4.0.** Label checking and the `markup_parser` module
> are included in the package.

## What happens by default

The DOT parser always finds where a `<...>` value ends, the same way Graphviz
does: by counting `<` and `>` until they balance. These values can appear
anywhere a name can, not just in `label`. What happens next depends on the
`markup` setting:

| `markup` | What happens | It is the default when… |
| --- | --- | --- |
| `.passthrough` | The value is kept exactly as written. Nobody looks inside, so `label=<<b>Bold</i>>` parses without complaint. | no label checker is bound |
| `.process` | A label checker checks what is inside. | a label checker is bound |
| `.none` | HTML-like values are reported as [unsupported](ERRORS.md#unsupported-is-not-invalid). | never |

So to check labels, bind a label checker, as shown below. Checking is then on
automatically.

The `markup` setting decides **whether** labels are checked. The label
checker's own settings decide **how**, through its [mode](MARKUP.md#two-modes):

- In 0.4.0 the built-in checker uses `.structural`: tags must match and
  attributes must be well-formed.
- On `main` (**unreleased**) it defaults to `.graphviz`, which also checks
  [Graphviz's tags and attributes](MARKUP.md#graphviz-vocabulary) and matches
  tag names ignoring ASCII case. It doesn't yet check all of Graphviz's label
  rules.

Neither mode is a browser HTML parser. Checking every label while parsing
covers **every** `<...>` value, not only labels. To check only labels, pick
them yourself, as shown [below](#check-the-labels-you-choose).

## Two ways to check labels

| | Check every label while parsing | Check the labels you choose, afterwards |
| --- | --- | --- |
| How | Add a label checker to your DOT profile | Parse DOT, then pass selected values to the markup parser |
| Which values | Every `<...>` value in the file | Only the ones your code picks, such as `label` |
| Diagnostics | One bag for DOT and labels together | Your choice of bag, separate from DOT's |
| Label trees | Discarded by default; opt-in retention is unreleased | Kept, if you want them |
| Memory | Allocator | Allocator or fixed buffers |
| Best for | "Is this whole file OK?" | Tools that need control or the parsed labels |

Both report errors at their real line and column in the DOT file.

## Check every label while parsing

Give your DOT profile a label checker. Every HTML-like value is then checked
during the same parse:

```zig
const dot = @import("dot_parser");
const markup = @import("markup_parser");

const Parser = dot.Profile(.{
    .processors = .{ .markup = markup.Profile(.{}) },
});

var bag = Parser.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var result = try Parser.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);

if (!result.documentValid()) {
    const locations = try allocator.alloc(dot.location.Location,
        try Parser.console.locationCapacity(bag.items()));
    defer allocator.free(locations);
    try Parser.console.renderBoxedList(bag.items(), 0, .{ .source = source }, locations, writer);
}
```

The result has two parts:

- `result.dot`: the ordinary DOT result, including the document. You still get
  the DOT document even when a label is wrong.
- `result.markup`: a summary of the labels: whether checking was on
  (`requested`), how many labels were checked (`visited`), how many were fine
  (`valid`), and whether every label was reached (`complete`).

`result.documentValid()` is true when the DOT is valid and every label was
checked and is fine. A file with no labels counts as fine.

If checking is off (`.passthrough` or `.none`), `documentValid()` only reflects
the DOT and says nothing about the labels. `result.markup.requested` is then
`false`, and `result.markup.allValid()` is also `false`, because nothing was
checked. Look at `requested` before relying on `allValid()`.
With retention enabled, [explicit delayed selection](#attach-delayed-results)
can later request checking and update this same result.

Each label is checked as soon as the parser has read the whole value, before it
reads any further. A value cut off by the end of the file isn't checked.
Everything runs in your thread, and your source is never copied.

Errors inside labels look like any other error, at their place in the DOT file:

```text
┌─ Error 1: repeated attribute name on one element
│ example.dot:1:39
│
│ 1 │ digraph { a [label=<<FONT COLOR='red' COLOR='blue'>Hello</FO…
│   │                           ──┬──       ^^^^^ same name as the earlier attribute
│   │                             └──── first attribute with this name
│
│ Hint: keep one attribute with the intended value, or change the duplicate-attribute policy
└─ E1 ─ [markup_parser:E.Validation.Attribute.006]
```

`parseAndValidate`'s last argument groups options for each side:

| Option | What it holds |
| --- | --- |
| `.dot` | The ordinary DOT options: run-time `.policy`, size hints in `.parse`, validation scratch in `.validation`, `.cancellation` |
| `.markup` | The label checker's options, such as a run-time `.policy` |
| `.markup_resources` | Resources for the label checker, such as `.scratch_allocator` |

### Turning checking on or off

Checking is on as soon as a label checker is bound. To bind one but keep
checking off, set `markup` in the DOT policy:

```zig
const Parser = dot.Profile(.{
    .policy = .{ .markup = .passthrough }, // bound, but not checked
    .processors = .{ .markup = markup.Profile(.{}) },
});
```

- **Presets don't change it.** Using `dot.presets.standard` or
  `dot.presets.lenient` keeps checking on. Set `markup` yourself to change it.
- **Per call.** With `.runtime_policy = true` on the DOT profile, each call can
  choose: `.dot = .{ .policy = .{ .markup = .passthrough } }` turns checking off
  for that call, and `.process` turns it back on. Each call starts again from
  the profile's compiled settings.
- **Off means not run.** When checking is off, the label checker isn't called
  and sets up no buffers. Its settings are still checked before parsing
  starts.
- **The checker's own settings are separate.** Turning checking on or off never
  changes them. To change them per call (`.markup = .{ .policy = ... }`), the
  label checker's profile needs `.runtime_policy = true` too.
- **`.process` needs a checker.** Without a bound label checker, `.process` in
  the compiled settings is a compile error. In per-call settings, the call
  returns `error.MarkupProcessorRequired` before reading any input.

Good to know:

- DOT and label settings are separate. Give each its own limits, as in the
  [composed example](../examples/composed_markup.zig).
- If DOT collects errors (the default), a bad label doesn't stop the rest of
  the file being checked. If DOT is set to fail fast, it stops after the first
  bad label, once that label has been fully checked.
- Label findings arrive when the parser reaches each label, before DOT's
  validation findings. See [order of diagnostics](ERRORS.md#order-of-diagnostics).
- This mode runs to completion. It can't run in [small steps](EXECUTION.md) yet.
- The checker reuses one set of buffers for all labels. That avoids thousands
  of small allocations, but the buffers stay as big as the largest label until
  the parse ends. Opt-in retained label trees instead own separate buffers.

### Retaining label trees for editors

> **Unreleased.** Processing and retention are separate choices.

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
defer result.deinit(allocator); // frees DOT and every retained child
for (result.markupResults() orelse &.{}) |child| {
    _ = child.envelope; // outer <...> operand, in DOT coordinates
    _ = child.input;    // inner bytes plus their original-source origin
    _ = child.result.parse.document; // child-local records; may be partial/null
    _ = child.result.validation;
}
```

| Setting | Controls |
| --- | --- |
| DOT `retention.partial` | Whether a failed outer parse keeps its DOT prefix |
| DOT `retention.markup` | Whether processed child results survive the call |
| Child `retention.partial` | Whether a failed child keeps its markup prefix |

All default off and are independently runtime-overridable when their profile
enables runtime policy. Child retention never turns processing on. With
`.passthrough`, explicit delayed selection can activate it; `.none` does not
allow attached processing. It requires a bound processor.

`markupResults()` is null when retention is inactive, otherwise a source-ordered
slice (possibly empty). Each raw HTML operand of a concatenation gets its own
entry. Entries remain useful even if DOT later fails or recovery encounters a
value outside the retained DOT prefix, so map them by source spans, not assumed
statement handles. Child records index `child.input.bytes`; add `input.origin`
for original-file positions. Diagnostics already use original-file positions.
Do not independently deinitialize child entries: the composed result owns them.

`result.scopeComplete()` checks the DOT representation. `subtreeComplete()`
also requires complete representations of all requested children.
`result.state()` uses the shared completeness enum, including `.not_processed`
when requested child work is pending and no representation is already partial.
`result.markup.representation` describes children alone. Check `requested`
first. These describe representation independently of validation and
`markup.complete` scheduling coverage.
An invalid label can therefore leave DOT complete but the subtree partial.
A repeated attribute can invalidate a complete tree without making it partial.
Unrequested processing is neutral for completeness, not a claim of validation.

Retaining children uses memory proportional to all retained child trees, rather
than one reused workspace. It does not copy source bytes. This remains a
synchronous allocator-backed API, with no combined work budget or fixed-buffer
composition yet. Custom processors may opt into this path by providing an owning
`CheckResult` and `Prepared.parseAndValidate`, with `result.deinit()` and the
same result/representation contract as the built-in child. A child result can
provide `subtreeComplete()` independently of validity; otherwise composition
conservatively treats a non-valid custom result as incomplete. Existing
workspace-only processors still work with retention off; unsupported retention
is rejected by policy preparation before parsing (`MarkupRetentionUnsupported`
for runtime policy, a compile error for a fixed baseline).

Run [partial_documents.zig](../examples/partial_documents.zig) for both a complete
DOT document with partial markup and an unfinished outer subgraph.

### Attach delayed results

> **Unreleased.** Use this when delayed children should belong to the same result
> and contribute to its completeness. Standalone delayed calls remain independent.

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
// Selected HTML operands are now pending; no child has run yet.
try Editor.processPendingMarkup(allocator, &result, bag.sink(), .{});
// Read owned child results with result.markupResults().
```

`requestMarkup` takes one raw identifier-expression span, including the outer
`<...>` delimiters. It checks bounds and spelling, extracts each HTML operand of
a concatenation, and ignores non-HTML operands. It does not decode, copy source,
or prove that a caller-built span belongs to the DOT grammar; use document spans.
For a partial DOT document, selections must lie inside its retained prefix.
Make selections in source order without overlap. Duplicate/backward selections
return `SelectionOutOfOrder`; invalid ranges/spellings and allocation failures
leave the existing selection unchanged.

| Stage | Outer representation | Child representation / coverage |
| --- | --- | --- |
| Passthrough, no selection | Unchanged | Not requested; neutral for subtree completeness |
| Selected, not run | Unchanged | `.not_processed`; `pendingMarkup()` lists envelopes |
| All selected trees complete | Unchanged | `.complete`, even if validation rejected a tree |
| Any selected tree missing/partial | Unchanged | `.partial` |
| Stopped before later children | Unchanged | Remaining operands stay pending; coverage is incomplete |

`markup.selection == .selected_operands` makes the scope of the report explicit:
`markup.allValid()` certifies only the selected set, not every HTML-like ID in
the file. `visited`, `valid`, `rejected`, and `unprocessed` count attempted
children; unattempted envelopes are in `pendingMarkup()`. Pending work prevents
`documentValid()` and `subtreeComplete()` from succeeding. A partial DOT tree
stays partial even when all selected children succeed.

This first API processes one synchronous batch. Starting it closes selection;
further selection or processing returns `SelectionClosed`, with no duplicate
diagnostics or implicit retry. Empty selection is a no-op. Parent `on_error`
is latched from the DOT operation. Child runtime policies and cancellation,
when enabled, are passed freshly as `.markup` options to `processPendingMarkup`;
child resources use `.markup_resources`. They are prepared before starting work.
An earlier outer operational/fail-fast stop cannot be bypassed with this call.
During the batch, parent fail-fast, child operational stops and sink stops leave
unattempted children pending; collecting parents continue after ordinary child
errors. These outcomes are in `markup.stop` and individual results, without
rewriting the already-finished DOT outcome.
`markup.diagnostic_delivery` and `markup.diagnostic_stop` preserve the child
stage's sink acknowledgment, including a failed retention-storage finding.

Use the same allocator for parsing, selection, processing and deinitialization.
The borrowed source must stay alive and unchanged. The pending-span queue is
allocated only on selection and released when drained; children own separate
buffers. This is not resumable processing or a shared work budget. Diagnostic
delivery follows operation order: outer findings first, then selected children
in source order, without sorting the bag globally. Run
[attached_markup.zig](../examples/attached_markup.zig) for the complete example.

## Check the labels you choose

For more control, parse the DOT first, then check the values you pick:

```zig
const Labels = markup.Profile(.{ .policy = markup.presets.untrusted });
const ready = Labels.prepare(.{}); // prepare once, reuse for every label

labels: for (document.attributes) |attribute| {
    if (!std.mem.eql(u8, document.text(attribute.key), "label")) continue;

    // A value can join several parts with `+`, so look at each part.
    var parts = try dot.identifier.parts(source, attribute.value);
    while (parts.next()) |part| {
        if (part.form != .html) continue;
        var checked = try ready.parseAndValidate(allocator, try part.fragment(source), bag.sink(), .{});
        defer checked.deinit();
        // checked.parse.document is this label's tree, if it parsed.
        if (checked.shouldStop(.collect)) break :labels; // stop the whole batch
    }
}
```

- `dot.identifier.parts` splits a value like `<<b>x</b>> + " text"` into its
  parts. `part.form` is `.html` for `<...>` parts.
- `part.fragment(source)` remembers where the part sits in the DOT file, so
  errors point at the right place.
- `checked.shouldStop(...)` says whether to stop checking labels
  **altogether**. It is true after a cancel, a full bag, or a memory or buffer
  failure, so break out of every loop, not just the inner one. Pass
  `.fail_fast` instead of `.collect` to also stop at the first label with
  errors.

Other ways to run each check:

- To avoid allocating for every label, use one reusable
  [workspace](MARKUP.md#checking-many-fragments).
- To use fixed buffers instead of an allocator, call
  `ready.parseAndValidateIn(...)`.

The table of result fields is in
[checking many fragments](MARKUP.md#checking-many-fragments).

## Use your own checker

Instead of `markup.Profile(...)`, you can bind your own label processor, for
example one for a different dialect or an application-specific vocabulary.
See [Bringing your own processor](CUSTOM_PROCESSORS.md).

## Examples

- [composed_markup.zig](../examples/composed_markup.zig): check every label
  while parsing, with one bag
- [delayed_markup.zig](../examples/delayed_markup.zig): check only `label`
  values after parsing
- [custom_processor.zig](../examples/custom_processor.zig): bind your own label
  checker

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.

## Not available yet

- Complete Graphviz label grammar, attribute-value and reference checking
- Automatically selecting Graphviz label contexts instead of every `<...>` value
- Checking labels in small steps, or with one budget for DOT and its labels

See the [roadmap](ROADMAP.md).
