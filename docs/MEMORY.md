# Memory

The library never allocates memory behind your back, and it never copies your
source text. You decide where every byte lives. This page shows the three ways
to give it memory, and the two rules that come with that.

Both parsers follow the same rules and offer the same three choices. The
examples here use DOT; the markup differences are in
[the markup parser](#in-the-markup-parser).

## Two rules

1. **Keep the source alive and unchanged** for as long as you use the
   document, or any diagnostic's position. The document stores positions in
   your source instead of copies of the text.
2. **A `Document` doesn't own memory.** It has no `deinit`. Free memory through
   the result that created it (`result.deinit(allocator)`), or by dropping the
   buffers you gave it. Copying a `Document` value is cheap and copies no
   data.

## Option 1: any allocator

The simplest choice. `deinit` gives the memory back.

```zig
var result = dot.parseAndValidate(gpa, source, bag.sink(), .{});
defer result.deinit(gpa);
```

## Option 2: an arena

Good when you parse many documents and free them all at once. Calling `deinit`
is still safe, but resetting the arena frees everything anyway.

There is one catch. The document's lists grow as parsing goes on, and an arena
can't reuse the space a list leaves behind when it grows. Without help, the
arena ends up holding several times the memory the document needs. To avoid
this, tell the parser the sizes up front. `measure` does a quick counting pass
and returns the exact sizes:

```zig
const measured = dot.measure(gpa, source, dot.diagnostic.discard, .{});
if (measured.capacities) |capacities| {
    var result = dot.parseAndValidate(arena.allocator(), source, bag.sink(), .{
        .parse = .{ .document_capacities = capacities },
    });
    _ = &result; // freed with the arena
}
```

`measure` keeps nothing, so its allocator is only used for temporary memory.
With size hints, the arena reserves each list once. In the main benchmark that
cuts the arena's memory from about 14 times the source size to about 3 times.

## Option 3: fixed buffers, no allocator

For embedded systems, or whenever you want memory use to be fixed and known in
advance. You declare the buffers yourself, so there is nothing to free.

```zig
var storage: dot.FixedDocumentStorage(.{
    .statements = 32,
    .nodes = 32,
    .edges = 16,
}) = .{};
var bag: dot.FixedDiagnosticBag(8) = .{};

const parsed = dot.parseBorrowedIn(source, .{ .document = storage.storage() }, bag.sink(), .{});
if (parsed.outcome == .success) {
    const document = parsed.document.?;
    const validation = dot.validate(&document, bag.sink(), .{});
    _ = validation.documentValid();
}
// Nothing to free. Reuse or drop `storage`.
```

`@TypeOf(storage).byte_size` tells you how many bytes the buffers take, at
compile time.

### What to reserve (DOT)

Each field sets how many of one kind of item the DOT buffers can hold. Fields
you leave out are zero.

| Field | Counts | Example |
| --- | --- | --- |
| `statements` | every statement, including those inside subgraphs | |
| `nodes` | node statements | `a;` |
| `edges` | single edges between two nodes | `a -> b` |
| `edge_chains` | chains between nodes | `a -> b -> c` |
| `edge_links` | each edge after the first in those chains | `a -> b -> c` needs 1 |
| `subgraphs` | every subgraph written | `{ ... }` |
| `scoped_edges` | edges or chains with a subgraph at one end | `a -> { b c }` |
| `scoped_edge_links` | each further edge in those | |
| `ported_references` | each node mention with a port | `a:out` |
| `attributes` | `key=value` pairs inside `[ ]` | `[x=1, y=2]` needs 2 |
| `assignments` | `key = value` statements | `rankdir = LR` |
| `attribute_statements` | `graph`, `node` or `edge` default statements | `node [shape=box]` |

The easiest way to pick numbers is to run `measure` (or `measureIn`, which needs
no allocator) on typical inputs and add some headroom. The
[attributes](../examples/attributes.zig), [edge chains](../examples/edge_chains.zig)
and [ports](../examples/ports.zig) examples show worked sizes.

### Subgraphs need nesting space

Parsing nested subgraphs needs a little temporary space for each level that is
open at the same time. With fixed buffers you provide it:

```zig
var pools: dot.FixedDocumentStorage(.{ .statements = 20, .subgraphs = 20 }) = .{};
var scratch: dot.FixedParseScratch(.{ .nesting = 4 }) = .{};
const parsed = dot.parseBorrowedIn(source, .{
    .document = pools.storage(),
    .scratch = scratch.storage(),
}, bag.sink(), .{});
```

`.nesting` is the deepest level you expect. The document itself is level 0,
and `{ { } }` reaches level 2. Subgraphs side by side reuse the same level, so
you need depth, not a count. With an allocator this space is taken and freed
for you during the parse.

### When a buffer is too small

The parse stops with `outcome == .storage_failure` (reason `.pool_exhausted`),
and a diagnostic names the buffer that filled up and its size. You never get a
half-filled document.

## Reusing buffers

You can parse again into the same buffers. Doing so makes any document from the
earlier parse invalid, so finish with it first. Reusing only the nesting space
doesn't affect a finished document.

## Rough sizes

A file of plain nodes and edges keeps about **34 bytes per statement** (64-bit
target), plus your source text, which is never copied. Other record sizes and
measured numbers are in [Performance](PERFORMANCE.md).

## In the markup parser

The markup parser follows the same two rules and the same three choices, with
fewer buffers to size:

```zig
var nodes: markup.FixedDocumentStorage(.{ .nodes = 16, .attributes = 32 }) = .{};
var frames: markup.FixedParseScratch(8) = .{}; // deepest element nesting
```

- `nodes` counts elements, text runs, comments and CDATA sections.
  `attributes` counts every attribute.
- `markup.measure` and `markup.measureIn` count these for a given input.
- A growable result's `parsed.retainedBytes()` reports how much it keeps.
- Each node and each attribute takes 20 bytes, and each nesting level 12 bytes,
  on the targets tested.

To check many fragments without allocating each time, reuse one
[workspace](MARKUP.md#checking-many-fragments).

## Threads

- Separate parses are independent. You can parse different files on different
  threads at the same time, each with its own buffers and bag.
- A finished document is read-only, so many threads can read it at once while
  its source and buffers stay alive.
- Don't share one bag or one set of buffers between parses that run at the
  same time.

## Examples

- [fixed_buffer.zig](../examples/fixed_buffer.zig): the whole pipeline with no
  allocator, printing the buffers' size
- [attributes.zig](../examples/attributes.zig),
  [edge_chains.zig](../examples/edge_chains.zig) and
  [ports.zig](../examples/ports.zig): fixed buffers sized for attributes, chains
  and ports
- [subgraphs.zig](../examples/subgraphs.zig): fixed buffers plus nesting space
- [markup.zig](../examples/markup.zig): markup with an allocator and
  untrusted-input limits

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.
