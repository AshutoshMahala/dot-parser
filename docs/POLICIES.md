# Parsing and graph policies

`dot.Profile(...)` binds a typed policy at compile time. Runtime overrides are
off by default. Policies configure limits, recovery, scanner selection,
execution, syntax acceptance, graph validation and effective interpretation.
Policies never rewrite source bytes.

The ordinary `dot.validate` and `dot.parseAndValidate` functions keep their strict
defaults. [Runnable example](../examples/policies.zig).

## Standard and lenient presets

`dot.presets.standard` names the library defaults; `dot.Profile(.{})` is
equivalent. `standard` is not called `strict`, which is also a DOT keyword with
unrelated duplicate-edge semantics. `dot.presets.lenient` changes only the three
syntax rules below to `.warn`. Both are ordinary, complete `dot.Policy` values,
not flags, alternate parsers, or validation bypasses. Runtime support remains
off unless explicitly enabled in `Profile`.

```zig
const Lenient = dot.Profile(.{ .policy = dot.presets.lenient });
var parsed = Lenient.parseBorrowed(allocator, "digraph { ; a --> b - c }", bag.sink(), .{});
defer parsed.deinit(allocator);
// success; accepted_deviations == 3, warnings == 3

const Runtime = dot.Profile(.{ .runtime_policy = true });
var dynamic = try Runtime.parseBorrowed(allocator, source, bag.sink(), .{
    .policy = .{ .syntax = dot.presets.lenient.syntax },
});
defer dynamic.deinit(allocator);
```

Passing a **complete preset** as a runtime patch replaces every baseline field,
including limits, scanner and execution settings. Copy only `.syntax`, as above,
to preserve the other baseline choices. To customize a compile-time preset, use
a comptime block returning a modified copy of its `Policy` value. Individual
runtime fields remain independently overridable, for example
`.{ .syntax = .{ .long_operator = .reject } }` against a lenient baseline.

| Policy field | `standard` | `lenient` | Meaning when accepted |
| --- | --- | --- | --- |
| `syntax.empty_statement` | `.reject` | `.warn` | Omit a standalone `;` at a statement boundary; an ordinary optional statement terminator is not a deviation |
| `syntax.long_operator` | `.reject` | `.warn` | Exact `---` becomes `--`; exact `-->` becomes `->`, independent of graph kind |
| `syntax.bare_dash.acceptance` | `.reject` | `.warn` | Accept `-` only in an edge-operator position |
| `syntax.bare_dash.interpretation` | `.from_keyword` | `.from_keyword` | Written `graph` supplies `--`; written `digraph` supplies `->` |

`Acceptance` has `.reject`, `.warn`, and `.accept`. `.warn` accepts and emits a
warning; `.accept` accepts silently but still counts the deviation. Every leaf
supports the same compile-time/runtime values and nested inheritance. Interpretation
currently has only `.from_keyword`; it stays dormant when acceptance is rejected.

Bare-dash interpretation uses the **written header**, even for a `graph` treated
as `.digraph`, `.generic`, or `.auto`. Syntax normalization precedes graph
validation and any effective conformance view: accepted `-->` can promote auto to
generic; a bare dash in `graph` cannot. A syntax warning and a mismatch warning
are separate facts. Lenient does not enable recovery, soften mismatch errors,
guess missing delimiters/headers, accept spaced operators, or allow keywords as
names. Negative numeric IDs and dashes in strings/comments are unaffected.

**Information loss:** retained structure drops empty statements and stores
normalized operators. Original bytes are unchanged, and operator ranges still
cover `-`, `---`, or `-->`. There is no per-edge duplicate spelling or hidden
history allocation. Counters are summaries, not an audit trail. Changing syntax
policy later requires reparsing; validating the normalized document cannot
reconstruct dropped syntax or reject its former spelling.

`ParseResult`, `FixedParseResult`, `MeasureResult` and `SessionProgress` expose
`accepted_deviations: u32` and `warnings: u32`. Counts describe actual acceptances
and produced syntax warnings, even before later failure/cancellation and even
with a discard, full, filtered or failing sink. Lexer numeral warnings count as
warnings, not accepted deviations. `CheckResult.accepted_deviations` preserves
the parse count; its `warnings` totals syntax and validation warnings. Staged
validation's count remains in `ValidationResult.outcome.completed.warnings`.
The parse-only u32 counters are bounded by the u32 source domain. Validation
counts and `CheckResult.warnings` use u64: independent checks can report the same
byte, so their aggregate is not bounded by source length. No counter retains history.

Empty statements consume neither statement pool capacity nor `max_statements`;
they still consume lexical/grammar work and count as deviations. Metered sessions
charge their normal scan/grammar steps; each acceptance warning is a diagnostic
callout on the accepting grammar step. Diagnostic callbacks remain outside the
credit guarantee. There is no new warning-volume limit; use a bounded bag/sink
and execution budgets where needed. Accepted syntax can commit; recovery after a
rejected construct still aborts and never publishes a partial document.

## Configurable checks

Every field below accepts `RuleSeverity.err`, `.warning`, or `.off`, at compile
time or runtime. Error severity rejects at the indicated stage; warning reports
without invalidating; off skips the check, rather than merely hiding its output.
Filtering a diagnostic sink never changes acceptance or counts.

| Field under `validation` | Default | Stage / scope |
| --- | --- | --- |
| `ambiguous_numeral` | `.warning` | Parsing: a numeral touches a following letter or dot, such as `1e3` or `1.2.3` |
| `invalid_utf8` | `.off` | Validation: every source byte, including comments, quoted expressions and trivia |
| `repeated_attribute` | `.off` | Validation: repeated logical keys in one statement's combined attribute lists |
| `restrictions.graph_kinds.undigraph` | `.off` | Validation: report an effective undigraph |
| `restrictions.graph_kinds.digraph` | `.off` | Validation: report an effective digraph |
| `restrictions.graph_kinds.generic` | `.off` | Validation: report an effective generic graph |
| `restrictions.ports` | `.off` | Validation: one finding per written qualified node reference |
| `restrictions.subgraphs` | `.off` | Validation: one finding per named or anonymous subgraph occurrence, including endpoints |

Numeral ambiguity is an existing **lexical** diagnostic, now configurable through
the policy model. `.err` produces `invalid_syntax`, follows the selected recovery
policy and publishes no document. `.warning` preserves the existing token split;
`.off` disables ambiguity detection without changing tokenization. No exponent or
floating-point interpretation is introduced. Parse, measure and sessions agree.
`validate()` does not re-scan lexical checks or repeat their warnings; changing
this leaf for an already parsed source requires reparsing. The low-level scanner
continues to expose its default warning independently of profiles.

UTF-8 checking never transcodes, normalizes or replaces bytes. It accepts only
well-formed UTF-8 (no overlong sequences, surrogates or values above U+10FFFF).
Recovery advances **one byte** after an invalid sequence start; each byte not
consumed by a valid sequence produces one finding. A valid following sequence or
ASCII byte is not swallowed. For example, a truncated multi-byte prefix can
produce multiple findings. NUL in comments is valid UTF-8; grammar-forbidden NUL
elsewhere still cannot be enabled by policy.

Repeated keys are legal DOT; this is an optional consumer lint. Keys compare by
decoded DOT identifier **bytes**, so `x` equals `"x"` and `"a"+"b"` equals `ab`.
Case, Unicode forms and numeral spellings are not normalized (`1` differs from
`1.0`). Adjacent lists on one statement share an owner; chains own their list
once. Separate statements, defaults, scopes and assignments are not merged.
Every occurrence after the first carries that first key's source span. Neither
attributes nor values are removed, reordered, selected or repaired.

Restrictions check syntax occurrences and the **effective** graph kind, without
building a resolved graph. A directed-only consumer can reject `.undigraph` and
`.generic` while leaving `.digraph = .off`. Auto resolves to undigraph for an
empty graph, and generic after a directed syntax operator. Restrictions never
change that interpretation or make operator mismatch errors disappear.

### Explicit validation scratch

Only repeated-key checking needs workspace: one `dot.AttributeKeyScratch` entry
per `document.attributes` element (16 bytes per entry on the supported targets).
The caller owns it and may reuse it immediately after validation; it must not
alias source, document pools, or diagnostic storage. No allocator is consulted.
The other checks require no caller scratch.

```zig
const Lint = dot.Profile(.{ .policy = .{ .validation = .{
    .invalid_utf8 = .err,
    .repeated_attribute = .warning,
    .restrictions = .{
        .graph_kinds = .{ .undigraph = .err, .generic = .err },
        .ports = .warning,
        .subgraphs = .err,
    },
} } });

// After a successful parse (or size this with measure().capacities.attributes):
const keys = try allocator.alloc(dot.AttributeKeyScratch, document.attributes.len);
defer allocator.free(keys);
const checked = Lint.validate(document, bag.sink(), .{
    .scratch = .{ .attribute_keys = keys },
});
// Fixed arrays work too. parseAndValidate accepts the same scratch through
// .{ .validation = .{ .attribute_keys = keys } }; sessions use
// session.validate(bag.sink(), .{ .attribute_keys = keys }).
```

Insufficient scratch returns `.insufficient_scratch` with required/provided entry
counts and an `E.Resource.Capacity.026` diagnostic. Preflight occurs before any
check or scratch write. `documentValid()` is false, but the parsed document stays
available. Supply enough scratch and rerun, or deliberately select `.off`.
Disabled duplicate checking neither touches nor requires scratch.

Validation merges findings in source order; ties use kind, operator, encoding,
repeated key, port, then subgraph order. `parseAndValidate` emits parse diagnostics
first and validation diagnostics second; it does not buffer both stages to sort
them together. UTF-8 costs one O(source bytes) pass. Repeated-key checking hashes
decoded bytes once, heap-sorts each owner's entries by fingerprint/logical key,
then restores their source order in scratch: O(A log A) comparisons, each exact
key comparison potentially reading key bytes. Hash collisions never establish
equality and never degrade into a quadratic hash-bucket scan. No string copies,
graph expansion, per-record metadata or hidden allocations are added. Optional
passes are unbudgeted and uncancellable; bounded validation remains deferred.

## Fixed baseline

```zig
const Checks = dot.Profile(.{ .policy = .{ .validation = .{
    .graph = .{
        .treated_as = .undigraph,
        .operator_mismatch = .warning,
        .operator_reading = .conform_to_kind,
    },
    .digraph = .{
        .operator_mismatch = .err,
        .operator_reading = .as_written,
    },
} } });

var result = Checks.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);
```

The outer `graph` and `digraph` keys match the **written DOT keyword**, not the
effective kind. A written `graph` treated as `.digraph` still uses the `graph`
branch. `digraph` has no `treated_as` field and always means `.digraph`.

The library defaults are `.undigraph` treatment for `graph`, `.err` mismatch
severity, and `.as_written` reading in both branches. Every input leaf is optional:
`null` or omission inherits, and an explicit value replaces the baseline leaf.
Configuring one branch never resets the other.

| `graph.treated_as` | Effective `GraphKind` | Operators |
| --- | --- | --- |
| `.undigraph` | `.undigraph` | `->` is a mismatch |
| `.digraph` | `.digraph` | `--` is a mismatch |
| `.generic` | Always `.generic`, even when empty | Both preserved; no mismatch |
| `.auto` | `.undigraph` until the first directed operator, then `.generic` | Both preserved; promotion is not a mismatch |

`GraphTreatment` includes `.auto`; `GraphKind` does not. Auto never becomes a
digraph, even for directed-only input. It considers every syntax edge, including
chains, ports, nested subgraphs and endpoint scopes, not text inside strings or
comments. Each document starts fresh.

For concrete kinds, the two controls are independent:

| Control | Meaning |
| --- | --- |
| `operator_mismatch = .err` | Each mismatch invalidates the document and emits an error |
| `.warning` | Each mismatch emits a warning without invalidating the document |
| `.off` | No mismatch diagnostic or mismatch count; interpretation is unchanged |
| `operator_reading = .as_written` | Preserve each operator in the effective view |
| `.conform_to_kind` | Supply the operator required by the effective concrete kind |

Conformance does not cancel error-severity validation. Conforming `a -- b` to a
digraph means `a -> b`, left to right, not two opposing edges. Changing severity
alone never converts an operator.

## Runtime overrides

Enable support when defining the profile, not while parsing:

```zig
const Checks = dot.Profile(.{
    .runtime_policy = true,
    .policy = .{ .validation = .{
        .graph = .{ .operator_mismatch = .warning },
    } },
});
const patch: dot.Policy = .{
    .limits = .{ .max_statements = 1000 },
    .validation = .{ .graph = .{ .treated_as = .auto } },
};
var result = try Checks.parseAndValidate(allocator, source, bag.sink(), .{
    .policy = patch,
});
defer result.deinit(allocator);
```

Both binding times accept the same `Policy` fields and values. Baseline omissions
inherit library defaults; runtime omissions inherit the compiled baseline.
Overrides apply only to that call. They do not mutate the profile, the document,
or a later call's baseline. Fixed profiles do not have a `.policy` option.

Under `.generic` and `.auto`, explicitly supplying either graph operator control
is a configuration error, even `.as_written` or `.err`. Leave those fields out.
Inherited concrete values remain dormant, not effective controls. Switching to
a concrete treatment uses the inherited values unless explicitly replaced. The
independent `digraph` controls remain applicable under every graph treatment.

## Verification and failures

`Checks.validatePolicy(patch)` returns `PolicyValidation`: `.valid` or
`.invalid: PolicyIssue`. It resolves inheritance and checks both branches without
reading DOT, allocating, or emitting diagnostics. If both graph controls are
inapplicable, the mismatch issue is reported first.

Invalid compiled baselines are compile errors. On fixed profiles, explicit
`validatePolicy` calls require a comptime argument; there is no runtime verifier.
The top-level `dot.validatePolicy` checks against the library-default fixed profile.

On runtime-enabled profiles, all profile-level parse, measure, validation and
interpretation entry points, plus `Session.init`/`reset`, return `PolicyError!T` and automatically
check before inspecting source/document, allocating, polling hooks or touching
session storage. Optional preflight returns the same issue; `issue.asError()`
maps it to the operation error. The current errors are
`GraphOperatorMismatchNotApplicable` and `GraphOperatorReadingNotApplicable`.
Fixed operations return `T` directly, without a configuration-error union.

These are configuration failures, **not** `ParseOutcome.invalid_syntax` and not
WDP diagnostics. Successful configuration verification says nothing about DOT
validity or whether the caller supplied sufficient storage.

## Limits, recovery, scanner and execution

These fields have identical values and semantics at both binding times:

| Policy field | Default | Meaning |
| --- | --- | --- |
| `limits.max_statements` | `maxInt(usize)` | Maximum source statements, not an edge or work budget |
| `limits.max_attributes` | `maxInt(usize)` | Maximum key/value pairs, including assignments |
| `limits.max_nesting` | `maxInt(usize)` | Maximum active subgraph depth; root depth is zero |
| `recovery` | `.fail_fast` | `.statements` continues diagnostics after a body syntax failure; never publishes a partial document |
| `scanner` | `.scalar` | `.block` selects the 64-byte scanner; credit counts differ, language results do not |
| `execution.metering` | `false` | Enable work-credit accounting and session `advance(budget)` |
| `execution.cancellation` | `false` | Enable polling of an explicitly supplied cancellation hook |

Zero limits are valid. Policy never disables mandatory capacity/overflow checks
or supplies backing memory. Limits remain distinct from per-call work credits.
Every metering/cancellation combination is supported independently.

Source, allocators, pools, scratch and cancellation contexts are **resources**,
not policy. `ParseOptions` retains `scratch_allocator` and `document_capacities`;
`CheckOptions.parse` now contains only those `ParseResources`. Capacity hints
reserve memory rather than limit acceptance. The cancellation resource is a
nullable hook on parse/session options when compiled in. Runtime policies that
disable cancellation never poll a supplied hook; an enabled policy with no hook
is valid. Explicit session `cancel()` always works.

`parseBorrowed`, `parseBorrowedIn`, `measure`, and `measureIn` apply the same
resolved parsing policy. Count-only measurement returns capacities only on
success; cancellation and recovery failures publish neither counts nor a
document. Measurement ignores document preallocation hints. One-shot calls
always run to completion (or failure/cancellation), even when metering is on;
they do not promise bounded allocation, diagnostics, or wall-clock time.

## Policy-bound sessions

```zig
const Parser = dot.Profile(.{
    .runtime_policy = true,
    .policy = .{
        .execution = .{ .metering = true },
        .limits = .{ .max_nesting = 8 },
    },
});
var session = try Parser.Session.init(source, memory, diagnostics, .{
    .policy = .{ .scanner = .block },
});
defer session.deinit();
while ((try session.advance(64)).outcome == null) {}
const parsed = session.result().?;
const checked = session.validate(diagnostics, .{}); // optional until document exists
const view = session.interpretation();          // optional; separate unbudgeted work
_ = parsed;
_ = checked;
_ = view;
```

All sessions use caller-owned fixed pools and scratch. Initialization resolves
once, selects one scanner/execution driver, and latches the policy across yields.
Changing the caller's options cannot alter the active session. `run`, `cancel`
and `result` are not configuration-error unions; runtime `advance` returns
`error.MeteringDisabled` without work when the selected policy is unmetered.
Calling `advance` on a fixed unmetered profile is a compile error. Use `run()`.

Reset resolves against the **compiled baseline**, not the preceding operation.
Invalid configuration leaves the old session and document views intact; a
successful reset cancels old work and invalidates prior pool views. Reset can
change every supported policy value, including scanner and execution mode.
Session `validate` and `interpretation` use the latched graph policy after a
successful parse. They remain separate, unbudgeted operations and are never
invoked implicitly by `advance`.

`dot.BoundedSession` is a fixed policy preset with metering enabled. The ordinary
top-level parse/measure functions use the default fixed profile (unmetered,
uncancellable, scalar). There is no separate execution-settings system.

## Staged validation and interpretation

`Document.kind` has type `DeclaredGraphKind`
(`.undigraph` or `.digraph`); a policy never changes it. `EdgeView.operator` and
source ranges likewise remain as parsed: normalization may supply the syntax
operator, but its range always preserves the original spelling. The public `GraphKind` now denotes the
three-valued effective kind; code that previously used it to type stored header
facts should use `DeclaredGraphKind` instead.

```zig
// With the runtime-enabled Checks and patch from above:
const options: Checks.Options = .{ .policy = patch };
const checked = try Checks.validate(document, bag.sink(), .{ .policy = patch });
const view = try Checks.interpretation(document, options);
const kind = document.effectiveKind(view);
var edges = document.edgeIterator();
while (edges.next()) |edge| {
    const operator = edge.effectiveOperator(document, view);
    // Consume kind/operator without replacing the parsed syntax or source.
    _ = operator;
}
_ = kind;
_ = checked;
```

Create an interpretation once per document and selected policy, then reuse it
for that document's edges. **Do not use it for a different document or after a
session reset/storage reuse.** Auto scans until the first directed syntax edge,
or the end; other treatments do not scan. Kind and operator queries are O(1).
No per-edge rescanning, allocation, document cache or retained per-edge policy is
introduced. Separate validation and interpretation calls should receive the
same patch when the consumer wants one consistent policy.

Parse-only methods still produce syntax, not validated semantics: validate and
interpret explicitly, or use `parseAndValidate`. Session helpers use the latched
policy; separate profile methods can intentionally re-interpret a document using
another policy. Live auto-promotion events remain deferred. A new completed
document needs a new interpretation.

## Diagnostics and cost

Validation counts error occurrences in `violations` and warning occurrences in
`warnings`, regardless of sink retention or delivery failure. Operator warnings use
`W.Validation.Operator.002`; errors retain `E.Validation.Operator.002`.
The payload records expected/found operators, the original header span and the
selected reading. Renderers distinguish a policy-selected kind from the written
header. Suggested operator fixes are machine-applicable under conformance and
otherwise only possible repairs; no fix is automatically applied.

Fixed concrete interpretation views have zero instance storage. Fixed auto views
retain only one input-derived kind. Runtime views retain a kind and a reading,
not an entire policy. Runtime support retains selectable behavior; it does not
claim the same code size or throughput as a fixed profile.

Fixed parsers keep limits/recovery in compiled code, not instance settings;
fail-fast profiles also exclude recovery skip-depth storage. Runtime sessions
hold one tagged driver union (the largest variant plus tag/alignment), resolved
parse-stage values and a small validation selection—not eight full sessions or
a full policy per node. Dispatch happens at operation/call boundaries, never
per source byte. Allocator-backed and fixed-storage adapters share one grammar.

On the current native 64-bit Zig 0.16.0 build, these views occupy 0/1/2 bytes,
respectively, and `Diagnostic` remains 80 bytes. The default fixed session is
1,064 bytes, `BoundedSession` is 1,104 bytes, and a runtime-enabled session is
1,288 bytes. A fixed lenient session is also 1,064 bytes. Compared with the
syntax-policy implementation before optional validation checks, fixed sessions
and parse-only results are unchanged; runtime sessions add 8 bytes of settings
and alignment. `Policy` grows from 80 to 96 bytes, and `CheckResult` from 296 to
304 bytes for the wider aggregate and validation outcome. Standard fixed
grammar machines exclude the acceptance counter and normalization path; their
public result fields remain present and report zero deviations. No fields were
added to `Document` or edge storage. Repeated-key scratch is separate and costs
16 bytes per attribute only when enabled. These are layout observations, not a throughput or
binary-size baseline. Performance comparisons still belong on the standard
benchmark machine; this work does not replace its baseline. Run
`zig build bench-policy -Doptimize=ReleaseFast` there for equivalent fixed,
runtime-baseline and runtime-override paths. `zig build check-benches` compiles
the probes without running or changing baselines.

Still outside this slice: keyword-as-name acceptance, deviation history, HTML,
bounded validation, allocator-backed resumable
sessions, semantic resolution, custom rules, and graph conversion/export.
