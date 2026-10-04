# Reading a parsed graph

A successful parse gives you a `dot.Document`. It is a faithful record of what
the file says, in the order it says it. This page shows how to read each part.

All the reading functions are cheap and allocate nothing. They return small
values that point into your source text.

## The document header

| Field | Meaning |
| --- | --- |
| `document.kind` | `.digraph` for `digraph`, `.undigraph` for `graph` |
| `document.strict` | `true` if the file starts with `strict` |
| `document.name` | The graph's name as a range, or `null` if it has none |
| `document.statementCount()` | Number of statements, including those inside subgraphs |

Why `undigraph`? In this library "graph" means any graph, directed or not. So
the undirected kind needs its own name.

## Names: spelling versus value

Every name and value in the document is a *range*: a start offset and a length
in your source. There are two ways to turn a range into text:

- `document.text(range)` returns the exact spelling, including quotes.
- `document.decodeIdentifier(range, &buffer)` returns the actual value.
  `document.writeIdentifier(range, writer)` writes the value without a buffer.

| Written | `text` | Decoded value |
| --- | --- | --- |
| `sensor` | `sensor` | `sensor` |
| `"two words"` | `"two words"` | `two words` |
| `"sen" + "sor"` | `"sen" + "sor"` | `sensor` |
| `"say \"hi\""` | `"say \"hi\""` | `say "hi"` |
| `-01.50` | `-01.50` | `-01.50` (numbers stay text) |
| `<<b>bold</b>>` | `<<b>bold</b>>` | `<b>bold</b>` (outer brackets removed) |
| `東京` | `東京` | `東京` (bytes kept as they are) |

Decoding only undoes DOT's quoting. It does not turn `\n` into a newline,
expand HTML entities, or convert numbers. It also doesn't check that text is
valid UTF-8. That is an optional check in [settings](POLICIES.md#optional-checks).

If you need the decoded size first,
`try dot.identifier.decodedLen(document.text(range))` gives it.

## Statements

`document.statements()` visits every statement in the order it was written.
Each one is a tagged union. You switch on its kind:

| You wrote | Kind | What it holds |
| --- | --- | --- |
| `a;` or `a [color=red];` | `.node` | `reference` (the node) and `attributes` |
| `a -> b;` | `.edge` | `left`, `operator`, `right`, `attributes` |
| `a -> b -> c;` | `.edge_chain` | `first` (the first edge) and the rest of the chain |
| `subgraph s { ... }` or `{ ... }` | `.subgraph` | the subgraph's id |
| `rankdir = LR;` | `.assignment` | `key` and `value` |
| `node [shape=box];` | `.attribute_statement` | `target` (`.graph`, `.node` or `.edge`) and `attributes` |

Statements inside a subgraph are in the same list. They come right after the
subgraph's own statement, so a simple loop never misses nested content. To
know which subgraph a statement is in, see [Subgraphs](#subgraphs).

## Nodes and ports

A node is stored as a small `NodeReference`. Ask the document for its parts:

```zig
const view = document.nodeReference(node.reference).?;
const name = document.text(view.identifier);
if (view.port) |port| {
    // `a:out` has port.first = "out"; `a:out:n` also has port.second = "n".
    _ = port.first;
    _ = port.second;
}
```

The parser records the port text only. It doesn't decide whether `n` is a
named port or a compass direction, because that depends on how the node is
defined elsewhere.

## Edges

`document.edgeIterator()` visits every edge in the file, in source order. A
chain `a -> b -> c` gives two edges: `a -> b`, then `b -> c`.

Each edge end is an `Endpoint`, which is either a node or a subgraph:

```zig
var edges = document.edgeIterator();
while (edges.next()) |edge| {
    switch (edge.right) {
        .node => |reference| {
            const node = document.nodeReference(reference).?;
            _ = node.identifier;
        },
        .subgraph => |id| {
            // `a -> { b c }`: the right end is a whole subgraph.
            const scope = document.scope(id).?;
            _ = scope;
        },
    }
    _ = edge.operator; // .directed (->) or .undirected (--)
    _ = edge.attributes; // shared by every edge of a chain
}
```

`a -> { b c }` is kept as one edge to a subgraph. It is **not** expanded into
`a -> b` and `a -> c`. You can expand it yourself by visiting the subgraph's
nodes (see below).

If you are walking statements and meet an `.edge_chain`, use
`document.edgeLinkCount(chain)` to count the edges after the first, and
`document.edgeLinks(chain)` to visit them.

## Attributes

Nodes, edges and attribute statements carry an `AttributeRange`. Turn it into
a list of key/value pairs with `attributeSlice`:

```zig
for (document.attributeSlice(node.attributes).?) |attribute| {
    const key = document.text(attribute.key);
    _ = key;
    try document.writeIdentifier(attribute.value, writer);
}
```

- Pairs keep their written order.
- Duplicates are kept. `[color=red, color=blue]` gives two pairs. Deciding
  which one wins is up to you.
- Several lists on one statement, like `a [x=1][y=2]`, become one list.
- Defaults are **not** applied. `node [shape=box]` is an
  `.attribute_statement`; nodes after it do not get a `shape` pair.

The [attributes example](../examples/attributes.zig) prints every pair in a
file.

## Subgraphs

Each subgraph written in the file gets its own id, a `ScopeId`. The whole
document is the *root* scope, `ScopeId.root`.

```zig
var scopes = document.subgraphs(); // every subgraph, in source order
while (scopes.next()) |scope| {
    const name = if (scope.name()) |range| document.text(range) else "(no name)";
    const parent = scope.parent().?; // the root has no parent
    _ = name;
    _ = parent;

    var edges = scope.edges(.direct); // edges written directly inside it
    while (edges.next()) |edge| _ = edge;
}
```

A scope can list four things, either `.direct` (only what is written directly
inside it) or `.recursive` (also what is inside nested subgraphs):

| Method | Lists |
| --- | --- |
| `scope.statements(mode)` | statements |
| `scope.subgraphs(mode)` | child subgraphs |
| `scope.edges(mode)` | edges |
| `scope.nodeReferences(mode)` | every place a node is mentioned |

Use `document.scope(id)` to look up a scope by id, and
`document.scope(.root).?` for the whole document.

To know which scope each statement is in while walking the full list, call
`nextScoped()` instead of `next()`:

```zig
var statements = document.statements();
while (statements.nextScoped()) |item| {
    // item.statement is the statement; item.scope is the scope it is in.
    _ = item;
}
```

Keep in mind:

- Two subgraphs with the same name get two different ids. They are not merged.
- `nodeReferences` lists every mention, so `{ a -> b; a }` mentions `a`
  twice. It is not a list of unique nodes.
- `cluster_` names have no special meaning to the parser.

See the [subgraphs example](../examples/subgraphs.zig) and the
[subgraph endpoints example](../examples/subgraph_endpoints.zig).

## What you work out yourself

The document records the file. These questions need decisions that depend on
your program, so they are left to you:

- **Which nodes exist?** Decode node names and remove duplicates.
- **What are a node's final attributes?** Apply `node [...]` defaults and
  subgraph scoping in the order you need.
- **Which node pairs does `a -> { b c }` connect?** Walk the subgraph's
  `nodeReferences(.recursive)`.
- **What does a port mean?** Look at the node's shape or label.

## Lifetimes

- Keep the source text alive and unchanged while you use the document or any
  view from it.
- If you reuse the document's storage for another parse, earlier documents and
  views from that storage become invalid.
- A finished document is read-only. Several threads may read it at once.

[Memory](MEMORY.md) covers ownership in detail.

## Examples

- [identifiers.zig](../examples/identifiers.zig): spelling versus decoded value,
  joined strings, numbers and non-ASCII names
- [attributes.zig](../examples/attributes.zig): attribute lists, defaults and
  assignments
- [edge_chains.zig](../examples/edge_chains.zig): chains and the edge iterator
- [ports.zig](../examples/ports.zig): reading ports
- [subgraphs.zig](../examples/subgraphs.zig): scopes, direct and recursive views,
  and `nextScoped()`
- [subgraph_endpoints.zig](../examples/subgraph_endpoints.zig): edges whose end
  is a subgraph

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.
