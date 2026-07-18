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

Retained documents cost 26 bytes per statement on 64-bit targets
(`StatementId` 8 B, `NodeStatement` 8 B, `EdgeStatement` 28 B); positions
are stored as compact 8-byte ranges and full line/column locations are
derived on demand. Measured throughput and arena footprints live in
[BASELINES.md](BASELINES.md).

Runnable versions of all three strategies are in
[../examples/](../examples/).
