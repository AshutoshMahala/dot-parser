# Ownership and memory

The library never allocates behind your back and never copies your source.
Every byte the parser retains is either a range into *your* source buffer
or lives in storage *you* chose. This page states who owns what, and how
each memory strategy releases it.

## The ownership table

| Value | Owner | Required lifetime | Release |
| --- | --- | --- | --- |
| Source bytes | Caller | Must outlive every use of the `Document` and of diagnostics' spans | Caller-defined |
| Document pools (`parseBorrowed`, `parseAndValidate`) | The returned result | Until `result.deinit(allocator)` | `deinit` with the same allocator |
| Document pools (`parseBorrowedIn`) | Caller (your slices / `FixedDocumentStorage`) | While the document is used | Reuse or discard the storage — there is nothing to free |
| Nesting scratch | Caller storage, or the explicit scratch/document allocator | During parsing; fixed sessions borrow it across yields and until discarded/reinitialized | Allocator-backed one-shot frees it before return; fixed storage is reused, not freed |
| Diagnostic bag / sink | Caller | Caller-defined | Depends on the bag's storage (a `FixedDiagnosticBag` is a plain value) |
| Fixed session and hook contexts | Caller | Throughout active parsing/yields | `session.deinit()` cleans up unfinished work; frees no pools |

Two rules fall out of this:

- **A `Document` is a non-owning view.** It has no `deinit` of its own —
  only `ParseResult`/`CheckResult.deinit` free allocator-backed pools, and
  fixed-storage documents never meet a free. Copying the struct is shallow
  and safe; it does not duplicate or transfer ownership.
- **Spans and ranges index the source.** `document.text(range)` and
  diagnostic spans slice the source buffer you passed in. If the source is
  freed or mutated while a document or a retained diagnostic is in use,
  those slices are dangling. (Rendering excerpts with
  `console.RenderOptions.source` has the same requirement.)

## The three memory strategies

**General-purpose allocator** — simplest; `deinit` returns the memory:

```zig
var checked = dot.parseAndValidate(gpa, source, bag.sink(), .{});
defer checked.deinit(gpa);
```

**Arena** — parse many documents, free all at once. `deinit` is still safe
to call, but dropping the arena releases everything anyway. Pass
`document_capacities` hints to skip pool-growth churn when the document
size is known:

```zig
var checked = dot.parseAndValidate(arena.allocator(), source, bag.sink(), .{
    .parse = .{ .document_capacities = .{ .statements = 200, .nodes = 120, .edges = 80 } },
});
```

**Fixed pools** — zero allocation, embedded-friendly. Capacity is visible
at the call site and `byte_size` makes the RAM budget explicit:

```zig
var storage: dot.FixedDocumentStorage(.{ .statements = 32, .nodes = 32, .edges = 16 }) = .{};
// @TypeOf(storage).byte_size bytes, known at compile time.
const parsed = dot.parseBorrowedIn(source, .{ .document = storage.storage() }, bag.sink(), .{});
```

`FixedParseResult` deliberately has **no** `deinit` — the storage is
yours. When a pool is too small the parse reports
`storage_failure: .pool_exhausted` with a diagnostic naming the exhausted
pool and its capacity (see [OUTCOMES.md](OUTCOMES.md)).

## Fixed-session lifetime

Fixed sessions borrow the same pools as `parseBorrowedIn`. They retain lexical,
grammar and dispatch continuation plus a cached terminal result, but no extra
source or output copies. Source, pools, nesting scratch and hook contexts must survive yields.
Do not inspect or mutate pools while active. Moving a session between calls is
supported; duplicating a live session or reentering it is not.

`cancel()`/`deinit()` terminate unfinished parsing without freeing caller storage.
`reset` cancels unfinished work and reuses those pools, invalidating prior
document views. Aborted storage is logically discarded, not wiped. See
[bounded execution](EXECUTION.md) for the API and detailed lifecycle.

## Costs

The equal node/edge benchmark mix now costs 34 bytes per statement on the native
64-bit target (`StatementId` 8 B, `NodeStatement` 16 B, `EdgeStatement` 36 B);
node and edge records each include an 8-byte attribute-pool range. Positions
are stored as compact 8-byte ranges and full line/column locations are
derived on demand. Measured throughput and arena footprints live in
[BASELINES.md](BASELINES.md).

## Attributes and memory

The document has ten decomposed pools: `order`, `nodes`, `edges`,
`edge_chains`, `edge_links`, `ported_references`, `subgraph_records`, `attributes`,
`assignments`, and `attribute_statements`. Freeing an owned
document remains a fixed number of pool releases, not a per-element walk.
Unused, unhinted pools allocate nothing. Node/edge
records still pay for their compact attribute range in the current profile;
compile-time syntax removal is not implemented yet.

An `Attribute` is two raw source ranges (16 bytes). `Assignment` has the same
layout in a separate statement pool. An `AttributeStatement` retains its
target, keyword range, and attribute range (20 bytes on the native target).
An `AttributeRange` contains element indices, not source byte offsets.
`document.attributeSlice(statement.attributes)` returns the ordered pairs,
or null for an out-of-bounds range. Identifier decoding works on each key/value.

```zig
var storage: dot.FixedDocumentStorage(.{
    .statements = 4, .nodes = 1, .edges = 1,
    .assignments = 1, .attribute_statements = 1, .attributes = 5,
}) = .{};
```

`statements` covers every statement kind. `attributes` counts pairs in bracket
lists (including graph/node/edge statements), not standalone assignments.
`assignments` and `attribute_statements` count their respective statements.
These same fields are available as allocator capacity hints. Fixed capacities
are hard bounds; allocator hints are initial reservations, not limits.

`max_attributes` is a separate parse limit covering **all** key/value pairs,
including standalone assignments. It is enforced when a key is accepted, before
its value is parsed, so an exhausted limit makes no claim about the remaining
syntax. Empty groups use no pair capacity but their owner still counts as a
statement. Neither this limit nor pool capacity bounds source scan length.

Pairs stream into the destination attribute pool while parsing a statement.
No temporary growable list is built for each statement. If a later pair or
closing bracket fails, the whole parse aborts and exposes no partial document.
Adjacent groups are flattened; duplicate keys and order are retained. Default
resolution and effective-value maps belong in a separate consumer/pass.

See [the runnable example](../examples/attributes.zig).

## Edge chains and memory

A single edge still occupies 36 bytes on the native target. A chain uses one
44-byte `EdgeChainStatement` plus one 20-byte `EdgeLink` for each continuation
after its first edge, and one 8-byte order entry. A chain of N edges therefore
retains `52 + 20 * (N - 1)` bytes, excluding port records, attributes and borrowed source.
No endpoint strings or attribute pairs are copied.

`chain.first` stores the first edge, including the whole chain's attribute range.
`document.edgeLinkSlice(chain.links)` returns checked, ordered continuations:
each stores its operator, operator source range, and right endpoint. Its left
endpoint is the preceding right endpoint.

```zig
var storage: dot.FixedDocumentStorage(.{
    .statements = 1, .edge_chains = 1, .edge_links = 2, .attributes = 1,
}) = .{}; // Enough for a -> b -> c -> d [color=red].
```

The `edges` pool contains only single-edge statements; `edge_chains` contains
chain owners. `document.statements()` preserves their written grouping.
For engine adapters, `document.edgeIterator()` visits both ordinary edges and
chain links in source order as by-value `EdgeStatement` views, sharing each
chain's attribute range. It allocates nothing and does not materialize an
expanded graph. Iteration and validation are separate, unbudgeted operations.

Continuation events stream directly into the final link pool before their owner
is committed. Yield retains staged data; cancel or failure discards it. The two
new pool capacities default to zero, so fixed callers must reserve them to
accept chains. Existing single-edge inputs need no extra pool space. Unused
pools still add fixed metadata to document/builder/session structs; compile-time
feature removal is not implemented.

See [the runnable chain example](../examples/edge_chains.zig).

## Node references and ports

`NodeStatement.reference`, edge `left`/`right`, and continuation `right` are
8-byte `NodeReference` values. Call `document.nodeReference(reference)` to get
a checked `NodeReferenceView` containing the base `identifier: Range` and
optional `port: PortSyntax`. Pass those ranges to the existing text/decoding
helpers. The accessor returns null for an out-of-bounds reference; handles are
document-local, not portable IDs, and must not be used after pool reuse.

A bare reference holds its source range inline. A qualified reference holds an
index into `document.ported_references`; each occurrence there costs 28 bytes
(base range, first suffix range, optional second range). A zero raw length marks
the pooled form, without stealing source-offset bits. Even `""` has a nonzero
raw spelling length. The normal 4 GiB retained-source domain is unchanged.
No identifiers are copied or interned. A qualified chain middle uses one pool
record, reused for its incoming and outgoing pairwise edges.

Fixed storage must reserve `.ported_references` for the number of qualified
**written occurrences**, including node statements. Repeated spelling occupies
separate records. Its default capacity is zero; bare inputs need no slots.
Allocator callers can use the same field as a reservation hint. Every completed
suffix streams directly into that pool; failure/cancellation discards all staged
records, and no partial document is returned.

The selected inline-or-pooled representation costs `8R + 28P` bytes for R stored
references and P qualified occurrences, excluding other fields/metadata. The
alternative 12-byte always-expanded reference plus a 20-byte suffix pool would
cost `12R + 20P`: equal at 50% qualification, with the selected representation
4 bytes/reference cheaper at 0% and 4 bytes/reference dearer at 100%. Fixed-pool
RAM uses reserved capacities, not actual occupancy. Node/edge/link record sizes
are unchanged, but pool metadata and parser continuation state have fixed costs;
this is not compile-time feature removal. See [current layouts](BASELINES.md).

## Subgraphs and nesting scratch

Each subgraph retains a 32-byte record plus one 8-byte global order entry:
**40 bytes per occurrence**, excluding statements inside it and their normal
payloads. The record holds its parent ID, optional raw name, whole-source range,
and a contiguous interval in the global statement order. Descendants are not
copied into ancestors; no scope tag is added to existing node/edge records.
The new pool still adds fixed document/builder/session metadata.

A temporary frame saves the enclosing opening-brace span for diagnostics:
32 bytes on the measured native 64-bit target. Active scratch is proportional
to maximum nesting depth D, not total subgraphs G. One frame handles any number
of non-nested siblings. Fixed RAM is reserved capacity: `40 * G_capacity`
for empty subgraphs and order, plus `32 * D_capacity` scratch, excluding source,
session/metadata, diagnostics and other statement pools. Use `byte_size` and
`@sizeOf` on your target rather than assuming native frame sizes.

```zig
var pools: dot.FixedDocumentStorage(.{ .statements = 20, .subgraphs = 20 }) = .{};
var scratch: dot.FixedParseScratch(.{ .nesting = 4 }) = .{};
const parsed = dot.parseBorrowedIn(source, .{
    .document = pools.storage(), .scratch = scratch.storage(),
}, bag.sink(), .{ .max_nesting = 4 });
```

The same `ParseMemory` bundle goes to `FixedSession.init`. Scratch defaults
to zero capacity, sufficient for flat documents; it is never hidden allocation.
`subgraphs` counts retained occurrences; `nesting` counts simultaneously active
frames. `max_nesting` is a separate policy limit; root depth is zero.
Scratch/pool exhaustion is a storage failure, while exceeding the policy is
resource exhaustion. Scope occurrences also consume `max_statements`.

Allocator-backed parsing grows temporary frames only when required, doubling
capacity and reusing it for siblings. `ParseOptions.scratch_allocator` defaults
to the passed document allocator; supply a separate temporary arena to separate
lifetimes. Scratch is freed before the one-shot returns and is not referenced
by the document. Arenas may keep growth copies until reset, just like output
pools. Document capacity hints reserve output pools only, not nesting scratch.

Fixed-session termination clears active scratch length in constant time.
Reuse scratch after one-shot completion, or after discarding a session; a
session retained for reset continues borrowing its buffers. Never share buffers
between active sessions. Reusing document pools invalidates scope/statement
views; reusing scratch alone does not invalidate a completed document.

See [scope traversal and complexity](SUBGRAPHS.md).

## Identifier values

All identifier forms use the same compact raw range. Even a concatenation such
as `"sen" /* join */ + "sor"` retains one range, not a list of components or
a copied string. `document.text(range)` returns that exact spelling; the
logical value is `sensor`. Numerals remain textual: `01.00` is not converted
or normalized to `1`.

- `document.decodeIdentifier(range, output)` decodes into caller storage.
- `document.writeIdentifier(range, writer)` streams the value via `writeAll`.
- `dot.identifier.decodedLen(raw)` reports the exact required output size.
  `decodeInto(raw, output)` and `writeDecoded(raw, writer)` are also available
  directly for consumers of lexer spans.

Decoding follows the [supported lexical rules](SUPPORTED_SYNTAX.md). It
validates the supplied raw expression, does linear work without allocation,
and does not cache results. Callers needing repeated access may retain the
decoded value in memory they own. Writer output contains the actual value
bytes, not terminal-escaped presentation.

These byte-transformation helpers use local Zig errors, not the parse/validation
diagnostic sink. `InvalidIdentifier` means the range is not exactly one
supported identifier expression; `NoSpaceLeft` means the output is too small;
`OverlappingBuffers` means its written region overlaps the raw source. Buffer
decoding leaves output unchanged on every error. On success the returned slice
borrows the output buffer and may outlive the document. Streaming validates
before writing, but a writer failure can leave partial output and propagates
the writer's own error unchanged.

The source and document pools must remain unchanged while the document is in
use. A range passed to a document method must lie within that document, just
as for `document.text`. Inter-component comments lie inside a concatenated
identifier's raw range but have no separately retained trivia records.

Runnable versions of all three strategies are in
[../examples/](../examples/).
