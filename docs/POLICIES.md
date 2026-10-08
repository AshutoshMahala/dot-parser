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

`dot.Profile(...)` takes three options:

| Option | Meaning |
| --- | --- |
| `.policy` | The compiled settings. Every field is listed in [all DOT settings](#all-dot-settings). |
| `.runtime_policy` | `true` lets each call pass a `.policy` patch. Default `false`. See [changing settings at run time](#changing-settings-at-run-time). |
| `.processors.markup` | DOT only. A processor that checks HTML-like `<...>` values during parsing. See [adding a label processor](#adding-a-label-processor). |

`markup.Profile(...)` takes `.policy` and `.runtime_policy` in the same way.

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
| `invalid_utf8` | `.off` | Bytes that aren't valid UTF-8, anywhere in the file |
| `repeated_attribute` | `.off` | The same key twice on one statement, like `[color=red, color=blue]` |
| `restrictions.graph_kinds.undigraph` | `.off` | The graph is undirected |
| `restrictions.graph_kinds.digraph` | `.off` | The graph is directed |
| `restrictions.graph_kinds.generic` | `.off` | The graph mixes directions (see below) |
| `restrictions.ports` | `.off` | Any node mention with a port, like `a:out` |
| `restrictions.subgraphs` | `.off` | Any subgraph |

Restrictions are for programs that can't handle some feature. For example, a
tool that only understands directed graphs without subgraphs:

```zig
const Lint = dot.Profile(.{ .policy = .{ .validation = .{
    .invalid_utf8 = .err,
    .restrictions = .{
        .graph_kinds = .{ .undigraph = .err, .generic = .err },
        .subgraphs = .err,
    },
} } });
```

`repeated_attribute` compares decoded values, so `x` and `"x"` count as the
same key. It needs a small scratch array, one entry per attribute in the
document, that you provide:

```zig
const Checks = dot.Profile(.{ .policy = .{ .validation = .{ .repeated_attribute = .warning } } });

const keys = try allocator.alloc(dot.AttributeKeyScratch, document.attributes.len);
defer allocator.free(keys);
const checked = Checks.validate(&document, bag.sink(), .{
    .scratch = .{ .attribute_keys = keys },
});
```

With `parseAndValidate`, pass the same array as
`.{ .validation = .{ .attribute_keys = keys } }`. Use `measure` to learn the
attribute count before parsing. If the array is too small, validation reports
`.insufficient_scratch` and checks nothing.

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
const kind = document.effectiveKind(view); // .undigraph, .digraph or .generic
var edges = document.edgeIterator();
while (edges.next()) |edge| {
    const operator = edge.effectiveOperator(&document, view);
    _ = operator;
}
_ = kind;
```

Under `.generic` and `.auto` there is no "wrong" operator, so setting
`operator_mismatch` or `operator_reading` for `graph` is a configuration error.

### Limits and other settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `limits.max_statements` | no limit | Most statements allowed |
| `limits.max_attributes` | no limit | Most `key=value` pairs allowed, including `key = value` statements |
| `limits.max_nesting` | no limit | Deepest subgraph nesting allowed (the document is level 0) |
| `on_error` | `.collect` | Keep looking after an error, or `.fail_fast` to stop at the first. See [errors](ERRORS.md#keep-going-or-stop-at-the-first-error). |
| `scanner` | `.scalar` | Which text scanner to use. See [scanners](EXECUTION.md#two-scanners). |
| `execution.metering` | `false` | Allow parsing in small steps. See [EXECUTION.md](EXECUTION.md). |
| `execution.cancellation` | `false` | Allow cancelling through a callback. See [EXECUTION.md](EXECUTION.md). |
| `markup` | `.process` with a label checker bound, otherwise `.passthrough` | Check HTML-like values with the label checker (`.process`), keep them unchecked (`.passthrough`), or report them as unsupported (`.none`). See [what happens by default](LABELS.md#what-happens-by-default). |
| `diagnostics.fixes` | `.all` | Which suggested fixes to include: `.all`, `.machine_applicable` or `.off` |
| `diagnostics.unsupported` | `.err` | How to report unsupported input: `.err`, `.warning` or `.silent` |

Hitting a limit gives the outcome `.resource_exhausted`. That means "too big
for your settings", not "invalid". Limits count items; they don't reserve
memory.

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
- **Optional checks cost more.** The UTF-8 check is another pass over the input,
  and the repeated-attribute check sorts each statement's keys. Validation
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

Markup profiles work the same way, except that every combination of markup
settings is valid. Their functions therefore never return a configuration
error, even with `.runtime_policy = true`.

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

Comment retention is a DOT storage policy, independent of processing and
validation: `.retention = .{ .comments = true }` preserves all recognized DOT
comments as raw kind/span records. See [comments](READING_DOCUMENTS.md#comments).

Every field of `dot.Policy`, with its default and where it is explained:

| Setting | Values | Default | See |
| --- | --- | --- | --- |
| `syntax.empty_statement` | `.reject`, `.warn`, `.accept` | `.reject` | [Lenient syntax](#lenient-syntax) |
| `syntax.long_operator` | `.reject`, `.warn`, `.accept` | `.reject` | [Lenient syntax](#lenient-syntax) |
| `syntax.bare_dash.acceptance` | `.reject`, `.warn`, `.accept` | `.reject` | [Lenient syntax](#lenient-syntax) |
| `syntax.bare_dash.interpretation` | `.from_keyword` | `.from_keyword` | [Lenient syntax](#lenient-syntax) |
| `validation.ambiguous_numeral` | `.err`, `.warning`, `.off` | `.warning` | [Optional checks](#optional-checks) |
| `validation.invalid_utf8` | `.err`, `.warning`, `.off` | `.off` | [Optional checks](#optional-checks) |
| `validation.repeated_attribute` | `.err`, `.warning`, `.off` | `.off` | [Optional checks](#optional-checks) |
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
| `retention.comments` | `true`, `false` | `false` | [Retaining comments](READING_DOCUMENTS.md#comments) |
| `limits.max_comments` | `u32` | maximum `u32` | Bounds retained comments when retention is enabled; not a source-byte or work limit |
| `execution.metering` | `true`, `false` | `false` | [Parsing in small steps](EXECUTION.md) |
| `execution.cancellation` | `true`, `false` | `false` | [Cancelling](EXECUTION.md#cancelling) |
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
