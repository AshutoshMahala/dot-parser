# Parsing markup on its own

The package has a second module, `markup_parser`, for HTML-like markup. It
works without the DOT parser. Use it to:

- check Graphviz HTML-like labels you got from somewhere other than a DOT file
- parse small HTML-like or XML-like fragments in your own format
- build checks for your own markup dialect on top of it

For your own format or dialect, use [structural mode](#two-modes).

To check labels inside DOT files, see [Checking HTML-like labels](LABELS.md).
For your own checks on attribute values, see
[string checks](STRINGS.md#attribute-processing-in-dot-and-markup)
(unreleased).

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
| Plain text, several top-level elements, empty input | Supported. Graphviz validation accepts an empty label, as Graphviz does, but reports one that holds only line breaks or comments (unreleased); see [label content](#label-content-and-attribute-values). |
| Elements `<a>...</a>` and self-closing `<br/>` | Supported. Structural mode matches closing tags exactly; Graphviz mode ignores ASCII case. |
| Quoted attributes `<font color="red">` | Supported, kept in order, including duplicates |
| References `&amp;`, `&#65;`, `&#x41;` | Checked for correct form and kept as written, not expanded |
| Comments `<!-- -->` and `<![CDATA[ ]]>` | Supported, kept as their own nodes |
| Unquoted attributes, `<br>` with no closing tag | Errors. This is XML-style, not browser HTML. |
| `<?...?>`, `<!DOCTYPE>` | Not supported |
| UTF-16 and UTF-32 input | Supported when turned on. See [source encodings](ENCODINGS.md). |

### Two modes

| `mode` | Use it for | Tag names | Also checks |
| --- | --- | --- | --- |
| `.graphviz` | Graphviz labels. The default since 0.5.0. | Matched ignoring ASCII case, as Graphviz does | [Graphviz's label rules](#graphviz-vocabulary): tags and attributes; also content, attribute values and named references (unreleased) |
| `.structural` | Your own markup, or other dialects. The default in 0.4.0. | Matched exactly | Nothing beyond the grammar |

To check your own markup, select structural mode:

```zig
const Structural = markup.Profile(.{ .policy = .{ .mode = .structural } });
```

Both presets select Graphviz mode. To keep the untrusted limits but check your
own markup, copy the preset and change its mode:

```zig
const Custom = markup.Profile(.{ .policy = blk: {
    var policy = markup.presets.untrusted;
    policy.mode = .structural;
    break :blk policy;
} });
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

### Decoding text and attribute values

> **Unreleased.** Not in 0.5.0.

`value()` and `content()` return the text as written, so `A&amp;B` stays
`A&amp;B`. To read the decoded characters, use
`markup.LogicalReader(encoding)` on the inside of one text node or one
attribute value (without its quotes):

- It gives you one character at a time, with references such as `&amp;`
  decoded. Each character keeps its position in your source; a reference's
  position covers its whole spelling.
- Its options choose which named references to decode (`references`), how to
  treat a broken `&` (`malformed_reference`), and whether tabs and line breaks
  count as spaces, as Graphviz does for attribute values
  (`normalize_attribute_whitespace`).
- It doesn't change the tree, copy the text, or turn on string checks.

See [logical readers](STRINGS.md#logical-readers).

## Validate

Parsing checks structure: tags match and attributes are well-formed. Even in
Graphviz mode, `parseBorrowed` does not run vocabulary checks; use
`parseAndValidate` for both steps, or validate the document separately.
Validation is a separate step with these checks, each `.err`, `.warning` or
`.off`:

| Setting | Default | Reports |
| --- | --- | --- |
| `validation.duplicate_attribute` | `.err` | The same attribute twice on one element |
| `validation.invalid_encoding` | `.off` | Text that isn't valid in the file's encoding, anywhere in the input (`invalid_utf8` in 0.4.0) |
| `validation.names.severity` | `.off` | Names that break the rule in `names.rule` |
| `validation.names.rule` | `.xml_1_0` | XML 1.0's rules for tag, attribute and reference names (the only rule today) |
| `validation.references.severity` | `.off` | Named references missing from `references.catalog` |
| `validation.references.catalog` | `.xml_predefined` | The five XML names `amp`, `lt`, `gt`, `quot`, `apos`, or `.graphviz` (unreleased): HTML 4's named references plus `apos` |
| `validation.graphviz.unknown_element` | `.err` in Graphviz mode | Elements Graphviz doesn't know |
| `validation.graphviz.invalid_attribute` | `.err` in Graphviz mode | Attributes not allowed on that Graphviz element |
| `validation.graphviz.invalid_content` (unreleased) | `.err` in Graphviz mode | Content in a place the label rules don't allow, such as a `TD` outside a `TR` |
| `validation.graphviz.invalid_value` (unreleased) | `.err` in Graphviz mode | Attribute values Graphviz doesn't allow, and missing required attributes |
| `validation.graphviz.unknown_reference` (unreleased) | `.err` in Graphviz mode | Named references Graphviz doesn't know, unless `validation.references` is on |

```zig
const Strict = markup.Profile(.{ .policy = .{ .validation = .{
    .invalid_encoding = .err,
    .names = .{ .rule = .xml_1_0, .severity = .err },
    .references = .{ .catalog = .xml_predefined, .severity = .warning },
} } });

const checked = Strict.validate(allocator, &document, bag.sink(), .{});
// Accept only if checked.completion == .complete and checked.validity == .valid.
```

- Turning on one check never turns on another. A check that is off was not
  run; it didn't pass.
- `checked.validity` is `.valid`, `.invalid` or `.unknown` (when checking
  stopped early or couldn't cover everything). `checked.errors` and
  `checked.warnings` count findings.
- Validation never changes the tree.
- `invalid_encoding` checks names, values, text, comments and CDATA, using the
  file's encoding: UTF-8 by default, or ASCII, UTF-16 or UTF-32. Whether it ran
  is in `checked.checks.invalid_encoding`. For labels inside DOT, this is the
  only encoding check: DOT's own check skips them. See
  [checking that the text is valid](ENCODINGS.md#checking-that-the-text-is-valid).
- `validateIn` does the same without an allocator. It needs a small scratch
  array only for duplicate checking; `markup.requiredValidationScratch(&document)`
  tells you how big.

## Graphviz vocabulary

In Graphviz mode, validation checks markup against the
[Graphviz documentation for HTML-like labels](https://graphviz.org/doc/info/shapes.html#html).
Graphviz mode is the default for the top-level `markup` functions,
`markup.Profile(.{})`, both presets, and a markup profile bound to DOT as a
label checker. Structural mode runs none of these checks.

These are the default settings, written out:

```zig
const Labels = markup.Profile(.{ .policy = .{
    .mode = .graphviz,
    .validation = .{ .graphviz = .{
        .unknown_element = .err,
        .invalid_attribute = .err,
        .invalid_content = .err, // unreleased
        .invalid_value = .err, // unreleased
        .unknown_reference = .err, // unreleased
    } },
} });
var result = try Labels.parseAndValidate(allocator, .{
    .bytes = "<TABLE BORDER=\"0\"><TR><TD>Hello</TD></TR></TABLE>",
    .origin = 0,
}, bag.sink(), .{});
defer result.deinit();
```

Each setting takes `.err`, `.warning` or `.off`, also as a
[run-time setting](#settings). `.off` skips that check.

### Tags and attributes

> **Available since 0.5.0.**

Validation checks that every element is one Graphviz knows, and that each
attribute is allowed on its element:

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

### Label content and attribute values

> **Unreleased.** Not in 0.5.0.

`invalid_content` checks what may go where:

| Where | Rule |
| --- | --- |
| The whole label | Either text (with style elements and `BR`), or one `TABLE`. A table may be wrapped once in `FONT`, `I`, `B`, `U` or `O`. A table can't be mixed with text or a second table. An empty label (`label=<>`) is fine, as in Graphviz, but a label with only line breaks or comments is reported. |
| `TABLE` and `TR` | `TABLE` holds `TR` rows and `TR` holds `TD` cells. `HR` goes between rows and `VR` between cells, never first, last or twice in a row. Spaces are fine; other text is reported. |
| `TD` | May be empty, or hold text or a table. An `IMG` may appear only in a `TD`, as the only thing in it. |
| Style elements | `FONT`, `I`, `B`, `U`, `O`, `SUB`, `SUP` and `S` need some text or a `BR` inside. `FONT`, `I`, `B`, `U` and `O` may hold a table instead. |
| `BR`, `IMG`, `HR`, `VR` | No content. `HR` and `VR` may contain whitespace. |
| Spaces around a table | Allowed around a bare table, and inside its wrapper, but not outside the wrapper: ` <B><TABLE>...</TABLE></B>` is reported. |

Characters below space, such as tabs and line breaks, are ignored in content.
For standalone markup, an empty label is an empty fragment. The enclosing
`<` and `>` in DOT's `label=<>` belong to DOT and aren't part of that fragment.

`invalid_value` checks attribute values, ignoring ASCII case:

| Attribute | Allowed values |
| --- | --- |
| `ALIGN`, `BALIGN` | `LEFT`, `CENTER`, `RIGHT`; on `TD`, `ALIGN` also allows `TEXT` |
| `VALIGN` | `TOP`, `MIDDLE`, `BOTTOM` |
| `FIXEDSIZE` | `TRUE`, `FALSE`. With `TRUE`, `WIDTH` and `HEIGHT` must be given and above 0. |
| `SCALE` | `FALSE`, `TRUE`, `WIDTH`, `HEIGHT`, `BOTH` |
| `ROWS`, `COLUMNS` | `*` |
| `SIDES` | Only the letters `L`, `T`, `R` and `B` |
| `STYLE` | `RADIAL`, and `ROUNDED` on `TABLE`, separated by spaces or commas |
| `BORDER`, `CELLPADDING` | Whole numbers 0 to 255 |
| `CELLBORDER` | Whole numbers 0 to 127 |
| `CELLSPACING` | Whole numbers -128 to 127 |
| `WIDTH`, `HEIGHT` | Whole numbers 0 to 65535 |
| `COLSPAN`, `ROWSPAN` | Whole numbers 1 to 65535 |
| `GRADIENTANGLE` | Whole numbers 0 to 360 |
| `POINT-SIZE` | A number from 0 to 255 |
| `SRC` on `IMG` | Required, and not empty |

Other attributes, such as `COLOR`, `HREF` or `PORT`, take any value.
References in values are decoded for these checks, and tabs and line breaks
written in a value count as spaces. A numeric reference such as `&#9;` keeps
its own character. The tree still holds the value exactly as written.

The number ranges follow
[Graphviz 16.0.0](https://gitlab.com/graphviz/graphviz/-/blob/16.0.0/lib/common/htmllex.c).
A few rules are deliberately stricter than Graphviz itself:

- A number must be a complete number. Graphviz sometimes ignores junk after
  it.
- `STYLE` accepts only the documented `ROUNDED` and `RADIAL`. Graphviz accepts
  some extra renderer-specific styles.
- Text directly inside `TABLE` or `TR` is reported. Graphviz may drop it
  silently.

Two forms that Graphviz's own
[label grammar](https://gitlab.com/graphviz/graphviz/-/blob/16.0.0/lib/common/htmlparse.y)
accepts are allowed: single **or** double quotes, and paired empty elements
such as `<BR></BR>`. A bare `<BR>` with no closer is still an error.

### Named references

> **Unreleased.** Not in 0.5.0.

`unknown_reference` reports named references Graphviz doesn't know:

- In text, Graphviz knows HTML 4's 252 named references, such as `&nbsp;`,
  plus `&apos;`.
- In attribute values, it knows only XML's five: `&amp;`, `&lt;`, `&gt;`,
  `&quot;` and `&apos;`. Graphviz passes attribute values to its XML parser
  unchanged.
- Names are case-sensitive, so `&NBSP;` is reported. Numeric references like
  `&#65;` are checked by the parser, not here.

If you turn on `validation.references`, its own catalog and severity are used
for text and attributes instead. To skip reference checks, set both
`validation.references.severity` and `graphviz.unknown_reference` to `.off`.
`references.catalog = .graphviz` also works in structural mode. The XML name
check stays separate and off by default.

References are decoded only to check them. Nothing is expanded into a buffer,
and no network access or DTD processing happens.

### What "valid" means here

`documentValid()` means valid under the checks that ran. It does **not** mean
Graphviz will draw the label as you expect. Not checked: color names and color
schemes, fonts, whether image files exist, ports, layout and renderer-specific
behaviour.

**Coverage.** `validation.checks.graphviz_elements` and `graphviz_attributes`,
and (unreleased) `graphviz_values`, `graphviz_content` and `references`, show
whether each check ran fully (`.complete`), partly (`.incomplete`), or not at
all (`.not_run`).

**Unknown elements.** An unknown element gets one finding. Graphviz has no
rules for it, so its attributes and content can't be checked, but the elements
inside it and the other checks still run. That leaves the label not fully
checked: if nothing else is wrong, `validity` is `.unknown` (not `.valid`),
`documentValid()` is false, and `completion` is `.incomplete`, pointing at the
first place that wasn't checked. This happens even with
`unknown_element = .off`. With content or value checks on (both are on by
default, unreleased), every unknown element causes it; with both off, only an
unknown element that has attributes does. An unknown attribute likewise leaves `graphviz_values`
incomplete.

**Unfinished trees.** In a [partial document](#partial-results-for-editors),
unfinished elements aren't reported as missing children. They leave content
coverage incomplete instead.

**Parts of a document.** These checks also work with `validateIn`,
`validateSource[In]` and `validateScope[In]`. When `validateScope` checks one
opening tag, its attributes and values are checked against that tag. A lone
`attribute_name` scope has no element or value to check against, so those
checks report `.not_run`. `validateSource` and `validateScope` have no tree, so
content placement isn't checked there (`graphviz_content` is `.not_run`): a
valid local result doesn't mean the whole label is valid. Use
`parseAndValidate` or `validate[In]` on a document for that.

**Costs and order.** Content checking looks at each element's direct children
once, with a short look inside a `FONT`, `I`, `B`, `U` or `O` wrapper. Its work
grows with the number of nodes and the bytes it reads; it doesn't allocate or
recurse. Value and reference checks use a fixed amount of memory; only the
duplicate check needs scratch. Document validation reports all other findings
first, then content findings, without sorting them. Cancelling or a full bag
stops it at any point; it can't run in small steps. See
[Performance](PERFORMANCE.md#graphviz-vocabulary-checks) for measured costs.

**Inside DOT.** Checking every label while parsing DOT checks **every** `<...>`
value, not only labels, so HTML-like values in other places get the Graphviz
rules too. To check only labels, pick them yourself and
[check the labels you choose](LABELS.md#check-the-labels-you-choose). Picking
label positions automatically isn't available yet.

[graphviz_vocabulary.zig](../examples/graphviz_vocabulary.zig) is a runnable
label-checking example.

## When parsing fails

By default the parser keeps going after an error to find more:

| Problem | What it does |
| --- | --- |
| A closing tag with nothing open | Reports it and skips it |
| A closing tag that doesn't match | Reports it. Closes back to an open element with exactly that name; otherwise may treat it as a typo ([see below](#closing-tag-typo-recovery)) |
| Elements still open at the end | Reports each one |
| A bad attribute, like a missing `=` | Reports it and skips to the end of the tag |
| An unclosed quote, comment or CDATA | Stops; there is no safe place to continue |

It never invents tags or repairs the source. By default, a failed parse returns
no tree. To keep the part that was recognised, turn on
[partial results](#partial-results-for-editors). Set `on_error = .fail_fast` to stop at the first error.

### Closing-tag typo recovery

> **Available since 0.5.0.** 0.4.0 behaves like `.exact`.

When a closing tag doesn't match, the parser first looks for an open element
with exactly that name and closes back to it. If there is none,
`closing_tag_recovery` decides whether to treat the closer as a typo for the
current element:

| `closing_tag_recovery` | When no open element matches exactly |
| --- | --- |
| `.exact` | Ignore the closing tag and keep everything open |
| `.one_edit` (default) | Treat it as closing the current element if the names differ by one edit: one character added, removed or changed, or two neighbours swapped. Both names need at least 4 characters. |
| `.two_edits` | As above, and also allow two edits when both names have at least 8 characters |

```zig
const Custom = markup.Profile(.{ .policy = .{
    .mode = .structural,
    .on_error = .collect,
    .closing_tag_recovery = .two_edits,
} });
```

**Why it helps.** In `<config><server></servr></config>`, the default reports
one mismatch, for `</servr>`. Without the guess, `<server>` would stay open and
`</config>` would be reported too.

**What it doesn't do.**

- It only changes how parsing carries on, to avoid follow-on errors. The
  mismatch is still reported, the result is still invalid, and a
  [partial document](#partial-results-for-editors) is unchanged. No closing
  tag is invented, nothing is rewritten, no fix is suggested, and the guess
  isn't counted as an accepted deviation.
- It only guesses for the current element, never one further out, and an exact
  match always wins. It doesn't look ahead.
- With `on_error = .fail_fast`, parsing stops at the mismatch without guessing.
- It can guess wrong. A stray `</item>` inside `<items>` can be taken for a
  typo, and then a later, correct `</items>` is reported as unexpected. Use
  `.exact` if you'd rather not guess.

**How names are compared.** Graphviz mode ignores ASCII case; structural mode
doesn't. "Characters" here means code units: bytes in UTF-8, 16-bit units in
UTF-16, 32-bit units in UTF-32. So a guess involving non-ASCII names can differ
between encodings, even when the names look the same. There is no Unicode
normalisation or case folding.

**Bounded work.** All searching after mismatches, exact or guessed, shares one
allowance: one credit per code unit of the source, including any byte order
mark. Each search step spends one credit, and the allowance is never refilled.
If it runs out, parsing ends with `resource_limit`, resource `.recovery_work`
(with `limit` in credits) and incomplete completion, so hostile input can't make
the search slow. The allowance is separate from session budgets and cancel
checks. With fixed settings, an unused matcher is left out of the program, and
`.fail_fast` leaves out all of this.

The setting can also be changed per call when run-time settings are on.

| `parsed.outcome` | Meaning |
| --- | --- |
| `success` | Parsed completely |
| `invalid_syntax` | The markup is malformed |
| `unsupported_feature` | Uses something the parser doesn't handle, like `<?...?>` |
| `resource_limit` | A configured limit or the recovery-search allowance was reached |
| `storage_exhausted` | A fixed buffer was too small |
| `out_of_memory` | The allocator ran out of memory |
| `cancelled` | You cancelled it |
| `diagnostic_stopped` | The bag asked to stop, for example because it was full |
| `sink_failure` | An internal step failed to accept parser output |

## Partial results for editors

> **Available since 0.5.0.**

With `retention.partial`, a failed parse can still return the part recognised
before the first error, for editors that need an outline while someone types.
See [Using it in an editor](EDITORS.md#keep-the-finished-part-of-markup).

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
file. A `markup.Fragment` is a piece of the file's bytes plus its `origin`:
where that piece starts in the original file. Diagnostics then point at the
original file.

```zig
const fragment = try markup.Fragment.fromSource(file_bytes, .{ .start = 120, .len = 40 });
var checked = try markup.parseAndValidate(allocator, fragment, bag.sink(), .{});
defer checked.deinit();
```

| Function | What it does |
| --- | --- |
| `Fragment.fromSource(source, span)` | Takes the `span` part of `source`, with bounds checks, and sets the origin |
| `Fragment.init(bytes, origin)` | Makes a fragment from bytes you already cut out of the file |
| `fragment.rebase(local_span)` | Turns a span inside the fragment into a span in the original file |
| `fragment.child(local_span)` | Makes a fragment for a raw piece inside this one, such as an attribute value |

Rules:

- Origins only work for **raw** pieces of the original file. Decoded, joined or
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
| `checked.parse` | The parse result. It has a document if parsing succeeded. With [partial results](#partial-results-for-editors) on, it can also have a partial document after a failure; check `document.state`. |
| `checked.validation` | Validation of the document if parsing succeeded. If parsing failed and errors are being collected, validation of the parts that could be recognised. `null` after a fail-fast syntax error, unsupported input, a limit, or a stop. |
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
  like DOT sessions. Sessions exist only on profiles that read UTF-8 alone.

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
Validating a parsed tree doesn't use these limits, and validation can't run in
small steps yet.

## Settings

A markup profile works like a DOT profile:

| Profile option | Meaning |
| --- | --- |
| `.policy` | The compiled settings. Fields you leave out keep their defaults. |
| `.runtime_policy` | `true` lets each call pass a `.policy` patch in its options. Default `false`. |
| `.source_encodings` | Which [source encodings](ENCODINGS.md) to read. Default: UTF-8 only. |
| `.processors` (unreleased) | `.string` binds a string checker for [string checks](STRINGS.md#attribute-processing-in-dot-and-markup) on attribute values. |

| Preset | What it is |
| --- | --- |
| `markup.presets.standard` | The defaults |
| `markup.presets.untrusted` | The defaults with finite limits (see above) |

Every setting:

| Setting | Default | Meaning |
| --- | --- | --- |
| `mode` | `.graphviz` | `.graphviz` or `.structural`. See [two modes](#two-modes). |
| `limits.max_source_bytes` | 4 GiB | Largest input accepted |
| `limits.max_nodes` | no limit | Elements, text runs, comments and CDATA sections |
| `limits.max_attributes` | no limit | Attributes in total |
| `limits.max_nesting` | no limit | Deepest element nesting (top-level elements are depth 1) |
| `on_error` | `.collect` | Keep looking after an error, or `.fail_fast` |
| `closing_tag_recovery` | `.one_edit` | `.exact`, `.one_edit` or `.two_edits`. See [closing-tag typo recovery](#closing-tag-typo-recovery). |
| `retention.partial` | `false` | Keep the part recognised before a failure. Doesn't change error handling or what is accepted. See [partial results](#partial-results-for-editors). |
| `syntax.malformed_reference` | `.reject` | `.warn` or `.accept` treat a broken `&` reference as plain text |
| `scanner` | `.scalar` | `.block` reads with vector instructions; same results |
| `diagnostics.fixes` | `.all` | Which suggested fixes to include: `.all`, `.machine_applicable` or `.off` |
| `diagnostics.unsupported` | `.err` | How to report unsupported input: `.err`, `.warning` or `.silent` |
| `execution.metering` | `false` | Allow parsing in small steps |
| `execution.cancellation` | `false` | Allow cancelling through a callback |
| `execution.cancellation_interval` (unreleased) | `1` | How many work steps parsing and measuring may take between cancel checks; must be above 0. Validation keeps its own check points. See [execution](EXECUTION.md#cancellation-interval). |
| `validation.*` | see [Validate](#validate) | Validation checks |
| `string` (unreleased) | `.passthrough` | What to do with attribute values: `.passthrough`, `.none` or `.process`. Compile time only. See [string checks](STRINGS.md#attribute-processing-in-dot-and-markup). |
| `attributes` (unreleased) | none | A `.string` rule for named attributes, overriding `string`. Compile time only. |

**Settings that can be wrong.** A zero `execution.cancellation_interval`
(unreleased) is the only invalid markup setting; zero limits are valid. In the
compiled settings it is a compile error. In a per-call patch, the call returns
`error.InvalidCancellationInterval` before reading any input.
`Profile.validatePolicy(patch)` checks a patch without parsing, as in DOT.

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
caller-built pools. Debug and `safe` builds catch some mistakes with
assertions.

In a partial document, `subtree_end == 0` marks an unfinished
element. Its kept children run to the end of `records`, and its raw span covers
only the part of its opening tag read so far. The node views handle this for
you: `NodeView.record()`, `span()`, `raw()` and child and root traversal treat
the element as running to `document.retained_end`. That doesn't mean a closing
tag was found; check the node's state. Use the views rather than reading
partial records directly.

## Not available yet

- HTML-style tags that never close, like `<br>`
- Other name rules, or your own name rules and reference lists
- Step-by-step sessions for UTF-16 and UTF-32 input, and source excerpts for
  them in boxed output. One-call parsing of those encodings is available;
  see [source encodings](ENCODINGS.md).

See the [roadmap](ROADMAP.md#markup).

## Examples

- [markup.zig](../examples/markup.zig): parse a fragment in structural mode,
  print the tree, and run the optional encoding, name and reference checks
- [graphviz_vocabulary.zig](../examples/graphviz_vocabulary.zig): check a
  Graphviz label with the default Graphviz rules
- [delayed_markup.zig](../examples/delayed_markup.zig): check pieces of a larger
  file with fragments
- [markup_partial.zig](../examples/markup_partial.zig): keep the part of a
  fragment recognised before an error
- [string_processor.zig](../examples/string_processor.zig): decode values with
  `markup.LogicalReader` and check attribute values with a string checker
  (unreleased)

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.
