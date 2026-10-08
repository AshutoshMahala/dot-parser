# Parsing markup on its own

The package has a second module, `markup_parser`, for HTML-like markup. It
works without the DOT parser. Use it to:

- check Graphviz HTML-like labels you got from somewhere other than a DOT file
- parse small HTML-like or XML-like fragments in your own format
- build checks for your own markup dialect on top of it

For your own format or dialect, use [structural mode](#two-modes).

To check labels inside DOT files, see [Checking HTML-like labels](LABELS.md).

> **Available since 0.4.0.** `markup_parser` is included in the same package
> as `dot_parser`.

## Add the module

```zig
const dot_parser = b.dependency("dot_parser", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("markup_parser", dot_parser.module("markup_parser"));
```

You can import `markup_parser` without `dot_parser`. Neither depends on the
other.

## What it understands

The built-in grammar is an XML-like subset of HTML:

| Input | Handling |
| --- | --- |
| Plain text, several top-level elements, empty input | Supported |
| Elements `<a>...</a>` and self-closing `<br/>` | Supported. Structural mode matches closing tags exactly; Graphviz mode ignores ASCII case. |
| Quoted attributes `<font color="red">` | Supported, kept in order, including duplicates |
| References `&amp;`, `&#65;`, `&#x41;` | Checked for correct form and kept as written, not expanded |
| Comments `<!-- -->` and `<![CDATA[ ]]>` | Supported, kept as their own nodes |
| Unquoted attributes, `<br>` with no closing tag | Errors. This is XML-style, not browser HTML. |
| `<?...?>`, `<!DOCTYPE>`, UTF-16/32 input | Not supported |

### Two modes

| `mode` | Use it for | Tag names | Also checks |
| --- | --- | --- | --- |
| `.graphviz` | Graphviz labels. The default on `main` (**unreleased**). | Matched ignoring ASCII case, as Graphviz does | [Graphviz's tags and attributes](#graphviz-vocabulary) |
| `.structural` | Your own markup, or other dialects. The default in 0.4.0. | Matched exactly | Nothing beyond the grammar |

To check your own markup on `main`, select structural mode:

```zig
const Structural = markup.Profile(.{ .policy = .{ .mode = .structural } });
```

Text, whitespace and non-ASCII bytes are kept exactly as written in either mode.

The parser is meant as a general base that different HTML-like dialects can
build on. Graphviz labels are its first and most important use, not its only
one. See the [roadmap](ROADMAP.md#markup).

## Parse and read a fragment

```zig
const markup = @import("markup_parser");

var bag = markup.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var parsed = markup.parseBorrowed(allocator, "Hello <b>world</b>!", bag.sink(), .{});
defer parsed.deinit();

if (parsed.document) |document| {
    var nodes = document.roots();
    while (nodes.next()) |node| {
        _ = node.kind(); // .element, .text, .comment or .cdata
        _ = node.name(); // tag name, or null for text
        _ = node.raw(); // the exact source text of this node
        var attributes = node.attributes();
        while (attributes.next()) |attribute| {
            _ = attribute.name();
            _ = attribute.value(); // without quotes, not decoded
        }
        var children = node.children();
        while (children.next()) |child| _ = child;
    }
}
```

| Node method | Returns |
| --- | --- |
| `kind()` | `.element`, `.text`, `.comment` or `.cdata` |
| `name()` | The tag name, or `null` for text, comments and CDATA |
| `raw()` | The node's exact source text, including its children |
| `content()` | The inside of a text, comment or CDATA node, without `<!--` or `<![CDATA[`; `null` for elements |
| `children()` | The node's direct children |
| `attributes()` | Its attributes, in order. Each has `name()`, `value()` (quotes removed), `rawValue()` (with quotes) and `raw()` (the whole pair). |

The result also has `parsed.outcome`, `parsed.counts` (nodes, elements,
attributes, deepest nesting) and the same `completion`, `syntax_errors` and
`warnings` fields as DOT results. Like DOT, the document points into your
source, so keep the source alive while you use it. `parsed.deinit()` frees the
tree, never your source or bag.

## Validate

Parsing checks structure: tags match and attributes are well-formed. Even in
Graphviz mode, `parseBorrowed` does not run vocabulary checks; use
`parseAndValidate` for both steps, or validate the document separately.
Validation is a separate step with these checks, each `.err`, `.warning` or
`.off`:

| Setting | Default | Reports |
| --- | --- | --- |
| `validation.duplicate_attribute` | `.err` | The same attribute twice on one element |
| `validation.invalid_utf8` | `.off` | Bytes that aren't valid UTF-8, anywhere in the input |
| `validation.names.severity` | `.off` | Names that break the rule in `names.rule` |
| `validation.names.rule` | `.xml_1_0` | XML 1.0's rules for tag, attribute and reference names (the only rule today) |
| `validation.references.severity` | `.off` | Named references missing from `references.catalog` |
| `validation.references.catalog` | `.xml_predefined` | The five XML names `amp`, `lt`, `gt`, `quot`, `apos` (the only list today) |
| `validation.graphviz.unknown_element` | `.err` in Graphviz mode | Elements Graphviz doesn't know (unreleased) |
| `validation.graphviz.invalid_attribute` | `.err` in Graphviz mode | Attributes not allowed on that Graphviz element (unreleased) |

```zig
const Strict = markup.Profile(.{ .policy = .{ .validation = .{
    .invalid_utf8 = .err,
    .names = .{ .rule = .xml_1_0, .severity = .err },
    .references = .{ .catalog = .xml_predefined, .severity = .warning },
} } });

const checked = Strict.validate(allocator, &document, bag.sink(), .{});
// Accept only if checked.completion == .complete and checked.validity == .valid.
```

- Turning on one check never turns on another. A check that is off was not
  run; it didn't pass.
- `checked.validity` is `.valid`, `.invalid` or `.unknown` (when checking
  stopped early). `checked.errors` and `checked.warnings` count findings.
- Validation never changes the tree.
- `validateIn` does the same without an allocator. It needs a small scratch
  array only for duplicate checking; `markup.requiredValidationScratch(&document)`
  tells you how big.

## Graphviz vocabulary

> **Unreleased.** Not in 0.4.0. This checks tag and attribute names only, not
> all of Graphviz's label rules.

In Graphviz mode, validation checks that every element is one Graphviz knows,
and that each attribute is allowed on its element. Graphviz mode is the default
for the top-level `markup` functions, `markup.Profile(.{})`, both presets, and a
markup profile bound to DOT as a label checker. These are the default settings,
written out:

```zig
const Labels = markup.Profile(.{ .policy = .{
    .mode = .graphviz,
    .validation = .{ .graphviz = .{
        .unknown_element = .err,
        .invalid_attribute = .err,
    } },
} });
var result = try Labels.parseAndValidate(allocator, .{
    .bytes = "<TABLE BORDER=\"0\"><TR><TD>Hello</TD></TR></TABLE>",
    .origin = 0,
}, bag.sink(), .{});
defer result.deinit();
```

The vocabulary follows the [Graphviz documentation for HTML-like labels](https://graphviz.org/doc/info/shapes.html#html):

| Elements | Allowed attributes |
| --- | --- |
| `TABLE`, `TD` | Their documented attribute lists |
| `FONT` | `COLOR`, `FACE`, `POINT-SIZE` |
| `BR` | `ALIGN` |
| `IMG` | `SCALE`, `SRC` |
| `TR`, `I`, `B`, `U`, `O`, `SUB`, `SUP`, `S`, `HR`, `VR` | None |

**How names are compared.** Tag names, attribute names, and matching a closing
tag to its opening tag all ignore ASCII case, as Graphviz does: `<b>` and `<B>`
are the same element, and `<B>...</b>` matches. Error recovery and the
duplicate-attribute check use the same rule, so `COLOR` and `color` on one
element are duplicates. Non-ASCII letters aren't case-folded, and typos aren't
guessed. Spelling, order, values and duplicates are still kept as written.

**Settings.**

- `validation.graphviz.unknown_element` and `invalid_attribute` each take
  `.err` (default), `.warning` or `.off`, also as run-time settings.
- They have no effect in structural mode.
- Both presets select Graphviz mode, even on top of a structural profile. To
  keep the untrusted limits but check your own markup, copy the preset and
  change its mode:

```zig
const Custom = markup.Profile(.{ .policy = blk: {
    var policy = markup.presets.untrusted;
    policy.mode = .structural;
    break :blk policy;
} });
```

**What "valid" means here.** `documentValid()` means valid under the checks that
ran. It does **not** mean Graphviz will accept the label. Not checked yet:

- which tags may contain which. `<TABLE><TD/></TABLE>` passes, even though the
  cell has no row.
- the order of children, whitespace rules, and empty-element forms
- the double quotes Graphviz requires, attribute values, and Graphviz's named
  references

XML name and reference checks remain separate, opt-in settings.

**Unknown elements.** An unknown element gets one finding. Graphviz has no
attribute list for it, so its attributes are skipped, but the elements inside
it and the other checks still run. If it has attributes, the attribute check
didn't cover everything. So, if nothing else is wrong, `validity` is `.unknown`
(not `.valid`) and `documentValid()` is false. `completion` is `.incomplete`,
pointing at the first place that wasn't checked. This happens even with
`unknown_element = .off`. An unknown element with no attributes doesn't cause
it. `validation.checks.graphviz_elements` and `graphviz_attributes` show whether
each check ran fully (`.complete`), partly (`.incomplete`), or not at all
(`.not_run`).

**Parts of a document.** These checks also work with `validateIn`,
`validateSource[In]` and `validateScope[In]`. When `validateScope` checks one
opening tag, its attributes are checked against that tag. A lone
`attribute_name` scope has no element to check against, so the attribute check
reports `.not_run`. Tags that can still be recognised after a syntax error are
checked; skipped regions are reported as not fully checked.

**Inside DOT.** Checking every label while parsing DOT checks **every** `<...>`
value, not only labels, so HTML-like values in other places get the Graphviz
rules too. To check only labels, pick them yourself with the
[delayed path](LABELS.md#check-the-labels-you-choose). Picking label positions
automatically is planned.

See [graphviz_vocabulary.zig](../examples/graphviz_vocabulary.zig) for a
runnable example, and [Performance](PERFORMANCE.md#graphviz-vocabulary-checks)
for what the checks cost.

## When parsing fails

By default the parser keeps going after an error to find more:

| Problem | What it does |
| --- | --- |
| A closing tag with nothing open | Reports it and skips it |
| A closing tag that doesn't match | Reports it once, and closes back to the matching open tag if there is one |
| Elements still open at the end | Reports each one |
| A bad attribute, like a missing `=` | Reports it and skips to the end of the tag |
| An unclosed quote, comment or CDATA | Stops; there is no safe place to continue |

It never invents tags or repairs the source. By default, a failed parse returns
no tree. To keep the part that was recognised, turn on
[partial results](#partial-results-for-editors) (unreleased). Set `on_error = .fail_fast` to stop at the first error.

| `parsed.outcome` | Meaning |
| --- | --- |
| `success` | Parsed completely |
| `invalid_syntax` | The markup is malformed |
| `unsupported_feature` | Uses something the parser doesn't handle, like `<?...?>` |
| `resource_limit` | A limit in your settings was reached |
| `storage_exhausted` | A fixed buffer was too small |
| `out_of_memory` | The allocator ran out of memory |
| `cancelled` | You cancelled it |
| `diagnostic_stopped` | The bag asked to stop, for example because it was full |
| `sink_failure` | An internal step failed to accept parser output |

## Partial results for editors

> **Unreleased.** Not in 0.4.0.

An editor can use the recognized part of a document for an outline while the
user is still typing. Enable partial retention to keep that part after a parse
failure; by default, failures return no document:

```zig
const Editor = markup.Profile(.{ .policy = .{
    .mode = .structural,
    .retention = .{ .partial = true },
} });
var parsed = Editor.parseBorrowed(allocator, "<root><done/><child x='unfinished", bag.sink(), .{});
defer parsed.deinit();
if (parsed.document) |document| {
    _ = document.state; // .partial here; the Document type is unchanged
    var roots = document.roots();
    while (roots.next()) |node| {
        _ = node.state(); // .partial for this unfinished <root>
        _ = node.children(); // <done/> is available inside unfinished <root>
        _ = node.attributes(); // completed attributes are available too
        _ = node.subtreeComplete(); // false: this element isn't fully represented
        _ = node.headerComplete(); // true for <root>; null for text/comments/CDATA
    }
    _ = document.unrepresented(); // source range not represented by the tree
}
```

Use `subtreeComplete()` when you need an element and all its children to be
complete. `scopeComplete()` checks just the current scope. They currently agree,
because an unfinished child also leaves its ancestors unfinished. Neither says
the markup is valid. `.not_processed` is reserved and isn't returned yet.

**Only the prefix before the first failure is retained.** `.collect` can keep
finding errors, but it doesn't add later nodes to the tree. A finished scan
(`parsed.completion == .complete`) can therefore still have a partial document.
Missing quotes, comments and closing tags are never guessed or repaired.

Use `unrepresented()` to find the remaining raw text, not as a place to restart
parsing. It may include whitespace already scanned, or be empty when only a
closing tag is missing at EOF. Use node views for traversal; see the
[raw-record rules](#building-a-document-yourself) if you access the pools directly.

This works with both scanners, fixed or growing storage, sessions, workspaces
and runtime policies. Cancellation, unsupported input or exhausted limits/storage
can leave a prefix too. A stop before parsing begins returns no document.
Outcomes and diagnostics don't change, and both presets turn retention off.
Keep the source and storage alive under the usual [ownership rules](MEMORY.md#two-rules);
[memory costs](PERFORMANCE.md#type-sizes) are documented separately.

`validate[In]` checks the retained tree and reports missing coverage or the reason
it stopped. `parseAndValidate` may also check later source regions after a
recoverable syntax error; `documentValid()` remains false for a partial document.
It does not start validation after an operational stop or fail-fast rejection.

This feature is currently for standalone markup. DOT doesn't return partial
trees, and automatic label checking doesn't retain the inner markup trees.

See [markup_partial.zig](../examples/markup_partial.zig) for a runnable example.

## Checking a fragment that failed to parse

Validation normally needs a parsed tree. If parsing failed, you can still check
the parts that can be recognised:

```zig
const result = Strict.validateSource(allocator, source, bag.sink(), .{});
```

For example, in `<FONT COLOR='red' COLOR='blue'></B>` it still reports the duplicate `COLOR`,
even though the closing tag is wrong. It only reports validation findings, not
the syntax errors again. A clean result here doesn't mean the markup is
well-formed; only a successful parse means that.

If checking couldn't cover everything, `result.completion` is
`.{ .incomplete = offset }`: the first place it couldn't check. Later parts may
still have been checked, so this is not a position to resume from.

To check one known region, such as one attribute value, use
`validateScope(allocator, source, scope, sink, options)` with a
`markup.ValidationScope`. Scopes you build yourself are checked in every build
mode. Bad ranges give `completion = .invalid_scope`, with no diagnostics.

## Parsing part of a larger file

Often the markup is a piece of a bigger file, as with a label inside a DOT
file. A `markup.Fragment` is a slice of bytes plus its `origin`: where the
slice starts in the original file. Diagnostics then point at the original file.

```zig
const fragment = try markup.Fragment.fromSource(file_bytes, .{ .start = 120, .len = 40 });
var checked = try markup.parseAndValidate(allocator, fragment, bag.sink(), .{});
defer checked.deinit();
```

| Function | What it does |
| --- | --- |
| `Fragment.fromSource(source, span)` | Slices `source` safely and sets the origin |
| `Fragment.init(bytes, origin)` | Makes a fragment from bytes you already sliced |
| `fragment.rebase(local_span)` | Turns a span inside the fragment into a span in the original file |
| `fragment.child(local_span)` | Makes a fragment for a raw piece inside this one, such as an attribute value |

Rules:

- Origins only work for **raw** slices of the original file. Decoded, joined or
  converted text needs a real source map, which the library doesn't provide.
- Only diagnostics are moved to original positions. The tree's own spans stay
  relative to the fragment's bytes. Render diagnostics against the original
  file.
- Calls that take a fragment move positions for you. For other calls (parse
  only, validate only, or a session), wrap your sink with
  `try markup.diagnostic.OriginSink.init(fragment, sink)`, and keep the wrapper
  at a fixed address while its `.sink()` is in use. Don't wrap a call that
  already takes a fragment, or positions would be moved twice.

## Checking many fragments

There are three ways to parse and validate a fragment in one call. They differ
in how long the result lives:

| Call | Result lives | Use it when |
| --- | --- | --- |
| `ready.parseAndValidate(allocator, fragment, sink, resources)` | Until you call its `deinit()` | You want to keep each tree on its own |
| `ready.parseAndValidateIn(fragment, memory, scratch, sink)` | As long as your fixed buffers | You need fixed memory and no allocator |
| `workspace.parseAndValidate(fragment, sink)` | Only **until the next call** on that workspace, or its `deinit()` | You check many fragments and use each result straight away |

`ready` comes from `Profile.prepare(options)`, which checks the settings once,
without scanning or allocating, and can be reused. A workspace also keeps its
buffers between calls, so checking thousands of small fragments doesn't
allocate thousands of times:

```zig
const Labels = markup.Profile(.{ .policy = markup.presets.untrusted });
const ready = Labels.prepare(.{});
var workspace = ready.initWorkspace(allocator, .{}); // allocates nothing yet
defer workspace.deinit();

for (fragments) |fragment| {
    const checked = try workspace.parseAndValidate(fragment, bag.sink());
    // Use checked.parse.document now. The next call reuses its memory.
    if (checked.shouldStop(.collect)) break;
}
```

Workspace rules:

- A result, and any tree view from it, is valid only until the next call on
  the same workspace, or `deinit()`.
- Don't use one workspace from two places at once, or call it again from inside
  your sink.
- Call `deinit()` exactly once. Copying the workspace value doesn't copy its
  buffers.
- Buffers grow to fit the largest fragment and stay that size until `deinit()`.
  This saves allocations but can raise peak memory. `workspace.reservedBytes()`
  reports the current buffer size.

All three calls return results with the same fields:

| Field | Meaning |
| --- | --- |
| `checked.parse` | The parse result. It has a document if parsing succeeded. With [partial results](#partial-results-for-editors) on (unreleased), it can also have a partial document after a failure; check `document.state`. |
| `checked.validation` | Validation of the document if parsing succeeded. If parsing failed and errors are being collected, validation of the parts that could be recognised. `null` after a fail-fast syntax error, unsupported input, or a stop. |
| `checked.documentValid()` | Parsed completely and validated with no errors |
| `checked.has_errors` | Errors were found, including a limit being reached or unsupported input reported as an error. `false` doesn't prove the input is valid or was fully checked. |
| `checked.stopped()` | A stop that isn't about the input: cancel, a memory or buffer failure, or the sink stopping or failing |
| `checked.shouldStop(caller_on_error)` | `stopped()`, or `has_errors` when the caller's setting is `.fail_fast`. If true, start no more fragments. |

## Fixed memory, counting, and small steps

The markup parser has the same memory and execution options as the DOT parser:

```zig
var nodes: markup.FixedDocumentStorage(.{ .nodes = 16, .attributes = 32 }) = .{};
var frames: markup.FixedParseScratch(8) = .{}; // deepest element nesting
const parsed = markup.parseBorrowedIn(source, .{
    .document = nodes.storage(),
    .scratch = frames.storage(),
}, bag.sink(), .{});
```

- `markup.measure(allocator, source, sink, options)` counts nodes, attributes
  and nesting depth without keeping a tree, so you can size fixed buffers.
- `markup.BoundedSession` parses in [small steps](EXECUTION.md) with fixed
  buffers, using `advance(budget)`, `run()`, `cancel()` and `reset(...)`, just
  like DOT sessions.

## Untrusted input

Start from `markup.presets.untrusted`. It is the default policy with these
limits:

| Limit | Value |
| --- | ---: |
| Input size | 8 MiB |
| Nodes | 100,000 |
| Attributes | 200,000 |
| Nesting depth | 256 |

These are starting points, not guarantees. Tune them for your program, and
follow the same [checklist as for DOT](POLICIES.md#untrusted-input).
Validation is not limited by these, and can't yet run in steps.

## Settings

A markup profile works like a DOT profile:

| Profile option | Meaning |
| --- | --- |
| `.policy` | The compiled settings. Fields you leave out keep their defaults. |
| `.runtime_policy` | `true` lets each call pass a `.policy` patch in its options. Default `false`. |

| Preset | What it is |
| --- | --- |
| `markup.presets.standard` | The defaults |
| `markup.presets.untrusted` | The defaults with finite limits (see above) |

Every setting:

| Setting | Default | Meaning |
| --- | --- | --- |
| `mode` | `.graphviz` on `main` (unreleased); `.structural` in 0.4.0 | `.graphviz` or `.structural`. See [two modes](#two-modes). |
| `limits.max_source_bytes` | 4 GiB | Largest input accepted |
| `limits.max_nodes` | no limit | Elements, text runs, comments and CDATA sections |
| `limits.max_attributes` | no limit | Attributes in total |
| `limits.max_nesting` | no limit | Deepest element nesting (top-level elements are depth 1) |
| `on_error` | `.collect` | Keep looking after an error, or `.fail_fast` |
| `retention.partial` | `false` | Keep the part recognised before a failure (unreleased). Doesn't change error handling or what is accepted. See [partial results](#partial-results-for-editors). |
| `syntax.malformed_reference` | `.reject` | `.warn` or `.accept` treat a broken `&` reference as plain text |
| `scanner` | `.scalar` | `.block` reads with vector instructions; same results |
| `diagnostics.fixes` | `.all` | Which suggested fixes to include: `.all`, `.machine_applicable` or `.off` |
| `diagnostics.unsupported` | `.err` | How to report unsupported input: `.err`, `.warning` or `.silent` |
| `execution.metering` | `false` | Allow parsing in small steps |
| `execution.cancellation` | `false` | Allow cancelling through a callback |
| `validation.*` | see [Validate](#validate) | Validation checks |

Every combination of markup settings is valid, so markup calls never return a
configuration error. `Profile.validatePolicy(patch)` exists for symmetry with
DOT and always returns `.valid`.

`mode` says *how* to check. Whether labels inside a DOT file are checked at
all is DOT's [`markup` setting](LABELS.md#what-happens-by-default). The same
`markup.Profile(.{ .policy = .{ .mode = .structural } })` works on its own or as
a label checker bound to DOT. DOT's `.process` runs it; `.passthrough` doesn't
run it and doesn't change its settings. [Your own processor](CUSTOM_PROCESSORS.md)
has its own settings and doesn't need a `mode`.

## Building a document yourself

A `markup.Document` is meant to come from the parser. If you build one by
hand, you must keep the parser's rules:

- spans point into the live source
- nodes are in tree order, with correct subtree ranges
- each element's attributes are in source order, grouped together, and inside
  that element

Validation assumes these storage rules hold; it doesn't repair or certify
caller-built pools. Debug and `ReleaseSafe` builds catch some mistakes with
assertions.

In a partial document (unreleased), `subtree_end == 0` marks an unfinished
element. Its kept children run to the end of `records`, and its raw span covers
only the part of its opening tag read so far. The node views handle this for
you: `NodeView.record()`, `span()`, `raw()` and child and root traversal treat
the element as running to `document.retained_end`. That doesn't mean a closing
tag was found; check the node's state. Use the views rather than reading
partial records directly.

## Examples

- [markup.zig](../examples/markup.zig): parse a fragment, print the tree, and
  run every validation check
- [delayed_markup.zig](../examples/delayed_markup.zig): check pieces of a larger
  file with fragments

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.

## Not available yet

- HTML-style tags that never close, like `<br>`
- Other name rules or reference lists, or your own
- UTF-16 or UTF-32 input. Convert it to UTF-8 first.

See the [roadmap](ROADMAP.md#markup).
