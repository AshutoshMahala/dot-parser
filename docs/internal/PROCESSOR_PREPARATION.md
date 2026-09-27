# Processor preparation — internal implementation notes

The preparation APIs below are implemented. Standalone markup now has its own
[structural slice](MARKUP.md); it does not use a composed `PolicySet` or scheduler.
DOT HTML recognition, inner-stage scheduling, and a `.processors` option on DOT's
`Profile` are not implemented yet. The intended
execution/result contract is in [the processor contract](PROCESSOR_CONTRACT.md).
These are implementation/design notes, not a public processor integration guide.

## Schema-owned policy binding

`dot.processor.PolicyBinding(Schema, config)` provides compile-time baseline
verification, `validatePolicy`, `Options`, `State`, and `prepare(options)`.
`config` has `.policy` and default-off `.runtime_policy` fields, like DOT profiles.

A schema supplies:

| Member | Contract |
| --- | --- |
| `Policy` | Typed partial input with an empty-struct default patch |
| `Effective`, `defaults` | Resolved representation and default values |
| `resolve(baseline, patch)` | Pure, allocation-free resolution into Effective |
| `check(effective, patch)` | Pure check returning `.valid` or `.invalid: Issue` |
| `Issue`, `Error` | Issue is an enum with `asError()` returning the schema's error set |

The original partial patch reaches `check`, preserving explicit versus inherited
fields. Public and effective layouts need not match. Fixed bindings have `State =
void`, empty options and compile-time-only policy verification. Runtime-enabled
bindings resolve/check once per `prepare`; they cannot replace an implementation.
DOT itself uses this binding machinery; it is not reserved for inner processors.

## Preparing named configured profiles

A configured profile exposes `Policies`, its policy binding. DOT profiles already
do so. `PolicySet` takes named profile **types at compile time** and generates typed
Options/State fields for precisely those profiles:

```zig
const Reader = dot.Profile(.{ .runtime_policy = true });
const Set = dot.processor.PolicySet(.{ .outer = Reader });
const prepared = try Set.prepare(.{
    .outer = .{ .policy = .{ .scanner = .block } },
});
// prepared.outer is Reader.Policies.State; fixed-only sets have zero-size State.
```

Consumer profiles can expose `Policies = dot.processor.PolicyBinding(MySchema,
config)` and join the same set. There is no runtime registry or type discovery.
Setup resolves all requested policy patches before any stage should be initialized.
Preparation neither invokes processors nor scans, allocates or emits diagnostics.

This is a preparation primitive, not an execution wrapper: existing DOT parsing
methods perform their own policy preparation internally. Calling `PolicySet.prepare`
and then an ordinary DOT method does not automatically reuse that prepared state.
Resolved-state stage integration and compatibility checks belong to the later
scheduler slice. Do not claim a composed budget from policy preflight alone.

## Raw fragment coordinates and diagnostics

`processor.Fragment.init(bytes, origin)` validates the u32 source domain;
`fragment.rebase(local_span)` checks local bounds and maps to original coordinates.
Apply it exactly once to every primary, related and fix span in a custom payload.
The caller establishes provenance; this does not prove that arbitrary bytes are
part of a particular file. Decoding or concatenating input needs a separate source
map and is not performed here.

The [shared reporting types](../REPORTING.md) support processor-owned diagnostic payloads.
`reporting.Severity` and `reporting.Applicability` share the existing vocabulary;
codes, catalogs, details and fix replacements remain processor-owned.
The [consumer tests](../../tests/processors.zig) exercise independent schemas, source
coordinates, multiple findings and stopping without requiring a markup grammar.
