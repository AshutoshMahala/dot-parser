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
| Diagnostic bag / sink | Caller | Caller-defined | Depends on the bag's storage (a `FixedDiagnosticBag` is a plain value) |

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
const parsed = dot.parseBorrowedIn(source, storage.storage(), bag.sink(), .{});
```

`FixedParseResult` deliberately has **no** `deinit` — the storage is
yours. When a pool is too small the parse reports
`storage_failure: .pool_exhausted` with a diagnostic naming the exhausted
pool and its capacity (see [OUTCOMES.md](OUTCOMES.md)).

## Costs

The equal node/edge benchmark mix now costs 34 bytes per statement on the native
64-bit target (`StatementId` 8 B, `NodeStatement` 16 B, `EdgeStatement` 36 B);
node and edge records each include an 8-byte attribute-pool range. Positions
are stored as compact 8-byte ranges and full line/column locations are
derived on demand. Measured throughput and arena footprints live in
[BASELINES.md](BASELINES.md).

## Attributes and memory

The document has six decomposed pools: `order`, `nodes`, `edges`,
`attributes`, `assignments`, and `attribute_statements`. Freeing an owned
document remains a fixed number of pool releases, not a per-element walk.
The three new pools allocate nothing when unused and unhinted. Node/edge
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
