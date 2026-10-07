# Parsing markup on its own

The package has a second module, `markup_parser`, for HTML-like markup. It
works without the DOT parser. Use it to:

- check Graphviz HTML-like labels you got from somewhere other than a DOT file
- parse small HTML-like or XML-like fragments in your own format
- build checks for your own markup dialect on top of it

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

In the default `.structural` mode, tag names can be anything. The optional
[Graphviz vocabulary mode](#graphviz-vocabulary) restricts tag and attribute names. Text,
whitespace and non-ASCII bytes are kept exactly as written.

The parser is meant as a general base that different HTML-like dialects can
build on. Graphviz labels are its first and most important use, not its only
one. See the [roadmap](ROADMAP.md#markup).

## Parse and read a fragment

```zig
const markup = @import("markup_parser");

var bag = markup.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var parsed = markup.parseBorrowed(allocator, "Hello <b class='x'>world</b>!", bag.sink(), .{});
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

Parsing checks structure: tags match and attributes are well-formed.
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
| `validation.graphviz.unknown_element` | `.err` in Graphviz mode | Element names outside the Graphviz vocabulary |
| `validation.graphviz.invalid_attribute` | `.err` in Graphviz mode | Attributes not allowed on a recognized Graphviz element |

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

**Unreleased, vocabulary slice only.** Select it explicitly; structural mode
and the parsing grammar are unchanged:

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

Both checks accept `.err`, `.warning` or `.off`, including runtime patches when
`runtime_policy = true`. They are inactive in `.structural`, regardless of their
stored settings. Complete `standard`/`untrusted` presets select `.structural`.

The vocabulary follows the [documented Graphviz label grammar](https://graphviz.org/doc/info/shapes.html#html):

| Elements | Attribute checking |
| --- | --- |
| `TABLE`, `TD` | Their respective documented attribute lists |
| `FONT` | `COLOR`, `FACE`, `POINT-SIZE` |
| `BR` | `ALIGN` |
| `IMG` | `SCALE`, `SRC` |
| `TR`, `I`, `B`, `U`, `O`, `SUB`, `SUP`, `S`, `HR`, `VR` | No attributes |

Vocabulary lookup, duplicate-attribute comparison and opening/closing tag matching
are ASCII case-insensitive. Recovery uses that same matching rule. Structural
mode remains byte-exact; neither mode normalizes non-ASCII names or guesses typos.
Spelling, attribute order, values and duplicates remain retained as written.
An unknown element gets one vocabulary finding when that check is enabled;
its attribute vocabulary is unavailable and skipped, but recognized descendants
and independent checks are still checked.

When attribute checking is enabled, attributes on an unknown element leave
`graphviz_attributes` incomplete and `completion.incomplete` at the first unchecked
attribute name (or an earlier coverage gap). This is not an additional diagnostic
or a reason to stop. Without other errors, validity is `unknown` and
`documentValid()` is false—even when
`unknown_element = .off`. Independent completed checks still report `complete`.
An unknown element with no attributes introduces no attribute-coverage gap;
an off attribute check remains `not_run`.

`validation.checks.graphviz_elements` and `graphviz_attributes` report coverage
of these two checks. `documentValid()` means valid under the implemented,
enabled checks, **not fully Graphviz-compatible**. This slice does not check
parent/child placement, child sequences, whitespace restrictions, empty-element
forms, double-quote requirements, attribute values or Graphviz's named-reference
catalog. For example, `<TABLE><TD/></TABLE>` passes vocabulary checks despite
missing a row. XML name/reference checks remain independent, opt-in policies.

These checks work with `validate`, `validateIn`, `validateSource[In]` and
`validateScope[In]`. An opening-header scope supplies attribute-owner context;
a bare `attribute_name` scope cannot check per-element permissions and reports
that check as `not_run`. Recognizable headers still get checked after enclosing
syntax errors; unknown or skipped regions retain incomplete coverage.

Lookup adds bounded comparisons per element/attribute, no retained fields and
no allocation of its own. Tree validation walks nodes and attributes once;
duplicate checking keeps its existing sorting/scratch costs. Source validation
needs no header buffer when duplicate checking is off. Fixed structural profiles
compile out vocabulary checks and case folding. Validation remains unmetered;
cancellation and diagnostic-stop behavior are unchanged. Runtime-enabled profiles
compile both modes and select one before parsing/validation; this has a binary-size
cost and should be benchmarked separately from fixed profiles.

For DOT, select label values explicitly using the [delayed path](LABELS.md).
Automatic composition still processes **every** HTML-like operand and does not
select Graphviz label contexts. Binding this profile there applies its vocabulary
restrictions to non-label operands too; automatic label-only selection is future
work. See [graphviz_vocabulary.zig](../examples/graphviz_vocabulary.zig) for standalone usage.
Measure post-parse vocabulary cost with
`zig build bench-markup -Doptimize=ReleaseFast -- --graphviz-only` (fixed/runtime,
valid/invalid inputs, parsing and diagnostic retention excluded).

## When parsing fails

By default the parser keeps going after an error to find more:

| Problem | What it does |
| --- | --- |
| A closing tag with nothing open | Reports it and skips it |
| A closing tag that doesn't match | Reports it once, and closes back to the matching open tag if there is one |
| Elements still open at the end | Reports each one |
| A bad attribute, like a missing `=` | Reports it and skips to the end of the tag |
| An unclosed quote, comment or CDATA | Stops; there is no safe place to continue |

It never invents tags or hands back a repaired or partial tree. Set
`on_error = .fail_fast` to stop at the first error.

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

## Checking a fragment that failed to parse

Validation normally needs a parsed tree. If parsing failed, you can still check
the parts that can be recognised:

```zig
const result = Strict.validateSource(allocator, source, bag.sink(), .{});
```

For example, in `<x a='1' a='2'></wrong>` it still reports the duplicate `a`,
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
| `checked.parse` | The parse result. It has a document only if parsing succeeded. |
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
| `mode` | `.structural` | `.structural` or `.graphviz` (vocabulary checks and ASCII-case-insensitive tag matching; see [coverage](#graphviz-vocabulary)) |
| `limits.max_source_bytes` | 4 GiB | Largest input accepted |
| `limits.max_nodes` | no limit | Elements, text runs, comments and CDATA sections |
| `limits.max_attributes` | no limit | Attributes in total |
| `limits.max_nesting` | no limit | Deepest element nesting (top-level elements are depth 1) |
| `on_error` | `.collect` | Keep looking after an error, or `.fail_fast` |
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

Validation reports findings on a well-formed document. It doesn't repair or
certify a malformed one. Debug and `ReleaseSafe` builds catch some mistakes
with assertions.

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
