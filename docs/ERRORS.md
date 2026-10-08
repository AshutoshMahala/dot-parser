# Errors and diagnostics

Every operation tells you two things, kept separate on purpose:

1. **What happened**: a small result value, such as `result.outcome`, that
   your code can switch on.
2. **Why**: a list of *diagnostics*. A diagnostic is one reported problem: an
   error or a warning, where it is, and often a suggested fix. Diagnostics go
   to a destination you choose, usually a *bag*.

The library never prints, never panics on bad input, and never reports bad
input through Zig's `error` values. Zig errors only appear for things like
an invalid configuration or a buffer you passed being too small.

Both parsers report problems this way, with the same bags, sinks, renderer and
fixes. The examples here use DOT; for markup, write `markup.` instead of
`dot.`. The few differences are in [the markup parser](#in-the-markup-parser).

## The short version

```zig
var bag = dot.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var result = dot.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);

if (result.documentValid()) {
    // Use result.document.?
} else {
    // Show bag.items() to the user.
}
```

`documentValid()` is true only when parsing finished, a document exists, and
validation found no errors. Warnings don't make it false.

## Parsing and validation

`parseAndValidate` runs two steps:

- **Parsing** checks the grammar and builds the document. A missing `}` or a
  stray `=` is a parsing (syntax) error.
- **Validation** checks rules that need the finished document. Using `--` in
  a `digraph` is a validation error.

So `digraph { a -- b }` parses fine (`result.outcome == .success`), but
validation rejects it (`result.documentValid() == false`). You still get the
document in this case, so tools can show or fix the problem.

If DOT parsing fails, there is **no document at all**. Markup also follows this
default, with an explicit [partial-retention option](MARKUP.md#partial-results-for-editors).

You can also run the steps on their own: `dot.parseBorrowed` parses, and
`dot.validate(&document, sink, .{})` validates.

## DOT parse outcomes

| `result.outcome` | Meaning | Is the input wrong? |
| --- | --- | --- |
| `.success` | Parsed completely. The document is available. | No syntax errors |
| `.invalid_syntax` | The text breaks DOT's grammar. | Yes |
| `.unsupported_feature` | The input uses something your settings turn off, such as HTML-like labels with `markup = .none`. | Not necessarily |
| `.resource_exhausted` | A limit you set was reached, such as `max_statements`. | Not necessarily |
| `.storage_failure` | Memory ran out (`.out_of_memory`), or a fixed buffer was too small (`.pool_exhausted`). | Not necessarily |
| `.diagnostic_stopped` | The diagnostic destination asked to stop *during parsing*, for example because the bag was full. | Unknown |
| `.cancelled` | You cancelled the operation. | Unknown |
| `.processor_stopped` | A label checker stopped the run early. See [checking HTML-like labels](LABELS.md). | Unknown |

Results also carry a few counts and flags:

- `syntax_errors`: how many syntax errors were found, even if the run stopped
  early for another reason.
- `warnings`: how many warnings were produced.
- `completion`: `.complete` if the parser reached the end of the input.
  Reaching the end is not the same as the input being valid.
- `diagnostic_delivery`: `.failed` if your destination failed to accept a
  diagnostic.
- `diagnostic_stop`: set if your destination asked to stop, or failed, in
  either step.

**An empty bag doesn't mean success.** Some outcomes, like `.cancelled`, have
no diagnostic. Always check the outcome or `documentValid()`.

## DOT validation results

When parsing succeeds, `result.validation` holds the validation result.
`result.validation.?.outcome` is one of:

| Outcome | Meaning |
| --- | --- |
| `.completed` | Every check ran. It reports `document_valid`, `violations` (errors) and `warnings`. |
| `.error_stopped` | Stopped at the first error because of `.fail_fast`. |
| `.diagnostic_stopped` | The diagnostic destination asked to stop, for example because the bag was full. |
| `.insufficient_scratch` | A check needed a scratch array that was too small, so no checks ran. See [optional checks](POLICIES.md#optional-checks). |

Only `.completed` with `document_valid` makes `documentValid()` true. In every
other case the document is still available, but it was not fully checked.

## Keep going, or stop at the first error

By default the parser **collects** errors (`on_error = .collect`). After a
syntax error it skips ahead to the next `;` or `}` and keeps looking, so one
run shows you several problems.

Some errors still end parsing, because there is no safe place to continue:

- a problem in the header, such as `digrph {`
- an unclosed `"quote"`, `/* comment */` or `<label>`
- extra text after the final `}`
- a limit being reached

Later errors can be side effects of earlier ones, so fix them from the top.
Collecting is best effort; it doesn't promise to find every error.

To stop at the first error instead, choose `.fail_fast` in the
[settings](POLICIES.md):

```zig
const Parser = dot.Profile(.{ .policy = .{ .on_error = .fail_fast } });
var result = Parser.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);
```

Validation follows the same setting. Warnings never trigger fail-fast.

## Order of diagnostics

Diagnostics arrive in a fixed, repeatable order, but not sorted by position:

- Parse findings come first, in the order they were found.
- Validation findings come next, in source order.
- With [label checking during parsing](LABELS.md#check-every-label-while-parsing),
  each label's findings arrive when the parser reaches that label, before any
  DOT validation findings.

So a validation error near the top of a file can appear after a syntax warning
near the bottom. If you want them sorted by position, sort the bag by `span`.

## Where diagnostics go

You pass a *sink* (a destination) to every operation. Bags are ready-made
sinks:

| Destination | Behaviour |
| --- | --- |
| `dot.GrowableDiagnosticBag.init(allocator, .{})` | Grows as needed, up to 1,024 entries by default, then asks to stop. |
| `dot.FixedDiagnosticBag(N)` | Holds N entries with no allocation, then asks to stop. |
| `dot.reporting.FixedBag(dot.Diagnostic, N, .omit)` | Keeps the first N and only counts the rest in `.omitted`. Never asks to stop. |
| `dot.diagnostic.discard` | Throws diagnostics away. Result counts still work. |
| Your own sink | Calls your function for each diagnostic. |

**When a bag fills up, it asks the operation to stop.** Where that shows up
depends on which step was running:

- **During parsing**, `result.outcome` becomes `.diagnostic_stopped` and there
  is no document.
- **During validation**, parsing has already succeeded, so `result.outcome`
  stays `.success` and the document is available. The stop shows up in
  `result.validation.?.outcome`, which is `.diagnostic_stopped`.

Either way `result.diagnostic_stop` records it and `documentValid()` is false.
A stop doesn't mean the input is bad. It means the input was not fully
checked.

To check the whole input:

- Use a bigger bag. A growable bag can hold up to 65,535 entries, or be
  `.unlimited`.
- Use a `.omit` bag. The run finishes and you learn how many findings there
  were, but only the first N are kept.
- Use your own sink that handles each finding as it arrives (for example,
  writes it out) and returns `.proceed`.

A growable bag's limit can be changed:

```zig
var bag = dot.GrowableDiagnosticBag.init(allocator, .{
    .max_entries = .{ .limited = 10_000 }, // up to 65,535; or `.unlimited`
});
```

### Writing your own sink

A sink is a context pointer and a function. Return `.proceed` to keep going or
`.stop` to end the operation early.

```zig
const Counter = struct {
    errors: usize = 0,

    fn emit(context: ?*anyopaque, problem: dot.Diagnostic) dot.DiagnosticSinkError!dot.DiagnosticAction {
        const self: *Counter = @ptrCast(@alignCast(context.?));
        if (problem.code.info().severity == .err) self.errors += 1;
        return .proceed;
    }

    fn sink(self: *Counter) dot.DiagnosticSink {
        return .{ .context = self, .emit_fn = emit };
    }
};

var counter: Counter = .{};
var result = dot.parseAndValidate(allocator, source, counter.sink(), .{});
defer result.deinit(allocator);
```

Your sink may be called during parsing, so it must not call back into the same
parse.

## What's inside a diagnostic

| Field | Meaning |
| --- | --- |
| `code` | What went wrong, such as `E.Syntax.Grammar.003`. `code.info()` gives its severity, a one-line summary and a hint. |
| `span` | Where: a byte offset and length in your source. `span.locate(source)` gives the 1-based `line` and `byte_column`. |
| `details` | Typed extra information, such as what was expected and what was found. `.none` if there is nothing more. |
| `fix` | An optional suggested repair. See [below](#suggested-fixes). |

Codes read like `E.Syntax.Token.032`. The first letter is the severity (`E`
error, `W` warning). The second part is the area: `Syntax`, `Validation`,
`Resource` or `Profile`. Codes follow the Waddling Diagnostic Protocol (WDP,
version 0.1.0-draft), which also defines a short five-character id for each
code.

Diagnostics hold no pre-written message strings. The wording comes from the
renderer, so you can write your own output (JSON, an editor integration, a
log line) from the same fields.

## Printing diagnostics

The built-in console renderer has four functions:

| Function | Output |
| --- | --- |
| `dot.console.renderBoxed(diagnostic, number, options, writer)` | One diagnostic in a box with source lines |
| `dot.console.renderBoxedList(items, omitted, options, locations, writer)` | All of them, plus a summary |
| `dot.console.render(diagnostic, options, writer)` | One diagnostic, compact log style |
| `dot.console.renderList(items, options, locations, writer)` | All of them, compact |

The list functions need a small scratch array to find line numbers in one
pass. Ask for its size with `locationCapacity`:

```zig
const locations = try allocator.alloc(dot.location.Location,
    try dot.console.locationCapacity(bag.items()));
defer allocator.free(locations);
try dot.console.renderBoxedList(bag.items(), 0, .{
    .source = source,
    .source_name = "graph.dot",
}, locations, writer);
```

The second argument is the number of diagnostics that were left out (use
`bag.omitted` for an `.omit` bag, otherwise 0).

Options:

| Option | Values |
| --- | --- |
| `.source` | Your source text. Without it, positions print as byte offsets and no source lines are shown. |
| `.source_name` | File name to show. |
| `.style` | `.unicode` (default) or `.ascii` box drawing |
| `.color` | `.none` (default) or `.ansi`. The library never checks if your terminal supports color; that's your decision. |
| `.verbose` | Also show the code's sequence alias and short id. |

The compact style looks like this:

```text
error[dot_parser:E.Syntax.Grammar.031]: input ended before the document was complete
  --> sample.dot:6:1: (byte column, offset 56, len 0)
  detail: while parsing the document body: expected a statement or '}', found end of input
  note: unclosed delimiter opened at 1:9; misindented closing brace at 5:1
  help: the input ends inside this scope; add the missing '}'; the '}' at 5:1 is indented like an outer scope, so the missing brace probably belongs above it
  fix: insert '}' at end of input (one possible repair)
```

The renderer never allocates, and it escapes control characters so a hostile
file can't send escape codes to your terminal. Column numbers count bytes; the
box drawing lines up wide characters such as `東` correctly.

[examples/check_file.zig](../examples/check_file.zig) is a ready-made
command-line checker built on these functions.

## Suggested fixes

When the library knows an edit that repairs a problem, the diagnostic carries
it in `fix`:

- `fix.span`: the bytes to change
- `fix.edit`: what to do with them
- `fix.applicability`: how sure the library is

| `fix.edit` | Meaning |
| --- | --- |
| `.delete` | Remove the span. |
| `.replace = r` | Replace the span with `r.text()`. |
| `.insert_before = r` | Insert `r.text()` at the start of the span. |
| `.insert_after = r` | Insert `r.text()` at the end of the span. |
| `.wrap_in_quotes` | Put the span in double quotes. |

| `fix.applicability` | Meaning |
| --- | --- |
| `.machine_applicable` | This is the one correct repair. A tool may apply it without asking. Examples: `-->` to `->`, deleting a stray `;`, quoting a keyword used as a name. |
| `.maybe` | One plausible repair among several. Ask the user first. Examples: closing an unclosed quote at the end of the file, adding a missing `=`. |

`problem.suggestedFix()` returns the fix, or `null`, for both parsers. DOT
also stores it directly in `problem.fix`.

The library never applies fixes itself. To apply several, work from the
highest offset down so earlier offsets stay correct, then parse again.

The `diagnostics.fixes` setting controls which fixes are included: `.all`
(default), `.machine_applicable` only, or `.off`. Filtering fixes never hides
the diagnostic itself.

## Unsupported is not invalid

- `.invalid_syntax` means *the file is wrong*.
- `.unsupported_feature` means *the file uses something your settings turned
  off*. Right now that only happens for HTML-like labels when you set
  `markup = .none`.

An unsupported result is never treated as success, and the parser makes no
claim about the part it skipped. The `diagnostics.unsupported` setting
chooses whether it is reported as an error (default), a warning, or not at
all. That only changes the reporting; the outcome stays `.unsupported_feature`.

## In the markup parser

Everything above applies to the markup parser too, with these differences:

- **Partial results.** `retention.partial` can preserve a safe prefix on failure.
  Its document state, parse outcome and validation coverage stay separate.
- **Names.** Use `markup.GrowableDiagnosticBag`, `markup.FixedDiagnosticBag`,
  `markup.DiagnosticSink` and `markup.console`.
- **Outcomes.** Markup parse outcomes have their own names, such as
  `resource_limit` instead of `resource_exhausted`. See
  [when parsing fails](MARKUP.md#when-parsing-fails). Markup validation reports
  `completion` and `validity` instead of DOT's validation outcomes. See
  [validate](MARKUP.md#validate).
- **Fixes.** Markup diagnostics store a compact fix; call
  `problem.suggestedFix()` to get it. Today the only markup fix adds a missing
  `;` to a reference like `&amp`, and it is always `.maybe`. So
  `diagnostics.fixes = .machine_applicable` hides every markup fix.
- **Related spans.** A markup diagnostic can point at a second place in
  `related`, such as the opening tag that a wrong closing tag fails to match.
- **One bag for both.** When you [check labels during DOT parsing](LABELS.md),
  the profile provides one bag type that holds both kinds of diagnostic, and
  `Parser.console` prints both.

## Error codes

Each parser has its own list of codes. The same text can appear in both, so a
full code includes its parser's name: `dot_parser:E.Syntax.Grammar.003` and
`markup_parser:E.Syntax.Grammar.003` are different codes. The console renderer
always prints the full form. Codes may change between 0.x versions.

### DOT error codes

| Code | When |
| --- | --- |
| `E.Syntax.Byte.003` | A byte that can't start anything in DOT, or a NUL byte inside quotes |
| `E.Syntax.Operator.003` | A `-` that isn't `--` or `->`, such as `a - b`, `-->` or `---` |
| `W.Syntax.Operator.003` | `-->`, `---` or a lone `-` accepted by the lenient setting |
| `W.Syntax.Grammar.034` | An empty statement (`;`) accepted by the lenient setting |
| `E.Syntax.Numeral.001` | `.` or `-.` with no digit |
| `W.Syntax.Numeral.033` | A number runs into a letter or second dot, like `1e3` or `1.2.3`. It is read as two names, as Graphviz does. |
| `E.Syntax.Numeral.033` | The same, when your settings make it an error |
| `E.Syntax.Token.032` | The input ended inside a quote, comment or `<label>` |
| `E.Syntax.Concatenation.003` | `+` is not followed by a quoted string or `<label>` |
| `E.Syntax.Grammar.003` | Something unexpected, such as a missing `=` or `]` |
| `E.Syntax.Grammar.031` | The input ended before the document was complete |
| `E.Syntax.Keyword.003` | A keyword used as a name, like `a -- node`. Quote it: `"node"`. |
| `E/W.Validation.Operator.002` | The edge operator doesn't match the graph kind |
| `E/W.Validation.Encoding.003` | Invalid UTF-8 (optional check) |
| `E/W.Validation.Attribute.035` | The same key twice on one statement (optional check) |
| `E/W.Validation.Restriction.003` | Input uses something you restricted, such as ports or subgraphs (optional check) |
| `E/W.Profile.Feature.009` | Input uses a feature your settings turned off |
| `E.Resource.Capacity.026` | A limit or fixed buffer was full; `details` names which one |
| `E.Resource.Memory.026` | The allocator ran out of memory |

The full list, with summaries and hints, is in
[src/dot/diagnostic.zig](../src/dot/diagnostic.zig).

### Markup error codes

| Code | When |
| --- | --- |
| `E.Syntax.Byte.003` | A forbidden byte, such as a control character |
| `E.Syntax.Grammar.003` | Something unexpected, such as an unquoted attribute value |
| `E.Syntax.Grammar.031` | The input ended inside a tag, quoted value, comment or CDATA section |
| `E.Syntax.Tag.002` | A closing tag doesn't match the open element |
| `E.Syntax.Tag.003` | A closing tag has no open element |
| `E.Syntax.Tag.032` | The input ended before an element was closed |
| `E/W.Syntax.Reference.003` | A malformed reference, like `&` on its own or `&amp` without `;`. A warning when your settings tolerate it. |
| `E/W.Validation.Attribute.006` | The same attribute twice on one element |
| `E/W.Validation.Encoding.003` | Invalid UTF-8 (optional check) |
| `E/W.Validation.Name.003` | A name that breaks the selected name rule (optional check) |
| `E/W.Validation.Reference.003` | A reference missing from the selected list, like `&nbsp;` (optional check) |
| `E/W.Validation.Tag.009` | An element Graphviz doesn't know (Graphviz mode, unreleased) |
| `E/W.Validation.Attribute.009` | An attribute not allowed on that Graphviz element, like `COLOR` on `<B>` (Graphviz mode, unreleased) |
| `E/W.Profile.Feature.009` | Something the parser doesn't handle, like `<?...?>` or UTF-16 input |
| `E.Resource.Capacity.026` | A limit or fixed buffer was full |
| `E.Resource.Memory.026` | The allocator ran out of memory |

The full list is in [src/markup/diagnostic.zig](../src/markup/diagnostic.zig).

## Examples

- [diagnostics_demo.zig](../examples/diagnostics_demo.zig): parse, validate and
  print every problem in boxes, with optional color
- [check_file.zig](../examples/check_file.zig): a command-line checker. Try
  `./zig-out/bin/check_file graph.dot`, with `--compact` for one-line output or
  `--fail-fast` to stop at the first error.
- [policies.zig](../examples/policies.zig): warnings, lenient mode and counts
- [markup.zig](../examples/markup.zig): markup diagnostics printed with
  `markup.console`
- [composed_markup.zig](../examples/composed_markup.zig): DOT and markup
  diagnostics in one bag

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.
