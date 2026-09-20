# Graph policies

`dot.Profile(...)` binds a typed policy at compile time. Runtime overrides are
off by default. This first slice configures graph validation and effective
interpretation; it does not change the DOT grammar or rewrite source.

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
const patch: dot.Policy = .{ .validation = .{
    .graph = .{ .treated_as = .auto },
} };
var result = try Checks.parseAndValidate(allocator, source, bag.sink(), .{
    .policy = patch,
    .parse = .{ .max_statements = 1000 },
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

On runtime-enabled profiles, `validate`, `interpretation`, and `parseAndValidate`
return `PolicyError!T` and automatically check before inspecting the document or
parsing/allocating. Optional preflight returns the same issue; `issue.asError()`
maps it to the operation error. The current errors are
`GraphOperatorMismatchNotApplicable` and `GraphOperatorReadingNotApplicable`.
Fixed operations return `T` directly, without a configuration-error union.

These are configuration failures, **not** `ParseOutcome.invalid_syntax` and not
WDP diagnostics. Successful configuration verification says nothing about DOT
validity or whether the caller supplied sufficient storage.

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

`Checks.parseBorrowed` and `Checks.parseBorrowedIn` are raw syntax aliases with
the existing parser options. They do not accept or apply policy overrides.
Validate/interpret their results explicitly; preflight before parsing if desired.
The same staged operations work after a `FixedSession`/`BoundedSession` completes.
This slice does not attach profiles to live sessions or expose provisional auto
promotion events. A new completed document needs a new interpretation.

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

On the current native 64-bit Zig 0.16.0 build, these views occupy 0/1/2 bytes,
respectively, and `Diagnostic` remains 80 bytes. No fields were added to
`Document` or edge storage. These are layout observations, not a throughput or
binary-size baseline. Performance comparisons still belong on the standard
benchmark machine; this work does not replace its baseline.

Still outside this slice: syntax leniency (including bare/long operators),
migrating limits/recovery/execution/scanner controls, live-session policy
integration, HTML, semantic resolution, custom rules, and graph conversion/export.
