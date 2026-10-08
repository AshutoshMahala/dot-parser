# Getting started

This guide takes you from an empty project to a program that parses a DOT
file, reports problems, and reads the result.

## 1. Add the package

You need Zig 0.16.0.

```sh
zig fetch --save git+https://github.com/AshutoshMahala/dot-parser#v0.4.0
```

This installs the latest release, 0.4.0. The docs follow the `main` branch:
anything marked **Unreleased** isn't in 0.4.0 yet. To use those features, use
`#main` instead of `#v0.4.0`.

In your `build.zig`, import the `dot_parser` module into your program:

```zig
const dot_parser = b.dependency("dot_parser", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("dot_parser", dot_parser.module("dot_parser"));
```

The package also provides a second, independent module, `markup_parser`, for
HTML-like markup. You only need it to check labels like `label=<<b>Hi</b>>`
([Checking HTML-like labels](LABELS.md)), or to parse markup on its own
([Parsing markup on its own](MARKUP.md)).

## 2. Parse and check

```zig
const dot = @import("dot_parser");

var bag = dot.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();

var result = dot.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);

if (result.documentValid()) {
    const document = result.document.?;
    // ... read the document ...
}
```

Three things are going on here:

- **The bag** collects problems. The library never prints anything or returns
  error messages as strings. It hands each problem (a *diagnostic*) to the
  bag, and you decide what to do with them.
- **`parseAndValidate`** does two steps. *Parsing* checks that the text
  follows DOT's grammar and builds the document. *Validation* then checks
  rules that need the whole document, such as "a `digraph` uses `->`, not
  `--`".
- **`documentValid()`** is true when both steps succeeded. This is the one
  check most programs need.

`source` is a `[]const u8` with your DOT text. The library doesn't read files;
load the bytes however you like. **Keep `source` alive and unchanged while you
use the document**, because the document points into it rather than copying
it.

## 3. Show the problems

When `documentValid()` is false, the bag explains why. The built-in console
renderer prints each problem with the source line underneath:

```zig
for (bag.items(), 1..) |problem, number| {
    try dot.console.renderBoxed(problem, number, .{
        .source = source,
        .source_name = "graph.dot",
    }, writer);
}
```

For `digraph { a -- b }` this prints:

```text
┌─ Error 1: edge operator does not match the graph kind
│ graph.dot:1:13
│
│ 1 │ digraph { a -- b }
│   │ ───┬───     ^^ expected '->', found '--'
│   │    └──── the document is directed because of this keyword
│
│ Hint: change '--' to '->', or declare the document with 'graph'
│ Fix: replace '--' with '->' (one possible repair)
└─ E1 ─ [dot_parser:E.Validation.Operator.002]
```

You can also read each diagnostic's fields yourself (its code, location and
suggested fix) to build your own output. See
[Errors and diagnostics](ERRORS.md).

## 4. Read the document

The document holds the statements in the order they were written. Each
statement is one of six kinds:

```zig
var statements = document.statements();
while (statements.next()) |statement| switch (statement) {
    .node => |node| {
        const name = document.nodeReference(node.reference).?.identifier;
        std.debug.print("node {s}\n", .{document.text(name)});
    },
    .edge => |edge| std.debug.print("edge using {s}\n", .{edge.operator.lexeme()}),
    .edge_chain => |chain| std.debug.print("chain of {d} edges\n", .{document.edgeLinkCount(chain) + 1}),
    .subgraph => |id| std.debug.print("subgraph #{d}\n", .{@intFromEnum(id)}),
    .assignment => |assignment| std.debug.print("{s} = {s}\n", .{
        document.text(assignment.key), document.text(assignment.value),
    }),
    .attribute_statement => |defaults| std.debug.print("{s} defaults\n", .{@tagName(defaults.target)}),
};
```

Names and values are stored as *ranges*: a start offset and a length inside
your source. `document.text(range)` returns those bytes exactly as written.

If you mostly care about edges, `document.edgeIterator()` is simpler. It
visits every edge, including each step of a chain like `a -> b -> c`:

```zig
var edges = document.edgeIterator();
while (edges.next()) |edge| {
    // edge.left and edge.right are each a node or a subgraph.
    if (edge.left == .node and edge.right == .node) {
        const from = document.nodeReference(edge.left.node).?.identifier;
        const to = document.nodeReference(edge.right.node).?.identifier;
        std.debug.print("{s} -> {s}\n", .{ document.text(from), document.text(to) });
    }
}
```

## 5. Get the real value of a name

`document.text` gives you the spelling, quotes and all. DOT lets you write the
same name in several ways, for example `sensor`, `"sensor"`, or
`"sen" + "sor"`. To get the actual value, decode it:

```zig
var buffer: [256]u8 = undefined;
const value = try document.decodeIdentifier(range, &buffer);
// `"sen" + "sor"` gives `sensor`
```

Or write it straight to a writer, with no buffer:
`try document.writeIdentifier(range, writer)`.

## Examples

- [quick_start.zig](../examples/quick_start.zig): the program from the README:
  parse, show problems, list edges
- [parse_undigraph.zig](../examples/parse_undigraph.zig): parse, validate and
  print every kind of statement
- [diagnostics_demo.zig](../examples/diagnostics_demo.zig): print problems with
  the console renderer, with color when the terminal supports it

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.

## Where to go next

- [Reading a parsed graph](READING_DOCUMENTS.md): attributes, ports,
  subgraphs, and the edge iterator in detail.
- [Errors and diagnostics](ERRORS.md): what each result means, and how to
  apply suggested fixes.
- [Memory](MEMORY.md): arenas, fixed buffers, and parsing with no allocator.
- [Settings](POLICIES.md): lenient parsing, extra checks, and limits for
  untrusted input.
- [README examples table](../README.md#examples): every runnable example and
  what it shows.
