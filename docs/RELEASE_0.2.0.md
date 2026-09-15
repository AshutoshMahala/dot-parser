# dot-parser 0.2.0

An experimental, breaking minor release of the standalone DOT syntax parser. The package remains engine-independent, uses explicit caller memory, and is dual-licensed under MIT OR Apache-2.0. Tested toolchain: Zig 0.16.0.

## Highlights

- Comments, numeral identifiers, quoted identifiers and quoted concatenation. Preserve identifier spelling; decode explicitly into caller storage or a writer.
- Basic attributes and assignments, preserving pair order and duplicate keys.
- Edge chains and raw port suffixes, with allocation-free pairwise edge views.
- Named, anonymous and nested subgraphs, including subgraphs as edge endpoints and mixed node/subgraph chains. Preserve scope occurrences without expanding node-to-node edge products.
- Fixed-storage `BoundedSession` and configurable `FixedSession`, with optional work metering and cooperative cancellation. Documents are published only after a successful parse; fixed pools never grow or fall back to an allocator.
- Structured diagnostics, additional failure-path and partition tests, runnable examples, and consumed RISC-V32/Wasm32 freestanding compile checks.

## Upgrading from 0.1.0

There are no compatibility shims. Recompile consumers and update exhaustive switches against the current exported types; diagnostic enums are experimental too. The following are the main integration changes.

### Statement and endpoint traversal

Statement switches must now account for `.assignment`, `.attribute_statement`, `.edge_chain` and `.subgraph`, in addition to `.node` and `.edge`.

Node statements expose `reference` rather than `identifier`. Resolve a `NodeReference` through `document.nodeReference(reference)` to obtain the identifier range and optional raw port suffix. `document.text(range)` returns source spelling; decoding the identifier value is a separate operation.

Statement edge views and `document.edgeIterator()` expose `EdgeView` values. Both endpoints are tagged `Endpoint` values: switch on `.node` or `.subgraph`; do not assume every endpoint is a node. A subgraph endpoint carries a `ScopeId` that can be resolved with `document.scope(id)`.

Use `document.edgeIterator()` for all written edge operators, including chain links, in operator source order. Raw `document.edges` is not the complete edge view. Use `document.edgeLinks(chain)` and `document.edgeLinkCount(chain)` for chain-specific traversal. See the runnable [endpoint example](../examples/subgraph_endpoints.zig) and [scope guide](SUBGRAPHS.md).

### Fixed storage and allocator-backed scratch

Fixed parsing and session initialization take a `ParseMemory` bundle containing document pools and optional nesting scratch, rather than document storage alone:

```zig
var pools: dot.FixedDocumentStorage(.{
    .statements = 8,
    .nodes = 8,
    .subgraphs = 4,
    .scoped_edges = 4,
}) = .{};
var scratch: dot.FixedParseScratch(.{ .nesting = 4 }) = .{};
const result = dot.parseBorrowedIn(
    "digraph { a -> { b; c } }",
    .{ .document = pools.storage(), .scratch = scratch.storage() },
    dot.diagnostic.discard,
    .{},
);
```

Reserve pools for the syntax your application accepts: attributes, assignments, attribute statements, ported references, node-only chains/links, subgraphs and generalized edges/links have explicit capacities. Exhaustion is a resource failure, not silent truncation. The example above is sized for its input, not for arbitrary DOT. Root depth is zero; sibling subgraphs reuse scratch frames.

Allocator-backed callers may supply a separate `scratch_allocator` and document capacity hints. Hints reserve storage, not hard limits. Scratch uses one frame per active nesting level, retaining suspended edge state when needed. See [ownership and memory](OWNERSHIP.md) for lifetimes and [baselines](BASELINES.md) for measured costs. Arena backing can exceed retained payload because growth copies and slack may remain allocated until arena reset.

### Outcomes and execution

Session callers must account for `.cancelled` in `ParseOutcome`. One-shot parsing does not produce cancellation. Cancellation is cooperative; work credits cover parser work, not wall-clock deadlines or arbitrary callback execution. Validation and identifier decoding are separate from session parse budgets.

Supported constructs no longer produce their former unsupported-feature codes. Update diagnostic/feature switches against the current registry rather than retaining removed variants. See [outcomes](OUTCOMES.md) and [bounded execution](EXECUTION.md).

## Deliberate boundaries

- This is a syntax document, not a layout engine or normalized semantic graph. Defaults, strict duplicate-edge semantics, repeated subgraph-name merging, port attachment resolution and edge-product expansion are not applied.
- HTML identifiers and non-ASCII bare identifiers remain deferred. Quoted byte handling is documented; parsing does not imply UTF-8 validation.
- Comments are skipped, not retained. Attribute-group boundaries are flattened; the document is not a lossless formatting tree.
- Parsing is fail-fast and does not publish partial documents. Validation can report multiple operator/kind violations.
- Syntax feature removal at compile time is not promised by this release. Execution metering and cancellation do have compile-time profiles.

The [supported syntax table](SUPPORTED_SYNTAX.md) is the authoritative language
boundary, including deliberate differences from Graphviz.

## Local release checks

Run from the repository root with Zig 0.16.0:

```sh
zig fmt --check build.zig build.zig.zon src tests examples bench
zig build test
zig build test -Doptimize=ReleaseSafe
zig build examples -Doptimize=ReleaseSafe
zig build check-freestanding
zig build -Doptimize=ReleaseSmall
git diff --check
```

These checks do not create a tag or publish a release. After reviewing and committing the release changes, publish the intended commit as `v0.2.0` and attach release notes. The package fingerprint is unchanged from 0.1.0.
