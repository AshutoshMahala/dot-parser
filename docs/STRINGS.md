# Standalone string checks

**Unreleased.** This module is on the development branch, not in v0.5.0.

`string_processor` checks borrowed string **contents** independently of DOT and
markup. It does not recognize quotes, unescape text, expand references, remove
a BOM, normalize text, or build a tree. `"SF"` (including its quotes), `&amp;`
and `\n` are literal contents. DOT/markup integration and attribute-based
selection are not implemented yet.

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
| `completion` | `complete`, `fail_fast`, `cancelled`, `diagnostic_stop(reason)`, or `invalid_validator` |
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
modified by this standalone module. Host dispatch, raw-to-logical adapters,
concatenation/source mapping and shared-budget integration remain later work.
See the [initial performance measurements](PERFORMANCE.md#standalone-strings-unreleased).
