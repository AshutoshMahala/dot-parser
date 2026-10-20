# Settings

All parsing behaviour is controlled by one struct, the **policy**. You attach a
policy to a **profile**: a type with the same functions as the top-level
`dot` module (`parseAndValidate`, `parseBorrowed`, `validate`, `measure`, and
so on).

> **Looking for one setting?** Every DOT setting, with its values and default,
> is in [All DOT settings](#all-dot-settings). Every markup setting is in
> [markup settings](MARKUP.md#settings).

```zig
const Parser = dot.Profile(.{ .policy = .{ .on_error = .fail_fast } });

var result = Parser.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);
```

`dot.parseAndValidate` and the other top-level functions are simply the
default profile, `dot.Profile(.{})`.

Settings are fixed at compile time unless you ask otherwise. That lets the
compiler leave out code you don't use. To change settings while the program
runs, see [Changing settings at run time](#changing-settings-at-run-time).

You only write the fields you want to change. Everything else keeps its
default. Settings never change your source text.

The markup parser uses the same system with `markup.Profile(...)`. This page
explains the shared parts and DOT's own settings. Markup's own settings are in
[markup settings](MARKUP.md#settings).

## Profile options

`dot.Profile(...)` takes these options:

| Option | Meaning |
| --- | --- |
| `.policy` | The compiled settings. Every field is listed in [all DOT settings](#all-dot-settings). |
| `.runtime_policy` | `true` lets each call pass a `.policy` patch. Default `false`. See [changing settings at run time](#changing-settings-at-run-time). |
| `.source_encodings` | Which encodings can be read, chosen at compile time. Left out means UTF-8; empty means ASCII only. See [source encodings](ENCODINGS.md). |
| `.processors.markup` | DOT only. A processor that checks HTML-like `<...>` values during parsing. See [adding a label processor](#adding-a-label-processor). |

`markup.Profile(...)` takes `.policy`, `.runtime_policy` and `.source_encodings` in the same way.

## Presets

| Preset | What it is |
| --- | --- |
| `dot.presets.standard` | The defaults. Same as `dot.Profile(.{})`. |
| `dot.presets.lenient` | The defaults, plus it accepts three common mistakes, with a warning for each. |

```zig
const Lenient = dot.Profile(.{ .policy = dot.presets.lenient });
```

The default preset is called `standard`, not `strict`, because `strict` is
already a DOT keyword with an unrelated meaning.

Neither DOT preset sets `markup`. So a profile with a
[label checker](#adding-a-label-processor) keeps checking labels when you use a
preset, and a profile without one keeps `.passthrough`. Set `markup` yourself
to change it.

Markup has `markup.presets.standard` (the defaults) and
`markup.presets.untrusted` (finite limits). See [markup settings](MARKUP.md#settings).

## Settings both parsers share

These settings exist in both parsers and mean the same thing in each:

| Setting | Meaning | Default |
| --- | --- | --- |
| `on_error` | Keep looking after an error (`.collect`), or stop at the first (`.fail_fast`). See [errors](ERRORS.md#keep-going-or-stop-at-the-first-error). | `.collect` |
| `scanner` | Read bytes one at a time (`.scalar`) or in 64-byte blocks (`.block`). Same results. See [two scanners](EXECUTION.md#two-scanners). | `.scalar` |
| `execution.metering` | Allow parsing in [small steps](EXECUTION.md) | `false` |
| `execution.cancellation` | Allow [cancelling](EXECUTION.md#cancelling) through a callback | `false` |
| `execution.cancellation_interval` (Unreleased) | Maximum parse work steps between cancellation polls; positive `u32` | `1` |
| `diagnostics.fixes` | Which [suggested fixes](ERRORS.md#suggested-fixes) to include: `.all`, `.machine_applicable` or `.off` | `.all` |
| `diagnostics.unsupported` | How to report [unsupported input](ERRORS.md#unsupported-is-not-invalid): `.err`, `.warning` or `.silent` | `.err` |

Each parser also has `limits`, `syntax` and `validation` settings, but their
fields differ, because the languages differ.

The two parsers' settings are separate even when they are used together. When
you [check labels during DOT parsing](LABELS.md), DOT's `on_error` and limits
apply to DOT, and the label checker's apply to each label.

## DOT settings

The rest of this page covers DOT's own settings. Every field is also listed in
[all DOT settings](#all-dot-settings).

### Lenient syntax

These three inputs are rejected by Graphviz and, by default, by this library.
The lenient preset accepts them with a warning:

| Setting | Accepts | Read as |
| --- | --- | --- |
| `syntax.empty_statement` | a stray `;`, as in `a;;` | nothing (the `;` is skipped) |
| `syntax.long_operator` | `-->` and `---` | `->` and `--` |
| `syntax.bare_dash.acceptance` | a lone `-` as an edge, as in `a - b` | `--` in a `graph`, `->` in a `digraph` |

Each takes `.reject` (default), `.warn` (accept and warn), or `.accept` (accept
quietly). Results count every accepted mistake in `accepted_deviations`, even
when accepted quietly.

`syntax.bare_dash.interpretation` decides what an accepted lone `-` means. Its
only value today is `.from_keyword`: the written `graph` or `digraph` keyword
decides, never nearby edges or the [graph kind setting](#graph-kinds-and-edge-operators).

After accepting, the document stores the corrected operator, but the edge's
range still points at what was written. Empty statements are dropped. To
change these settings for a file, parse it again.

Lenient mode doesn't guess anything else. Missing brackets, keywords used as
names, and spaced-out operators like `- >` are still errors.

### Optional checks

These checks run during validation (or parsing, for numbers). Each takes
`.err`, `.warning` or `.off`. Turning a check off skips it; it doesn't just
hide the result.

| Setting, under `validation` | Default | Reports |
| --- | --- | --- |
| `ambiguous_numeral` | `.warning` | A number that runs into a letter or dot, like `1e3` (read as `1` and `e3`, as Graphviz does) |
| `invalid_encoding` | `.off` | Text that isn't valid in the file's encoding, anywhere except inside HTML-like labels (`invalid_utf8` in 0.4.0) |
| `repeated_attribute` | `.off` | The same key twice on one statement, like `[color=red, color=blue]` |
| `graphviz.unknown_attribute` | `.off` | A key absent from the optional Graphviz attribute catalog |
| `restrictions.graph_kinds.undigraph` | `.off` | The graph is undirected |
| `restrictions.graph_kinds.digraph` | `.off` | The graph is directed |
| `restrictions.graph_kinds.generic` | `.off` | The graph mixes directions (see below) |
| `restrictions.ports` | `.off` | Any node mention with a port, like `a:out` |
| `restrictions.subgraphs` | `.off` | Any subgraph |

`invalid_encoding` checks names, strings, comments and the space between, using
the file's encoding: UTF-8 by default, or ASCII, UTF-16 or UTF-32. It skips the
inside of HTML-like labels. Those are checked by the label checker's own
`invalid_encoding`, and not at all when labels aren't checked. 0.4.0's
`invalid_utf8` checked them too. See
[checking that the text is valid](ENCODINGS.md#checking-that-the-text-is-valid).

Restrictions are for programs that can't handle some feature. For example, a
tool that only understands directed graphs without subgraphs:

```zig
const Lint = dot.Profile(.{ .policy = .{ .validation = .{
    .invalid_encoding = .err,
    .restrictions = .{
        .graph_kinds = .{ .undigraph = .err, .generic = .err },
        .subgraphs = .err,
    },
} } });
```

`repeated_attribute` compares decoded values, so `x` and `"x"` count as the
same key. It needs a scratch array, sized from the parsed document:

```zig
const Checks = dot.Profile(.{ .policy = .{ .validation = .{ .repeated_attribute = .warning } } });

const keys = try allocator.alloc(dot.AttributeKeyScratch, dot.requiredValidationScratch(&document));
defer allocator.free(keys);
const checked = Checks.validate(&document, bag.sink(), .{
    .scratch = .{ .attribute_keys = keys },
});
```

- `dot.requiredValidationScratch(&document)` gives the exact
  number of entries needed, without reading the source or allocating. Each
  entry is 16 bytes. 0.4.0 doesn't have it; use `document.attributes.len`
  there, which is always enough.
- The array is reused from one attribute list to the next, so it needs about
  as many entries as the longest list, not the whole file. It is never more
  than `document.attributes.len`. Lists with zero or one attribute need none.
- With `parseAndValidate`, pass the same array as
  `.{ .validation = .{ .attribute_keys = keys } }`. The document doesn't exist
  yet, so use `measure` first; its attribute count is always enough.
- If the array is too small, validation reports `.insufficient_scratch` with
  the number of entries it needs, before checking anything.
- With `repeated_attribute = .off`, no scratch is needed.
- Validation never changes the source or the document.

### Optional Graphviz attribute catalog

Available in Unreleased. Custom attributes are legal DOT, so this check is off
by default. Enable it to catch spelling mistakes such as `shpe`:

```zig
const Checks = dot.Profile(.{ .policy = .{ .validation = .{
    .graphviz = .{ .unknown_attribute = .warning },
} } });
```

It compares logical, case-sensitive names: `color`, `"color"` and
`"co" + "lor"` are equal. It checks attribute lists and graph assignments,
including statements retained after recovery, in source order. No extra
allocation or validation scratch is needed. Fixed-disabled profiles omit the
check; runtime-enabled profiles can override its severity.

`dot.attribute_catalog.lookup("shape")` returns metadata, or `null` for an
unknown key. `entries` contains all 177 entries in the
[Graphviz attribute table](https://graphviz.org/doc/info/attrs.html), captured
2026-10-17. Entries expose `name`, `targets`, `type_name`, `default_value` and
`minimum`. Types/defaults/minimums are descriptive strings, not applied graph
semantics. This catalog does **not** yet validate DOT attribute values, resolve
defaults, enforce target applicability, or provide color/shape suggestions.

### Graph kinds and edge operators

By default, a `graph` must use `--` and a `digraph` must use `->`. A wrong
operator is a validation error. The parser itself accepts both operators in
either kind, so a tool can still show or fix the file.

Settings live under `validation.graph` for files that say `graph`, and
`validation.digraph` for files that say `digraph`. The written keyword picks
the branch, even when a `graph` is treated as directed.

| Setting | Values |
| --- | --- |
| `validation.graph.treated_as` | `.undigraph` (default), `.digraph`, `.generic` (both operators allowed), or `.auto` (undirected until the first `->`, then generic) |
| `validation.graph.operator_mismatch` | `.err` (default), `.warning`, `.off` |
| `validation.graph.operator_reading` | `.as_written` (default), or `.conform_to_kind` (read a wrong operator as the right one) |
| `validation.digraph.operator_mismatch` | `.err` (default), `.warning`, `.off` |
| `validation.digraph.operator_reading` | `.as_written` (default), or `.conform_to_kind` |

A `digraph` is always directed, so it has no `treated_as`.

```zig
const Forgiving = dot.Profile(.{ .policy = .{ .validation = .{
    .graph = .{ .operator_mismatch = .warning, .operator_reading = .conform_to_kind },
} } });
```

The document always keeps what was written. To read edges the way the policy
sees them, ask for an *interpretation*:

```zig
const view = Forgiving.interpretation(&document, .{});
const kind = document.effectiveKind(view); // ?GraphKind
var edges = document.edgeIterator();
while (edges.next()) |edge| {
    const operator = edge.effectiveOperator(&document, view);
    _ = operator;
}
_ = kind;
```

`effectiveKind` returns `?GraphKind` (0.4.0 returns `GraphKind`).
It is `null` only for an [unfinished document](EDITORS.md#keep-the-finished-part-of-a-dot-file)
under `.auto` with no `->` kept yet, because the missing part could still make
it generic. Complete documents always have a kind. Under `.auto`, operators are
still read as written while the kind is unknown, and graph-kind restrictions
only check a known kind.

Under `.generic` and `.auto` there is no "wrong" operator, so setting
`operator_mismatch` or `operator_reading` for `graph` is a configuration error.

### Keeping comments

> **Available since 0.5.0.**

Comments are skipped by default. `.retention = .{ .comments = true }` keeps
every DOT comment as a record of its kind and position, without interpreting
it. `limits.max_comments` caps how many are kept. Both presets turn retention
off. See [comments](READING_DOCUMENTS.md#comments) and
[comment storage](MEMORY.md#comment-storage).

### Limits and other settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `limits.max_statements` | no limit | Most statements allowed |
| `limits.max_attributes` | no limit | Most `key=value` pairs allowed, including `key = value` statements |
| `limits.max_nesting` | no limit | Deepest subgraph nesting allowed (the document is level 0) |
| `limits.max_comments` | no limit | Most comments kept when comment retention is on |
| `retention.comments` | `false` | Keep comments in the document. See [keeping comments](#keeping-comments). |
| `retention.partial` | `false` | Keep the finished part of the file after an error. See [Using it in an editor](EDITORS.md#keep-the-finished-part-of-a-dot-file). |
| `retention.markup` | `false` | Keep the tree of each checked label. See [keeping label trees](EDITORS.md#keep-the-label-trees-from-a-dot-file). |
| `on_error` | `.collect` | Keep looking after an error, or `.fail_fast` to stop at the first. See [errors](ERRORS.md#keep-going-or-stop-at-the-first-error). |
| `scanner` | `.scalar` | Which text scanner to use. See [scanners](EXECUTION.md#two-scanners). |
| `execution.metering` | `false` | Allow parsing in small steps. See [EXECUTION.md](EXECUTION.md). |
| `execution.cancellation` | `false` | Allow cancelling through a callback. See [EXECUTION.md](EXECUTION.md). |
| `execution.cancellation_interval` (Unreleased) | `1` | Positive work-step interval, independent of metering. See [cancellation interval](EXECUTION.md#cancellation-interval). |
| `markup` | `.process` with a label checker bound, otherwise `.passthrough` | Check HTML-like values with the label checker (`.process`), keep them unchecked (`.passthrough`), or report them as unsupported (`.none`). See [what happens by default](LABELS.md#what-happens-by-default). |
| `diagnostics.fixes` | `.all` | Which suggested fixes to include: `.all`, `.machine_applicable` or `.off` |
| `diagnostics.unsupported` | `.err` | How to report unsupported input: `.err`, `.warning` or `.silent` |

Hitting a limit gives the outcome `.resource_exhausted`. That means "too big
for your settings", not "invalid". Limits count items; they don't reserve
memory.
With partial collection, later retained comments still count toward
`max_comments`. Keeping more output can therefore hit a storage/resource limit
that prefix-only parsing did not; recovery never bypasses the cap.

## Untrusted input

If the input comes from people you don't trust, such as uploads or network
requests, follow this checklist. It applies to both parsers. For markup, start
from `markup.presets.untrusted`, which already sets finite
[limits](MARKUP.md#untrusted-input).

1. **Limit the input size before you read it.** DOT has no source-size
   setting. Positions are 32-bit, so 4 GiB is the hard ceiling, which is far
   too big for a server.
2. **Set all three limits** (`max_statements`, `max_attributes`,
   `max_nesting`).
3. **Bound the other memory too.** Use fixed buffers, or an allocator with a
   cap. The default growable bag already stops at 1,024 diagnostics.
4. **Bound the time** if that matters to you. Use
   [step-by-step parsing](EXECUTION.md) with your own overall budget.
5. **Build with `ReleaseSafe`** at the boundary, so unexpected bugs stop the
   program instead of continuing silently.
6. **Treat values as bytes.** They can contain any byte, including NUL. Check
   before passing them to C functions that expect NUL-terminated strings.

```zig
const Safe = dot.Profile(.{ .policy = .{ .limits = .{
    .max_statements = 10_000,
    .max_attributes = 50_000,
    .max_nesting = 32,
} } });
```

What the library does and doesn't guarantee:

- **Parsing** uses no recursion and makes one pass over the input. Deep nesting
  can't overflow the stack, and parse time grows roughly in step with input
  size.
- **Optional checks cost more.** The encoding check is another pass over the
  input, and the repeated-attribute check sorts each statement's keys. Validation
  can't yet be split into steps or cancelled.
- **Limits are off by default.** Without the budgets above, a large input can
  still use a lot of memory and time. The library gives you the controls; it
  doesn't choose the numbers for you.

## Changing settings at run time

Turn on `.runtime_policy` in the profile. Each call can then pass a `policy`
patch. Fields you leave out keep the profile's compiled values:

```zig
const Runtime = dot.Profile(.{ .runtime_policy = true });

var result = try Runtime.parseAndValidate(allocator, source, bag.sink(), .{
    .policy = .{ .limits = .{ .max_statements = 1000 } },
});
defer result.deinit(allocator);
```

- Functions on a runtime profile return an error union, because a patch can
  be an invalid combination. They check it before reading any input.
- A patch only affects that one call.
- Passing a **whole preset** as a patch replaces every setting except
  `markup`, including limits. `markup` keeps the profile's compiled choice
  unless the patch sets it. To borrow just the lenient syntax rules, copy only
  that part: `.policy = .{ .syntax = dot.presets.lenient.syntax }`.
- `Runtime.validatePolicy(patch)` checks a patch without parsing anything.

Runtime profiles keep all options in the program, so they are a little larger
than fixed ones.

**Unreleased:** markup profiles follow the same rule: runtime policy entry points, including
`prepare` and session initialization/reset, can return a configuration error.
For both parsers, `execution.cancellation_interval = 0` returns
`error.InvalidCancellationInterval`. Zero resource limits remain valid.

## Adding a label processor

A profile can also bring in a processor that checks HTML-like `<...>` values
while parsing. It can be the built-in markup parser, or one you write:

```zig
const Parser = dot.Profile(.{
    .processors = .{ .markup = markup.Profile(.{}) }, // or your own type
});
```

Binding a processor turns label checking on: `markup` defaults to `.process`.
Set `markup = .passthrough` to bind it but leave checking off; see
[turning checking on or off](LABELS.md#turning-checking-on-or-off).

Unlike the policy, a processor is a compile-time choice; it can't be changed by
a run-time patch. The processor keeps its own settings, separate from DOT's.

- [Checking HTML-like labels](LABELS.md) shows how to use it.
- [Bringing your own processor](CUSTOM_PROCESSORS.md) shows how to write one.
- [Markup settings](MARKUP.md#settings) lists the built-in processor's
  settings.

## All DOT settings

Every field of `dot.Policy`, with its default and where it is explained:

| Setting | Values | Default | See |
| --- | --- | --- | --- |
| `syntax.empty_statement` | `.reject`, `.warn`, `.accept` | `.reject` | [Lenient syntax](#lenient-syntax) |
| `syntax.long_operator` | `.reject`, `.warn`, `.accept` | `.reject` | [Lenient syntax](#lenient-syntax) |
| `syntax.bare_dash.acceptance` | `.reject`, `.warn`, `.accept` | `.reject` | [Lenient syntax](#lenient-syntax) |
| `syntax.bare_dash.interpretation` | `.from_keyword` | `.from_keyword` | [Lenient syntax](#lenient-syntax) |
| `validation.ambiguous_numeral` | `.err`, `.warning`, `.off` | `.warning` | [Optional checks](#optional-checks) |
| `validation.invalid_encoding` | `.err`, `.warning`, `.off` | `.off` | [Optional checks](#optional-checks) (`invalid_utf8` in 0.4.0) |
| `validation.repeated_attribute` | `.err`, `.warning`, `.off` | `.off` | [Optional checks](#optional-checks) |
| `validation.graphviz.unknown_attribute` | `.err`, `.warning`, `.off` | `.off` | [Graphviz catalog](#optional-graphviz-attribute-catalog) |
| `validation.restrictions.graph_kinds.undigraph` | `.err`, `.warning`, `.off` | `.off` | [Optional checks](#optional-checks) |
| `validation.restrictions.graph_kinds.digraph` | `.err`, `.warning`, `.off` | `.off` | [Optional checks](#optional-checks) |
| `validation.restrictions.graph_kinds.generic` | `.err`, `.warning`, `.off` | `.off` | [Optional checks](#optional-checks) |
| `validation.restrictions.ports` | `.err`, `.warning`, `.off` | `.off` | [Optional checks](#optional-checks) |
| `validation.restrictions.subgraphs` | `.err`, `.warning`, `.off` | `.off` | [Optional checks](#optional-checks) |
| `validation.graph.treated_as` | `.undigraph`, `.digraph`, `.generic`, `.auto` | `.undigraph` | [Graph kinds](#graph-kinds-and-edge-operators) |
| `validation.graph.operator_mismatch` | `.err`, `.warning`, `.off` | `.err` | [Graph kinds](#graph-kinds-and-edge-operators) |
| `validation.graph.operator_reading` | `.as_written`, `.conform_to_kind` | `.as_written` | [Graph kinds](#graph-kinds-and-edge-operators) |
| `validation.digraph.operator_mismatch` | `.err`, `.warning`, `.off` | `.err` | [Graph kinds](#graph-kinds-and-edge-operators) |
| `validation.digraph.operator_reading` | `.as_written`, `.conform_to_kind` | `.as_written` | [Graph kinds](#graph-kinds-and-edge-operators) |
| `limits.max_statements` | a number | no limit | [Limits](#limits-and-other-settings) |
| `limits.max_attributes` | a number | no limit | [Limits](#limits-and-other-settings) |
| `limits.max_nesting` | a number | no limit | [Limits](#limits-and-other-settings) |
| `on_error` | `.collect`, `.fail_fast` | `.collect` | [Errors](ERRORS.md#keep-going-or-stop-at-the-first-error) |
| `scanner` | `.scalar`, `.block` | `.scalar` | [Two scanners](EXECUTION.md#two-scanners) |
| `retention.comments` | `true`, `false` | `false` | [Keeping comments](#keeping-comments) |
| `retention.partial` | `true`, `false` | `false` | [Partial DOT results](EDITORS.md#keep-the-finished-part-of-a-dot-file) |
| `retention.markup` | `true`, `false` | `false` | [Keeping label trees](EDITORS.md#keep-the-label-trees-from-a-dot-file) |
| `limits.max_comments` | a number | no limit | [Keeping comments](#keeping-comments) |
| `execution.metering` | `true`, `false` | `false` | [Parsing in small steps](EXECUTION.md) |
| `execution.cancellation` | `true`, `false` | `false` | [Cancelling](EXECUTION.md#cancelling) |
| `execution.cancellation_interval` (Unreleased) | `1` to `maxInt(u32)` | `1` | [Cancellation interval](EXECUTION.md#cancellation-interval) |
| `markup` | `.none`, `.passthrough`, `.process` | `.process` with a bound processor, otherwise `.passthrough` | [Checking HTML-like labels](LABELS.md#what-happens-by-default) |
| `diagnostics.fixes` | `.all`, `.machine_applicable`, `.off` | `.all` | [Suggested fixes](ERRORS.md#suggested-fixes) |
| `diagnostics.unsupported` | `.err`, `.warning`, `.silent` | `.err` | [Unsupported is not invalid](ERRORS.md#unsupported-is-not-invalid) |

## Examples

- [policies.zig](../examples/policies.zig): optional checks, the lenient
  preset, graph kinds, run-time changes and a policy-bound session, all running
  together
- [check_file.zig](../examples/check_file.zig): choosing `on_error` at run time
  from a command-line flag
- [fixed_buffer.zig](../examples/fixed_buffer.zig): a profile with a statement
  limit and fixed buffers

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.
