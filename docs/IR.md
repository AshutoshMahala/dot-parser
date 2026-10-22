# DOT graph topology

**Unreleased, first increment.** `dot.ir` is an optional layer above the parser.
It resolves logical node identities and scope membership, retains symbolic
connections, and answers topology questions. It does **not** yet resolve
effective attributes or defaults. Ordinary parsing does not invoke or allocate
storage for it.

## Start here

```zig
var result = try dot.ir.parse(allocator, source, .{ .diagnostics = bag.sink() });
defer result.deinit();
const ir = result.ir() orelse return error.GraphUnavailable;

var nodes = ir.nodeIterator();
while (nodes.next()) |node|
    std.debug.print("node {f}\n", .{try ir.nodeName(node)});
```

`dot.ir.parse` uses the default UTF-8 DOT profile. It parses once, validates,
lowers accepted input and releases the temporary Document pools. It does not
copy source bytes or expand edges. The result owns the IR; keep the source
alive and unchanged. The pointer returned by `result.ir()` is borrowed from
that result, which must stay alive and unmoved while the pointer is used.

Diagnostics go to the supplied sink. Render the bag on success too: warnings
do not prevent a graph. A null `ir()` means DOT checking rejected **or stopped**;
`result.checking` preserves the parse outcome/completion, validation result,
counts and diagnostic delivery/stop reason. It must not be interpreted as
proof of invalid input. Lowering failures return typed errors and release
temporary storage. No failed or partial IR is published.

See runnable [build_graph.zig](../examples/build_graph.zig). It parses
`digraph { a -> { b c }; "a" -> d; subgraph s { x } }`, reports diagnostics,
and prints:

```text
node a
node b
node c
node d
node x
edge a -> b
edge a -> c
edge a -> d
```

Here `a` and `"a"` are one node, edge endpoints introduce nodes implicitly,
and the isolated `x` remains present. Individual edges are materialized only
by the example's explicit request; lowering keeps connections symbolic.

## Already have a Document or a custom profile?

Use the existing lowering entry point instead of parsing again:

```zig
const Dot = dot.Profile(.{}); // Your accepting profile.
const IR = dot.ir.Lowering(.{});

var parsed = Dot.parseAndValidate(allocator, source, bag.sink(), .{});
defer parsed.deinit(allocator);
if (!parsed.documentValid()) return error.InvalidInput;
const doc = &parsed.document.?;
var ir = try IR.lowerComplete(allocator, doc, .{
    .interpretation = Dot.interpretation(doc, .{}),
});
defer ir.deinit();
```

Use the interpretation from the **same profile and runtime options** that
accepted the Document. Runtime-policy profiles require `try` when obtaining
their interpretation. The lowering call requires this explicitly so conforming
operators or reading `graph` as generic cannot silently change meaning.

Input must be an accepted, complete parser-produced Document, with its normal
invariants intact. Lowering checks completeness but does not repeat syntax or
policy validation. It rejects partial Documents with `IncompleteDocument`.
Optional child-processor validation is the caller's acceptance decision.

## What you can read

| API/data | Meaning |
| --- | --- |
| `nodes` / `findNode(logical_name)` | Unique logical node identities, including implicit endpoints |
| `nodeIterator()` | Iterate unique node IDs in first-introduction order, without index conversions or allocation |
| `nodeName(node)` | Borrowed logical-name formatter for `{f}`; checks the node handle, decodes only when printed |
| `nodeSpelling(node)` | Borrowed first source spelling, in its original encoding, including quotes/concatenation |
| `writeNodeName(node, writer)` | Stream the logical name without allocating a decoded copy or rechecking DOT syntax |
| `scopes` | Semantic subgraphs; named scopes merge within the same semantic parent, anonymous scopes remain distinct |
| `occurrences` | Each written scope body, its source range and immutable membership version |
| `mentions` | Written node references with source spans and owning scope occurrence |
| `connections` | One record per written chain link, with symbolic endpoints, ports, written/effective operators and raw attributes |
| `contains(membership, node)` | Membership in that specific version, without edge expansion |
| `scopeMembership(scope)` | Final version of a semantic scope |
| `hasEdge(from, to)` | Whether any effective connection covers the pair; undirected edges work both ways |
| `attributes` / `declarations` | Raw attributes and explicit node/default/graph-assignment contributions; **not** final values |

IDs and membership handles belong to one IR. Don't manufacture them or mix
handles from different graphs. Public membership/query calls bounds-check
handles, but equal numeric IDs from different IRs are not distinguishable.
Keep returned arrays immutable. `text(range)` expects a range from this IR,
as `Document.text` expects a range from its Document.

Names use DOT logical identity: `a`, `"a"`, and `"a" + ""` identify one node.
Queries take logical UTF-8 bytes, not quoted DOT expressions. There is no case
folding, Unicode normalization, numerical normalization, or HTML entity
expansion. If the accepting UTF-8 profile preserved invalid bytes, identity
preserves those bytes too. Hash collisions are checked with logical equality.

`writeNodeName` uses those same logical bytes: native UTF-16/32 names are
written as UTF-8, while byte-profile names preserve their bytes. It does not
expand HTML entities or escape names for any output format. `nodeSpelling`
borrows the source instead; keep that source alive and unchanged. Writer
errors propagate, and a stopped write may have emitted a prefix. There is no
hidden decoded-name cache or allocation (the supplied writer may allocate).

`nodeName` formats the same logical bytes using ordinary writer semantics:
writer failures propagate, with no IR cancellation polling or work budget.
Use `writeNodeNameWith` for explicitly limited/cancellable writes. A formatter
borrows source bytes; do not manufacture or mutate its internal fields. The
iterator and formatter add no retained storage to the IR.

Node IDs follow first introduction, including a left endpoint encountered
before its subgraph endpoint. Connections follow semantic execution order:
nested endpoint-body connections precede their containing statement's links.
These are distinct orderings. Source spans retain original byte offsets.

## Symbolic first; expand explicitly

`{ a b } -> { x y }` is **one connection**, not four stored edges. Membership
uses shared node-mention ranges and immutable scope-prefix snapshots, not
copied ancestor sets. Singleton endpoints carry a node ID directly.

All endpoint versions are captured after the whole edge statement executes.
Thus both ends of `subgraph s { a } -> subgraph s { b }` contain `a` and `b`.
An earlier statement's snapshot does not change when `s` reopens later.

To get individual edges:

```zig
var graph = try ir.materialize(.{});
defer graph.deinit();
for (graph.edges) |edge| {
    // edge.from / edge.to are IDs in ir.nodes.
}
```

Materialization visits connections forward, expands their endpoint products,
and uses a collision-checked pair map for strict graphs. It does not run a
whole-graph query for every emitted edge. Non-strict graphs retain parallel
occurrences; strict directed pairs are ordered, strict undirected pairs are
unordered. Ports do not change edge identity. Each edge records its first
connection; **all** written contributions remain in `ir.connections`.
Effective attribute merging is not implemented by materialization yet.

Strict generic graphs, and strict concrete graphs preserving an operator
inconsistent with their effective kind, return `UnsupportedSemantics`.
Non-strict generic graphs retain both edge kinds. No mixed-kind strict identity
rule is invented here.

## Ownership, limits and costs

The IR owns its tables through the supplied allocator and borrows only the
immutable source bytes. Document pools may be released after lowering. Keep
source bytes alive until the IR is released. Materialized edges own their
array but refer to IR-local node/connection IDs; retain the IR to interpret
those IDs and read names or provenance. No source text is copied.

Lowering and materialization allocate explicitly. Name access, `findNode`, `contains`,
`scopeMembership`, and `hasEdge` allocate nothing. Pair queries currently scan
symbolic connections; membership uses per-node postings and shared intervals.
This is not a prebuilt adjacency index. Materialization needs memory
proportional to its output, plus deduplication scratch for strict graphs.

Finite defaults are defined by `dot.ir.Limits`:

| Limit | Default |
| --- | ---: |
| Unique nodes | 1,000,000 |
| Written scopes, including root | 100,000 |
| Node mentions | 4,000,000 |
| Symbolic connections | 2,000,000 |
| Raw attributes, including assignments | 2,000,000 |
| Materialized edges | 1,000,000 |
| Candidate pair visits during materialization | 4,000,000 |
| Accounted work per operation | 100,000,000 |
| Peak live requested allocation bytes per operation | 256 MiB |

Set a compile-time baseline with `Lowering(.{ .limits = ... })`, or pass
`.limits` at lowering. `findNodeWith`, `writeNodeNameWith`, `hasEdgeWith`, and `materialize` accept
operation-specific `.limits` and `.cancellation`. There is no unlimited-by-zero
special case. Counts/indices are `u32`, pair/work totals are `u64`; byte limits
use the allocator's `usize` domain. Candidate products use checked arithmetic.

For `dot.ir.parse`, `.dot` supplies ordinary default-profile `CheckOptions`
(parse/validation resources); `.lowering` supplies the IR operation options.
IR limits/cancellation apply to lowering only, not to DOT parsing/validation
or a combined peak across both stages. The temporary Document overlaps IR
construction before it is released. There is no shared budget or metered
session in this convenience call. Use explicit profiles/lowering when those
stages need different policies or source encodings.

Limits or cancellation return typed errors, **never** `false`, absence, or a
truncated graph presented as complete. Failure frees operation-owned storage.
Work limits count table probes, comparisons and traversal work; they are not
wall-clock deadlines. Cancellation is cooperative. Existing trusted-name
primitives are charged by their byte lengths and polled around each call;
allocation, copying during growth, and an individual name operation are not
interruptible. This is a one-shot API, not a metered/resumable session. It does
not change the parser's existing metering or cancellation guarantees.

`retainedBytes()` reports retained allocation payload including spare capacity.
`peak_bytes` includes temporary scratch and overlapping growth buffers, but
excludes source/Document storage, allocator metadata and process RSS. A
materialization peak excludes the already-retained IR. Arena allocators may
retain freed blocks or reserve extra chunk capacity; use a bounded backing
allocator when that physical capacity must have a hard cap.

UTF-8 is the default. To lower native Documents, enable the corresponding
readers with `Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } })`.
The Document supplies the actual encoding and original byte ranges. Unused
native readers remain compiled out.
ASCII-admitted Documents are also readable by the UTF-8 configuration. Native
logical-name decoding can return `InvalidIdentifier` if the accepting parser
left encoding validation off and a name contains malformed code units.

## Verification

```sh
zig build test-ir
zig build test-ir -Doptimize=ReleaseSafe
zig build bench-ir -Doptimize=ReleaseFast
```

The benchmark reports lowering separately from parsing and materialization,
including a 50,000 × 50,000 endpoint product that stays symbolic. It reports
retained/requested peak bytes and arena capacity separately. This is the first
production topology baseline, not a comparison with a previously shipped IR.
Recorded numbers are in [Performance](PERFORMANCE.md#document-to-ir-topology-unreleased-2026-10-21).

Effective attributes/defaults, event-based lowering, partial IR results,
fixed-storage IR construction and resumable IR operations remain later work.
