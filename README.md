# dot-parser

A reusable [DOT-language](https://graphviz.org/doc/info/lang.html) parser
library for Zig. It parses DOT input and exposes its structure without
performing layout and without depending on any particular graph engine.

> **Status: experimental `0.x`.** Backward compatibility is not promised and
> breaking changes are expected.

## First goal (in progress)

One narrow end-to-end vertical slice before broadening the grammar:

```dot
graph {
    a;
    b;
    a -- b;
}
```

- Exactly one anonymous root `graph` document (the source keyword `graph`
  maps to the library kind `undigraph`).
- Bare ASCII identifiers, node statements, single-edge statements,
  semicolons.
- Borrowed source spans, explicit caller memory, fixed-buffer operation.

Everything else (`digraph`, `strict`, graph names, comments, quoted/numeral/
HTML IDs, attributes, edge chains, ports, subgraphs, …) is deliberately
deferred to later vertical slices.

## Usage

```zig
const dot = @import("dot_parser");

var bag: dot.FixedDiagnosticBag(16) = .{};
var checked = dot.parseAndValidate(allocator, source, bag.sink(), .{});
defer checked.deinit(allocator);

if (checked.documentValid()) {
    const document = checked.document.?;
    var statements = document.statements();
    while (statements.next()) |statement| {
        switch (statement) {
            .node => |node| std.log.info("node {s}", .{document.text(node.identifier)}),
            .edge => |edge| std.log.info("edge {s} {s} {s}", .{
                document.text(edge.left),
                edge.operator.lexeme(),
                document.text(edge.right),
            }),
        }
    }
}
```

`parseBorrowed` and `validate` are also available as separate stages. For
fixed-memory operation, hand `parseBorrowedIn` your own pools — no
allocator, nothing grows, and capacity is visible in the declarations:

```zig
var storage: dot.FixedDocumentStorage(.{
    .statements = 32,
    .nodes = 32,
    .edges = 16,
}) = .{};
var bag: dot.FixedDiagnosticBag(8) = .{};

const parsed = dot.parseBorrowedIn(source, storage.storage(), bag.sink(), .{});
if (parsed.outcome == .success) {
    const validation = dot.validate(&parsed.document.?, bag.sink(), .{});
    _ = validation;
}
// release by reusing or discarding the storage — there is nothing to free
```

(The allocator-based calls also accept arenas and
`std.heap.FixedBufferAllocator` with `document_capacities` hints, if an
allocator fits your architecture better.)

The source bytes are borrowed: keep them alive and unchanged for as long as
the returned document is used.

## Building

Requires Zig **0.16.0** or newer.

```sh
zig build test        # unit + public integration tests
zig build examples    # build and run the examples
```

The library target has no OS, network, or filesystem dependency: it parses
caller-supplied bytes, so input can come from a file, a pipe, a socket, or
generated in memory — reading it is the application's job.

## Design documents

- [docs/architecture/PROJECT_STRUCTURE.md](docs/architecture/PROJECT_STRUCTURE.md)

## License

Licensed under either of

- MIT license ([LICENSE-MIT](LICENSE-MIT))
- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

at your option (`MIT OR Apache-2.0`).

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in this work by you shall be dual licensed as above,
without any additional terms or conditions.
