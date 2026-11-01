# String checks

> **Unreleased.** Not in 0.5.0.

The `string_processor` module checks a piece of text against rules you choose:

- is it equal to an expected value?
- is it one of a set of allowed values?
- does it pass your own check (a *validator*)?

It reports problems as diagnostics, the same way the DOT and markup parsers do,
and tells you whether the text passed. You can use it in three ways:

- on plain text, on its own ([quick start](#quick-start));
- on the decoded value of DOT or markup text, read through a
  [logical reader](#logical-readers);
- on attribute values while a DOT or markup document is parsed
  ([attribute processing](#attribute-processing-in-dot-and-markup)).

The module never changes or copies the text. It takes no allocator, allocates
nothing, and owns no source, tree or diagnostic storage.

## Quick start

Add `dependency.module("string_processor")` to your build's imports. Then:

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
    // bag.items() holds the findings. result.completion says whether
    // every check ran to the end.
}
```

- A *profile* (`strings.Profile(...)`) is a type that fixes the rules at
  compile time.
- `parseAndValidate` checks one piece of text and returns a `Result`.
- Findings go to the diagnostic bag you pass in. You own the bag. The growable
  bag keeps at most 1,024 findings by default. A fixed bag
  (`City.FixedDiagnosticBag(8)`) or `City.Sink.discard` works too. Where the
  findings go never changes whether the text is valid.

The runnable program is [string_processor.zig](../examples/string_processor.zig).

## What gets checked

The input is a `Fragment`:

- `.bytes`: the text. It is borrowed, not copied.
- `.origin`: the byte offset where this text starts in your original source.
  Use 0 when there is no larger source.

Findings report positions as byte offsets in the original source (origin plus
the byte offset inside the text). They are bytes, not character columns.
`bytes.len` and `origin + bytes.len` must both fit in a `u32`, otherwise you
get `error.InvalidFragment`. Keep the source unchanged while a call or session
uses it.

**The text is taken literally.** The standalone check does not remove quotes,
decode escapes or character references, strip a byte-order mark (BOM), or
normalize Unicode. `"SF"` with its quotes, `&amp;` and `\n` are checked exactly
as written. To check what DOT or markup text *means*, use a
[logical reader](#logical-readers). Don't decode or join text into a new buffer
and pass it with the old origin: its positions would no longer match the source.

**The encoding is checked first.** Every operation first checks that the
**whole** text is well-formed in the selected encoding. That includes any part
after an early mismatch, which an equality check alone would never read.

- Each run of adjacent malformed bytes gives one `invalid_encoding` error.
- Nothing is replaced or repaired.
- If the text is not well-formed, the content checks don't run. They are
  reported as `unavailable`.
- Bad encoding is always an error here. It is not an optional rule.
- NUL and Unicode noncharacters are accepted. A host language may forbid them,
  but this module does not.

## Reading the result

| `Result` field | Meaning |
| --- | --- |
| `completion` | How the operation ended (next table) |
| `checks.encoding`, `checks.equals`, `checks.one_of`, `checks.custom` | The state of each check (table below) |
| `errors`, `warnings` | How many error and warning findings were found. They count findings even when the sink dropped them. |
| `delivery` | `.complete`, or `.failed` if handing a finding to the sink failed |
| `valid()` | `true` only if the operation completed, the encoding check and every enabled check completed, delivery succeeded, and there were no errors |
| `input_failure` | Only on [reader-bound results](#findings-and-unavailable-input): why the reader could not supply the value |

| `completion` | Meaning |
| --- | --- |
| `complete` | All scheduled work finished. The text can still have errors. |
| `fail_fast` | `on_error = .fail_fast` stopped at the first error |
| `cancelled` | A cancellation request or `cancel()` stopped the work |
| `diagnostic_stop` | The sink asked to stop, was full, or failed. The payload says which: `requested`, `capacity`, `failure` or `out_of_memory`. |
| `invalid_validator` | A validator broke its contract (see [custom validators](#custom-validators)), or a finding counter would overflow |
| `input_unavailable` | Reader-bound only: the reader could not produce the whole value |

| Check state | Meaning |
| --- | --- |
| `disabled` | The check is off. This is not the same as passed. |
| `not_run` | Enabled, but never started because work stopped earlier |
| `incomplete` | Started but did not finish |
| `complete` | Finished. It may have found errors. |
| `unavailable` | Could not run: the text was not well-formed, or the reader failed |

Points to remember:

- A complete check can still have errors. "Complete" is not "valid": use
  `valid()`.
- A sink that asks to stop ends the work at once. A fixed bag asks to stop when
  it stores its last free entry, so a bag of size 1 stops after one finding.
- Stops are never turned into input errors.
- There is no tree and nothing to free in a result.

### Errors returned before any checking

These come back as Zig errors before the text is read. Malformed text is never
one of them: it is a finding.

| Error | Cause |
| --- | --- |
| `InvalidFragment` | The text is longer than a `u32`, or `origin + len` doesn't fit in one |
| `UnsupportedEncoding` | `options.encoding` names an encoding this profile didn't compile, or one that conflicts with a bound reader |
| `EncodingRequired` | No `options.encoding`, and the profile compiles neither UTF-8 nor ASCII |
| `UnicodeFoldingDisabled`, `InvalidPatternEncoding`, `CustomValidatorRequired`, `InvalidCustomSettings`, `InvalidCancellationInterval`, `NonResumableValidator` | A per-call policy override is invalid. Only profiles with `runtime_policy = true` return these; fixed profiles report the same problems at compile time. |

The error set also contains `InvalidSpan`, which `Fragment.child` and
`Fragment.rebase` use; checking itself reports out-of-range input as
`InvalidFragment`.

## Choosing checks

### Profile settings

These are the fields of `strings.Profile(.{ ... })`. Unknown fields are compile
errors.

| Field | Default | Meaning |
| --- | --- | --- |
| `policy` | `.{}` | The baseline settings (next table) |
| `custom` | none | Your [validator](#custom-validators) type. Binding it does not turn it on. |
| `source_encodings` | UTF-8 only | Encodings to compile: `.ascii`, `.utf8`, `.utf16`, `.utf32`. `&.{}` means ASCII only. `.utf16` and `.utf32` compile both byte orders. |
| `unicode_case_folding` | `false` | Compile full Unicode case folding, so `.case_insensitive` can be used |
| `runtime_policy` | `false` | Allow settings to be changed per call ([runtime settings](#changing-settings-per-call)) |

### Policy settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `comparison` | `.case_sensitive` | How text is compared ([comparison](#comparison)) |
| `on_error` | `.collect` | `.collect` runs every enabled check. `.fail_fast` stops at the first error; warnings never stop it. |
| `diagnostics.fixes` | `.all` | Which fix offers findings keep: `.all`, `.machine_applicable` or `.off`. Validity doesn't change. |
| `execution.metering` | `false` | Allow checking in steps with [sessions](#metering-cancellation-and-sessions) |
| `execution.cancellation` | `false` | Poll a cancellation hook. Independent of metering. |
| `execution.cancellation_interval` | `1` | Poll at most this many work steps apart. Must be positive. |
| `validation.equals` | off | Equality check: `.{ .expected, .severity, .comparison }` |
| `validation.one_of` | off | Allowed-values check: `.{ .values, .severity, .comparison }` |
| `validation.custom` | `.off` | Severity of the bound custom validator: `.off`, `.warning` or `.err` |
| `custom` | the validator's `defaults` | The settings value passed to the bound validator |

| `equals` / `one_of` field | Default | Meaning |
| --- | --- | --- |
| `expected` (`equals`) | `""` | The required value |
| `values` (`one_of`) | empty | The allowed values |
| `severity` | `.off` | `.off`, `.warning` or `.err` |
| `comparison` | `null` | Override `comparison` for this check only; `null` uses the policy's |

How they behave:

- Every content check is off by default. Setting `expected` or `values` does
  not turn a check on: set its `severity`.
- With `.collect`, enabled checks run in this order: `equals`, `one_of`,
  `custom`.
- An empty `values` list rejects every value, including empty text. A list
  that contains `""` accepts empty text.
- `expected` and `values` are always UTF-8, whatever the source encoding. A
  pattern that isn't valid UTF-8 is a configuration error.
- A fixed profile's policy is checked at compile time. That costs nothing per
  call.

### Changing settings per call

With `runtime_policy = true`, pass a `.policy` patch in the options:

```zig
const result = try Text.parseAndValidate(fragment, bag.sink(), .{ .policy = .{
    .validation = .{ .equals = .{ .expected = "SF", .severity = .err } },
} });
```

- Fields you leave out keep the baseline value.
- `equals`, `one_of` and `custom` settings are replaced whole, not merged
  field by field. In the example, `equals.comparison` goes back to `null`.
- A patch can't replace the validator, and can't turn on an encoding or Unicode
  folding the profile didn't compile.
- `Text.validatePolicy(patch)` checks a patch without running anything. It
  returns `.valid` or `.invalid` with an issue. On fixed profiles,
  `validatePolicy` works at compile time only.
- Checking a patch scans the patterns it enables (to verify their UTF-8) and may
  call the validator's `validateSettings`. This happens before the text is read.
- A runtime profile allowed to pick Unicode folding keeps the folding code and
  data in the binary, even for calls that don't use it.

### Source encodings

Pick the encoding with `options.encoding`: `.ascii`, `.utf8`, `.utf16le`,
`.utf16be`, `.utf32le` or `.utf32be`. The profile must compile it.

- Without `options.encoding`, UTF-8 is used if compiled, otherwise ASCII.
  Profiles that compile only UTF-16 or UTF-32 need an explicit encoding.
- This is the text's contents, **not a file**. A leading U+FEFF is ordinary
  content, not a BOM, and nothing guesses the encoding.
- No converted copy is made.

### Comparison

| `comparison` | What it does |
| --- | --- |
| `.case_sensitive` (default) | Compares Unicode scalar values exactly. No case folding, no normalization. |
| `.ascii_case_insensitive` | Treats ASCII `A`–`Z` like `a`–`z` and nothing else. Works for UTF-8, UTF-16 and UTF-32 text (it doesn't mean the text is ASCII). The same in every locale. Needs no Unicode tables. |
| `.case_insensitive` | Full Unicode case folding as defined by Unicode 17.0.0: the C and F entries of `CaseFolding.txt`, without the Turkish/Azeri T entries or the simple S entries. So `ß` matches `ss`. It is neither ASCII-only matching nor locale-aware sorting. Needs `unicode_case_folding = true`. |

Any of the three works as the profile baseline, as a per-check override for
`equals` and `one_of`, and in the shared comparison helpers custom validators
use (in sessions too). Runtime profiles may select `.ascii_case_insensitive`
without compiling Unicode folding. Asking for `.case_insensitive` without
`unicode_case_folding = true` is a compile error on fixed profiles and
`UnicodeFoldingDisabled` on runtime ones.

ASCII comparison treats `TRUE` and `true` as equal, but not `ellipſe` and
`ellipse`, `É` and `é`, or `Straße` and `STRASSE`. Punctuation is never folded.
Use it for application rules that ignore ASCII case. Don't use it as a blanket
Graphviz policy: DOT attribute names and many values are case-sensitive. This
setting doesn't change how DOT keywords or markup vocabulary are matched.

Folding is not normalization: `é` and `e` followed by a combining acute accent
stay different. Folded characters stream through small fixed buffers (at most
three characters per side). No folded copy is built. Findings from built-in
checks highlight the original whole value; folding never moves positions or
changes the source.

What gets linked into your program:

- Profiles that never use Unicode folding don't include its tables or buffers.
- Fixed profiles that never use ASCII folding don't include that code either.
- Validators that don't compare text need no comparison setting.

The folding table is generated from the pinned
[Unicode 17.0.0 data](https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt).
Its license is in `src/string/UNICODE_LICENSE.txt`.

## Custom validators

A *validator* is the code behind a check. The built-in
`strings.validators.Equals` and `strings.validators.OneOf` use the same
interface as yours. You bind one custom validator per profile at compile time
with `.custom = MyValidator`, and turn it on with
`.policy.validation.custom = .err` or `.warning`. There is no run-time registry.

### The simplest validator: a predicate

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

`Predicate(Settings, default_settings, function)` wraps a function that returns
`true` to pass. A `false` result gives one generic finding. A predicate runs to
completion in one call, so it can't be paused or cancelled halfway. Enabling it
together with metering is rejected: a compile error on fixed profiles,
`NonResumableValidator` on runtime ones.

### A full validator

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
        if (first != null and first.? == settings.scalar) return .passed;
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

This one uses `value.cursor()`, which exists on plain text only. For a
validator that also works on decoded DOT and markup values, see
[one validator interface](#one-validator-interface).

| Declaration | Required | Meaning |
| --- | --- | --- |
| `Settings` | yes | The type of the settings value |
| `defaults` | yes | The default `Settings` value |
| `uses_comparison` | yes | `true` to use the shared comparison helpers (`equals`, `equalsStep`, `equalsBatch`) |
| `check(value, settings, context) Outcome` | `check`, or `State` + `step` | Runs to completion in one call |
| `State(Context)` and `step(state, value, settings, context) Step` | | The resumable form, needed for metering. See [resumable validators](#resumable-custom-validators). |
| `batch(state, value, settings, context, allowance) u32` | no | An optional faster path for sessions; needs `State` and `step` |
| `validateSettings(settings) bool` | no | Rejects bad settings |
| `Detail` | no | A type your findings can carry |
| `message(detail, writer)`, `hint(detail, writer)` | no | Wording for findings that carry a `Detail` |

- You can provide both `check` and `State`/`step`.
- `.policy.custom` supplies the settings and `.policy.validation.custom` the
  severity. `Text.Policy` uses your `Settings` type for `custom`.
- `validateSettings` must be pure: no allocation, no source access and no
  context calls. The library calls it on the effective settings (`defaults`
  unless you supplied others) even while the validator is off.

### What a validator sees

On plain text the `value` has:

| Member | Meaning |
| --- | --- |
| `bytes` | The borrowed text |
| `origin` | Its byte offset in the original source |
| `encoding` | Its encoding, known at compile time |
| `cursor()` | A cursor whose `next()` returns the next character, or null at the end |
| `span()` | The whole value as a local span. Returns `SourceTooLarge` for a hand-made value longer than a `u32`. |
| `location()`, `contiguous()` | The same views a [logical value](#one-validator-interface) has |

Byte length is not a character count. A validator never sees a node, element,
attribute name or host syntax tree. Don't keep the value, the context or
pointers into them after returning, and don't change the source. Validators are
trusted Zig code: binding one at compile time is not a sandbox.

### Outcomes

`check` returns `passed`, `failed` or `stopped`. (`step` can also return
`pending`.)

- `failed` with no finding reported gives one generic custom-check finding.
- If you reported findings, no extra generic finding is added, however many you
  reported.
- `passed` can't erase findings already reported.
- `stopped` must have a reason: a cancellation, a sink stop, or a call to
  `context.invalidValidator()`. Without one the result is `invalid_validator`,
  never success.

### Shared comparisons and diagnostics

The `context` a validator receives offers these services:

| Method | What it does |
| --- | --- |
| `report(finding) bool` | Emits a finding. `false` means stop now. |
| `cancelled() bool` | `true` when cancellation was requested or the operation has already stopped |
| `invalidValidator()` | Declares that your validator broke its own contract |
| `equals(value, expected) ?bool` | Compares with the profile's comparison setting. `null` means stop. For `check` only. |
| `equalsStep(&state, value, expected) Step` | The same comparison, one step at a time, for `step` |
| `readStep(&cursor, value)` | Reads one character of the value; see [one validator interface](#one-validator-interface) |

The comparison helpers:

- need `uses_comparison = true`. Validators without it can't call them, and
  their input is never silently lowercased;
- use the policy's `comparison` setting (custom validators don't get the
  per-check overrides `equals` and `one_of` have);
- must get the original `value` you were handed, not a substring or a value
  you built (anything else gives `invalid_validator`);
- check that `expected` is valid UTF-8 every time, including any part after a
  mismatch.

`equals` is for `check` only. Calling it from `step` is a compile error whenever
the session engine is compiled; use `equalsStep` there. There is no bundled
regex engine. A validator can implement its own matching.

### Findings

| `Finding` field | Meaning |
| --- | --- |
| `span` | A byte range inside the value (plain text only). Omitted: the whole value. |
| `related` | A second local range, shown as "related value" |
| `at` | A location in the original source, from `value.location()` or `readStep` |
| `related_at` | A related location in the original source |
| `detail` | Your `Detail` value |
| `fix` | A fix offer with a local span (plain text only) |

- Every span, including the span of a fix offer that is then filtered out, is
  checked against the value and moved to source coordinates once. A range
  outside the value gives `invalid_validator`, in every build mode.
- Don't combine `at` with `span`, or `related_at` with `related`.
- The rule decides the severity. Custom findings use `custom_check_failed` for an
  error rule and `custom_check_warning` for a warning rule. A validator can't
  change that.
- Built-in codes are `invalid_encoding`, `unequal` / `unequal_warning` and
  `not_one_of` / `not_one_of_warning`. All codes are in the
  `string_processor` namespace.
- Every finding keeps its `detail`, so you can switch on it instead of on the
  rendered text. Findings without a detail use the generic wording.

Fix offers:

- Replacement text is borrowed UTF-8. To apply it to UTF-16 or UTF-32 source,
  encode it yourself.
- `diagnostics.fixes` filters offers (`.all` by default) without changing
  validity. Nothing is ever applied automatically.
- Anything borrowed in a detail or fix must outlive the stored diagnostics.
  Don't point at a buffer local to your validator.

Each profile has its own `Diagnostic`, `FixedDiagnosticBag(N)`,
`GrowableDiagnosticBag`, `Sink` and `console` renderer. The console output looks
the same as for the other parsers. Render against the **original** source,
with its encoding.

## Metering, cancellation and sessions

*Metering* lets you check text in small steps. A *session* does at most `N`
*credits* of work per `advance(N)` call and then returns, so a long check
doesn't block your event loop. *Cancellation* lets a hook you supply stop the
work. These use the same setting names and session lifecycle as DOT and markup
(see [parsing in small steps](EXECUTION.md)).

```zig
const Text = strings.Profile(.{ .policy = .{
    .execution = .{
        .metering = true,             // default false
        .cancellation = true,         // default false; independent of metering
        .cancellation_interval = 1,   // positive, default 1
    },
    .validation = .{ .equals = .{ .expected = "Seattle", .severity = .err } },
} });
var bag = Text.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var session = try Text.Session.init(
    .{ .bytes = source, .origin = 0 }, bag.sink(),
    .{ .cancellation = cancel_hook }, // a strings.Cancellation you own
);
defer session.deinit();
while (true) {
    const progress = session.advance(64);
    // At most 64 credits were used. Return to your event loop here if needed.
    if (progress.outcome != null) break;
}
const result = session.result().?;
```

| Session method | What it does |
| --- | --- |
| `Session.init(fragment, sink, options)` | Prepares a session. Returns an error before any work if the input or settings are bad. |
| `advance(budget) Progress` | Does at most `budget` credits of work. Needs metering: on a fixed profile without it this is a compile error; on a runtime profile it returns `error.MeteringDisabled` (so use `try`). |
| `run() Result` | Runs to the end with no credit limit |
| `result() ?Result` | `null` until the session has finished, including while paused |
| `cancel() Result` | Stops unfinished work. Creates no input findings. |
| `reset(fragment, sink, options)` | Starts a fresh check. If the new input or settings are invalid, the old session is left as it was. |
| `deinit()` | The same as `cancel()`. There is nothing to free. |

| Option | When it exists | Meaning |
| --- | --- | --- |
| `encoding` | always | The text's encoding ([source encodings](#source-encodings)) |
| `policy` | `runtime_policy = true` | A per-call settings patch, fixed at `init`/`reset` |
| `cancellation` | runtime profiles, or when `execution.cancellation` is on | An optional borrowed hook |

| `Progress` field | Meaning |
| --- | --- |
| `outcome` | `null` while unfinished, otherwise the `completion` |
| `work_used` | Credits used by this call only |
| `source_frontier` | Bytes of the text the encoding pass has read so far, counted from the start of the fragment. It stays at the full length while the content checks run. |
| `stage` | `encoding`, `equals`, `one_of`, `custom` or `done` |

- `parseAndValidate` and `Session.run()` both run to completion. If metering or
  cancellation is on, they use the same bounded steps internally.
- `advance(0)` does no work, but still checks for cancellation.
- Once a session has finished, further calls do no work, don't poll, and return
  the same result.
- `strings.BoundedSession` is a ready-made session type with metering on and no
  content checks (it checks the encoding only).
- Sessions can be moved between calls. Don't drive one from two threads at once.
  A sink or validator must not call any method of the session that is running
  it. A cancellation hook may call that session's `cancel()` and return
  `false`; the session still ends as `cancelled`. It must not call any other
  session method.

### Credit and cancellation guarantees

One credit runs one bounded step. A built-in step does one of these:

- decodes one character (at most four bytes) of the text or of a pattern, or
  skips one malformed code unit;
- compares at most one character from each side, including one character of a
  Unicode folding expansion;
- emits a finding, finishes a check or candidate value, or moves to the next
  stage. A comparison that finishes may also emit its one generic finding in
  the same step.

What that means for you:

- Credits are **not bytes or time**. They are not the same unit as DOT or
  markup credits.
- A budget of 1 always makes progress.
- Splitting the same work into different budgets gives the same total credits,
  findings and result.
- No built-in step hides a scan of a whole value or a whole list. A membership
  check remembers which allowed value it was comparing, and folding remembers a
  half-finished expansion, across pauses.

Cancellation, when enabled:

- is checked on every call that still has work, including `advance(0)`, and at
  most `cancellation_interval` steps apart;
- larger intervals don't change credit counts and never let `advance` go over
  its budget;
- leaves a check that was running as `incomplete`, and later checks as
  `not_run`;
- loses to a result that has already finished.

The module creates no clocks, threads or locks. You own the hook: its lifetime,
its thread safety and its cost. The hook only answers "stop or not"; it must not
call methods on the session.

Not counted in credits:

- preparing the fragment and policy at `init`/`reset`, including checking a
  runtime patch's patterns and calling `validateSettings`. This can't be paused;
- the time your sink and hook take. They run synchronously, so credits don't
  bound them.

### Resumable custom validators

Built-in and custom validators share the same resumable form: `State(Context)`
plus `step`, with optional `batch` and `check` shortcuts. For example, a custom
equality check using the shared helpers:

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

Bind it with `.custom = Match` and enable `.policy.validation.custom`.

**`step`:**

- Each call costs one credit and returns `pending`, `passed`, `failed` or
  `stopped`.
- `State` starts from its field defaults. Those defaults must be cheap: no
  scanning, no callbacks, no allocation.
- Keep progress in the state, never in pointers to the context or session.
- Do a small, bounded amount of work per call and return `pending` when not
  done. The engine can't enforce a time limit on your code: a loop or regex
  call placed inside `step` is not made bounded by being there.
- `equalsStep` first checks the UTF-8 of `expected` step by step, then compares
  using the profile's comparison setting. Pass the original value and the same
  unchanged `expected` pattern until it finishes, and reset its state before a
  new comparison.
- Patterns and custom settings are borrowed and must outlive the session.
- Use `context.report` as in `check`. Findings survive pauses and suppress the
  generic failure finding for the whole check.

**`batch` (optional):**

- It may do the work of several **consecutive `pending` steps** at once. It
  returns how many steps' worth of credits it used, never more than
  `allowance`. Returning more gives `invalid_validator`.
- Returning 0 must leave the state unchanged; the engine then calls `step`.
- It must leave exactly the state and credit count repeated `step` calls would
  have. It must not skip findings, polls, final outcomes or other side effects.
- The batch context has no `report` or `cancelled`, only `equalsBatch`.
  `equalsBatch` consumes matching ASCII runs. Returning 0 leaves Unicode,
  folding, mismatches, malformed patterns and the final answer to `step`.
- Never rely on `batch` being called: small budgets, short poll intervals and
  unsuitable input skip it. A validator with only `State`/`step` works
  unchanged. `equals` and `one_of` use this same optional contract.
- When the validator is bound through [`WithReader`](#validating-logical-values),
  both `step` and `batch` get a logical value, which has no `bytes`. A `batch`
  that reads `value.bytes` directly works on plain text only. To keep one in a
  portable validator, return 0 without changing anything for logical values,
  for example with
  `if (!@hasField(@TypeOf(value), "bytes")) return 0;`. The portable `step`
  then handles that input.

**`check` alongside `step`:** an optional `check` is used on the plain one-shot
path (no metering, no cancellation). It must agree with `step` on the answer and
the findings. A validator with only `step` also works without metering.

A validator with only `check` (such as a `Predicate`):

- works without metering;
- is rejected when metering is on and the check is enabled: a compile error on
  fixed profiles, an invalid `validatePolicy` result or `init` error on runtime
  ones. It is never silently treated as bounded;
- can run with cancellation on (without metering), but must call
  `context.cancelled()` itself during long work.

## Execution costs

- With metering and cancellation both off, a one-shot check has no session
  state, credit counters or cancellation polling.
- With either on, checks run in bounded steps, even through
  `parseAndValidate` or `Session.run`.
- Small budgets and short cancellation intervals use the one-step-at-a-time
  driver. Larger ones may combine plain ASCII steps without changing their
  credits. A failed attempt to combine falls back to a short run of single
  steps rather than retrying at every character. Combining never crosses the
  remaining budget or the next cancellation poll. A budget of 1 and an interval
  of 1 always use single steps.
- Larger budgets can cut resume and per-step overhead. They never reduce the
  credits charged.
- Session storage has a fixed size: it covers only the compiled rules and
  folding support. It doesn't grow with the text or the number of allowed
  values. Runtime profiles keep state for every rule they might enable. Check
  `@sizeOf(Text.Session)` for a given profile.

Where time goes:

- The encoding is checked before the rules run; comparisons may read the text
  again.
- With metering and cancellation both off, UTF-8 text is checked with the
  standard library's validator, which skips ASCII runs quickly. Malformed text
  then gets a second pass to locate each bad run.
- Exact comparison of UTF-8 or ASCII text can compare bytes directly once the
  encoding is known to be good. ASCII-insensitive comparison can fold bytes.
  UTF-16 and UTF-32 readers fold only the decoded ASCII characters.
- With metering, plain ASCII runs can be compared in groups, keeping the same
  credits and poll points. Tails, mismatches and non-ASCII text use single
  steps. Cancellable comparisons still poll as configured.
- Membership is a linear search through the allowed values that stops at the
  first match. It is not a hash lookup.
- The shared comparison helper checks the UTF-8 of `expected` for built-in and
  custom validators alike. On fixed profiles without metering or cancellation,
  an exact byte match skips that second scan (the text's own encoding check already covers
  it); a mismatch still checks the whole pattern, including a malformed tail.
  Metered or cancellable checks keep their original pattern-check credits and
  polls. Don't assume patterns chosen at run time are free.
- Custom settings, validator code and your sink add their own costs.
- No heap allocation happens in the processor or the comparison helpers. Only a
  bag you chose, or your own callbacks, may allocate. There is no string tree,
  no per-value processor object, no normalization buffer and no source copy.

### Measuring

| Command | What it measures |
| --- | --- |
| `zig build test-string` | Tests the standalone module |
| `zig build test-logical` | Tests the logical readers: positions, native encodings, bounded progress, agreement with the host decoders |
| `zig build bench-string -Doptimize=fast` | Exact, ASCII-insensitive, Unicode-folding and custom checks |
| `zig build bench-string-sessions -Doptimize=fast` | Metering and cancellation: time, credits, hook calls and state size, fixed and runtime policies, several budgets and intervals |
| `zig build bench-logical-strings -Doptimize=fast` | Reader-bound checks on plain, DOT and markup text: short, long, Unicode and concatenation-heavy input, `run` versus budgets of 1 and 64, session size and credits. `-- --csv` writes the repository's benchmark CSV format. |
| `zig build bench-string-integration -Doptimize=fast` | Host defaults, passthrough and processed attribute routes, including allocator-request totals |
| `zig build bench-string-passthrough -Doptimize=fast` | Real DOT quote scanning against a simulated hand-off to string checks. It is not host integration. |
| `zig build check-wasm` | Builds stripped Wasm programs for exact, ASCII-insensitive, Unicode-folding and non-comparing profiles, runs their exports with Node, and checks the folding table is left out where unused. `zig build check` includes it. |
| `zig build perf-string -- --baseline HEAD` | A before/after report for your working tree against a Git revision. See [report options](PERFORMANCE.md#one-command-string-comparison). |

`perf-string` suites are `native`, `sessions` (the default pair), `logical`,
`integration` and `host-defaults`. For example:

```sh
zig build perf-string -- --baseline HEAD --suites logical,native,sessions
zig build perf-string -- --baseline HEAD --suites host-defaults,integration \
  --modes fast,safe,small --runs 5
```

`host-defaults` builds only the ordinary host operations on both sides, so
string routes can't affect the binary-size or default-path numbers.
`integration` also builds the routed profiles; rows that don't exist in the
baseline are marked new rather than compared with a made-up baseline. Keeping
the two suites apart stops code-layout changes in a mixed benchmark from looking
like a cost that applications without string checks pay.

This module doesn't touch the DOT or markup parsing hot paths. Measurements are
in [performance](PERFORMANCE.md#standalone-strings).

## Logical readers

> **Unreleased.** Not in 0.5.0.

A *logical value* is what host text means after the host's own spelling rules
are applied. In DOT, `"Sea" + "ttle"` means `Seattle`. In markup, `A&amp;B`
means `A&B`. A *logical reader* walks such text one character at a time,
without building a decoded copy, and tells you where each character came from
in the original source.

| Reader | Reads | Decodes |
| --- | --- | --- |
| `strings.LogicalReader(encoding)` | Plain contents | Nothing: no escapes, references or BOM removal |
| `dot.identifier.LogicalReader(encoding)` | One DOT identifier expression, as written (with its quotes) | Removes quotes, `\"` escapes, line continuations (backslash + newline) and the `+` glue between parts, including comments between them. Other escapes, such as `\n` or `\\`, are kept as written. |
| `markup.LogicalReader(encoding)` | The contents of one markup text or attribute value, **without** its quotes | Numeric references, and named references from the selected catalog |

`encoding` is the actual encoding, including byte order (`.utf8`,
`.utf16le`, ...), fixed at compile time. Give each reader a `Fragment` with the
text's **original** origin. `init` checks the coordinates only: it doesn't scan
the text or look for a BOM. The shared types (`SourceLocation`, `Scalar`,
`Failure`, `Step`, `BorrowedContents`) are available as `strings.logical`,
`dot.logical` and `markup.logical`, so one loop works for all three readers:

```zig
var reader = try markup.LogicalReader(.utf8).init(
    .{ .bytes = "A&amp;B", .origin = 100 },
    .{},
);
while (true) {
    switch (reader.step()) {
        .pending => {},
        .scalar => |item| {
            // Characters: A, &, B. The '&' covers { .start = 101, .len = 5 }.
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

`consume` and `handleReadFailure` stand for your own code; they are not
library functions.

| Reader member | Meaning |
| --- | --- |
| `init(fragment)` (markup: `init(fragment, options)`) | Creates a reader. Returns `error.InvalidFragment` for out-of-range coordinates. |
| `step()` | Returns `pending` (no character yet, call again), `scalar` (a character and its location), `end`, or `failure` |
| `location()` | The whole original input as a location |
| `contiguous()` | The unchanged contents as one borrowed view, when the reader knows that's safe; otherwise `null` |
| `position()` | Where the reader is in the input, in bytes |
| `fragment()`, `restarted()` | The input, and a fresh reader over the same input |
| `encoding_kind` | The reader's encoding, at compile time |
| `asciiRun()`, `skipAscii(count)` | Optional fast path; see [sessions and costs](#sessions-and-costs) |

Readers don't emit diagnostics or decide severity. A failure is one of:

| Failure reason | Meaning |
| --- | --- |
| `invalid_encoding` | Malformed bytes for the encoding |
| `invalid_syntax` | Text the reader can't read as its host form (for example an unterminated DOT quote, or a malformed markup reference with `.malformed_reference = .reject`) |
| `unresolved_reference` | A well-formed markup reference whose name isn't in the catalog |
| `unsupported_form` | A DOT HTML-like part (`<...>`), which has no plain-text value |

- Failures are final: later `step()` calls return the same failure and do no
  work. Characters already returned are only a prefix, not a resolved value.
  A successful `end` is final in the same way.
- The DOT reader is not a full identifier checker. Give it one value the DOT
  parser selected, or check the syntax yourself. Malformed input can never make
  any reader read out of bounds.

### Mapping and borrowed contents

- Each character carries its original byte `span`, covering the whole escape or
  reference spelling (`&amp;` for `&`), and a `segment_start`: the opening
  quote or content start of the part it came from. UTF-16 and UTF-32 positions
  are bytes too.
- `Fragment.child` combines origins once. Never add an enclosing origin again.
- `SourceLocation.mapping` is `exact` for one character's own spelling, or
  `enclosing` for a whole-value highlight.
- `reader.location()` covers the whole original input, including DOT quotes and
  concatenation glue. An empty markup or plain value gives a zero-length
  location at its origin. An empty DOT string gives an enclosing location over
  its quotes.
- **Neither kind of location is permission to edit the source.** Helpers that
  select ranges across parts, validate insertion points or build host-aware
  fixes don't exist yet.
- `contiguous()` returns the unchanged contents with their encoding and
  location, or `null`. It doesn't check validity or scan for a fast path. Plain
  contents and unquoted DOT values return a view. Quoted or empty DOT values
  and non-empty markup return `null`; empty markup returns a view. `null` means
  "use `step()`", not "allocate a decoded string".
- No tree, position table or decoded buffer is created. The source must stay
  unchanged and outlive readers and any locations or views you keep.
- Reader fields are internal. Create readers with `init` and don't change their
  fields.

### Host rules and bounded work

A markup fragment on its own doesn't know its surrounding profile, so markup
rules are explicit options:

| `markup.LogicalOptions` field | Default | Meaning |
| --- | --- | --- |
| `references` | `.xml_predefined` | Named references to decode. `.xml_predefined` is the five XML names (`amp`, `lt`, `gt`, `quot`, `apos`); `.graphviz` is Graphviz's HTML 4 catalog plus `apos`. |
| `malformed_reference` | `.reject` | `.reject` makes a malformed reference a failure. `.warn` and `.accept` read it literally, as the host scanner accepts it; the **host** owns any warning. |
| `normalize_attribute_whitespace` | `false` | `true` turns literal tabs, CR and LF into spaces, as Graphviz attribute checks do. Numeric references keep their decoded characters. |

- Reference names are case-sensitive. An unknown name is a failure, never
  invented text or a replacement character.
- Numeric references use the markup parser's character rules. Very large
  numbers saturate rather than wrap.
- There is no recursive expansion, no DTD and no external entity lookup.
- For CDATA contents, use the plain reader, not the markup one.
- DOT HTML-like parts return `unsupported_form`, also inside a mixed
  concatenation. No reader strips tags, flattens markup or expands DOT layout
  escapes.
- Comments between quoted DOT parts are skipped one code unit at a time. Their
  bytes are not checked for encoding: that is the host's job.

Every step does a small, fixed amount of work: it reads at most one code unit,
decodes at most four bytes, or looks up a fixed catalog. Multi-unit characters,
long references and concatenation glue return `pending` along the way. No step
scans a long name or comment. State has a fixed size and can be copied or moved
between steps.

An accepted malformed reference is replayed as literal text, so `position()`
can move backwards. It is a cursor, **not** a progress mark or a work counter.
Replay is still linear.

You can pause between steps or check for cancellation before the next one.
These are reader steps, not parser or string-session credits, and readers don't
schedule work or poll anything themselves. [Binding a reader](#validating-logical-values)
to a string profile adds session scheduling.

## Validating logical values

> **Unreleased.** Not in 0.5.0.

Bind a reader type to a string profile at compile time with `WithReader`. You
get the same checks, settings, diagnostics and execution options, applied to the
decoded value:

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

- `Text.WithReader(dot.identifier.LogicalReader(.utf8))` reads a quoted DOT
  concatenation as one value. `Text.WithReader(strings.LogicalReader(.utf8))`
  uses the same interface on plain contents.
- The reader's encoding must be one the string profile compiles (otherwise a
  compile error). An `options.encoding` that differs from the reader's gives
  `UnsupportedEncoding`. No encoding is guessed or converted.
- Each call starts from the beginning of the input, even if you already
  stepped the reader. The reader's source and options are kept.
- You can write your own reader. It must provide `encoding_kind`, `fragment()`,
  `restarted()`, `step()`, `location()`, `contiguous()` and `position()`, keep
  each step bounded, never change the source, and be safe to copy or move
  between steps. Binding it is not a sandbox.

### One validator interface

Plain and decoded values use the same `State(Context)` / `step` and optional
`check` interface. The built-in equality and membership checks use it too,
including ASCII-only and full Unicode folding. Patterns stay UTF-8 whatever the
source encoding.

A portable validator uses only:

- `value.location()` and `value.contiguous()`;
- `context.readStep(&cursor, value)`, where the cursor (`Context.Cursor`)
  starts as `.{}` and lives in your state. It returns `pending`, `scalar` (a
  character plus its original location), `end` or `stopped`. `pending` is not
  the end;
- the comparison helpers, with their usual rules.

Rules:

- In a session, call `readStep` at most once per `step`. A second call gives
  `invalid_validator`.
- Other work in `step` must still be bounded.
- Never compare `contiguous().bytes` without taking its encoding into account.

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

Bind it with `.custom = NoAmpersands` and `.policy.validation.custom = .err`.
It runs unchanged on plain text and on any bound reader. Validators that use
`value.bytes` or `cursor()` still work on plain text. Decoded values
deliberately don't expose the raw spelling as if it were the decoded text.
Don't keep the value, the context or pointers to them across calls; keep
cursors and locations in your state instead.

### Findings and unavailable input

- Use `Finding.at` and `related_at` for locations. They are already source
  locations and are **not moved again**. A finding at the `&` above covers all
  of `&amp;`. For UTF-16 and UTF-32 text, spans cover every byte of each code
  unit. Without `at`, the finding highlights the whole original value,
  including DOT quotes and glue.
- `detail`, severity, fail-fast, sink stops and the generic failure finding
  work as for plain text.
- Plain and bound contexts both check that a location lies inside the value,
  that its `segment_start` is consistent, and (for UTF-16 and UTF-32) that it is
  aligned to code units, in every build mode. Combining `at` with `span`, or
  `related_at` with `related`, is invalid.
- Bound contexts reject `span`, `related` and `fix`, even a fix that
  `diagnostics.fixes` would filter out. Local byte ranges can't describe edits to
  host text. A location is a highlight, not proof that a range can be edited,
  and these checks don't prove a hand-made location came from the reader.
  Host-aware replacements don't exist yet.

Before any check runs, the binding reads the **whole logical value**. If the
reader fails (an unresolved reference, bad encoding, malformed host spelling,
or an unsupported part):

- `completion` is `.input_unavailable`, and `result.input_failure` holds the
  reason and its original location;
- requested checks become `unavailable`, `checks.encoding` stays `incomplete`,
  and `valid()` is false;
- no string finding is made up for it: the host reports syntax and reference
  problems.

So an early mismatch or an empty `one_of` list can't hide a bad tail. A
completed read covers what the reader reads; it doesn't cover skipped DOT
comment bytes or the full host grammar. The plain `Result` has no
`input_failure` field and pays nothing for it.

### Sessions and costs

The bound type has `Session.init`, `advance`, `run`, `result`, `cancel`,
`reset` and `deinit`, with the same rules as plain sessions. Turn on
`.execution.metering` to advance by budgets; runtime overrides need
`runtime_policy = true` as usual. `reset` checks the replacement before
discarding the current progress.

Credits:

- One credit of the reading pass does at most one reader step.
- A comparison step does at most one reader step plus a bounded amount of
  pattern, character or folding work, or one pattern-checking step.
- Long references and comments between DOT parts return `pending` along the
  way; they are not hidden in one credit.
- Totals don't depend on how you split the budget. Cancellation is checked on
  entry and at the configured interval. Finished operations stay finished.
- `source_frontier` is the furthest byte the reading pass has reached. It is not
  a count of decoded characters or finished checks, and replayed references
  never move it backwards.

Speed:

- Plain-text checking is compiled separately and doesn't pay for any of this.
- Bound checks can do 16 unchanged ASCII steps at once, using the same optional
  validator `batch` contract. Each byte still costs its own credit. A group
  never crosses the remaining budget or the next cancellation poll, and never
  skips a final step, finding, reference, escape or half-finished fold.
- Values shorter than 64 bytes, small budgets, short cancellation intervals,
  UTF-16 and UTF-32, and readers without the fast path use single steps.
- The reader fast path is optional: `asciiRun()` returns an unchanged ASCII run
  without moving the reader, and `skipAscii(count)` moves over a run it has
  checked, or returns `false` and changes nothing. A reader may only expose
  bytes that each equal one plain step. The built-in readers expose 16 bytes at
  a time. Custom readers need neither method, and validators without `batch`
  keep using `step`.

Memory:

- No decoded copy and no source-sized position table. A session holds the
  reader, the reading-pass cursor and the cursors of active validators. Check
  `@sizeOf(Label.Session)` for a given profile.
- Each check, and each `one_of` candidate, may read and decode the value again.
- Diagnostic bags cost whatever memory you gave them.
- Bound execution still does reader and position-tracking work that plain
  contiguous text doesn't.

## Attribute processing in DOT and markup

> **Unreleased.** Not in 0.5.0.

DOT and markup profiles can send attribute values to a string profile while
they parse. You bind the string profile at compile time and choose, per
attribute name, what happens to its value. A *route* is that choice:

| Route | What happens |
| --- | --- |
| `.passthrough` | The value is left alone (the default) |
| `.process` | The value is decoded and checked by the bound string profile with its own baseline settings |
| `.{ .process = child_policy }` | The same, with `child_policy` applied on top of the string profile's baseline |
| `.none` | String values are reported as unsupported, using the host's `diagnostics.unsupported` severity |

Binding a string profile does **not** turn checking on: every route defaults to
`.passthrough`. Only `.process` runs the string profile.

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

- `markup.Profile` takes the same `.processors.string`, `.policy.string` and
  `.policy.attributes` fields. Its input is still a `Fragment`, and its result's
  `deinit()` takes no allocator.
- Markup hands over decoded attribute contents: `A&amp;B` is checked as `A&B`,
  and findings point back at the original `&amp;`.
- If you bind such a markup profile into DOT, its string checks run too:
  during parsing, in reused workspaces, and for delayed markup processing. Their
  results count toward that label's validity.
- All stages can share one bag and one console renderer.

### Selection and precedence

| Situation | Route used |
| --- | --- |
| The attribute has an entry with `.string` | That route, including an explicit `.none` or `.passthrough` |
| The entry has no `.string`, or no entry matches | The host's `.policy.string` |
| `.policy.string` is omitted | `.passthrough`, even with a string profile bound |
| `.process` | The string profile's baseline, unchanged |
| `.{ .process = child_policy }` | The baseline with `child_policy` applied |
| The string profile has `runtime_policy = true` | The operation's `.string.policy` is applied on top of each processing route's settings |

- `child_policy` is applied like any [settings patch](#changing-settings-per-call):
  `equals` and `one_of` settings replace the whole setting; other fields you
  leave out are inherited.
- String profiles, route names and route choices are fixed at compile time.
  There is no run-time registry.
- Per-call options: host settings go under `.dot` (DOT) or `.markup` (markup);
  the string profile's runtime patch and cancellation hook go under `.string`.
  A route's `child_policy` can turn on cancellation for the string profile.
- The host picks the source encoding; the string profile can't reinterpret it.
  If the string profile lists `source_encodings`, the host compiles those
  encodings as well; if it doesn't, it follows the host.

Matching attribute names:

- DOT compares the logical attribute name exactly, so a quoted or concatenated
  key such as `"la"+"bel"` matches `label`. It visits every written attribute
  pair and every standalone assignment (`label=x;`). It doesn't apply graph
  defaults or merge declarations.
- Markup compares names exactly in structural mode and ignoring ASCII case in
  Graphviz mode. Route names that differ only in ASCII case are a compile error
  when Graphviz mode is possible.
- Route names are UTF-8, whatever the source encoding.

What reaches the string profile:

- Only attribute **values**. Identifiers elsewhere, markup text, comments and
  attribute names are never routed.
- A DOT value that is entirely HTML-like (`<...>`) belongs to the markup path
  and never reaches a string validator.
- A DOT concatenation that mixes quoted and HTML-like parts can't be turned into
  plain text. With `.process` it counts as `unavailable`; with `.none` it is
  reported as unsupported; with `.passthrough` it is left alone.
- Routes support only `.string`. Any other field in a route entry is a compile
  error. Markup handling of whole labels is unchanged.

`.none` needs no string profile. The host's `diagnostics.unsupported` decides
between an error, a warning or silence (default `.err`); silence creates no
diagnostic. A rejected value, or one that fails its checks, is never retried
with another route.

### Results, scheduling and costs

With at least one route that isn't `.passthrough`, the profile returns a
combined result:

| Member | Meaning |
| --- | --- |
| `result.host` | The ordinary host result |
| `result.string` | A small fixed-size summary of the string work (next table) |
| `documentValid()` | Host accepted the document **and** all requested string work completed without errors |
| `scopeComplete()` | The host document is complete. It says nothing about strings. |
| `subtreeComplete()` | The host's completeness check (for DOT with markup, including the labels), plus string coverage complete with nothing unavailable |
| `deinit(allocator)` (DOT), `deinit()` (markup) | Frees the host result |
| `stopped()`, `has_errors` | Markup only: whether the host or strings stopped early, and whether any errors were found |

| `result.string` field | Meaning |
| --- | --- |
| `complete` | The attribute walk finished over a complete host tree. It doesn't mean every check passed. |
| `processed`, `passed` | Values checked, and values that passed |
| `passthrough` | Values left alone |
| `unsupported` | Values rejected by a `.none` route |
| `unavailable` | Values that couldn't be read as plain text |
| `errors`, `warnings` | Totals across all values |
| `delivery`, `diagnostic_stop` | Whether delivery to the sink failed, and why the sink stopped |
| `stop` | Why the walk stopped early: `parent_error`, `cancelled`, `invalid_validator` or `diagnostic_stop` |
| `first_unavailable` | The reason and location of the first unavailable value |
| `valid()`, `stopped()` | Summary checks used by the result methods above |

No per-attribute list and no decoded strings are kept.

Order of work:

- The host parses (and validates) first. Then strings visit the kept attributes
  in source order. Diagnostics follow this stage order; they are not sorted by
  position across stages.
- String checks run only if the host finished without stopping: its outcome is
  success, or recovered syntax errors under `on_error = .collect`, with no sink
  stop and no failed delivery. Under `.collect`, ordinary host validation errors
  don't prevent them. Under `.fail_fast`, any host error does. Other host stops
  (cancellation, limits, unsupported input) also prevent them.
- A string profile's own fail-fast ends the check of that value. A collecting
  host goes on to the other values.
- Sink stops, cancellation and `invalid_validator` stop the whole walk.
- With [partial results](EDITORS.md#keep-the-finished-part-of-a-dot-file), the
  kept attributes are checked but `complete` stays false. With no tree at all,
  string checks don't run; that is not reported as checked input.

Underlying host API and delayed checks:

- `Parser.Outer` is the underlying host profile (sessions, fixed storage and so
  on). For DOT with markup bound, it is the markup composition.
- `processStrings` checks a document you already have, later. It allocates
  nothing and returns a separate summary; it doesn't change an earlier result.
  Pass a document this profile's parser produced (hand-edited documents are not
  supported). Values and their source stay borrowed.

```zig
// DOT document, same routed profile and diagnostic type:
const checked = try Parser.processStrings(&document, bag.sink(), .{});
// Markup also takes the fragment's original origin:
const checked_markup = try MarkupParser.processStrings(
    &markup_document, original_origin, markup_bag.sink(), .{},
);
```

Markup reference and whitespace rules come from the host markup profile:

- Attribute values use the five XML references when the markup profile is in
  Graphviz mode with its `validation.references` rule off. Otherwise they use
  that rule's `catalog` setting (`.xml_predefined` unless you changed it).
  Graphviz's HTML 4 names apply to text, not attribute values, by default.
- In Graphviz mode, literal tabs and newlines in values become spaces; numeric
  references keep their decoded character.
- The markup `syntax.malformed_reference` setting decides whether a malformed
  reference is read literally.
- An unresolved reference can't pass a string check just because the host
  doesn't report it. The value counts as `unavailable`, without a duplicate
  finding.

Costs:

- Profiles with no active route return the original host profile type. No
  attribute walk, summary, diagnostic union or string state is added.
- Active routes add name matching, reader-bound checking, a fixed-size summary
  and session state, and a diagnostic union sized for the largest payload.
- The library adds no heap allocation for routing or built-in checks. Host
  pools, diagnostic bags and your callbacks keep their own costs.
- Markup keeps its fixed-storage and reusable-workspace entry points
  (`prepare`, `parseAndValidateIn`, `initWorkspace`). The routed DOT operation
  is `parseAndValidate` with an allocator; for sessions, use `Parser.Outer`,
  which doesn't run string checks.

`zig build bench-string-integration -Doptimize=fast` measures default,
passthrough and processing costs, including allocator-request totals. See
[measuring](#measuring) for before/after reports and
[performance](PERFORMANCE.md#attribute-string-processing) for measurements.

## Not available yet

- One shared work budget across DOT, markup and string checks.
- Host-aware fix offers for decoded values, and helpers that select ranges
  across concatenated parts.
- Checking attributes without a kept tree, for example after syntax was
  discarded, or from [DOT events](EVENTS.md).
- Routed DOT sessions or fixed-storage routed DOT parsing.
- Per-attribute markup routing (`.markup` in a route entry).
- A regex engine, and Unicode normalization.

## Examples

- [string_processor.zig](../examples/string_processor.zig): a standalone
  allowed-values check, a custom predicate, a resumable custom validator in a
  metered session, markup and DOT logical readers bound with `WithReader`, and
  attribute routing through DOT and an embedded markup label with one shared
  bag

Run it with `zig build examples`. The program is also installed in
`zig-out/bin/`.
