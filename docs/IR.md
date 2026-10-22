# DOT semantic graph

**Unreleased.** `dot.ir` is an optional layer above the parser. It resolves
logical node identities, scope membership and effective attributes/defaults,
while retaining symbolic connections and source provenance. Ordinary parsing
does not invoke or allocate storage for it.

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
and the isolated `x` remains present. The example streams individual edges
without retaining an expanded edge array; lowering keeps connections symbolic.

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
| `edgeIterator(options)` | Stream individual edges in semantic order, without retaining the expanded output array |
| `materialize(options)` | Retain those edges in an owning array |
| `nodeAttribute(node, key)` | Final node value with origin, or absence |
| `scopeAttribute(scope, key)` | Final graph/subgraph value with origin; `.root` is the graph |
| `edgeAttribute(edge, key)` | Final value for a streamed/materialized edge, including strict updates |
| `attributeValue(resolved)` | Borrowed `{f}` formatter for a resolved logical value |
| `nodeView(id)` / `scopeView(id)` / `edgeView(edge)` | Borrowed component access with `.attribute(key)` and `.attributes(options)` |
| `attributes` / `declarations` | Retained raw attributes and node/default/graph-assignment contributions, separate from effective values |

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

## Effective attributes

```zig
// digraph { node[color=red]; a; node[color=blue]; b; a[shape=box] }
const node = try ir.nodeView((try ir.findNode("a")).?);
if (try node.attribute("color")) |color| {
    std.debug.print("color={f}\n", .{color.value()}); // red
    // color.resolved.kind == .inherited; provenance points to color=red.
}

var attributes = try node.attributes(.{});
defer attributes.deinit();
while (try attributes.next()) |attribute|
    std.debug.print("{f}={f}\n", .{ attribute.key(), attribute.value() });
```

See [graph_attributes.zig](../examples/graph_attributes.zig) for a runnable
example with diagnostics, effective node values and streamed edge values.
Query keys are case-sensitive logical UTF-8 names, just like `findNode`.
Individual attribute lookups allocate nothing and do not expand edge sets.

### Component views and all attributes

`nodeView`, `scopeView` and `edgeView` create small borrowed values, without
allocating or adding owner pointers to stored nodes/edges. Use `scopeView(.root)`
for the graph and another scope ID for a subgraph. Use an `Edge` from this IR's
stream or materialized array with `edgeView`; a node pair alone cannot identify
a non-strict parallel occurrence. The ID-oriented APIs above remain useful when
storing compact handles rather than views. Node/edge iterators still yield those
compact handles/records; convert once when component methods are useful.

All three views have `.attribute(key)`, `.attributeWith(key, options)` and
`.attributes(options)`. A node also has `.id` and `.name()`; an edge has its
original `.edge` record and `.from()`/`.to()` node views. A lookup/iteration
entry exposes `.key()` and `.value()` as borrowed logical formatters, plus
`.resolved` with the full `ResolvedAttribute` provenance described below.

The iterator returns **one final effective value per key** in that object kind's
first-introduction order (semantic traversal order, not alphabetical). It
includes inherited defaults and implicit empties, even when a key was first
written on another object of the same kind. It never returns duplicate written
assignments. Use raw `ir.attributes`/`declarations` for source history.

Each `next()` returns one entry, `null` on exhaustion, or a typed error. Limits
and cancellation accumulate across the iterator, including preparation; an error
is terminal and repeated on later calls. Always `deinit()`, even on early exit
or error. Entries borrow the IR/source, **not** iterator scratch, and remain
usable after iterator cleanup. Keep the IR alive, unmoved and immutable; don't
manufacture or mutate views or copy a live attribute iterator. `edgeView` checks
record bounds; membership and strict first-contribution identity are checked
when attributes are accessed.

Node, scope and non-strict-edge attribute iteration allocate nothing. Strict
edges scan contributions once before the first entry; when matching explicit
assignments exist, a sorted winner table uses **12 bytes per distinct edge key
in the IR**. Repeated updates overwrite those slots, not append history, and
keys belonging only to nodes/graphs need no slots. A strict edge with only
inherited defaults needs no scratch. `.peakBytes()` reports this iterator's peak
requested scratch, bounded by `.limits.max_bytes`. This merges attributes for
one edge, not a whole-graph bulk materialization, and never expands endpoint sets.

Lookups distinguish the cases below. On a view entry, these fields live under
`.resolved`; the ID-oriented methods return `ResolvedAttribute` directly.

| Result | Meaning |
| --- | --- |
| `null` | The key was never introduced for that object kind (graph, node or edge) |
| `.kind = .explicit` | An explicit assignment supplies the final value |
| `.kind = .inherited` | A creation-time default or parent graph snapshot supplies it |
| `.kind = .empty` | The key exists, but DOT supplies an implicit empty value here |

An explicit `color=""` is still `.explicit`, with `.value = .written`.
A language-defined empty is `.value = .empty`, not a fabricated source range.
No Graphviz renderer defaults (such as an assumed default shape) are added.

`ResolvedAttribute.attribute` indexes `ir.attributes`; `.origin` identifies
the declaration or connection and `.scope` identifies that origin's scope.
For an implicit empty, these identify **the first assignment introducing the
key**, not a source assignment of an empty string. A chain shares its written
attribute list, but an explicit edge result identifies the applicable link.
The original key/value ranges remain available, including quotes and HTML-like
delimiters. All ranges use original source-byte offsets.

`attributeValue` follows logical DOT identifier decoding: it joins quoted
parts when printed and writes native UTF-16/32 as UTF-8. It does not interpret
renderer escapes, expand HTML entities, or normalize numbers. It borrows the
source, allocates no decoded copy, and follows ordinary writer failure behavior,
without IR work limits or cancellation polling. Only use results from the
same live IR; do not manufacture or mutate formatter fields.

### Default and update rules

- Node/edge defaults apply when the object is first created. Changing a default
  does not replace a value on an existing object. Introducing a new key gives
  existing objects without that key an implicit empty value.
- Later explicit assignments update only their supplied keys; omitted keys
  retain their earlier values. Duplicate keys within a list use the last value.
- A subgraph captures parent **graph attributes** when first created. Reopening
  it does not replace that snapshot. Node/edge defaults instead inherit current
  parent defaults unless locally overridden; newly created objects use those
  current defaults. Existing objects still keep their creation-time values.
- A strict edge uses the first covering connection's defaults, then merges
  explicit contributions in semantic order, including overlapping endpoint sets
  and reversed undirected statements. There is no specificity priority.
- Non-strict parallel edges remain independent. `edgeAttribute` takes an `Edge`
  from iteration/materialization, not just a node pair, so it cannot silently
  choose one parallel occurrence's attributes.

These rules have focused comparisons against Graphviz 16.0.0's cgraph behavior.
Endpoint ports are still retained separately. Synthesizing `headport`/`tailport`
and their precedence with explicit attributes is not implemented: querying
either key returns `UnsupportedSemantics` if a contribution to that edge uses
an endpoint port. Other attribute queries remain available. All-attribute edge
iteration returns `UnsupportedSemantics` **before yielding any entries** for
such an edge, even if port keys weren't explicitly written: it cannot honestly
enumerate all effective attributes while synthesized ports remain unsupported.

## Symbolic first; expand explicitly

`{ a b } -> { x y }` is **one connection**, not four stored edges. Membership
uses shared node-mention ranges and immutable scope-prefix snapshots, not
copied ancestor sets. Singleton endpoints carry a node ID directly.

All endpoint versions are captured after the whole edge statement executes.
Thus both ends of `subgraph s { a } -> subgraph s { b }` contain `a` and `b`.
An earlier statement's snapshot does not change when `s` reopens later.

To consume individual edges without keeping them all:

```zig
var edges = try ir.edgeIterator(.{});
defer edges.deinit();
while (try edges.next()) |edge|
    std.debug.print("{f} {s} {f}\n", .{
        try ir.nodeName(edge.from), edge.operator.lexeme(), try ir.nodeName(edge.to),
    });
```

You can stop early with `break`; `deinit()` releases scratch without visiting
the remaining pairs. Keep the IR alive, unmoved and immutable while iterating.
Do not copy a live iterator. Each `next()` returns an edge value, `null` on
exhaustion, or a typed error. An error is terminal: subsequent calls return
that same error, not `null`. Already consumed edges cannot be retracted; a
consumer that needs all-or-nothing publication must stage its own result or
use `materialize`.

Connections are visited forward, and endpoint members follow first-mention
order. Streaming and materialization share this traversal and deduplication.
Non-strict graphs retain parallel occurrences; strict directed pairs are
ordered, strict undirected pairs are unordered. A strict edge keeps the first
connection's orientation and provenance. Ports do not change edge identity.
**All** written contributions remain in `ir.connections`. Use `edgeAttribute`
to resolve a value across them. Iteration/materialization still produce topology
records, not copied per-edge attribute tables.

If you need to retain the entire expanded edge array instead:

```zig
var graph = try ir.materialize(.{});
defer graph.deinit();
for (graph.edges) |edge| {
    // edge.from / edge.to are IDs in ir.nodes.
}
```

Materialization uses a collision-checked pair map for strict graphs, indexing
its output rather than retaining a second edge list. Neither expansion path
runs a whole-graph query for every emitted edge.

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

Lowering, streaming and materialization use the supplied allocator. Name access, `findNode`, `contains`,
`scopeMembership`, and `hasEdge` allocate nothing. Pair queries currently scan
symbolic connections; membership uses per-node postings and shared intervals.
This is not a prebuilt adjacency index. Materialization needs memory
proportional to its output, plus deduplication scratch for strict graphs.

Effective node/graph values use immutable balanced maps referencing written
attributes. Creation snapshots share map branches; there is no full default-table
copy per node or descendant scope. Updating a key retains O(log K) map cells
for K distinct keys in that map, plus bounded rotation cells. Reopening a scope
after its parent's defaults change reapplies that scope's local overrides.
Attribute-free input allocates no attribute-state storage. On the measured
64-bit build the node record remains 24 bytes: its state handle uses existing
padding. Layout on another target follows that target's alignment rules.

Node/scope queries perform logical key lookup followed by O(log K) map lookup.
Non-strict edge queries inspect their own connection's list and creation map;
strict queries scan symbolic connections and membership, retaining no expanded
pairs. All probes, comparisons and map/traversal steps are work-limited.
Repeated per-edge queries can therefore cost edges × connections: this is
**not** a bulk attribute-export index. A forward-pass materializer that folds
all effective attributes across all edges remains future work.

All-attribute iteration scans the interned key catalog (including skipping other
object kinds). Node/scope iteration performs a map lookup per relevant key.
Non-strict edges search their own written list per key, then their creation map.
Strict-edge iteration scans symbolic contributions/membership once and merges
explicit writes with O(log K) winner-table comparisons for K edge keys, then
looks up inherited defaults for keys with no explicit winner. It does not rerun
a graph-wide query per key, but enumerating attributes separately for every
strict edge still revisits connections per edge. Formatting keys/values follows
ordinary writer semantics, outside iterator work accounting.

Streaming allocates scratch lazily. Non-strict singleton-to-singleton iteration
allocates nothing. Set endpoints reuse two member buffers and a `u32` mark per
IR node for deduplicating mentions. These buffers grow to the largest endpoints
visited, not to their Cartesian product. Strict streaming additionally retains
compact pair keys and a hash table proportional to unique edges already
emitted: it is **not** constant-memory. Output consumed by the caller is not
part of the iterator's allocation limit.

Finite defaults are defined by `dot.ir.Limits`:

| Limit | Default |
| --- | ---: |
| Unique nodes | 1,000,000 |
| Written scopes, including root | 100,000 |
| Node mentions | 4,000,000 |
| Symbolic connections | 2,000,000 |
| Raw attributes, including assignments | 2,000,000 |
| Persistent attribute-map cells | 8,000,000 |
| Edges emitted or materialized | 1,000,000 |
| Candidate pair visits during expansion | 4,000,000 |
| Accounted work per operation | 100,000,000 |
| Peak live requested allocation bytes per operation | 256 MiB |

Set a compile-time baseline with `Lowering(.{ .limits = ... })`, or pass
`.limits` at lowering. `findNodeWith`, `writeNodeNameWith`, `hasEdgeWith`, `edgeIterator`, and `materialize` accept
operation-specific `.limits` and `.cancellation`. There is no unlimited-by-zero
special case. Counts/indices are `u32`, pair/work totals are `u64`; byte limits
use the allocator's `usize` domain. Candidate products use checked arithmetic.
`nodeAttributeWith`, `scopeAttributeWith` and `edgeAttributeWith` accept the
same options. `max_attribute_states` bounds retained map cells; exhausting it
returns `AttributeStateLimit`, with no incomplete IR published.

Iterator limits accumulate across all `next()` calls; they do not reset per
edge. Pair visits include strict duplicates, while `max_edges` counts emitted
edges. Streaming can consume a small prefix of a product larger than its pair
allowance; attempting to visit the next pair beyond the allowance returns
`PairLimit`. Materialization, which promises a whole result, rejects an
over-budget connection product before allocating its expanded output.

For `dot.ir.parse`, `.dot` supplies ordinary default-profile `CheckOptions`
(parse/validation resources); `.lowering` supplies the IR operation options.
IR limits/cancellation apply to lowering only, not to DOT parsing/validation
or a combined peak across both stages. The temporary Document overlaps IR
construction before it is released. There is no shared budget or metered
session in this convenience call. Use explicit profiles/lowering when those
stages need different policies or source encodings.

Limits or cancellation return typed errors, **never** `false`, absence, or a
truncated graph presented as complete. One-shot failure frees operation-owned
storage; an iterator must be `deinit()`ed on failure or early exit too.
Work limits count table probes, comparisons and traversal work; they are not
wall-clock deadlines. Cancellation is cooperative. Existing trusted-name
primitives are charged by their byte lengths and polled around each call;
allocation, copying during growth, and an individual name operation are not
interruptible. An iterator polls during endpoint traversal, pair visits and
deduplication, including when one `next()` skips many duplicates. A call may
need to enumerate whole endpoint memberships before yielding an edge. Pull
iteration allows stopping between edges, but is **not** a fixed-work-per-call
metered session with replenishable credits. None of this changes the parser's
existing metering or cancellation guarantees.

`retainedBytes()` reports retained allocation payload including spare capacity.
`peak_bytes` includes temporary scratch and overlapping growth buffers, but
excludes source/Document storage, allocator metadata and process RSS. A
materialization peak excludes the already-retained IR. `edges.peakBytes()`
reports the corresponding iterator scratch peak. Arena allocators may
retain freed blocks or reserve extra chunk capacity; use a bounded backing
allocator when that physical capacity must have a hard cap.

UTF-8 is the default. To lower native Documents, enable the corresponding
readers with `Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } })`.
The Document supplies the actual encoding and original byte ranges. Unused
native readers remain compiled out.
ASCII-admitted Documents are also readable by the UTF-8 configuration. Native
logical-name/value decoding can return `InvalidIdentifier` if the accepting
parser left encoding validation off and a name or attribute value contains
malformed code units. Native values are checked while lowering, before exposing
their formatters; byte-profile values preserve their raw bytes.

## Verification

```sh
zig build test-ir
zig build test-ir -Doptimize=ReleaseSafe
zig build bench-ir -Doptimize=ReleaseFast
```

The benchmark reports lowering separately from parsing, materialization and
streaming, including strict deduplication and a 1,000-edge prefix of a
50,000 × 50,000 endpoint product. It reports retained/requested peak bytes and
arena capacity separately. This is the first
production topology baseline, not a comparison with a previously shipped IR.
Recorded numbers are in [Performance](PERFORMANCE.md#document-to-ir-topology-unreleased-2026-10-21).

The same command also reports attribute-bearing lowering and direct query costs,
including shared defaults, repeated updates, reopened/deep scopes and a symbolic
product. Bulk attribute folding, port resolution, event-based lowering, partial
IR results, fixed-storage IR construction and resumable IR operations remain
later work.
