# Standalone string checks

**Unreleased.** This module is on the development branch, not in v0.5.0.

`string_processor` checks borrowed string **contents** independently of DOT and
markup. It does not recognize quotes, unescape text, expand references, remove
a BOM, normalize text, or build a tree. `"SF"` (including its quotes), `&amp;`
and `\n` are literal contents on the standalone path. Explicit
[logical-reader binding](#validating-logical-values) supports decoded host values;
[attribute processing](#attribute-processing-in-dot-and-markup) connects it to
DOT and markup with default passthrough.

```zig
const strings = @import("string_processor");
const City = strings.Profile(.{ .policy = .{ .validation = .{
    .one_of = .{ .values = &.{ "SF", "Seattle" }, .severity = .err },
} } });

var bag = City.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
const result = try City.parseAndValidate(
    .{ .bytes = "Seattle", .origin = 0 }, bag.sink(), .{},
);
if (!result.valid()) {
    // Check result.completion as well as the findings in bag.items().
}
```

Add `dependency.module("string_processor")` to your build's imports. See the
[runnable example](../examples/string_processor.zig). The processor takes no
allocator and owns no source, tree, scratch allocation or diagnostic storage.
The growable bag above is caller-owned (default cap: 1,024 entries); fixed bags
and `City.Sink.discard` work too. A discard/filtering sink does not change validity.

## Input and results

Input is `Fragment{ .bytes, .origin }`. The operation checks its bounds, including
the `u32` original-source range. `origin` is the physical byte offset of these
contents in the original source, not a character column. Source must remain
unchanged for the duration of the call or session. Do not concatenate or decode host
spellings and pretend their positions still have a simple origin offset.

The first stage verifies the **entire** selected encoding, including suffixes an
early-failing equality check would not inspect. Adjacent malformed units produce
one error per run. There is no replacement decoding. Content checks require
well-formed input; they are marked `unavailable` if that prerequisite failed.
Invalid encoding is a mandatory error for this logical-string API, not an
optional syntax/character repertoire rule. NUL and valid Unicode noncharacters
are not rejected merely because a host language might forbid them.

`Result` contains:

| Field | Meaning |
| --- | --- |
| `completion` | `complete`, `fail_fast`, `cancelled`, `diagnostic_stop(reason)`, or `invalid_validator`; reader-bound operations can also return `input_unavailable` |
| `checks.encoding/equals/one_of/custom` | `disabled`, `not_run`, `incomplete`, `complete`, or `unavailable` |
| `errors`, `warnings` | Factual findings, independent of diagnostic visibility |
| `delivery` | Whether attempted diagnostic delivery succeeded |
| `valid()` | All scheduled work completed, delivery succeeded, and no error was found |

A complete check can have errors; completion is not validity. A disabled check
is not a passed check. A sink stop cancels further work immediately, even when
the last finding fit exactly. Operational stops do not turn into ordinary input
errors. Invalid policy/input bounds or uncompiled encoding selection are returned
as Zig errors before content processing starts; malformed content is a finding.
There is no partial tree or result deinitialization.

## Policies and encodings

```zig
const Text = strings.Profile(.{
    .runtime_policy = true, // default false
    .source_encodings = &.{ .utf8, .utf16, .utf32 }, // omitted: UTF-8
    .unicode_case_folding = true, // default false; compiles folding capability
    .policy = .{
        .comparison = .case_sensitive,
        .on_error = .collect,
        .validation = .{
            .equals = .{ .expected = "Seattle", .severity = .warning },
            .one_of = .{
                .values = &.{ "SF", "Seattle" }, .severity = .err,
                .comparison = .case_insensitive, // override for this check only
            },
        },
    },
});
```

All content checks default off. Specifying a check's arguments does not implicitly
enable it: set its severity to `err` or `warning`. Under `collect`, enabled checks
run in order: `equals`, `one_of`, `custom`. Under `fail_fast`, the first **error**
stops work; warnings do not. An empty allowed set rejects every value, including
empty input; a set containing `""` accepts the empty string.

Compile-time policy is checked at compilation. With `runtime_policy = true`,
`Text.validatePolicy(patch)` returns `valid` or `invalid(issue)`, and
`parseAndValidate(..., .{ .policy = patch })` prepares it before scanning input.
Omitted fields inherit the baseline. Supplied `equals`, `one_of` and custom
settings are **whole setting values**, not recursively merged patches. Runtime
overrides cannot replace the validator or enable excluded encoding/folding code.
Runtime pattern verification has a cost proportional to the supplied/effective
UTF-8 patterns; fixed policy verification has no per-call cost.

`source_encodings = &.{}` means ASCII-only. UTF-16/32 compile native readers for
both byte orders; select `options.encoding = .utf16le`, `.utf16be`, `.utf32le` or
`.utf32be`. Without a selection, use UTF-8 if compiled, otherwise ASCII if
compiled; native-only profiles require an explicit encoding. These are already
bounded string contents, **not files**: a leading U+FEFF remains content and is
not an encoding detector. No transcoded buffer is allocated. Patterns in policies
and the shared comparator are always UTF-8, independent of source encoding.

### Comparison

- `case_sensitive`: scalar-value equality, with no folding or normalization.
- `ascii_case_insensitive`: fold only ASCII `A`–`Z` to `a`–`z`, leaving every
  non-ASCII scalar unchanged. Locale-independent and available without
  `unicode_case_folding`. This applies to UTF-8/16/32 contents too; it does not
  select ASCII input encoding.
- `case_insensitive`: Unicode **17.0.0 full default case folding** (C + F mappings,
  excluding Turkic T and simple S), including expansions such as `ß` → `ss`.
  This is neither ASCII-only matching nor locale-tailored collation.

`case_sensitive` remains the default. All three choices work as the baseline,
as per-check overrides for `equals`/`one_of`, and through the shared comparison
helpers used by custom validators, including sessions. With runtime policies
enabled, ASCII comparison may be selected without enabling Unicode folding.

For example, ASCII comparison equates `TRUE` and `true`, but not `ellipſe` and
`ellipse`, `É` and `é`, or `Straße` and `STRASSE`. Punctuation is not folded.
Use it for application rules requiring ASCII-insensitive words, not as a blanket
Graphviz attribute policy: DOT attribute names and many values are case-sensitive.
This option does not change existing DOT keyword or markup vocabulary matching.

The [pinned Unicode data](https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt)
does not imply normalization: `é` and `e` followed by a combining acute accent
remain different. Folded scalars are streamed through bounded three-scalar
buffers, not copied into a new string. Built-in failures highlight the original
whole value; folding never changes its stored span or source.

Exact/ASCII-only profiles do not reference Unicode folding tables or use Unicode
expansion buffers. Requesting `case_insensitive` without
`unicode_case_folding = true` is a configuration error. Fixed profiles with no
enabled ASCII-insensitive comparison also exclude its comparison paths. A
runtime profile allowed to select Unicode folding necessarily retains its code
and data even on exact/ASCII calls. Non-comparison validators need neither a case field
nor a folding capability. The generated table and Unicode license live in
`src/string/`; its generator verifies the compressed table against the pinned
input across the full code-point range.

## Custom validators

Policies configure checks and their behavior; validators implement those checks.

Built-in `strings.validators.Equals` and `OneOf` use the same contract as custom
validators; there is no runtime callback registry. Bind one custom implementation
per profile with `.custom = Validator`. Binding does **not** run it: enable
`.policy.validation.custom = .err` or `.warning`.

```zig
const Nonempty = strings.validators.Predicate(void, {}, struct {
    fn check(value: anytype, _: void) bool {
        return value.bytes.len != 0;
    }
}.check);
const Text = strings.Profile(.{
    .custom = Nonempty,
    .policy = .{ .validation = .{ .custom = .err } },
});
```

A structured validator supplies:

```zig
const RequiredInitial = struct {
    pub const Settings = struct { scalar: u21 = 'A' };
    pub const defaults: Settings = .{};
    pub const uses_comparison = false;
    pub const Detail = enum { wrong_initial };

    pub fn check(value: anytype, settings: Settings, context: anytype) strings.Outcome {
        if (context.cancelled()) return .stopped;
        var cursor = value.cursor();
        const first = cursor.next() catch {
            context.invalidValidator();
            return .stopped;
        };
        if (first == settings.scalar) return .passed;
        if (!context.report(.{ .detail = .wrong_initial })) return .stopped;
        return .failed;
    }
    pub fn message(_: Detail, writer: anytype) !void {
        try writer.writeAll("the required initial character is missing");
    }
    pub fn hint(_: Detail, writer: anytype) !void {
        try writer.writeAll("start with the configured application character");
    }
};
```

`Settings`, `defaults` and `uses_comparison` are required. Supply `check` for a
synchronous validator, or `State(Context)` and `step` for a resumable validator
(both forms can coexist). Optional
`validateSettings(settings) bool` must be pure, allocation-free, source-independent
configuration verification; it must not invoke execution callbacks. Policy
`.custom` supplies the settings, while `.validation.custom` supplies severity.
`Text.Policy` has the bound validator's settings type. Defaults are checked even
when a validator is bound but disabled.

The value exposes borrowed `bytes`, original `origin`, its compile-time `encoding`,
a scalar `cursor().next()` and a checked **local** `try span()` (`SourceTooLarge`
for consumer-constructed values exceeding the u32 domain). Raw byte length is not a
character count. A validator sees no node, element, attribute name or host AST.
It must not retain context pointers or mutate source. Consumer code is trusted
Zig code: binding it at compile time is not a sandbox.

The outcomes are `passed`, `failed`, `stopped`. An unexplained `failed` produces
one generic custom-check finding. Detailed findings suppress that fallback, so
multiple reports do not gain a duplicate generic error. A `passed` return cannot
erase reports. Returning `stopped` without signalling cancellation, a sink stop
or validator failure produces `invalid_validator`, not success.

### Shared comparisons and diagnostics

With `uses_comparison = true`, `context.equals(value, expected_utf8)` returns
`?bool`: null means stop. It uses the profile's comparison setting. Nonparticipating
validators cannot call it; their original input is never silently lowercased.
This synchronous helper is available only to the unstepped fast path. Any
validator compiled for the session engine must use `equalsStep` instead,
including cancellable and runtime-policy profiles with metering disabled.
Pass the original supplied value, not a fabricated view or substring; this
ensures comparisons reuse the verified input prerequisite. An independently
configured regex can instead own its comparison semantics.
There is no bundled regex engine.

`context.report(finding)` returns false when work must stop. A finding can contain
local `span`, `related`, typed `detail`, and `fix`. Missing primary span means
the whole value. **Every standard span field** is checked against the fragment and rebased once,
including ignored fix offers. Invalid ranges produce `invalid_validator` even in
ReleaseFast. Rule severity is authoritative; a custom report cannot secretly
promote a warning rule or bypass an error rule.

The WDP `custom_check_failed`/`custom_check_warning` family identifies the custom
rule; optional `Validator.Detail` retains its finer typed identity and payload.
Optional `message(detail, writer)` and `hint(detail, writer)` customize wording
without allocated message strings. All reports retain their `detail`; consumers
can switch on it independently of rendered wording. Findings without detail use
the generic message. Each bound profile exposes its matching `Diagnostic`,
`FixedDiagnosticBag(N)`, `GrowableDiagnosticBag`, `Sink` and `console` renderer.
Console layout/positions/annotations come from the common renderer, not a new
format. Render against the **original** source and select its source encoding.

Fix replacement text is borrowed UTF-8; an edit application must encode it for a
UTF-16/32 source. `diagnostics.fixes = all` is the default; `machine_applicable`
filters uncertain offers and `off` removes all offers, without changing validity.
No edit is applied automatically. Any borrowed references in details or fixes
must outlive their retained diagnostics; do not report pointers to callback-local
buffers.

## Metering, cancellation and sessions

Execution uses the same policy names and session lifecycle as DOT and markup:

```zig
const Text = strings.Profile(.{ .policy = .{
    .execution = .{
        .metering = true,             // default false
        .cancellation = true,         // default false; independent of metering
        .cancellation_interval = 1,   // positive work-step count, default 1
    },
    .validation = .{ .equals = .{ .expected = "Seattle", .severity = .err } },
} });
var session = try Text.Session.init(
    .{ .bytes = source, .origin = 0 }, bag.sink(),
    .{ .cancellation = cancel_token }, // optional borrowed hook
);
defer session.deinit();
while (true) {
    const progress = session.advance(64);
    // At most 64 credits used; return to your event loop here if unfinished.
    if (progress.outcome != null) break;
}
const result = session.result().?;
```

`parseAndValidate` remains a single run-to-completion call. `Session.run()` also
runs to completion without a credit limit. `advance(budget)` yields without
restarting a check; `advance(0)` does no content work but checks cancellation at
entry. `result()` is null until terminal, including after a pause. `cancel()`
and `deinit()` end unfinished work without creating input-error diagnostics.
After termination, further calls do no work or polling and keep the same result.
`reset(fragment, sink, options)` starts a fresh operation; an invalid reset leaves
the previous session unchanged. There is no allocation to free. Sessions can move
between calls, but cannot be driven concurrently or reentered by a callback.

With `runtime_policy = true`, execution overrides are resolved and latched at
init/reset; `advance` returns an error union and needs `try`. It returns
`MeteringDisabled` if metering is off. For fixed profiles, calling `advance` with
metering off is a compile error. The top-level `strings.BoundedSession` enables
metering with all content rules off. Cancellation lives under
`.policy.execution.cancellation`, not a separate top-level profile setting.

### Credit and cancellation guarantees

One credit dispatches one bounded state-machine step. Built-in steps perform
one of these operations:

- Decode one source or expected scalar (at most four physical bytes), or advance
  one malformed physical code unit.
- Compare at most one scalar per side, including producing or consuming a
  bounded Unicode-fold expansion.
- Emit a finding, finish a check/candidate, or move to the next stage. A finishing
  comparison may also emit its one generic failure finding within that step.

Credits are **not bytes or wall-clock time**, and are not interchangeable with
DOT/markup scanner credits. Budget one always permits progress. Partitioning the
same work into different positive budgets does not change total charged work,
findings or results. No scan of an entire value or candidate list is hidden in
one built-in step. Membership retains its candidate position; folding retains its
pending expansion across pauses. `work_used` counts this call only.
`source_frontier` counts physical source bytes classified by the encoding pass,
relative to the fragment; it stays at the source length while content checks
continue. `stage` distinguishes `encoding`, `equals`, `one_of`, `custom`, `done`.

When enabled, cancellation is checked on every live entry and at most
`cancellation_interval` work steps apart. Larger intervals do not change credits
or allow `advance` to exceed its budget. A cancelled check stays incomplete;
scheduled later checks stay not run. A finished result wins over late cancellation.
No clocks, threads or synchronization are created. The caller owns hook lifetime,
thread safety, and delivery cost.

Fragment/policy preparation occurs at init/reset, **outside** the work budget.
Runtime policy verification scans effective patterns and may call custom
`validateSettings`; this is not resumable. Sinks and hooks are synchronous callbacks,
not preemptible operations. Their execution time is not bounded by credits.

### Resumable custom validators

Built-ins and custom validators use exactly the same `State(Context)` / `step`
contract, with optional `batch` and unmetered `check` fast paths. For example,
a custom comparison can use the shared bounded helpers:

```zig
const Match = struct {
    pub const Settings = []const u8;
    pub const defaults: Settings = "Seattle";
    pub const uses_comparison = true;
    pub fn State(comptime Context: type) type {
        return struct { comparison: Context.ComparisonState = .{} };
    }
    pub fn step(state: anytype, value: anytype, expected: Settings,
                context: anytype) strings.Step {
        return context.equalsStep(&state.comparison, value, expected);
    }
    pub fn batch(state: anytype, value: anytype, expected: Settings,
                 context: anytype, allowance: u32) u32 {
        return context.equalsBatch(&state.comparison, value, expected, allowance);
    }
};
```

Bind it with `.custom = Match` and enable `.policy.validation.custom` as usual.
Each `step` costs one credit and returns `pending`, `passed`, `failed` or
`stopped`. State starts with its default field values. Those defaults must be bounded
and must not scan input, invoke callbacks or allocate. Store progress in that state, not
in retained context/session pointers. Do bounded work per call and yield
`pending` when unfinished; the engine cannot enforce a time limit on arbitrary
trusted Zig code. A custom loop or regex call does not become bounded just by
being placed inside `step`.

`equalsStep` validates its UTF-8 expected argument incrementally, then compares
using the profile's case setting. Pass the original value and the same unchanged
expected slice until terminal, and reset its state before a new comparison.
Patterns and custom settings remain borrowed and must outlive the session.
Calling synchronous `context.equals` from a session-engine validator is a compile
error, even when metering is disabled for that call.
Use `context.report` for detailed diagnostics as before; reports survive pauses
and suppress the generic failure fallback across the whole check.

An optional `batch(state, value, settings, context, allowance) u32` can replace
**consecutive pending steps** with equivalent bounded work. Return their exact
credit count, no greater than `allowance`. Returning zero must leave state
unchanged and requests the scalar fallback. It must preserve the state and work
count that repeated `step` calls would produce: do not skip reports, polls,
terminal outcomes or other callback side effects. Overcharging is reported as
`invalid_validator`; arbitrary trusted Zig code still owns its work bounds.

The batch context deliberately exposes no `report` or `cancelled` methods. Its
`equalsBatch` helper consumes matching ASCII runs or expected-pattern ASCII runs;
zero leaves the original `step` to handle Unicode, folding, mismatches, malformed
patterns and completion. This helper is not available in a single-step context.
Both `equals` and `one_of` use this same optional contract. A validator with only
`State`/`step` remains supported without modification. Never rely on a batch
being called: small budgets, poll intervals and unsuitable input can bypass it.

An optional `check` provides an unmetered fast path, exactly as it does for
built-ins. It must agree with `step` on acceptance and diagnostics. A step-only
validator also works unmetered. A check-only validator (including `Predicate`)
is accepted unmetered but rejected by `validatePolicy`/init if active metering is
requested; it is never silently treated as bounded. Cancellation-only execution
can call it, but it must poll `context.cancelled()` inside long work itself.

## Execution costs

With both execution features off, the one-shot path has no session state,
credit counters or cancellation polling. Opting into metering or cancellation
uses bounded work, even when calling `parseAndValidate` or `Session.run`. Small
budgets and cancellation intervals use the scalar driver directly. Larger
allowances can combine equivalent ASCII steps without changing their credits;
a failed batch probe falls back to a bounded scalar run instead of probing
overlapping windows at every scalar. No batch or fallback crosses the remaining
budget or next cancellation poll. Budget one and interval one remain scalar.
Larger budgets can reduce both resume and per-step overhead, but do not reduce
the charged work. Session storage includes only compiled-in
rules and folding capability; runtime-configurable profiles retain the possible
rule states. Storage is fixed-size and caller-owned, not proportional to input
length or membership-list length.

Source encoding is checked before the enabled rules; comparisons may scan
it again. Uncancellable UTF-8 uses the standard validator's ASCII fast path;
malformed input then takes a locating pass for diagnostic runs. Exact UTF-8/ASCII
comparison can use byte equality after validation; ASCII-insensitive comparison
can use bytewise ASCII folding. Native readers fold only the decoded ASCII
scalars. Metered ASCII runs can batch equivalent pending comparisons, preserving
credits and poll boundaries; tails, mismatches and non-ASCII use scalar steps.
Cancellable comparisons retain cooperative polling. Membership is a short-circuit
linear search through candidates, not a
compiled hash index. Custom settings, code and sink behavior determine their own
additional costs. The shared comparator also verifies its UTF-8 expected argument,
equally for built-ins and custom code. An unmetered, uncancellable exact byte match
can reuse the input's encoding proof instead of scanning identical bytes again;
a mismatch still checks the entire expected argument, including malformed suffixes.
Metered/cancellable checks retain their original expected-scan credits and polling.
Do not assume dynamic expected patterns are free to prepare or scan.
No heap allocations occur in the processor or comparators;
only caller-selected bags or consumer callbacks may allocate. There is no string
tree, retained processor per value, normalization buffer or source copy.

For a single before/after report, run `zig build perf-string -- --baseline HEAD`.
It covers native comparisons and sessions in ReleaseFast/ReleaseSafe and saves
timings, ranges, sizes and work counters; see [report options](PERFORMANCE.md#one-command-string-comparison).

Run `zig build test-string`, `zig build bench-string -Doptimize=ReleaseFast`,
`zig build bench-string-sessions -Doptimize=ReleaseFast`, and `zig build check-wasm`.
`zig build bench-string-passthrough -Doptimize=ReleaseFast` compares real DOT
quote scanning with simulated handoff to string checks; it is not host integration.
The session benchmark reports time, credits, hook calls and state size for
fixed/runtime policies and multiple budgets/intervals. The last command builds
consumed, stripped Wasm probes for exact, ASCII-insensitive, Unicode folding and
non-comparison builds and uses Node to execute their exports and verify
folding-table exclusion. `zig build check` includes these
Wasm checks alongside the repository's other correctness/build checks, without
running benchmarks. DOT/markup hot paths are not
modified by this standalone module. Explicit logical-reader binding is available
below, followed by optional automatic host dispatch. Shared-budget composition
remains later work.
See the [initial performance measurements](PERFORMANCE.md#standalone-strings-unreleased).

## Logical readers

> **Unreleased.** A shared reader foundation, not automatic string processing.

These allocation-free readers expose the same `step()`, `location()`,
`contiguous()` and `position()` interface. Select the actual encoding, including
byte order, at compile time. Supply a borrowed `Fragment` with its **original**
byte origin. Initialization checks coordinates without scanning or BOM detection.

| Reader | Input and interpretation |
| --- | --- |
| `strings.LogicalReader(actual)` | Already-logical contents; no unescaping, reference decoding or BOM stripping |
| `dot.identifier.LogicalReader(actual)` | One host-selected identifier expression; removes DOT quoting, escaped quotes, line continuations and concatenation glue; preserves layout/unknown escapes |
| `markup.LogicalReader(actual)` | One text or attribute-content scope **without delimiters**; decodes numeric and selected named references |

The shared types are available as `strings.logical`, `dot.logical` and
`markup.logical`. A caller can use one generic consumption loop for all three:

```zig
var reader = try markup.LogicalReader(.utf8).init(
    .{ .bytes = "A&amp;B", .origin = 100 },
    .{},
);
while (true) {
    switch (reader.step()) {
        .pending => {},
        .scalar => |item| {
            // Characters: A, &, B. The '&' span is { start = 101, len = 5 }.
            consume(item.codepoint, item.location);
        },
        .end => break,
        .failure => |problem| {
            handleReadFailure(problem);
            break;
        },
    }
}
```

`consume` and `handleReadFailure` are application callbacks in this illustration,
not library functions. Readers do not emit diagnostics or decide severity.
Failures distinguish `invalid_encoding`, `invalid_syntax`,
`unresolved_reference` and `unsupported_form`. They are terminal; repeated calls
return the same failure without further work. Previously delivered characters
are only a prefix, not a successfully resolved whole value. Successful EOF is
likewise stable. DOT's reader is not an identifier grammar validator: select
one value using the host parser, or validate its syntax independently. Malformed
caller input still cannot cause out-of-bounds reads.

### Mapping and borrowed contents

Each scalar carries its original physical byte `span`, including the complete
escape/reference spelling, and `segment_start` identifying its operand's opening
quote or content start. Native UTF-16/32 coordinates remain physical bytes.
`Fragment.child` composes origins once; never add enclosing origins again.

`SourceLocation.mapping` distinguishes exact item spellings from enclosing
whole-value highlights. `reader.location()` supplies the whole original input,
including DOT quotes and concatenation glue; an empty markup/raw value has a
zero-length location at its origin. A DOT empty string has an enclosing location
covering its quotes. **Neither kind authorizes a raw text edit.** Cross-operand
selection helpers, insertion-boundary validation and host-aware fix materialization
remain future integration work. Mapped custom findings are supported below.

`contiguous()` returns optional borrowed, unchanged contents with their encoding
and location. It does not validate them or scan to discover a fast path. Plain
contents and unquoted DOT values can return a view; quoted DOT values and nonempty
markup conservatively return null. Null means use `step()`, not allocate a
decoded string. No tree, mapping array or decoded buffer is created. Source must
remain immutable and outlive readers and retained locations/views. Reader fields
are implementation state: initialize through `init` and do not modify them.

### Host rules and bounded work

Markup options are explicit because a raw content fragment has no enclosing
profile/context. `references` defaults to `.xml_predefined`; `.graphviz` enables
the existing HTML4-plus-`apos` catalog. Names are case-sensitive. Unknown names
remain unresolved, not invented text or replacement characters. Numeric
references use the existing markup character-validity rules and saturating
accumulation. There is no recursive expansion, DTD or external entity lookup.

`malformed_reference` defaults to `.reject`. With `.warn` or `.accept`, malformed
spellings are read literally, matching host syntax acceptance; the **host** owns
any warning. `normalize_attribute_whitespace` defaults to false. Set it to true
for the existing Graphviz attribute-check behavior: literal tabs/CR/LF become
spaces, but numeric references keep their decoded characters. CDATA contents
should use the plain reader instead of the reference-decoding reader.

DOT HTML-like operands return `unsupported_form`, including in mixed
concatenations. The reader never strips tags, flattens markup or expands DOT
layout escapes. Comments between quoted operands are skipped, one unit at a
time; encoding checks on skipped comment contents remain the host's responsibility.

Each step consumes at most one physical source code unit, with fixed-size scalar
decoding (at most four bytes) or fixed-catalog lookup. Multi-unit scalars, long
references and concatenation glue yield `pending`. Accepted malformed references
may replay their spelling as literal text, so `position()` is a traversal cursor,
**not** a monotonic validation frontier or work counter. Replay remains linear.
No step scans an arbitrarily long name or comment. State is fixed-size and can
be copied/moved between steps without pointers into the reader itself.

Callers may pause between steps or check cancellation before another step.
These are reader steps, **not a redefinition of existing parser/string-session
credits**. The readers themselves do not implement a scheduler or automatic
polling. The explicit binding below adds string-session scheduling without
changing standalone credit accounting or batching.
Run `zig build test-logical` for mapping, native encodings, bounded progress and
host-decoder parity tests.

## Validating logical values

> **Unreleased.** Explicit binding; not automatic DOT/markup attribute routing.

Bind the reader type at compile time to reuse a string profile's checks, policy,
diagnostics and execution settings:

```zig
const Text = strings.Profile(.{ .policy = .{ .validation = .{
    .equals = .{ .expected = "A&B", .severity = .err },
} } });
const Label = Text.WithReader(markup.LogicalReader(.utf8));
const reader = try markup.LogicalReader(.utf8).init(
    .{ .bytes = "A&amp;B", .origin = 100 }, .{},
);
var bag: Text.FixedDiagnosticBag(8) = .{};
const result = try Label.parseAndValidate(reader, bag.sink(), .{});
std.debug.assert(result.valid());
```

`Text.WithReader(dot.identifier.LogicalReader(.utf8))` also reads quoted
concatenations as one value. `Text.WithReader(strings.LogicalReader(.utf8))`
uses the same interface on already-logical contents. Bound native encodings must
be enabled by the string profile's `source_encodings`; a conflicting explicit
`Options.encoding` is rejected. No encoding is guessed or converted.

Each call starts a fresh traversal, even if the supplied reader was previously
advanced. Its source and host options are retained. The reader contract adds
`encoding_kind`, `fragment()` and checked `restarted()`; third-party reader
implementations must obey the same bounded-work, immutable-source and movable
state contract. Compile-time binding does not sandbox custom Zig code.

### One validator interface

The same `State(Context)` / `step` and optional synchronous `check` contract is
used for plain and host-decoded values. Built-in equality/membership also use
this interface, including ASCII-only and full Unicode folding. Patterns remain
UTF-8 configuration independently of source encoding.

Portable custom validators use `value.location()`, `value.contiguous()` and
`context.readStep(&cursor, value)`. A `Context.Cursor` starts as `.{}` and retains
fixed-size traversal state. `readStep` returns `pending`, `scalar` (codepoint plus
original-source location), `end` or `stopped`. Do not treat `pending` as EOF. The
session step context allows at most one `readStep` per validator step; a second call is an
`invalid_validator` contract failure. Custom work beyond the supplied services
must still be bounded. Comparison helpers retain their `equalsStep`/`equals`
contract; never compare `contiguous().bytes` without respecting its encoding.

```zig
const NoAmpersands = struct {
    pub const Settings = void;
    pub const defaults: Settings = {};
    pub const uses_comparison = false;
    pub fn State(comptime Context: type) type {
        return struct { cursor: Context.Cursor = .{} };
    }
    pub fn step(state: anytype, value: anytype, _: Settings,
                context: anytype) strings.Step {
        return switch (context.readStep(&state.cursor, value)) {
            .pending => .pending,
            .stopped => .stopped,
            .end => .passed,
            .scalar => |item| blk: {
                if (item.codepoint == '&' and
                    !context.report(.{ .at = item.location }))
                    break :blk .stopped;
                break :blk .pending;
            },
        };
    }
};
```

Bind with `.custom = NoAmpersands` and `.policy.validation.custom = .err`.
This example runs unchanged on standalone values or any bound reader. Existing
standalone-only validators using `value.bytes`/`cursor()` remain valid there;
decoded host values deliberately do not expose raw spelling as logical bytes.
Do not retain the value view/context or their pointers across calls. Retain
cursors and source locations in validator state instead.

### Findings and unavailable input

Use `Finding.at` and `related_at` for original-source locations. They are
**not rebased again**. A finding on the `&` above spans all of `&amp;`; native
spans include the physical bytes of every code unit. Omitted `at` highlights the
whole original value (including DOT quotes/glue). `detail`, severity, fail-fast,
sink stops and generic-failure suppression work as for standalone strings.

Both standalone and bound contexts check location bounds, segment origin and
native code-unit alignment even in ReleaseFast. Combining `at` with local `span`,
or `related_at` with local `related`, is invalid. Bound contexts reject local
`span`/`related` and raw `fix` offers: those cannot safely describe logical host
edits. This includes offers filtered by `diagnostics.fixes`. Locations are
highlights, not proof of editability; these checks do not certify that a
hand-fabricated location came from the reader. Host-aware logical replacements
and their materialization are not exposed yet.

Before running checks, the binding traverses the **whole logical input**. An
unresolved reference, invalid encoding/framing or unsupported operand produces
`completion = .input_unavailable` and a typed `result.input_failure` with its
original location. Requested checks become `unavailable`, `checks.encoding`
stays `incomplete`, and `valid()` is false. No string finding is fabricated for
this prerequisite failure: the host owns syntax/reference reporting. A completed
prerequisite covers the logical reader's domain, not skipped DOT comment bytes
or full host grammar. This prevents an early equality mismatch or empty `one_of`
from hiding an invalid suffix. Standalone `Result` has no failure payload cost.

### Sessions and costs

The bound type exposes `Session.init`, `advance`, `run`, `result`, `cancel`,
`reset` and `deinit`, following standalone string-session rules. Enable
`.execution.metering` to advance by budgets; runtime policy overrides remain
opt-in. Reset validates its replacement before discarding existing progress.

One bound input-pass credit performs at most one reader step. A comparison step
performs at most one reader step plus bounded pattern/scalar/folding work, or
one pattern-validation step. Long references and concatenation comments yield;
they are not hidden behind one credit. Credit totals are independent of budget
partitioning. Cancellation is polled at entry and the configured interval;
completed operations remain terminal. `source_frontier` is the input pass's
physical-byte high-water mark, not a count of decoded characters or completed
checks. Reference replay never moves it backwards.

The existing standalone optimized/batched path remains separate at compile time.
Reader-bound execution currently uses scalar stepping and does not invoke
optional validator batches. There is no decoded-value allocation or source-sized
mapping table. Sessions retain the initial reader, input-pass cursor, and active
validator cursors; inspect `@sizeOf(Label.Session)` for a chosen profile. Checks
and `one_of` candidates can traverse/decode the input again. Diagnostic bags
retain their caller-selected memory cost. Automatic attribute dispatch is
available below; shared DOT/markup/string budgets and host-aware fixes remain
separate work.

Run `zig build bench-logical-strings -Doptimize=ReleaseFast` for explicit binding
costs (plain/DOT/markup, short/long/Unicode/glue-heavy inputs, run/budget-one/
budget-64, session bytes and credits). `-- --csv` produces the repository's
benchmark CSV format. Use `zig build perf-string -- --baseline HEAD` to compare
the existing standalone paths before/after a change; these are distinct studies,
not a claim that bound scalar execution has the same cost as contiguous input.

## Attribute processing in DOT and markup

**Unreleased.** Both hosts support compile-time string routing. Binding a string
processor does **not** enable it: the default is `.passthrough`. Only `.process`
invokes the child; `.none` and `.passthrough` are host decisions.

```zig
const Text = strings.Profile(.{});
const city_policy = Text.Policy{
    .validation = .{
        .one_of = .{ .values = &.{ "SF", "Seattle" }, .severity = .err },
    },
};
const Parser = dot.Profile(.{
    .processors = .{ .string = Text },
    .policy = .{
        .string = .passthrough,
        .attributes = .{
            .label = .{ .string = .{ .process = city_policy } },
            .description = .{ .string = .passthrough },
            .restricted = .{ .string = .none },
        },
    },
});
var bag = Parser.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var result = try Parser.parseAndValidate(
    allocator, "graph { a[label=\"Sea\" + \"ttle\"] }", bag.sink(), .{},
);
defer result.deinit(allocator);
std.debug.assert(result.documentValid());
```

The same `.processors.string`, `.policy.string` and `.policy.attributes` fields
work in `markup.Profile`. Its input remains a fragment and its result uses
`deinit()` without an allocator argument. Markup supplies decoded attribute
contents: `A&amp;B` becomes `A&B`, with findings pointing back to the original
reference spelling. Binding that markup profile into DOT also runs its string
checks, including through reused workspaces and delayed markup processing.
All stages can use one composed bag and renderer.

### Selection and precedence

| Situation | Selected handling |
| --- | --- |
| Attribute has an explicit `.string` rule | That rule, including explicit `.none` or `.passthrough` |
| Attribute entry omits `.string`, or no entry matches | Host `.policy.string` |
| Host `.policy.string` omitted | `.passthrough`, even with a processor bound |
| `.process` | Child baseline, with no delegated changes |
| `.{ .process = child_policy }` | Child baseline overridden by the supplied child policy |
| Child runtime policies enabled | Operation's `.string.policy` overrides each selected delegated baseline |

Delegation uses the child's normal policy resolution: for built-in strings,
`equals` and `one_of` settings replace their respective settings records rather
than implicitly merging their members. Unspecified checks and other policy
branches inherit. Processor implementations, route names and route choices
are compile-time bindings, not a runtime registry. Runtime host policies stay
under `.dot` (DOT) or `.markup` (markup); child runtime patches and cancellation
hooks are under `.string`. A delegated policy can enable child cancellation.
The host alone selects the source encoding; the child cannot reinterpret it.

DOT matches logical attribute names exactly, including quoted/concatenated
keys. It visits written attribute pairs and standalone assignments, without
applying graph defaults or merging declarations. Markup matches names exactly
in structural mode and ASCII-insensitively in Graphviz mode. Ambiguous
ASCII-insensitive route names are rejected at compile time when Graphviz mode
is available. Route names are UTF-8 configuration, independent of source
encoding.

String rules select attribute **values**, not identifiers elsewhere, markup
text nodes, comments or attribute names. A pure HTML-like DOT value belongs to
the markup path and never reaches a string validator. Mixed quoted/HTML
concatenations cannot be flattened: `.process` records unavailable string
coverage; `.none` rejects the string form according to the host's unsupported
severity. This slice does not add per-attribute `.markup` routing; existing
global markup handling is unchanged, and unsupported routing fields are
compile-time errors.

`.none` needs no processor binding. The host's `diagnostics.unsupported`
controls error, warning or silent continuation. Silent handling constructs no
diagnostic. Neither rejection nor a failed child check falls back to another
route.

### Results, scheduling and costs

Active routing profiles return `result.host` (the existing host result) and
`result.string` (a constant-size aggregate). `result.documentValid()` requires
both host acceptance and complete, error-free requested string work.
`result.scopeComplete()` still describes the outer document alone.

The string report exposes `processed`, `passed`, `passthrough`, `unsupported`,
`unavailable`, error/warning totals, delivery/stop status and the first typed
unavailable-input location. `complete` means the selected attribute traversal
finished on a complete host tree, not that every string check passed. No
per-attribute result array or decoded string storage is retained.

These are synchronous stages: host parsing/validation runs first, then strings
visit retained attributes in source order. Ordinary host validation errors do
not suppress strings under `collect`. Host fail-fast and operational stops
prevent later stages. A child's fail-fast stops that value; a collecting host
continues other values. Sink stops, cancellation and invalid-validator failures
stop the batch. Diagnostic order follows stage order, not a global source sort.

Partial trees check their retained attributes but leave string coverage
incomplete. With no retained tree, automatic string work does not run; this is
not reported as successfully checked input. Tree-independent attribute checking
after discarded syntax, event-stream checking and shared-budget composed
sessions remain future work.

Use `Parser.Outer` for the underlying host API. For DOT with markup bound this
is the existing markup composition, not a new DOT-only session facade.
Explicit delayed
string checking is allocation-free:

```zig
// DOT document, same routed profile and diagnostic type:
const checked = try Parser.processStrings(&document, bag.sink(), .{});
// Markup additionally takes the original fragment origin:
const checked_markup = try MarkupParser.processStrings(
    &markup_document, original_origin, markup_bag.sink(), .{},
);
```

These calls return a separate report; they do not mutate an earlier result.
Documents must obey the same trusted representation contract as other document
validation APIs. Raw values and their source remain borrowed.

Markup reference and whitespace rules remain host-owned. Graphviz attributes
use XML-predefined references by default (HTML4 text references are a different
scope); an explicitly enabled reference-catalog rule supplies that catalog.
Graphviz literal attribute whitespace is normalized, while numeric references
keep their decoded character. Accepted malformed references remain literal.
Unresolved references cannot pass a string check merely because host reporting
was disabled; they leave string coverage unavailable without a duplicate finding.

Profiles with no active routes return the original host profile type: no
string traversal, aggregate, diagnostic union or processor state is added.
Active routes add matching and logical-reader validation work, fixed-size
aggregate/session state and a diagnostic union sized for its largest payload.
The library adds no heap allocation for routing or built-in string checks;
host pools, diagnostic bags and consumer callbacks retain their own costs.
Markup keeps its fixed-pool and reusable-workspace entry points. DOT's composed
operation remains allocator-backed; existing outer-only sessions are unchanged.

Run `zig build bench-string-integration -Doptimize=ReleaseFast` for default,
passthrough and enabled costs, including allocator-request totals. For an
alternating before/after report:

```sh
zig build perf-string -- --baseline HEAD --suites host-defaults,integration \
  --modes ReleaseFast,ReleaseSafe,ReleaseSmall --runs 5
```

`host-defaults` builds only the existing host operations on both sides, keeping
enabled processors out of the binary-size/default-path comparison.
`integration` also builds the enabled routes; newly introduced passthrough/
process rows are marked new, not given a fabricated baseline. Keeping these
suites separate avoids confusing changes in mixed-benchmark code layout with
costs paid by an application that never enables strings.
