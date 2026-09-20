# Parsing and graph policies

`dot.Profile(...)` binds a typed policy at compile time. Runtime overrides are
off by default. Policies configure limits, recovery, scanner selection,
execution, graph validation and effective interpretation. Syntax leniency is
the next slice; this work does not broaden the grammar or rewrite source.

The ordinary `dot.validate` and `dot.parseAndValidate` functions keep their strict
defaults. [Runnable example](../examples/policies.zig).

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
const checked = session.validate(diagnostics); // optional until document exists
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

Syntax remains source truth. `Document.kind` has type `DeclaredGraphKind`
(`.undigraph` or `.digraph`); a policy never changes it. `EdgeView.operator` and
source ranges likewise remain as parsed. The public `GraphKind` now denotes the
three-valued effective kind; code that previously used it to type stored header
facts should use `DeclaredGraphKind` instead.

```zig
// With the runtime-enabled Checks and patch from above:
const options: Checks.Options = .{ .policy = patch };
const checked = try Checks.validate(document, bag.sink(), options);
const view = try Checks.interpretation(document, options);
const kind = document.effectiveKind(view);
var edges = document.edgeIterator();
while (edges.next()) |edge| {
    const operator = edge.effectiveOperator(document, view);
    // Consume kind/operator without replacing the original syntax.
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
`warnings`, regardless of sink retention or delivery failure. Warnings use
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
1,040 bytes, `BoundedSession` is 1,080 bytes, and a runtime-enabled session is
1,256 bytes. No fields were added to `Document` or edge storage. These are layout
observations, not a throughput or
binary-size baseline. Performance comparisons still belong on the standard
benchmark machine; this work does not replace its baseline. Run
`zig build bench-policy -Doptimize=ReleaseFast` there for equivalent fixed,
runtime-baseline and runtime-override paths. `zig build check-benches` compiles
the probes without running or changing baselines.

Still outside this slice: syntax leniency (empty statements, bare/long operators
and factual counters), HTML, bounded validation, allocator-backed resumable
sessions, semantic resolution, custom rules, and graph conversion/export.
